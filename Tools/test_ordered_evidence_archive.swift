import AppKit
import Foundation

private struct SeededArchiveRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

@main
struct OrderedEvidenceArchiveTestMain {
    static func main() {
        testAll720OrdersCompleteAndRewardExactlyOnce()
        testEveryPossibleWrongClickFailsButReclaimContinues()
        testDuplicateCallbacksDoNotAdvanceOrFail()
        testInterleavedSessionsIgnoreOldCallbacks()
        testPreviewMissingFadeAndCancelNeverReward()
        testOrderGeneratorNeverRepeatsFirstKind()
        testHUDContract()
        print("有序证物归档模型与 HUD 自检通过。")
    }

    private static func testAll720OrdersCompleteAndRewardExactlyOnce() {
        let orders = permutations(of: AccessoryKind.allCases)
        precondition(orders.count == 720, "6 件证物应有 720 种完整排列")
        var sessions = AccessoryScatterSessionState()

        for (orderIndex, order) in orders.enumerated() {
            let sessionID = sessions.beginSession()
            var archive = OrderedEvidenceArchive()
            guard case let .started(initial) = archive.begin(
                sessionID: sessionID,
                mode: .real,
                expectedKinds: Set(AccessoryKind.allCases),
                order: order
            ) else {
                preconditionFailure("顺序 \(orderIndex) 应可开始")
            }
            precondition(initial.completedCount == 0 && initial.nextExpectedKind == order[0])

            for (step, kind) in order.enumerated() {
                let result = archive.recordReclaimed(kind, sessionID: sessionID)
                if step == order.count - 1 {
                    guard case let .completed(snapshot) = result else {
                        preconditionFailure("顺序 \(orderIndex) 末步应完成")
                    }
                    precondition(snapshot.completedCount == 6 && snapshot.phase == .completed)
                } else {
                    guard case let .advanced(snapshot) = result else {
                        preconditionFailure("顺序 \(orderIndex) 第 \(step + 1) 步应前进")
                    }
                    precondition(snapshot.completedCount == step + 1)
                    precondition(snapshot.nextExpectedKind == order[step + 1])
                }
            }

            precondition(archive.finish(sessionID: sessionID) == .reward)
            precondition(
                archive.finish(sessionID: sessionID) == .ignored,
                "顺序 \(orderIndex) 不得二次奖励"
            )
        }
    }

    private static func testEveryPossibleWrongClickFailsButReclaimContinues() {
        let orders = permutations(of: AccessoryKind.allCases)
        var sessions = AccessoryScatterSessionState()
        var checkedWrongClicks = 0

        for order in orders {
            // At the last step only one unreclaimed item remains, so every
            // physically possible wrong click occurs in steps 0...4.
            for step in 0..<(order.count - 1) {
                for wrongKind in order[(step + 1)...] {
                    let sessionID = sessions.beginSession()
                    var archive = OrderedEvidenceArchive()
                    _ = archive.begin(
                        sessionID: sessionID,
                        mode: .real,
                        expectedKinds: Set(AccessoryKind.allCases),
                        order: order
                    )
                    for correctKind in order.prefix(step) {
                        _ = archive.recordReclaimed(correctKind, sessionID: sessionID)
                    }

                    guard case let .failed(snapshot) = archive.recordReclaimed(
                        wrongKind,
                        sessionID: sessionID
                    ) else {
                        preconditionFailure("错点必须立即结束有序挑战")
                    }
                    precondition(snapshot.phase == .failed)
                    precondition(snapshot.completedCount == step)

                    // Remaining ordinary reclaim callbacks are ignored by the
                    // challenge model, not blocked or turned into a reward.
                    for kind in order where kind != wrongKind {
                        _ = archive.recordReclaimed(kind, sessionID: sessionID)
                    }
                    precondition(archive.finish(sessionID: sessionID) == .noReward)
                    checkedWrongClicks += 1
                }
            }
        }
        precondition(checkedWrongClicks == 10_800, "应覆盖所有未回收错误选项")
    }

    private static func testDuplicateCallbacksDoNotAdvanceOrFail() {
        var sessions = AccessoryScatterSessionState()
        let sessionID = sessions.beginSession()
        let order = AccessoryKind.allCases
        var archive = OrderedEvidenceArchive()
        _ = archive.begin(
            sessionID: sessionID,
            mode: .real,
            expectedKinds: Set(order),
            order: order
        )

        for (index, kind) in order.enumerated() {
            _ = archive.recordReclaimed(kind, sessionID: sessionID)
            guard case let .duplicate(snapshot) = archive.recordReclaimed(
                kind,
                sessionID: sessionID
            ) else {
                preconditionFailure("重复回调应被合并")
            }
            precondition(snapshot.completedCount == index + 1)
        }
        precondition(archive.finish(sessionID: sessionID) == .reward)
    }

