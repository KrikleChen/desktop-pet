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
}

private final class AccessoryScatterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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

    /// 参数为道具在本次抛出列表中的序号；首次有效点击开始飞回时回调。
    /// 调用方可在此同步播放接住动作和台词。
    var onAccessoryReclaimed: ((Int) -> Void)?

    /// 回收开始时动态取得桌宠当前手边的全局坐标；为空时退回散落起点。
    /// 使用闭包而不是固定坐标，避免桌宠在道具落地后移动导致道具飞回旧位置。
    var reclaimTargetProvider: (() -> NSPoint?)?

    /// 所有道具淡出释放，或显式取消一次正在进行的散落后回调。
    var onFinished: (() -> Void)?

    private final class ScatterItem {
        let id: Int
        let panel: NSPanel
        let restitution: CGFloat
        var velocity: CGVector
        var restingDuration: TimeInterval = 0
        var reclaimState = AccessoryReclaimState()
        var isSleeping = false
        var fadeWorkItem: DispatchWorkItem?
        var animationGeneration = 0

        init(
            id: Int,
            panel: NSPanel,
            velocity: CGVector,
            restitution: CGFloat
        ) {
            self.id = id
            self.panel = panel
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

    var isActive: Bool { !items.isEmpty }

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

        let selectedImages = Array(images.filter {
            $0.size.width > 0 && $0.size.height > 0
        }.prefix(6))
        guard !selectedImages.isEmpty else { return false }

        targetVisibleFrame = screen.visibleFrame
        guard targetVisibleFrame.width > 4, targetVisibleFrame.height > 4 else { return false }

        didFinishCurrentScatter = false
        let source = NSPoint(
            x: petWindowFrame.midX,
            y: petWindowFrame.midY
        )
        reclaimAnchor = source

        for (index, image) in selectedImages.enumerated() {
            let item = makeItem(id: index, image: image, source: source)
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

    private func makeItem(id: Int, image: NSImage, source: NSPoint) -> ScatterItem {
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
            id: id,
            panel: panel,
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

    private func reclaim(item: ScatterItem) {
        assert(Thread.isMainThread, "AccessoryScatterController 必须在主线程使用")
        guard
            items.contains(where: { $0 === item }),
            item.reclaimState.beginReclaim()
        else { return }

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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.48
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            item.panel.animator().setFrameOrigin(destination)
            item.panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak item] in
            guard
                let self,
                let item,
                item.animationGeneration == animationGeneration,
                item.reclaimState.isReclaiming,
                self.items.contains(where: { $0 === item })
            else { return }

            item.panel.orderOut(nil)
            self.items.removeAll { $0 === item }
            self.finishIfNeeded()
        }

        if items.allSatisfy({ $0.isSleeping }) {
            stopPhysics()
        }
        onAccessoryReclaimed?(item.id)
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
                self.finishIfNeeded()
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

    private func finishIfNeeded() {
        guard items.isEmpty, !didFinishCurrentScatter else { return }
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
            item.panel.orderOut(nil)
        }
        items.removeAll(keepingCapacity: true)
        didFinishCurrentScatter = true

        if notify, hadActiveScatter {
            onFinished?()
        }
    }
}
