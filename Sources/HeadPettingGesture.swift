import AppKit
import Foundation

/// 识别“不按鼠标、在头发上轻柔往返”的独立手势模型。
///
/// 预期由 `PetView.mouseMoved(with:)` 持续投递样本；主按键按下的
/// `mouseDragged` 不应被识别为抚摸。所有方法都应在 AppKit 主线程调用。
final class HeadPettingGesture {
    struct Configuration {
        /// 一次往返手势允许的最长时间窗口。
        var windowDuration: TimeInterval = 2.4

        /// “右 -> 左”或“左 -> 右”算一次换向。
        var minimumReversalCount = 3

        /// 小于此距离的单段往返当作手部抖动。
        var minimumSegmentExcursion: CGFloat = 14

        /// 完整手势的累计路径，防止小范围摆动误触。
        var minimumTotalDistance: CGFloat = 92

        /// 光标在头发上实际覆盖的水平范围。
        var minimumHorizontalSpan: CGFloat = 26

        /// 换向后需再移动这么远才确认，过滤单像素方向抖动。
        var reversalConfirmationDistance: CGFloat = 4

        /// 移动速度超过此值会被视为快速拖拽/甩动。
        var maximumSpeed: CGFloat = 330

        /// 纵向距离不能超过同段水平距离的该倍数。
        var maximumVerticalToHorizontalRatio: CGFloat = 0.85

        var jitterTolerance: CGFloat = 0.8
        var maximumSampleGap: TimeInterval = 0.34
        var cooldown: TimeInterval = 8
    }

    enum ResetReason: Equatable {
        case leftHairRegion
        case primaryButtonPressed
        case movedTooFast
        case verticalMotion
        case sampleGap
        case invalidTimestamp
    }

    /// 调用方只需在 `.triggered` 时播放“压扁 -> 弹回”动画。
    /// `trackingStarted` / `progress` 便于调试或将来加入轻量视觉反馈。
    enum Event: Equatable {
        case none
        case trackingStarted
        case progress(reversalCount: Int, totalDistance: CGFloat)
        case triggered
        case reset(ResetReason)
        case coolingDown(remaining: TimeInterval)
    }

    private struct Sample {
        let timestamp: TimeInterval
        let position: NSPoint
    }

    private let configuration: Configuration
    private var samples: [Sample] = []
    private var previousSample: Sample?
    private var currentDirection = 0
    private var segmentStartX: CGFloat?
    private var segmentExtremeX: CGFloat?
    private var reversalCount = 0
    private var totalDistance: CGFloat = 0
    private var lastTriggerTimestamp: TimeInterval?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var isTracking: Bool { previousSample != nil }

    /// 投递一个未按键的光标移动样本。
    ///
    /// - Parameters:
    ///   - timestamp: `NSEvent.timestamp` 或同一单调时钟下的时间。
    ///   - position: 建议使用 `PetView` 本地坐标。
    ///   - region: 由 `GrabRegionDetector` 命中的角色部位；透明区为 `nil`。
    ///   - isPrimaryButtonDown: 可由 `NSEvent.pressedMouseButtons & 1 != 0` 得到。
    @discardableResult
    func addSample(
        timestamp: TimeInterval,
        position: NSPoint,
        region: GrabRegion?,
        isPrimaryButtonDown: Bool
    ) -> Event {
        if isPrimaryButtonDown {
            return resetIfNeeded(reason: .primaryButtonPressed)
        }

        guard region == .hairHead else {
            return resetIfNeeded(reason: .leftHairRegion)
        }

        if let lastTriggerTimestamp {
            let elapsed = timestamp - lastTriggerTimestamp
            if elapsed >= 0, elapsed < configuration.cooldown {
                resetMotion()
                return .coolingDown(remaining: configuration.cooldown - elapsed)
            }
        }

        let sample = Sample(timestamp: timestamp, position: position)
        guard let previousSample else {
            beginTracking(with: sample)
            return .trackingStarted
        }

        let deltaTime = timestamp - previousSample.timestamp
        guard deltaTime > 0 else {
            resetMotion()
            return .reset(.invalidTimestamp)
        }

        if deltaTime > configuration.maximumSampleGap {
            beginTracking(with: sample)
            return .reset(.sampleGap)
        }

        let deltaX = position.x - previousSample.position.x
        let deltaY = position.y - previousSample.position.y
        let distance = hypot(deltaX, deltaY)

        if distance < configuration.jitterTolerance {
            self.previousSample = sample
            return .none
        }

        let speed = distance / CGFloat(deltaTime)
        guard speed <= configuration.maximumSpeed else {
            resetMotion()
            return .reset(.movedTooFast)
        }

        let horizontalDistance = abs(deltaX)
        if abs(deltaY) > max(
            configuration.jitterTolerance,
            horizontalDistance * configuration.maximumVerticalToHorizontalRatio
        ) {
            resetMotion()
            return .reset(.verticalMotion)
        }

        self.previousSample = sample
        samples.append(sample)
        totalDistance += distance
        pruneHistory(relativeTo: timestamp)

        guard horizontalDistance >= configuration.jitterTolerance else {
            return .progress(reversalCount: reversalCount, totalDistance: totalDistance)
        }

        let direction = deltaX > 0 ? 1 : -1
        if currentDirection == 0 {
            currentDirection = direction
            segmentStartX = previousSample.position.x
            segmentExtremeX = position.x
            return .progress(reversalCount: reversalCount, totalDistance: totalDistance)
        }

        if direction == currentDirection {
            updateExtreme(position.x)
            return triggerOrProgress(at: timestamp)
        }

        guard
            let segmentStartX,
            let segmentExtremeX,
            abs(segmentExtremeX - segmentStartX) >= configuration.minimumSegmentExcursion,
            abs(position.x - segmentExtremeX) >= configuration.reversalConfirmationDistance
        else {
            return .progress(reversalCount: reversalCount, totalDistance: totalDistance)
        }

        reversalCount += 1
        currentDirection = direction
        self.segmentStartX = segmentExtremeX
        self.segmentExtremeX = position.x
        return triggerOrProgress(at: timestamp)
    }