    private static func testInterleavedSessionsIgnoreOldCallbacks() {
        var sessions = AccessoryScatterSessionState()
        let oldSessionID = sessions.beginSession()
        var archive = OrderedEvidenceArchive()
        _ = archive.begin(
            sessionID: oldSessionID,
            mode: .real,
            expectedKinds: Set(AccessoryKind.allCases),
            order: AccessoryKind.allCases
        )
        _ = archive.recordReclaimed(.attorneyBadge, sessionID: oldSessionID)

        let newSessionID = sessions.beginSession()
        let newOrder = Array(AccessoryKind.allCases.reversed())
        _ = archive.begin(
            sessionID: newSessionID,
            mode: .real,
            expectedKinds: Set(AccessoryKind.allCases),
            order: newOrder
        )
        precondition(archive.activeSessionID == newSessionID)
        precondition(
            archive.recordReclaimed(.caseFile, sessionID: oldSessionID) == .ignored
        )
        precondition(archive.finish(sessionID: oldSessionID) == .ignored)
        precondition(!archive.cancel(sessionID: oldSessionID))

        for kind in newOrder {
            _ = archive.recordReclaimed(kind, sessionID: newSessionID)
        }
        precondition(archive.finish(sessionID: newSessionID) == .reward)
    }

    private static func testPreviewMissingFadeAndCancelNeverReward() {
        var sessions = AccessoryScatterSessionState()
        let allKinds = AccessoryKind.allCases

        let previewID = sessions.beginSession()
        var archive = OrderedEvidenceArchive()
        precondition(
            archive.begin(
                sessionID: previewID,
                mode: .preview,
                expectedKinds: Set(allKinds),
                order: allKinds
            ) == .ineligible
        )
        for kind in allKinds {
            precondition(archive.recordReclaimed(kind, sessionID: previewID) == .ignored)
        }
        precondition(archive.finish(sessionID: previewID) == .ignored)

        let missingID = sessions.beginSession()
        let fiveKinds = Set(allKinds.prefix(5))
        precondition(
            archive.begin(
                sessionID: missingID,
                mode: .real,
                expectedKinds: fiveKinds,
                order: Array(allKinds.prefix(5))
            ) == .ineligible
        )
        precondition(archive.finish(sessionID: missingID) == .ignored)

        let malformedID = sessions.beginSession()
        let malformedOrder = Array(repeating: AccessoryKind.attorneyBadge, count: 6)
        precondition(
            archive.begin(
                sessionID: malformedID,
                mode: .real,
                expectedKinds: Set(allKinds),
                order: malformedOrder
            ) == .ineligible
        )

        let fadedID = sessions.beginSession()
        _ = archive.begin(
            sessionID: fadedID,
            mode: .real,
            expectedKinds: Set(allKinds),
            order: allKinds
        )
        for kind in allKinds.prefix(5) {
            _ = archive.recordReclaimed(kind, sessionID: fadedID)
        }
        precondition(archive.finish(sessionID: fadedID) == .noReward)
        precondition(archive.finish(sessionID: fadedID) == .ignored)

        let cancelledID = sessions.beginSession()
        _ = archive.begin(
            sessionID: cancelledID,
            mode: .real,
            expectedKinds: Set(allKinds),
            order: allKinds
        )
        _ = archive.recordReclaimed(.attorneyBadge, sessionID: cancelledID)
        precondition(archive.cancel(sessionID: cancelledID))
        precondition(!archive.cancel(sessionID: cancelledID))
        precondition(archive.finish(sessionID: cancelledID) == .ignored)
    }

    private static func testOrderGeneratorNeverRepeatsFirstKind() {
        for seed in 1...100 {
            var generator = OrderedEvidenceArchiveOrderGenerator(
                randomNumberGenerator: SeededArchiveRandomNumberGenerator(
                    seed: UInt64(seed)
                )
            )
            var previousFirst: AccessoryKind?
            for _ in 0..<1_000 {
                let order = generator.nextOrder()
                precondition(order.count == 6)
                precondition(Set(order) == Set(AccessoryKind.allCases))
                if let previousFirst {
                    precondition(order.first != previousFirst, "生成器首项不得连续重复")
                }
                previousFirst = order.first
            }
        }
    }

    private static func testHUDContract() {
        let hud = OrderedEvidenceArchiveHUDView(
            frame: NSRect(x: 0, y: 0, width: 224, height: 32)
        )
        precondition(hud.intrinsicContentSize == NSSize(width: 224, height: 32))
        precondition(hud.hitTest(NSPoint(x: 10, y: 10)) == nil)
        precondition(hud.accessibilityRole() == .staticText)

        let snapshot = OrderedEvidenceArchiveSnapshot(
            order: AccessoryKind.allCases,
            completedCount: 2,
            phase: .active
        )
        hud.show(snapshot)
        precondition(!hud.isHidden)
        precondition(hud.accessibilityLabel()?.contains("下一件") == true)
        precondition(hud.accessibilityLabel()?.contains(AccessoryKind.magatama.displayName) == true)
        hud.hide()
        precondition(hud.isHidden)
    }

    private static func permutations<T>(of values: [T]) -> [[T]] {
        guard !values.isEmpty else { return [[]] }
        var result: [[T]] = []
        for index in values.indices {
            var remainder = values
            let value = remainder.remove(at: index)
            for suffix in permutations(of: remainder) {
                result.append([value] + suffix)
            }
        }
        return result
    }
}
