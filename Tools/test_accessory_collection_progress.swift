import Foundation

@main
struct AccessoryCollectionProgressTestMain {
    static func main() {
        testEverySixItemOrderRewardsExactlyOnce()
        testRapidDuplicateCallbacksCountOnce()
        testInterleavedSessionsRejectStaleCallbacks()
        testFiveReclaimsThenFadeOrCancelDoNotReward()
        testPreviewNeverRewards()
        testMissingKindCannotClaimAllRecoveredReward()
        print("散落证物全部回收状态自检通过。")
    }

    private static func testEverySixItemOrderRewardsExactlyOnce() {
        let orders = permutations(of: AccessoryKind.allCases)
        precondition(orders.count == 720, "6 件证物应有 720 种回收顺序")

        var sessionState = AccessoryScatterSessionState()
        for (orderIndex, order) in orders.enumerated() {
            let sessionID = sessionState.beginSession()
            var progress = AccessoryCollectionProgress()
            progress.begin(
                sessionID: sessionID,
                mode: .real,
                expectedKinds: Set(AccessoryKind.allCases)
            )

            for (itemIndex, kind) in order.enumerated() {
                let result = progress.recordReclaimed(kind, sessionID: sessionID)
                expectRecorded(
                    result,
                    count: itemIndex + 1,
                    complete: itemIndex == order.count - 1,
                    context: "顺序 \(orderIndex) 的第 \(itemIndex + 1) 件"
                )
            }

            precondition(
                progress.finish(sessionID: sessionID) == .reward,
                "顺序 \(orderIndex) 六件全回收后应奖励"
            )
            precondition(
                progress.finish(sessionID: sessionID) == .ignored,
                "顺序 \(orderIndex) 同一轮不得二次奖励"
            )
        }
    }

    private static func testRapidDuplicateCallbacksCountOnce() {
        var sessions = AccessoryScatterSessionState()
        let sessionID = sessions.beginSession()
        var progress = AccessoryCollectionProgress()
        progress.begin(
            sessionID: sessionID,
            mode: .real,
            expectedKinds: Set(AccessoryKind.allCases)
        )

        for (index, kind) in AccessoryKind.allCases.enumerated() {
            expectRecorded(
                progress.recordReclaimed(kind, sessionID: sessionID),
                count: index + 1,
                complete: index == AccessoryKind.allCases.count - 1,
                context: "快速回调第 \(index + 1) 件"
            )
            precondition(
                progress.recordReclaimed(kind, sessionID: sessionID)
                    == .duplicate(collectedCount: index + 1),
                "快速重复回调不应增加计数"
            )
        }
        precondition(progress.collectedCount == 6)
        precondition(progress.finish(sessionID: sessionID) == .reward)
        precondition(progress.finish(sessionID: sessionID) == .ignored)
    }

    private static func testInterleavedSessionsRejectStaleCallbacks() {
        var sessions = AccessoryScatterSessionState()
        let oldSessionID = sessions.beginSession()
        var progress = AccessoryCollectionProgress()
        progress.begin(
            sessionID: oldSessionID,
            mode: .real,
            expectedKinds: Set(AccessoryKind.allCases)
        )
        for kind in AccessoryKind.allCases.prefix(3) {
            _ = progress.recordReclaimed(kind, sessionID: oldSessionID)
        }

        let newSessionID = sessions.beginSession()
        progress.begin(
            sessionID: newSessionID,
            mode: .real,
            expectedKinds: Set(AccessoryKind.allCases)
        )
        precondition(progress.activeSessionID == newSessionID)
        precondition(
            progress.recordReclaimed(.attorneyBadge, sessionID: oldSessionID) == .ignored,
            "旧轮延迟回收不得污染新轮"
        )
        precondition(
            progress.finish(sessionID: oldSessionID) == .ignored,
            "旧轮结束不得结束新轮"
        )
        precondition(
            !progress.cancel(sessionID: oldSessionID),
            "旧轮取消不得取消新轮"
        )

        for kind in AccessoryKind.allCases.reversed() {
            _ = progress.recordReclaimed(kind, sessionID: newSessionID)
        }
        precondition(progress.finish(sessionID: newSessionID) == .reward)
    }

    private static func testFiveReclaimsThenFadeOrCancelDoNotReward() {
        var sessions = AccessoryScatterSessionState()
        let fadedSessionID = sessions.beginSession()
        var progress = AccessoryCollectionProgress()
        progress.begin(
            sessionID: fadedSessionID,
            mode: .real,
            expectedKinds: Set(AccessoryKind.allCases)
        )
        for kind in AccessoryKind.allCases.prefix(5) {
            _ = progress.recordReclaimed(kind, sessionID: fadedSessionID)
        }
        precondition(
            progress.finish(sessionID: fadedSessionID) == .noReward,
            "5 件回收 + 1 件自然淡出不得奖励"
        )

        let cancelledSessionID = sessions.beginSession()
        progress.begin(
            sessionID: cancelledSessionID,
            mode: .real,
            expectedKinds: Set(AccessoryKind.allCases)
        )
        for kind in AccessoryKind.allCases.prefix(5) {
            _ = progress.recordReclaimed(kind, sessionID: cancelledSessionID)
        }
        precondition(progress.cancel(sessionID: cancelledSessionID))
        precondition(
            progress.finish(sessionID: cancelledSessionID) == .ignored,
            "取消轮次后的 finish 不得奖励"
        )
    }

    private static func testPreviewNeverRewards() {
        var sessions = AccessoryScatterSessionState()
        let sessionID = sessions.beginSession()
        var progress = AccessoryCollectionProgress()
        progress.begin(
            sessionID: sessionID,
            mode: .preview,
            expectedKinds: Set(AccessoryKind.allCases)
        )
        for kind in AccessoryKind.allCases {
            _ = progress.recordReclaimed(kind, sessionID: sessionID)
        }
        precondition(
            progress.finish(sessionID: sessionID) == .noReward,
            "预览轮即使六件全回收也不得奖励"
        )
    }

    private static func testMissingKindCannotClaimAllRecoveredReward() {
        var sessions = AccessoryScatterSessionState()
        let sessionID = sessions.beginSession()
        let incompleteKindSet = Set(AccessoryKind.allCases.prefix(5))
        var progress = AccessoryCollectionProgress()
        progress.begin(
            sessionID: sessionID,
            mode: .real,
            expectedKinds: incompleteKindSet
        )
        for kind in incompleteKindSet {
            _ = progress.recordReclaimed(kind, sessionID: sessionID)
        }
        precondition(
            progress.finish(sessionID: sessionID) == .noReward,
            "散落时本就缺少第六件时不得宣称全部回收"
        )
    }

    private static func expectRecorded(
        _ actual: AccessoryCollectionReclaimResult,
        count: Int,
        complete: Bool,
        context: String
    ) {
        let expected = AccessoryCollectionReclaimResult.recorded(
            collectedCount: count,
            hasCollectedEveryExpectedKind: complete
        )
        precondition(actual == expected, "\(context): \(actual) != \(expected)")
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
