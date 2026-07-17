import AppKit
import Foundation

@main
struct CourtRecordUnlockTestMain {
    static func main() {
        testUnlockEventSemantics()
        testMigrationDoesNotEmitUnlockEvent()
        testAnnouncementQueue()
        print("法庭记录首次解锁事件与有界播报队列自检通过。")
    }

    private static func testUnlockEventSemantics() {
        withDefaults { defaults in
            let store = CourtRecordStore(defaults: defaults)
            var unlockedIDs: [String] = []
            var changeCount = 0
            let unlockObserver = NotificationCenter.default.addObserver(
                forName: .courtRecordStoreDidUnlock,
                object: store,
                queue: nil
            ) { notification in
                guard let event = CourtRecordUnlockEvent(notification: notification) else {
                    preconditionFailure("解锁通知必须携带类型化 record ID")
                }
                unlockedIDs.append(event.recordID)
            }
            let changeObserver = NotificationCenter.default.addObserver(
                forName: .courtRecordStoreDidChange,
                object: store,
                queue: nil
            ) { _ in changeCount += 1 }
            defer {
                NotificationCenter.default.removeObserver(unlockObserver)
                NotificationCenter.default.removeObserver(changeObserver)
            }

            let firstID = CourtRecordID.thrown
            precondition(store.record(firstID), "首次 record 应返回 true")
            precondition(unlockedIDs == [firstID], "首次 record 只应发一次专用解锁事件")
            precondition(store.count(for: firstID) == 1)

            for offset in 1...100 {
                precondition(
                    !store.record(firstID, at: Date(timeIntervalSince1970: TimeInterval(offset))),
                    "重复 record 不应返回首次解锁"
                )
            }
            precondition(unlockedIDs == [firstID], "重复 100 次不得冒充解锁事件")
            precondition(store.count(for: firstID) == 101, "普通 record 仍应正常计数")

            let moreIDs = [CourtRecordID.darkPlace, CourtRecordID.edgeRest]
            for id in moreIDs {
                precondition(store.unlock(id), "新 ID 应解锁")
            }
            precondition(unlockedIDs == [firstID] + moreIDs, "连续解锁应保持顺序")

            let unlockCountBeforeUnknown = unlockedIDs.count
            let changeCountBeforeUnknown = changeCount
            precondition(!store.record("unknown.record"), "未知 ID 应被拒绝")
            precondition(!store.unlock("unknown.record"), "未知 ID 不应解锁")
            precondition(unlockedIDs.count == unlockCountBeforeUnknown)
            precondition(changeCount == changeCountBeforeUnknown, "未知 ID 不应产生普通变更")
            precondition(changeCount == 103, "didChange 可正常反映首次与重复计数")
        }
    }

    private static func testMigrationDoesNotEmitUnlockEvent() {
        withDefaults { defaults in
            let legacy = CourtRecordProgress(entriesByID: [
                CourtRecordID.thrown: CourtRecordEntryProgress(
                    unlockedAt: Date(timeIntervalSince1970: 10),
                    count: 7,
                    lastSeen: Date(timeIntervalSince1970: 20)
                ),
            ])
            let data = try! JSONEncoder().encode(legacy)
            defaults.set(data, forKey: CourtRecordStore.legacyStorageKey)

            var unlockCount = 0
            let observer = NotificationCenter.default.addObserver(
                forName: .courtRecordStoreDidUnlock,
                object: nil,
                queue: nil
            ) { _ in unlockCount += 1 }
            defer { NotificationCenter.default.removeObserver(observer) }

            let migratedStore = CourtRecordStore(defaults: defaults)
            precondition(migratedStore.count(for: CourtRecordID.thrown) == 7)
            precondition(unlockCount == 0, "迁移加载不得冒充新解锁")
            precondition(defaults.data(forKey: CourtRecordStore.storageKey) != nil)

            _ = CourtRecordStore(defaults: defaults)
            precondition(unlockCount == 0, "新格式重新加载也不得发解锁事件")
        }
    }

    private static func testAnnouncementQueue() {
        var queue = CourtRecordUnlockAnnouncementQueue(capacity: 3)
        guard case let .activated(first) = queue.enqueue(recordID: "record.1") else {
            preconditionFailure("空队列的第一项应立即激活")
        }
        guard case let .queued(second) = queue.enqueue(recordID: "record.2") else {
            preconditionFailure("第二项应按顺序等待")
        }
        guard case let .queued(third) = queue.enqueue(recordID: "record.3") else {
            preconditionFailure("第三项应按顺序等待")
        }
        precondition(queue.count == 3)
        precondition(queue.enqueue(recordID: "record.2") == .merged(into: second))
        precondition(queue.count == 3, "重复项应合并")
        precondition(queue.enqueue(recordID: "record.4") == .dropped(recordID: "record.4"))
        precondition(queue.count == queue.capacity, "队列不得超过上限")

        precondition(queue.complete(first) == .advanced(to: second))
        precondition(queue.active == second, "应严格保持加入顺序")
        precondition(queue.complete(first) == .ignored, "旧完成回调不得跳过新项")
        precondition(queue.cancel(third) == .pendingCancelled)
        precondition(queue.cancel(second) == .activeCancelled(next: nil))
        precondition(queue.isEmpty)

        guard case let .activated(afterCancel) = queue.enqueue(recordID: "record.5") else {
            preconditionFailure("取消后应能继续播报")
        }
        _ = queue.enqueue(recordID: "record.6")
        queue.cancelAll()
        precondition(queue.isEmpty && queue.count == 0, "cancelAll 应清空所有项")
        precondition(queue.complete(afterCancel) == .ignored, "取消后的延迟回调应失效")
    }

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.ymatrix.phoenix-desktop-pet.unlock-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("无法创建隔离的解锁测试存储")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
