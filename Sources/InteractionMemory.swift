import Foundation

/// 记录短时间内的连续捉弄和名字呼叫。
///
/// 该类型不读取系统时钟、不创建计时器。调用方传入单调时间戳，
/// 因此可以直接用 `NSEvent.timestamp` 或
/// `ProcessInfo.processInfo.systemUptime` 接入，也可以在测试中使用固定值。
struct InteractionMemory {
    enum TeasingInteraction: Equatable {
        /// 拖拽腿部或倒吊摇晃。
        case legDrag

        /// 拎起或拖拽其他部位。
        case grab

        /// 将桌宠甩出。
        case thrown
    }

    enum TeasingStage: String, Equatable {
        case normal
        case irritated
        case resigned
    }

    enum NameResponse: String, Equatable {
        case first
        case again
        case exasperated
    }

    struct Configuration: Equatable {
        let teasingWindow: TimeInterval
        let irritatedThreshold: Int
        let resignedThreshold: Int
        let nameCallWindow: TimeInterval

        init(
            teasingWindow: TimeInterval = 18,
            irritatedThreshold: Int = 3,
            resignedThreshold: Int = 5,
            nameCallWindow: TimeInterval = 10
        ) {
            precondition(
                teasingWindow.isFinite && teasingWindow > 0,
                "teasingWindow must be finite and positive"
            )
            precondition(irritatedThreshold > 0, "irritatedThreshold must be positive")
            precondition(
                resignedThreshold > irritatedThreshold,
                "resignedThreshold must be greater than irritatedThreshold"
            )
            precondition(
                nameCallWindow.isFinite && nameCallWindow > 0,
                "nameCallWindow must be finite and positive"
            )

            self.teasingWindow = teasingWindow
            self.irritatedThreshold = irritatedThreshold
            self.resignedThreshold = resignedThreshold
            self.nameCallWindow = nameCallWindow
        }
    }

    private struct TeasingEvent {
        let interaction: TeasingInteraction
        let timestamp: TimeInterval
    }

    let configuration: Configuration

    private var teasingEvents: [TeasingEvent] = []
    private var lastNameCallTimestamp: TimeInterval?
    private var consecutiveNameCallCount = 0

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// 记录一次捉弄，并返回记录后的反应阶段。
    ///
    /// 每种交互计为一次；只保留 `teasingWindow` 内的事件。
    /// 处于窗口边界的事件仍然有效，超过边界才衰减。
    @discardableResult
    mutating func recordTeasing(
        _ interaction: TeasingInteraction,
        at timestamp: TimeInterval
    ) -> TeasingStage {
        validate(timestamp: timestamp)
        prepareTeasingEvents(for: timestamp)
        teasingEvents.append(TeasingEvent(interaction: interaction, timestamp: timestamp))
        return stage(forEventCount: teasingEvents.count)
    }

    /// 清理已过期事件并返回当前反应阶段。
    mutating func teasingStage(at timestamp: TimeInterval) -> TeasingStage {
        validate(timestamp: timestamp)
        prepareTeasingEvents(for: timestamp)
        return stage(forEventCount: teasingEvents.count)
    }

    /// 记录一次名字呼叫。
    ///
    /// 每次呼叫与上一次的间隔不超过 `nameCallWindow` 时，
    /// 依次返回 `first`、`again`、`exasperated`；第三次之后
    /// 持续返回 `exasperated`。超时或时钟回退时从 `first` 重新开始。
    @discardableResult
    mutating func recordNameCall(at timestamp: TimeInterval) -> NameResponse {
        validate(timestamp: timestamp)
        if let lastTimestamp = lastNameCallTimestamp {
            let elapsed = timestamp - lastTimestamp
            if elapsed < 0 || elapsed > configuration.nameCallWindow {
                consecutiveNameCallCount = 0
            }
        } else {
            consecutiveNameCallCount = 0
        }

        lastNameCallTimestamp = timestamp
        if consecutiveNameCallCount < 3 {
            consecutiveNameCallCount += 1
        }

        switch consecutiveNameCallCount {
        case 1:
            return .first
        case 2:
            return .again
        default:
            return .exasperated
        }
    }

    mutating func resetTeasing() {
        teasingEvents.removeAll(keepingCapacity: true)
    }

    mutating func resetNameCalls() {
        lastNameCallTimestamp = nil
        consecutiveNameCallCount = 0
    }

    mutating func reset() {
        resetTeasing()
        resetNameCalls()
    }

    private mutating func prepareTeasingEvents(for timestamp: TimeInterval) {
        if let latestTimestamp = teasingEvents.last?.timestamp,
           timestamp < latestTimestamp {
            // 单调时钟理论上不会回退。若调用方更换了时钟基准，
            // 丢弃旧基准下的事件，避免它们永不过期。
            resetTeasing()
            return
        }

        teasingEvents.removeAll { event in
            timestamp - event.timestamp > configuration.teasingWindow
        }
    }

    private func stage(forEventCount count: Int) -> TeasingStage {
        if count >= configuration.resignedThreshold {
            return .resigned
        }
        if count >= configuration.irritatedThreshold {
            return .irritated
        }
        return .normal
    }

    private func validate(timestamp: TimeInterval) {
        precondition(timestamp.isFinite, "timestamp must be finite")
    }
}