    /// `mouseExited` 或交互模式切换时可主动取消本次识别。
    @discardableResult
    func cancel(reason: ResetReason = .leftHairRegion) -> Event {
        resetIfNeeded(reason: reason)
    }

    private func triggerOrProgress(at timestamp: TimeInterval) -> Event {
        guard qualifiesForTrigger() else {
            return .progress(reversalCount: reversalCount, totalDistance: totalDistance)
        }

        lastTriggerTimestamp = timestamp
        resetMotion()
        return .triggered
    }

    private func qualifiesForTrigger() -> Bool {
        guard
            reversalCount >= configuration.minimumReversalCount,
            totalDistance >= configuration.minimumTotalDistance,
            let minimumX = samples.map(\.position.x).min(),
            let maximumX = samples.map(\.position.x).max(),
            maximumX - minimumX >= configuration.minimumHorizontalSpan
        else {
            return false
        }
        return true
    }

    private func updateExtreme(_ x: CGFloat) {
        guard let segmentExtremeX else {
            self.segmentExtremeX = x
            return
        }
        if currentDirection > 0, x > segmentExtremeX {
            self.segmentExtremeX = x
        } else if currentDirection < 0, x < segmentExtremeX {
            self.segmentExtremeX = x
        }
    }

    private func pruneHistory(relativeTo timestamp: TimeInterval) {
        let cutoff = timestamp - configuration.windowDuration
        guard let firstRetainedIndex = samples.firstIndex(where: { $0.timestamp >= cutoff }) else {
            beginTracking(with: samples.last ?? Sample(timestamp: timestamp, position: .zero))
            return
        }

        if firstRetainedIndex > 0 {
            samples.removeFirst(firstRetainedIndex)
            rebuildMotionState()
        }
    }

    /// 历史窗口滑动后从保留样本重算，避免窗口外的距离继续累计。
    private func rebuildMotionState() {
        let retained = samples
        resetMotion(keepingLastTrigger: true)
        guard let first = retained.first else { return }
        beginTracking(with: first)

        for sample in retained.dropFirst() {
            guard let previous = previousSample else { break }
            let deltaX = sample.position.x - previous.position.x
            let deltaY = sample.position.y - previous.position.y
            let distance = hypot(deltaX, deltaY)
            previousSample = sample
            samples.append(sample)
            totalDistance += distance

            guard abs(deltaX) >= configuration.jitterTolerance else { continue }
            let direction = deltaX > 0 ? 1 : -1
            if currentDirection == 0 {
                currentDirection = direction
                segmentStartX = previous.position.x
                segmentExtremeX = sample.position.x
            } else if direction == currentDirection {
                updateExtreme(sample.position.x)
            } else if let start = segmentStartX,
                      let extreme = segmentExtremeX,
                      abs(extreme - start) >= configuration.minimumSegmentExcursion,
                      abs(sample.position.x - extreme) >= configuration.reversalConfirmationDistance {
                reversalCount += 1
                currentDirection = direction
                segmentStartX = extreme
                segmentExtremeX = sample.position.x
            }
        }
    }

    private func beginTracking(with sample: Sample) {
        resetMotion()
        previousSample = sample
        samples = [sample]
    }

    private func resetIfNeeded(reason: ResetReason) -> Event {
        guard isTracking || !samples.isEmpty else { return .none }
        resetMotion()
        return .reset(reason)
    }

    private func resetMotion(keepingLastTrigger: Bool = true) {
        samples.removeAll(keepingCapacity: true)
        previousSample = nil
        currentDirection = 0
        segmentStartX = nil
        segmentExtremeX = nil
        reversalCount = 0
        totalDistance = 0
        if !keepingLastTrigger {
            lastTriggerTimestamp = nil
        }
    }
}
