import AppKit
import QuartzCore

/// 可不创建窗口即验证的回收门闩：只有首次落地后的首次点击会生效。
struct AccessoryReclaimState {
    private(set) var hasLanded = false
    private(set) var isReclaiming = false

    @discardableResult
    mutating func markLanded() -> Bool {
        guard !hasLanded else { return false }
        hasLanded = true
        return true
    }

    @discardableResult
    mutating func beginReclaim() -> Bool {
        guard hasLanded, !isReclaiming else { return false }
        isReclaiming = true
        return true
    }
}

/// 单次道具散落的稳定身份。数值只由 `AccessoryScatterSessionState` 单调递增地产生。
struct AccessoryScatterSessionID: Hashable, Comparable {
    fileprivate let rawValue: UInt64

    static func < (lhs: AccessoryScatterSessionID, rhs: AccessoryScatterSessionID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 不依赖窗口的散落轮次状态机，集中约束预览回收只能作用于当前轮次。
struct AccessoryScatterSessionState {
    private var lastIssuedRawValue: UInt64 = 0
    private(set) var activeSessionID: AccessoryScatterSessionID?

    mutating func beginSession() -> AccessoryScatterSessionID {
        precondition(
            lastIssuedRawValue < UInt64.max,
            "AccessoryScatterSessionID 已耗尽"
        )
        lastIssuedRawValue += 1
        let sessionID = AccessoryScatterSessionID(rawValue: lastIssuedRawValue)
        activeSessionID = sessionID
        return sessionID
    }

    @discardableResult
    mutating func finishSession(_ sessionID: AccessoryScatterSessionID) -> Bool {
        guard activeSessionID == sessionID else { return false }
        activeSessionID = nil
        return true
    }

    mutating func cancelActiveSession() {
        activeSessionID = nil
    }

    func permitsPreviewReclaim(
        requestedSessionID: AccessoryScatterSessionID?,
        itemSessionID: AccessoryScatterSessionID,
        reclaimState: AccessoryReclaimState
    ) -> Bool {
        guard let requestedSessionID else { return false }
        return activeSessionID == requestedSessionID
            && itemSessionID == requestedSessionID
            && reclaimState.hasLanded
            && !reclaimState.isReclaiming
    }
}

/// 道具图集中的稳定槽位。rawValue 与既有图片顺序、兼容回调中的 id 一致。
enum AccessoryKind: Int, CaseIterable {
    case attorneyBadge = 0
    case caseFile = 1
    case magatama = 2
    case evidence = 3
    case pen = 4
    case stickyNote = 5

    var displayName: String {
        switch self {
        case .attorneyBadge: return "律师徽章"
        case .caseFile: return "案件文件"
        case .magatama: return "勾玉"
        case .evidence: return "证物"
        case .pen: return "笔"
        case .stickyNote: return "便签"
        }
    }

    var reclaimMotion: AccessoryReclaimMotionConfiguration {
        switch self {
        case .attorneyBadge:
            return AccessoryReclaimMotionConfiguration(
                duration: 0.56,
                curve: .goldenArc,
                trailStyle: .goldenArc,
                rotationTurns: 0.72,
                swingAmplitude: 0.04,
                swingCycles: 1.5,
                trailFraction: 0.30
            )
        case .caseFile:
            return AccessoryReclaimMotionConfiguration(
                duration: 0.70,
                curve: .fileFlutter,
                trailStyle: .fileFlutter,
                rotationTurns: 0.03,
                swingAmplitude: 0.14,
                swingCycles: 3.0,
                trailFraction: 0.27
            )
        case .magatama:
            return AccessoryReclaimMotionConfiguration(
                duration: 0.62,
                curve: .cyanSpirit,
                trailStyle: .cyanSpirit,
                rotationTurns: 0.34,
                swingAmplitude: 0.08,
                swingCycles: 2.0,
                trailFraction: 0.38
            )
        case .evidence:
            return AccessoryReclaimMotionConfiguration(
                duration: 0.55,
                curve: .redBlueEmphasis,
                trailStyle: .redBlueEmphasis,
                rotationTurns: -0.18,
                swingAmplitude: 0.10,
                swingCycles: 3.2,
                trailFraction: 0.29
            )
        case .pen:
            return AccessoryReclaimMotionConfiguration(
                duration: 0.48,
                curve: .penSpiral,
                trailStyle: .penFineLine,
                rotationTurns: 1.35,
                swingAmplitude: 0.03,
                swingCycles: 2.0,
                trailFraction: 0.23
            )
        case .stickyNote:
            return AccessoryReclaimMotionConfiguration(
                duration: 0.74,
                curve: .paperFall,
                trailStyle: .paperPieces,
                rotationTurns: 0.06,
                swingAmplitude: 0.24,
                swingCycles: 3.5,
                trailFraction: 0.32
            )
        }
    }
}

/// 新回调使用的稳定事件；id 保留 Int，便于旧代理渐进迁移。
struct AccessoryReclaimEvent: Equatable {
    let kind: AccessoryKind
    let id: Int

    init(kind: AccessoryKind, id: Int? = nil) {
        self.kind = kind
        self.id = id ?? kind.rawValue
    }
}

enum AccessoryReclaimCurve: CaseIterable {
    case goldenArc
    case fileFlutter
    case cyanSpirit
    case redBlueEmphasis
    case penSpiral
    case paperFall
}

enum AccessoryTrailStyle: CaseIterable {
    case goldenArc
    case fileFlutter
    case cyanSpirit
    case redBlueEmphasis
    case penFineLine
    case paperPieces
}

struct AccessoryReclaimMotionConfiguration: Equatable {
    let duration: TimeInterval
    let curve: AccessoryReclaimCurve
    let trailStyle: AccessoryTrailStyle
    let rotationTurns: CGFloat
    let swingAmplitude: CGFloat
    let swingCycles: CGFloat
    let trailFraction: CGFloat
}

/// 将回收终点约束在散落所属屏幕的可见区内。
enum AccessoryReclaimGeometry {
    static func destinationOrigin(
        itemSize: NSSize,
        near target: NSPoint,
        inside visibleFrame: NSRect
    ) -> NSPoint {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - itemSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - itemSize.height)
        return NSPoint(
            x: min(max(target.x - itemSize.width * 0.5, visibleFrame.minX), maximumX),
            y: min(max(target.y - itemSize.height * 0.5, visibleFrame.minY), maximumY)
        )
    }

    /// 生成纯几何轨迹点。逐点约束可避免负坐标副屏或屏幕边缘的窗口越界。
    static func sampledCenters(
        from start: NSPoint,
        to destination: NSPoint,
        itemSize: NSSize,
        inside visibleFrame: NSRect,
        motion: AccessoryReclaimMotionConfiguration,
        sampleCount: Int = 97
    ) -> [NSPoint] {
        let count = max(2, sampleCount)
        return (0..<count).map { index in
            let progress = CGFloat(index) / CGFloat(count - 1)
            let point = unconstrainedCenter(
                from: start,
                to: destination,
                progress: progress,
                curve: motion.curve
            )
            return constrainedCenter(point, itemSize: itemSize, inside: visibleFrame)
        }
    }

    static func interpolatedCenter(in samples: [NSPoint], progress: CGFloat) -> NSPoint {
        guard let first = samples.first else { return .zero }
        guard samples.count > 1 else { return first }

        let boundedProgress = min(max(progress, 0), 1)
        let position = boundedProgress * CGFloat(samples.count - 1)
        let lowerIndex = min(Int(floor(position)), samples.count - 1)
        let upperIndex = min(lowerIndex + 1, samples.count - 1)
        let fraction = position - CGFloat(lowerIndex)
        let lower = samples[lowerIndex]
        let upper = samples[upperIndex]
        return NSPoint(
            x: lower.x + (upper.x - lower.x) * fraction,
            y: lower.y + (upper.y - lower.y) * fraction
        )
    }

    static func easedProgress(_ progress: CGFloat) -> CGFloat {
        let boundedProgress = min(max(progress, 0), 1)
        if boundedProgress < 0.5 {
            return 4 * boundedProgress * boundedProgress * boundedProgress
        }
        return 1 - pow(-2 * boundedProgress + 2, 3) / 2
    }

    private static func unconstrainedCenter(
        from start: NSPoint,
        to destination: NSPoint,
        progress: CGFloat,
        curve: AccessoryReclaimCurve
    ) -> NSPoint {
        let deltaX = destination.x - start.x
        let deltaY = destination.y - start.y
        let distance = max(1, hypot(deltaX, deltaY))
        let direction = CGVector(dx: deltaX / distance, dy: deltaY / distance)
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let envelope = sin(.pi * progress)
        var point = NSPoint(
            x: start.x + deltaX * progress,
            y: start.y + deltaY * progress
        )

        func add(direction vector: CGVector, amount: CGFloat) {
            point.x += vector.dx * amount
            point.y += vector.dy * amount
        }

        switch curve {
        case .goldenArc:
            point.y += min(76, max(24, distance * 0.18)) * envelope

        case .fileFlutter:
            point.y += min(38, max(16, distance * 0.08)) * envelope
            add(
                direction: normal,
                amount: sin(3 * .pi * progress) * min(22, max(9, distance * 0.055)) * envelope
            )

        case .cyanSpirit:
            point.y += min(46, max(20, distance * 0.11)) * envelope
            add(
                direction: normal,
                amount: (16 + 8 * sin(4 * .pi * progress)) * envelope
            )

        case .redBlueEmphasis:
            point.y += min(24, max(10, distance * 0.05)) * envelope
            add(
                direction: normal,
                amount: sin(2 * .pi * progress) * min(30, max(12, distance * 0.075)) * envelope
            )

        case .penSpiral:
            let radius = min(20, max(8, distance * 0.05)) * envelope * (1 - 0.55 * progress)
            add(direction: normal, amount: sin(4 * .pi * progress) * radius)
            add(direction: direction, amount: cos(4 * .pi * progress) * radius * 0.42)

        case .paperFall:
            let fallingEnvelope = envelope * pow(1 - progress, 0.35)
            point.y -= min(46, max(22, distance * 0.10)) * fallingEnvelope
            add(
                direction: normal,
                amount: sin(3 * .pi * progress) * min(24, max(10, distance * 0.06)) * envelope
            )
        }
        return point
    }

    private static func constrainedCenter(
        _ center: NSPoint,
        itemSize: NSSize,
        inside visibleFrame: NSRect
    ) -> NSPoint {
        let minimumX = visibleFrame.minX + itemSize.width * 0.5
        let maximumX = max(minimumX, visibleFrame.maxX - itemSize.width * 0.5)
        let minimumY = visibleFrame.minY + itemSize.height * 0.5
        let maximumY = max(minimumY, visibleFrame.maxY - itemSize.height * 0.5)
        return NSPoint(
            x: min(max(center.x, minimumX), maximumX),
            y: min(max(center.y, minimumY), maximumY)
        )
    }
}

private final class AccessoryScatterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AccessoryTrailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct AccessoryTrailLayerSpecification {
    let color: NSColor
    let lineWidth: CGFloat
    let lineCap: CAShapeLayerLineCap
    let dashPattern: [NSNumber]?
    let perpendicularOffset: CGFloat
    let opacity: Float
    let shadowRadius: CGFloat
}

private final class AccessoryTrailPresentation {
    let panel: AccessoryTrailPanel
    let frame: NSRect
    let layers: [(layer: CAShapeLayer, specification: AccessoryTrailLayerSpecification)]

