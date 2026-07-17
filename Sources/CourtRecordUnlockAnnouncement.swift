import Foundation

/// 一次可视的首次解锁播报。`sequence` 用于识别已经过期的完成回调。
struct CourtRecordUnlockAnnouncement: Equatable {
    let recordID: String
    fileprivate let sequence: UInt64
}

/// 不依赖界面或计时器的有界播报状态机。
///
/// 宿主展示 `active`，动画完成时调用 `complete(_:)`。同一 ID 已在播报或
/// 等待时会被合并；达到容量后会明确丢弃新项，不会无限积压。
struct CourtRecordUnlockAnnouncementQueue {
    enum EnqueueResult: Equatable {
        case activated(CourtRecordUnlockAnnouncement)
        case queued(CourtRecordUnlockAnnouncement)
        case merged(into: CourtRecordUnlockAnnouncement)
        case dropped(recordID: String)
    }

    enum CompletionResult: Equatable {
        case advanced(to: CourtRecordUnlockAnnouncement?)
        case ignored
    }

    enum CancellationResult: Equatable {
        case activeCancelled(next: CourtRecordUnlockAnnouncement?)
        case pendingCancelled
        case notFound
    }

    let capacity: Int
    private(set) var active: CourtRecordUnlockAnnouncement?
    private(set) var pending: [CourtRecordUnlockAnnouncement] = []

    private var nextSequence: UInt64 = 1

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    var count: Int {
        (active == nil ? 0 : 1) + pending.count
    }

    var isEmpty: Bool {
        active == nil
    }

    @discardableResult
    mutating func enqueue(recordID: String) -> EnqueueResult {
        guard !recordID.isEmpty else { return .dropped(recordID: recordID) }

        if let active = active, active.recordID == recordID {
            return .merged(into: active)
        }
        if let existing = pending.first(where: { $0.recordID == recordID }) {
            return .merged(into: existing)
        }
        guard count < capacity else { return .dropped(recordID: recordID) }

        let announcement = CourtRecordUnlockAnnouncement(
            recordID: recordID,
            sequence: takeSequence()
        )
        if active == nil {
            active = announcement
            return .activated(announcement)
        }

        pending.append(announcement)
        return .queued(announcement)
    }

    /// 只完成当前正在展示的那一项。旧动画的延迟回调不会跳过新项。
    @discardableResult
    mutating func complete(
        _ announcement: CourtRecordUnlockAnnouncement
    ) -> CompletionResult {
        guard active == announcement else { return .ignored }
        return .advanced(to: advance())
    }

    /// 取消指定播报。取消当前项时会按原顺序启动下一项。
    @discardableResult
    mutating func cancel(
        _ announcement: CourtRecordUnlockAnnouncement
    ) -> CancellationResult {
        if active == announcement {
            return .activeCancelled(next: advance())
        }
        guard let index = pending.firstIndex(of: announcement) else { return .notFound }
        pending.remove(at: index)
        return .pendingCancelled
    }

    /// 取消当前项和全部等待项。已派发的旧完成回调随后会被忽略。
    mutating func cancelAll() {
        active = nil
        pending.removeAll(keepingCapacity: true)
    }

    private mutating func advance() -> CourtRecordUnlockAnnouncement? {
        if pending.isEmpty {
            active = nil
        } else {
            active = pending.removeFirst()
        }
        return active
    }

    private mutating func takeSequence() -> UInt64 {
        let sequence = nextSequence
        nextSequence = nextSequence == UInt64.max ? 1 : nextSequence + 1
        return sequence
    }
}