    init(
        panel: AccessoryTrailPanel,
        frame: NSRect,
        layers: [(layer: CAShapeLayer, specification: AccessoryTrailLayerSpecification)]
    ) {
        self.panel = panel
        self.frame = frame
        self.layers = layers
    }
}

private final class AccessoryClickView: NSView {
    let image: NSImage
    var onPrimaryClick: (() -> Void)?

    init(frame frameRect: NSRect, image: NSImage) {
        self.image = image
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        onPrimaryClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        image.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

/// 仅用于调用方已经确认是 `.leg` 抓取后的左右倒吊摇摆识别。
///
/// 调用顺序：
/// 1. 腿部开始拖拽时调用 `beginLegGrab(timestamp:globalPosition:)`。
/// 2. 拖拽过程中持续调用 `addSample(timestamp:globalPosition:)`。
/// 3. 松手时调用 `endLegGrab()`。
///
/// 每次抓取会话最多返回一次 `true`；成功后还有 30 秒全局冷却。
final class ShakeGestureDetector {
    struct Configuration {
        /// 统计有效反转的滑动窗口。取 1.6 秒，位于需求的 1.2～1.8 秒范围内。
        var windowDuration: TimeInterval = 1.6
        var minimumReversalCount = 3
        var minimumHorizontalSpeed: CGFloat = 190
        var minimumSegmentExcursion: CGFloat = 28
        var minimumTotalExcursion: CGFloat = 145
        var minimumOverallSpan: CGFloat = 72
        var reversalConfirmationDistance: CGFloat = 9
        var reversalDebounceInterval: TimeInterval = 0.10
        var jitterTolerance: CGFloat = 1.5
        var maximumSampleGap: TimeInterval = 0.28
        var cooldown: TimeInterval = 30
    }

    private struct Sample {
        let timestamp: TimeInterval
        let x: CGFloat
    }

    private struct Reversal {
        let timestamp: TimeInterval
        let excursion: CGFloat
    }

    private let configuration: Configuration
    private var isTrackingLegGrab = false
    private(set) var didTriggerCurrentGrab = false
    private var lastTriggerTimestamp: TimeInterval?

    private var samples: [Sample] = []
    private var reversals: [Reversal] = []
    private var previousSample: Sample?
    private var currentDirection = 0
    private var segmentStartX: CGFloat?
    private var segmentStartTimestamp: TimeInterval?
    private var segmentExtremeX: CGFloat?
    private var segmentExtremeTimestamp: TimeInterval?
    private var lastAcceptedReversalTimestamp: TimeInterval?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    var isTracking: Bool { isTrackingLegGrab }

    func beginLegGrab(timestamp: TimeInterval, globalPosition: NSPoint) {
        resetCurrentGesture()
        isTrackingLegGrab = true
        let sample = Sample(timestamp: timestamp, x: globalPosition.x)
        previousSample = sample
        samples = [sample]
    }

    /// - Returns: 本次样本是否刚刚触发“道具散落”。一次抓取最多返回一次 `true`。
    @discardableResult
    func addSample(timestamp: TimeInterval, globalPosition: NSPoint) -> Bool {
        guard isTrackingLegGrab, !didTriggerCurrentGrab else { return false }

        let sample = Sample(timestamp: timestamp, x: globalPosition.x)
        guard let previous = previousSample else {
            previousSample = sample
            samples = [sample]
            return false
        }

        let deltaTime = timestamp - previous.timestamp
        guard deltaTime > 0 else { return false }

        if deltaTime > configuration.maximumSampleGap {
            resetMotionState(keeping: sample)
            return false
        }

        previousSample = sample
        samples.append(sample)
        pruneHistory(relativeTo: timestamp)

        let deltaX = sample.x - previous.x
        guard abs(deltaX) >= configuration.jitterTolerance else { return false }

        let direction = deltaX > 0 ? 1 : -1
        let speed = abs(deltaX) / CGFloat(deltaTime)

        if currentDirection == 0 {
            guard speed >= configuration.minimumHorizontalSpeed else { return false }
            currentDirection = direction
            segmentStartX = previous.x
            segmentStartTimestamp = previous.timestamp
            segmentExtremeX = sample.x
            segmentExtremeTimestamp = sample.timestamp
            return false
        }

        if direction == currentDirection {
            updateExtreme(with: sample, direction: direction)
            return false
        }

        guard
            let startX = segmentStartX,
            let extremeX = segmentExtremeX,
            abs(sample.x - extremeX) >= configuration.reversalConfirmationDistance,
            abs(extremeX - startX) >= configuration.minimumSegmentExcursion,
            speed >= configuration.minimumHorizontalSpeed
        else {
            return false
        }

        if let lastAcceptedReversalTimestamp,
           timestamp - lastAcceptedReversalTimestamp < configuration.reversalDebounceInterval {
            return false
        }

        let completedExcursion = abs(extremeX - startX)
        reversals.append(Reversal(timestamp: timestamp, excursion: completedExcursion))
        lastAcceptedReversalTimestamp = timestamp
        currentDirection = direction
        segmentStartX = extremeX
        segmentStartTimestamp = segmentExtremeTimestamp
        segmentExtremeX = sample.x
        segmentExtremeTimestamp = sample.timestamp
        pruneHistory(relativeTo: timestamp)

        guard qualifiesForTrigger(at: timestamp) else { return false }
        didTriggerCurrentGrab = true
        lastTriggerTimestamp = timestamp
        return true
    }

    func endLegGrab() {
        resetCurrentGesture()
    }

    func cancelCurrentGrab() {
        resetCurrentGesture()
    }

    private func qualifiesForTrigger(at timestamp: TimeInterval) -> Bool {
        if let lastTriggerTimestamp {
            let elapsed = timestamp - lastTriggerTimestamp
            guard elapsed >= configuration.cooldown else { return false }
        }

        guard reversals.count >= configuration.minimumReversalCount else { return false }

        let totalExcursion = reversals.reduce(CGFloat.zero) { $0 + $1.excursion }
        guard totalExcursion >= configuration.minimumTotalExcursion else { return false }

        guard
            let minimumX = samples.map(\.x).min(),
            let maximumX = samples.map(\.x).max(),
            maximumX - minimumX >= configuration.minimumOverallSpan
        else {
            return false
        }

        return true
    }

    private func updateExtreme(with sample: Sample, direction: Int) {
        guard let current = segmentExtremeX else {
            segmentExtremeX = sample.x
            segmentExtremeTimestamp = sample.timestamp
            return
        }
        if direction > 0 {
            if sample.x > current {
                segmentExtremeX = sample.x
                segmentExtremeTimestamp = sample.timestamp
            }
        } else if sample.x < current {
            segmentExtremeX = sample.x
            segmentExtremeTimestamp = sample.timestamp
        }
    }

    private func pruneHistory(relativeTo timestamp: TimeInterval) {
        let oldestAllowed = timestamp - configuration.windowDuration
        samples.removeAll { $0.timestamp < oldestAllowed }
        reversals.removeAll { $0.timestamp < oldestAllowed }

        // 连续朝一个方向拖动很久后再摇摆时，不把窗口外的位移计入本次幅度。
        if let segmentStartTimestamp,
           segmentStartTimestamp < oldestAllowed,
           let firstRetainedSample = samples.first {
            segmentStartX = firstRetainedSample.x
            self.segmentStartTimestamp = firstRetainedSample.timestamp
        }
    }

    private func resetMotionState(keeping sample: Sample) {
        samples = [sample]
        reversals.removeAll(keepingCapacity: true)
        previousSample = sample
        currentDirection = 0
        segmentStartX = nil
        segmentStartTimestamp = nil
        segmentExtremeX = nil
        segmentExtremeTimestamp = nil
        lastAcceptedReversalTimestamp = nil
    }

    private func resetCurrentGesture() {
        isTrackingLegGrab = false
        didTriggerCurrentGrab = false
        samples.removeAll(keepingCapacity: true)
        reversals.removeAll(keepingCapacity: true)
        previousSample = nil
        currentDirection = 0
        segmentStartX = nil
        segmentStartTimestamp = nil
        segmentExtremeX = nil
        segmentExtremeTimestamp = nil
        lastAcceptedReversalTimestamp = nil
    }
}

/// 把最多六个角色道具作为独立小窗口抛出，执行轻量重力、碰撞和淡出动画。
/// 所有公开方法和回调都在主线程使用。
final class AccessoryScatterController {
    /// 参数为本次实际抛出的道具数量。
    var onTriggered: ((Int) -> Void)?

    /// 参数为道具在本次抛出列表中的序号；每个道具首次触地只回调一次。
    var onItemLanded: ((Int) -> Void)?

    /// 兼容旧代理：参数为稳定槽位 id（与 `AccessoryKind.rawValue` 一致）。
    var onAccessoryReclaimed: ((Int) -> Void)?

    /// 首次有效点击开始飞回时回调，携带稳定种类与 id。
    /// 新代理应优先使用此回调，以便按道具提供独立角色反馈。
    var onAccessoryReclaimedEvent: ((AccessoryReclaimEvent) -> Void)?

    /// 回收开始时动态取得桌宠当前手边的全局坐标；为空时退回散落起点。
    /// 使用闭包而不是固定坐标，避免桌宠在道具落地后移动导致道具飞回旧位置。
    var reclaimTargetProvider: (() -> NSPoint?)?

    /// 所有道具淡出释放，或显式取消一次正在进行的散落后回调。
    var onFinished: (() -> Void)?

    private final class ScatterItem {
        let id: Int
        let kind: AccessoryKind
        let sessionID: AccessoryScatterSessionID
        let panel: NSPanel
        let clickView: AccessoryClickView
        let restitution: CGFloat
        var velocity: CGVector
        var restingDuration: TimeInterval = 0
        var reclaimState = AccessoryReclaimState()
        var isSleeping = false
        var fadeWorkItem: DispatchWorkItem?
        var animationGeneration = 0
        var reclaimTimer: Timer?
        var trailPresentation: AccessoryTrailPresentation?

        init(
            id: Int,
            kind: AccessoryKind,
            sessionID: AccessoryScatterSessionID,
            panel: NSPanel,
            clickView: AccessoryClickView,
            velocity: CGVector,
            restitution: CGFloat
        ) {
            self.id = id
            self.kind = kind
            self.sessionID = sessionID
            self.panel = panel
            self.clickView = clickView
            self.velocity = velocity
            self.restitution = restitution
        }
    }

    private let gravity: CGFloat = -840
    private let targetFrameInterval: TimeInterval = 1.0 / 60.0
    private var items: [ScatterItem] = []
    private var physicsTimer: Timer?
    private var lastPhysicsTimestamp: TimeInterval?
    private var targetVisibleFrame = NSRect.zero
    private var reclaimAnchor = NSPoint.zero
    private var didFinishCurrentScatter = true
    private var sessionState = AccessoryScatterSessionState()

    var isActive: Bool { !items.isEmpty }

    /// 当前仍可回收的散落轮次；失败、取消或全部结束后为 `nil`。
    var activeSessionID: AccessoryScatterSessionID? { sessionState.activeSessionID }

    deinit {
        cancelInternal(notify: false)
    }

    /// 从桌宠窗口附近抛出道具。已有散落会先被无回调清理。
    ///
    /// - Parameters:
    ///   - images: 道具透明 PNG 对应的 `NSImage`；只使用前六张非空尺寸图片。
    ///   - petWindowFrame: AppKit 全局屏幕坐标中的桌宠窗口 frame。
    ///   - screen: 道具必须留在其 `visibleFrame` 内的目标显示器。
    /// - Returns: 是否成功创建了至少一个道具。
    @discardableResult
    func scatter(
        images: [NSImage],
        from petWindowFrame: NSRect,
        on screen: NSScreen
    ) -> Bool {
        assert(Thread.isMainThread, "AccessoryScatterController 必须在主线程使用")
        cancelInternal(notify: false)
        let sessionID = sessionState.beginSession()

        let selectedImages: [(kind: AccessoryKind, image: NSImage)] = Array(
            images.prefix(AccessoryKind.allCases.count)
        ).enumerated().compactMap { index, image in
            guard
                image.size.width > 0,
                image.size.height > 0,
                let kind = AccessoryKind(rawValue: index)
            else { return nil }
            return (kind: kind, image: image)
        }
        guard !selectedImages.isEmpty else {
            sessionState.finishSession(sessionID)
            return false
        }

        targetVisibleFrame = screen.visibleFrame
        guard targetVisibleFrame.width > 4, targetVisibleFrame.height > 4 else {
            sessionState.finishSession(sessionID)
            return false
        }

        didFinishCurrentScatter = false
        let source = NSPoint(
            x: petWindowFrame.midX,
            y: petWindowFrame.midY
        )
        reclaimAnchor = source

        for selection in selectedImages {
            let item = makeItem(
                kind: selection.kind,
                sessionID: sessionID,
                image: selection.image,
                source: source
            )
            items.append(item)
            item.panel.orderFrontRegardless()
        }

        onTriggered?(items.count)
        if !items.isEmpty {
            startPhysics()
        }
        return true
    }

    /// 只掌握桌宠窗口全局原点时可使用的便捷入口。
    @discardableResult
    func scatter(
        images: [NSImage],
        from petWindowGlobalPosition: NSPoint,
        on screen: NSScreen
    ) -> Bool {
        scatter(
            images: images,
            from: NSRect(origin: petWindowGlobalPosition, size: .zero),
            on: screen
        )
    }

    /// 立即停止物理、取消淡出并释放全部道具窗口。
    func cancelAndRemoveAll() {
        assert(Thread.isMainThread, "AccessoryScatterController 必须在主线程使用")
        cancelInternal(notify: true)
    }

    /// 仅供本地画面验收：token 属于当前轮且道具已落地时，走真实点击回收链。
    @discardableResult
    func reclaimForPreview(
        kind: AccessoryKind,
        sessionID requestedSessionID: AccessoryScatterSessionID
    ) -> Bool {
        assert(Thread.isMainThread, "AccessoryScatterController 必须在主线程使用")
        guard let item = items.first(where: {
            $0.kind == kind
                && sessionState.permitsPreviewReclaim(
                    requestedSessionID: requestedSessionID,
                    itemSessionID: $0.sessionID,
                    reclaimState: $0.reclaimState
                )
        }) else { return false }
        return reclaim(item: item)
    }

    /// 旧调用方的源码兼容壳。缺少轮次身份无法安全判断归属，因此固定失败。
    @available(*, deprecated, message: "请捕获 activeSessionID 并传给 reclaimForPreview(kind:sessionID:)")
    @discardableResult
    func reclaimForPreview(kind: AccessoryKind) -> Bool {
        assert(Thread.isMainThread, "AccessoryScatterController 必须在主线程使用")
        return false
    }

    private func makeItem(
        kind: AccessoryKind,
        sessionID: AccessoryScatterSessionID,
        image: NSImage,
        source: NSPoint
    ) -> ScatterItem {
        let maximumSide = max(4, min(42, min(targetVisibleFrame.width, targetVisibleFrame.height)))
        let longSide = CGFloat.random(in: min(26, maximumSide)...maximumSide)
        let aspect = image.size.width / max(1, image.size.height)
        var size: NSSize
        if aspect >= 1 {
            size = NSSize(width: longSide, height: max(4, longSide / aspect))
        } else {
            size = NSSize(width: max(4, longSide * aspect), height: longSide)
        }
        let fitScale = min(
            1,
            targetVisibleFrame.width / max(1, size.width),
            targetVisibleFrame.height / max(1, size.height)
        )
        if fitScale < 1 {
            size.width *= fitScale
            size.height *= fitScale
        }

        let safeX = min(
            max(source.x + CGFloat.random(in: -18...18), targetVisibleFrame.minX),
            targetVisibleFrame.maxX - size.width
        )
        let safeY = min(
            max(source.y + CGFloat.random(in: -12...22), targetVisibleFrame.minY),
            targetVisibleFrame.maxY - size.height
        )
        let frame = NSRect(origin: NSPoint(x: safeX, y: safeY), size: size)

        let panel = AccessoryScatterPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: nil
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let clickView = AccessoryClickView(
            frame: NSRect(origin: .zero, size: size),
            image: image
        )
        panel.contentView = clickView

        let horizontalMagnitude = CGFloat.random(in: 125...285)
        let horizontalSign: CGFloat = Bool.random() ? 1 : -1
        let item = ScatterItem(
            id: kind.rawValue,
            kind: kind,
            sessionID: sessionID,
            panel: panel,
            clickView: clickView,
            velocity: CGVector(
                dx: horizontalMagnitude * horizontalSign,
                dy: CGFloat.random(in: 185...335)
            ),
            restitution: CGFloat.random(in: 0.34...0.52)
        )
        clickView.onPrimaryClick = { [weak self, weak item] in
            guard let self, let item else { return }
            self.reclaim(item: item)
        }
        return item
    }

    private func startPhysics() {
        physicsTimer?.invalidate()
        lastPhysicsTimestamp = ProcessInfo.processInfo.systemUptime

        let timer = Timer(timeInterval: targetFrameInterval, repeats: true) { [weak self] _ in
            self?.stepPhysics()
        }
        physicsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stepPhysics() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - (lastPhysicsTimestamp ?? now)
        lastPhysicsTimestamp = now
        let deltaTime = min(max(elapsed, 1.0 / 120.0), 1.0 / 30.0)

        var hasMovingItem = false
        for item in items where !item.isSleeping {
            hasMovingItem = true
            integrate(item: item, deltaTime: deltaTime)
        }

        if !hasMovingItem || items.allSatisfy({ $0.isSleeping }) {
            stopPhysics()
        }
    }

    private func integrate(item: ScatterItem, deltaTime: TimeInterval) {
        var frame = item.panel.frame
        var velocity = item.velocity
        let dt = CGFloat(deltaTime)

        velocity.dy += gravity * dt
        frame.origin.x += velocity.dx * dt
        frame.origin.y += velocity.dy * dt

        let leftBoundary = targetVisibleFrame.minX
        let rightBoundary = max(leftBoundary, targetVisibleFrame.maxX - frame.width)
        if frame.minX < leftBoundary {
            frame.origin.x = leftBoundary
            velocity.dx = abs(velocity.dx) * 0.62
        } else if frame.minX > rightBoundary {
            frame.origin.x = rightBoundary
            velocity.dx = -abs(velocity.dx) * 0.62
        }

        let ceiling = max(targetVisibleFrame.minY, targetVisibleFrame.maxY - frame.height)
        if frame.minY > ceiling {
            frame.origin.y = ceiling
            velocity.dy = -abs(velocity.dy) * 0.45
        }

        let floor = targetVisibleFrame.minY
        if frame.minY <= floor {
            frame.origin.y = floor
            if item.reclaimState.markLanded() {
                item.panel.ignoresMouseEvents = false
                onItemLanded?(item.id)
            }

            if abs(velocity.dy) > 48 {
                velocity.dy = abs(velocity.dy) * item.restitution
                velocity.dx *= 0.80
                item.restingDuration = 0
            } else {
                velocity.dy = 0
                velocity.dx *= CGFloat(pow(0.88, deltaTime * 60))
                if abs(velocity.dx) < 13 {
                    velocity.dx = 0
                    item.restingDuration += deltaTime
                } else {
                    item.restingDuration = 0
                }
            }
        } else {
            item.restingDuration = 0
        }

        item.velocity = velocity
        item.panel.setFrameOrigin(frame.origin)

        if item.restingDuration >= 0.24 {
            item.isSleeping = true
            scheduleFade(for: item)
        }
    }

    @discardableResult
    private func reclaim(item: ScatterItem) -> Bool {
        assert(Thread.isMainThread, "AccessoryScatterController 必须在主线程使用")
        guard
            sessionState.activeSessionID == item.sessionID,
            items.contains(where: { $0 === item }),
            item.reclaimState.beginReclaim()
        else { return false }

        item.isSleeping = true
        item.velocity = .zero
        item.fadeWorkItem?.cancel()
        item.fadeWorkItem = nil
        item.animationGeneration &+= 1
        let animationGeneration = item.animationGeneration
        item.panel.ignoresMouseEvents = true

        let currentTarget = reclaimTargetProvider?() ?? reclaimAnchor
        let destination = AccessoryReclaimGeometry.destinationOrigin(
            itemSize: item.panel.frame.size,
            near: currentTarget,
            inside: targetVisibleFrame
        )
        startReclaimAnimation(
            for: item,
            destinationOrigin: destination,
            generation: animationGeneration
        )

        if items.allSatisfy({ $0.isSleeping }) {
            stopPhysics()
        }
        let event = AccessoryReclaimEvent(kind: item.kind, id: item.id)
        onAccessoryReclaimedEvent?(event)
        onAccessoryReclaimed?(item.id)
        return true
    }

    private func startReclaimAnimation(
        for item: ScatterItem,
        destinationOrigin: NSPoint,
        generation: Int
    ) {
        let motion = item.kind.reclaimMotion
        let itemSize = item.panel.frame.size
        let startCenter = NSPoint(x: item.panel.frame.midX, y: item.panel.frame.midY)
        let destinationCenter = NSPoint(
            x: destinationOrigin.x + itemSize.width * 0.5,
            y: destinationOrigin.y + itemSize.height * 0.5
        )
        let samples = AccessoryReclaimGeometry.sampledCenters(
            from: startCenter,
            to: destinationCenter,
            itemSize: itemSize,
            inside: targetVisibleFrame,
            motion: motion
        )

        item.clickView.wantsLayer = true
        item.trailPresentation = makeTrailPresentation(for: item, motion: motion)
        let startTimestamp = ProcessInfo.processInfo.systemUptime

        renderReclaim(
            item: item,
            samples: samples,
            motion: motion,
            progress: 0
        )

        let timer = Timer(timeInterval: targetFrameInterval, repeats: true) {
            [weak self, weak item] timer in
            guard
                let self,
                let item,
                item.animationGeneration == generation,
                item.reclaimState.isReclaiming,
                self.items.contains(where: { $0 === item })
            else {
                timer.invalidate()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startTimestamp
            let progress = min(max(CGFloat(elapsed / motion.duration), 0), 1)
            self.renderReclaim(
                item: item,
                samples: samples,
                motion: motion,
                progress: progress
            )
            if progress >= 1 {
                self.completeReclaim(item: item, generation: generation)
            }
        }
        item.reclaimTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func renderReclaim(
        item: ScatterItem,
        samples: [NSPoint],
        motion: AccessoryReclaimMotionConfiguration,
        progress: CGFloat
    ) {
        let boundedProgress = min(max(progress, 0), 1)
        let pathProgress = AccessoryReclaimGeometry.easedProgress(boundedProgress)
        let center = AccessoryReclaimGeometry.interpolatedCenter(
            in: samples,
            progress: pathProgress
        )
        let itemSize = item.panel.frame.size
        item.panel.setFrameOrigin(NSPoint(
            x: center.x - itemSize.width * 0.5,
            y: center.y - itemSize.height * 0.5
        ))

        let swingEnvelope = sin(.pi * boundedProgress)
        let rotation = motion.rotationTurns * 2 * .pi * boundedProgress
            + sin(2 * .pi * motion.swingCycles * boundedProgress)
                * motion.swingAmplitude * swingEnvelope
        let scale = 1 - 0.34 * boundedProgress * boundedProgress
        let fadeProgress = min(max((boundedProgress - 0.72) / 0.28, 0), 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        item.clickView.layer?.setAffineTransform(
            CGAffineTransform(rotationAngle: rotation).scaledBy(x: scale, y: scale)
        )
        item.panel.alphaValue = 1 - fadeProgress
        updateTrail(
            item.trailPresentation,
            samples: samples,
            headProgress: pathProgress,
            animationProgress: boundedProgress,
            tailFraction: motion.trailFraction
        )
        CATransaction.commit()
    }

    private func completeReclaim(item: ScatterItem, generation: Int) {
        guard
            item.animationGeneration == generation,
            item.reclaimState.isReclaiming,
            items.contains(where: { $0 === item })
        else { return }

        removeReclaimPresentation(for: item)
        item.panel.orderOut(nil)
        items.removeAll { $0 === item }
        finishIfNeeded(sessionID: item.sessionID)
    }

    private func makeTrailPresentation(
        for item: ScatterItem,
        motion: AccessoryReclaimMotionConfiguration
    ) -> AccessoryTrailPresentation {
        let panel = AccessoryTrailPanel(
            contentRect: targetVisibleFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: nil
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let contentView = NSView(frame: NSRect(origin: .zero, size: targetVisibleFrame.size))
        contentView.wantsLayer = true
        panel.contentView = contentView

        let specifications = trailLayerSpecifications(for: motion.trailStyle)
        let layers = specifications.map { specification -> (
            layer: CAShapeLayer,
            specification: AccessoryTrailLayerSpecification
        ) in
            let layer = CAShapeLayer()
            layer.frame = contentView.bounds
            layer.fillColor = NSColor.clear.cgColor
            layer.strokeColor = specification.color.cgColor
            layer.lineWidth = specification.lineWidth
            layer.lineCap = specification.lineCap
            layer.lineJoin = .round
            layer.lineDashPattern = specification.dashPattern
            layer.opacity = specification.opacity
            if specification.shadowRadius > 0 {
                layer.shadowColor = specification.color.cgColor
                layer.shadowOpacity = min(1, specification.opacity)
                layer.shadowRadius = specification.shadowRadius
                layer.shadowOffset = .zero
            }
            contentView.layer?.addSublayer(layer)
            return (layer: layer, specification: specification)
        }

        // 新建的透明面板需要先进入屏幕窗口列表；直接做
        // relative order 在部分 macOS 版本上会保持未显示，导致轨迹实际不可见。
        panel.orderFrontRegardless()
        panel.order(.below, relativeTo: item.panel.windowNumber)
        return AccessoryTrailPresentation(
            panel: panel,
            frame: targetVisibleFrame,
            layers: layers
        )
    }

    private func updateTrail(
        _ presentation: AccessoryTrailPresentation?,
        samples: [NSPoint],
        headProgress: CGFloat,
        animationProgress: CGFloat,
        tailFraction: CGFloat
    ) {
        guard let presentation else { return }
        let startProgress = max(0, headProgress - tailFraction)
        let fade = Float(1 - min(max((animationProgress - 0.76) / 0.24, 0), 1))

        for entry in presentation.layers {
            entry.layer.path = trailPath(
                samples: samples,
                from: startProgress,
                to: headProgress,
                frameOrigin: presentation.frame.origin,
                perpendicularOffset: entry.specification.perpendicularOffset
            )
            entry.layer.opacity = entry.specification.opacity * fade
        }
    }

    private func trailPath(
        samples: [NSPoint],
        from startProgress: CGFloat,
        to endProgress: CGFloat,
        frameOrigin: NSPoint,
        perpendicularOffset: CGFloat
    ) -> CGPath? {
        guard endProgress - startProgress > 0.001 else { return nil }
        let segmentCount = max(3, Int(ceil((endProgress - startProgress) * 96)))
        let path = CGMutablePath()

        for index in 0...segmentCount {
            let fraction = CGFloat(index) / CGFloat(segmentCount)
            let progress = startProgress + (endProgress - startProgress) * fraction
            var point = AccessoryReclaimGeometry.interpolatedCenter(
                in: samples,
                progress: progress
            )
            if perpendicularOffset != 0 {
                let before = AccessoryReclaimGeometry.interpolatedCenter(
                    in: samples,
                    progress: max(0, progress - 0.005)
                )
                let after = AccessoryReclaimGeometry.interpolatedCenter(
                    in: samples,
                    progress: min(1, progress + 0.005)
                )
                let deltaX = after.x - before.x
                let deltaY = after.y - before.y
                let length = max(0.001, hypot(deltaX, deltaY))
                let taperedOffset = perpendicularOffset * sin(.pi * progress)
                point.x -= deltaY / length * taperedOffset
                point.y += deltaX / length * taperedOffset
            }
            let localPoint = CGPoint(
                x: point.x - frameOrigin.x,
                y: point.y - frameOrigin.y
            )
            if index == 0 {
                path.move(to: localPoint)
            } else {
                path.addLine(to: localPoint)
            }
        }
        return path
    }

    private func trailLayerSpecifications(
        for style: AccessoryTrailStyle
    ) -> [AccessoryTrailLayerSpecification] {
        switch style {
        case .goldenArc:
            let gold = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.16, alpha: 1)
            return [
                AccessoryTrailLayerSpecification(
                    color: gold,
                    lineWidth: 6.5,
                    lineCap: .round,
                    dashPattern: nil,
                    perpendicularOffset: 0,
                    opacity: 0.24,
                    shadowRadius: 5
                ),
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 1.0, green: 0.90, blue: 0.48, alpha: 1),
                    lineWidth: 2.1,
                    lineCap: .round,
                    dashPattern: nil,
                    perpendicularOffset: 0,
                    opacity: 0.88,
                    shadowRadius: 0
                )
            ]

        case .fileFlutter:
            return [
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 0.78, green: 0.88, blue: 0.94, alpha: 1),
                    lineWidth: 3.2,
                    lineCap: .round,
                    dashPattern: [9, 7],
                    perpendicularOffset: 0,
                    opacity: 0.52,
                    shadowRadius: 0
                ),
                AccessoryTrailLayerSpecification(
                    color: NSColor.white,
                    lineWidth: 1.0,
                    lineCap: .round,
                    dashPattern: [9, 7],
                    perpendicularOffset: 0,
                    opacity: 0.78,
                    shadowRadius: 0
                )
            ]

        case .cyanSpirit:
            let cyan = NSColor(calibratedRed: 0.22, green: 0.94, blue: 0.90, alpha: 1)
            return [
                AccessoryTrailLayerSpecification(
                    color: cyan,
                    lineWidth: 8.0,
                    lineCap: .round,
                    dashPattern: nil,
                    perpendicularOffset: 0,
                    opacity: 0.20,
                    shadowRadius: 9
                ),
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 0.66, green: 1.0, blue: 0.96, alpha: 1),
                    lineWidth: 2.3,
                    lineCap: .round,
                    dashPattern: nil,
                    perpendicularOffset: 0,
                    opacity: 0.90,
                    shadowRadius: 3
                )
            ]

        case .redBlueEmphasis:
            return [
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 0.96, green: 0.22, blue: 0.24, alpha: 1),
                    lineWidth: 2.4,
                    lineCap: .round,
                    dashPattern: nil,
                    perpendicularOffset: 2.2,
                    opacity: 0.84,
                    shadowRadius: 2
                ),
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 0.20, green: 0.52, blue: 1.0, alpha: 1),
                    lineWidth: 2.4,
                    lineCap: .round,
                    dashPattern: nil,
                    perpendicularOffset: -2.2,
                    opacity: 0.84,
                    shadowRadius: 2
                )
            ]

        case .penFineLine:
            return [
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 0.46, green: 0.72, blue: 0.96, alpha: 1),
                    lineWidth: 1.15,
                    lineCap: .round,
                    dashPattern: nil,
                    perpendicularOffset: 0,
                    opacity: 0.86,
                    shadowRadius: 0
                )
            ]

        case .paperPieces:
            return [
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.30, alpha: 1),
                    lineWidth: 4.2,
                    lineCap: .square,
                    dashPattern: [2, 8],
                    perpendicularOffset: 0,
                    opacity: 0.72,
                    shadowRadius: 0
                ),
                AccessoryTrailLayerSpecification(
                    color: NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.20, alpha: 1),
                    lineWidth: 1.1,
                    lineCap: .square,
                    dashPattern: [7, 11],
                    perpendicularOffset: 0,
                    opacity: 0.66,
                    shadowRadius: 0
                )
            ]
        }
    }

    private func removeReclaimPresentation(for item: ScatterItem) {
        item.reclaimTimer?.invalidate()
        item.reclaimTimer = nil
        if let presentation = item.trailPresentation {
            presentation.layers.forEach { $0.layer.removeFromSuperlayer() }
            presentation.panel.orderOut(nil)
            item.trailPresentation = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        item.clickView.layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    private func scheduleFade(for item: ScatterItem) {
        guard item.fadeWorkItem == nil, !item.reclaimState.isReclaiming else { return }
        let animationGeneration = item.animationGeneration
        let workItem = DispatchWorkItem { [weak self, weak item] in
            guard
                let self,
                let item,
                item.animationGeneration == animationGeneration,
                !item.reclaimState.isReclaiming,
                self.items.contains(where: { $0 === item })
            else { return }
            item.fadeWorkItem = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.65
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                item.panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak item] in
                guard
                    let self,
                    let item,
                    item.animationGeneration == animationGeneration,
                    !item.reclaimState.isReclaiming,
                    self.items.contains(where: { $0 === item })
                else { return }
                item.panel.orderOut(nil)
                self.items.removeAll { $0 === item }
                self.finishIfNeeded(sessionID: item.sessionID)
            }
        }
        item.fadeWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double.random(in: 8...12),
            execute: workItem
        )
    }

    private func stopPhysics() {
        physicsTimer?.invalidate()
        physicsTimer = nil
        lastPhysicsTimestamp = nil
    }

    private func finishIfNeeded(sessionID: AccessoryScatterSessionID) {
        guard items.isEmpty, !didFinishCurrentScatter else { return }
        guard sessionState.finishSession(sessionID) else { return }
        stopPhysics()
        didFinishCurrentScatter = true
        onFinished?()
    }

    private func cancelInternal(notify: Bool) {
        let hadActiveScatter = !items.isEmpty && !didFinishCurrentScatter
        stopPhysics()
        for item in items {
            item.fadeWorkItem?.cancel()
            item.fadeWorkItem = nil
            removeReclaimPresentation(for: item)
            item.panel.orderOut(nil)
        }
        items.removeAll(keepingCapacity: true)
        didFinishCurrentScatter = true
        sessionState.cancelActiveSession()

        if notify, hadActiveScatter {
            onFinished?()
        }
    }
}
