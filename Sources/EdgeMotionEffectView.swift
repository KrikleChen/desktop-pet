import AppKit
import QuartzCore

/// A transparent, non-interactive overlay for the pet's edge-rest motion cues.
///
/// Add the view immediately before the pet artwork with the same bounds as its
/// container. Its trails stay behind the opaque character pixels, so movement
/// reads as surrounding depth instead of lines painted across the character.
/// Drawing is clipped below 190 points and cannot enter the caption area.
final class EdgeMotionEffectView: NSView {
    enum Phase: Equatable {
        case stopped
        case entering(EdgeIdleBehavior.Edge)
        case ambient(EdgeIdleBehavior.Edge)
        case exiting(EdgeIdleBehavior.Edge)
    }

    private static let drawingHeight: CGFloat = 190
    private static let entranceDuration: TimeInterval = 0.62
    private static let ambientDuration: TimeInterval = 0.78
    private static let ambientInterval: TimeInterval = 2.05
    private static let exitDuration: TimeInterval = 0.48

    private let effectLayer = CALayer()
    private var transitionWorkItem: DispatchWorkItem?
    private var ambientWorkItem: DispatchWorkItem?
    private var cleanupWorkItem: DispatchWorkItem?
    private var pendingExitCompletion: (() -> Void)?
    private var generation: UInt = 0

    private(set) var phase: Phase = .stopped

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    deinit {
        transitionWorkItem?.cancel()
        ambientWorkItem?.cancel()
        cleanupWorkItem?.cancel()
        pendingExitCompletion = nil
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        updateEffectLayerFrame()
    }

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        if newSuperview == nil, superview != nil {
            stop()
        }
        super.viewWillMove(toSuperview: newSuperview)
    }

    /// The overlay never takes clicks, drags, or contextual-menu events from the pet.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Plays three restrained directional strokes, then enters ambient mode.
    ///
    /// Calling this again replaces any entrance, ambient scan, or exit already in
    /// progress. The first ambient scan occurs about two seconds after settling.
    func playEntrance(edge: EdgeIdleBehavior.Edge) {
        requireMainThread()
        beginNewSequence()
        phase = .entering(edge)
        prepareForPlayback()

        let strokes = EdgeMotionEffectGeometry.directionalStrokes(
            in: effectLayer.bounds,
            edge: edge,
            direction: .entrance
        )
        addDirectionalLayers(strokes, exiting: false)

        let currentGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.transitionWorkItem = nil
            self.removeEffectSublayers()
            self.phase = .ambient(edge)
            self.scheduleAmbientScan(edge: edge, after: Self.ambientInterval)
        }
        transitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.entranceDuration,
            execute: workItem
        )
    }

    /// Starts low-frequency investigation scans without replaying the entrance.
    ///
    /// The first scan is immediate; subsequent scans begin roughly every two seconds.
    /// Repeating this call for the active edge is intentionally a no-op.
    func beginAmbient(edge: EdgeIdleBehavior.Edge) {
        requireMainThread()
        if phase == .ambient(edge) { return }

        beginNewSequence()
        phase = .ambient(edge)
        prepareForPlayback()
        playAmbientScan(edge: edge)
    }

    /// Plays the entrance paths in reverse and calls `completion` after they retract.
    ///
    /// A completion belongs only to this exit. It is discarded if another public
    /// playback method or `stop()` cancels the exit before it finishes.
    func playExit(
        edge: EdgeIdleBehavior.Edge,
        completion: (() -> Void)? = nil
    ) {
        requireMainThread()
        beginNewSequence()
        pendingExitCompletion = completion
        phase = .exiting(edge)
        prepareForPlayback()

        let strokes = EdgeMotionEffectGeometry.directionalStrokes(
            in: effectLayer.bounds,
            edge: edge,
            direction: .exit
        )
        addDirectionalLayers(strokes, exiting: true)

        let currentGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.transitionWorkItem = nil
            let completion = self.pendingExitCompletion
            self.pendingExitCompletion = nil
            self.removeEffectSublayers()
            self.phase = .stopped
            self.alphaValue = 0
            self.isHidden = true
            completion?()
        }
        transitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.exitDuration,
            execute: workItem
        )
    }

    /// Cancels callbacks and animations, clears all transient layers, and hides.
    func stop() {
        requireMainThread()
        beginNewSequence()
        phase = .stopped
        removeEffectSublayers()
        alphaValue = 0
        isHidden = true
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        layer?.zPosition = -1

        effectLayer.backgroundColor = NSColor.clear.cgColor
        effectLayer.masksToBounds = true
        effectLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "sublayers": NSNull(),
        ]
        layer?.addSublayer(effectLayer)

        alphaValue = 0
        isHidden = true
        setAccessibilityElement(false)
        updateEffectLayerFrame()
    }

    private func requireMainThread() {
        precondition(Thread.isMainThread, "EdgeMotionEffectView must be used on the main thread")
    }

    private func beginNewSequence() {
        generation &+= 1
        transitionWorkItem?.cancel()
        ambientWorkItem?.cancel()
        cleanupWorkItem?.cancel()
        transitionWorkItem = nil
        ambientWorkItem = nil
        cleanupWorkItem = nil
        pendingExitCompletion = nil
        removeEffectSublayers()
    }

    private func prepareForPlayback() {
        layoutSubtreeIfNeeded()
        updateEffectLayerFrame()
        alphaValue = 1
        isHidden = false
    }

    private func updateEffectLayerFrame() {
        let height = min(max(0, bounds.height), Self.drawingHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectLayer.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width), height: height)
        CATransaction.commit()
    }

    private func addDirectionalLayers(
        _ strokes: [EdgeMotionStroke],
        exiting: Bool
    ) {
        let colors = [Self.paleBlue, Self.iceBlue, Self.mutedGold]
        let widths: [CGFloat] = [1.45, 1.85, 1.15]

        for (index, stroke) in strokes.enumerated() {
            let shape = makeShapeLayer(
                path: stroke.path,
                color: colors[index % colors.count],
                lineWidth: widths[index % widths.count]
            )
            addEffectSublayer(shape)

            let strokeEnd = CAKeyframeAnimation(keyPath: "strokeEnd")
            strokeEnd.values = [0.0, 0.82, 1.0, 1.0]
            strokeEnd.keyTimes = [0.0, 0.38, 0.62, 1.0]

            let strokeStart = CAKeyframeAnimation(keyPath: "strokeStart")
            strokeStart.values = [0.0, 0.0, exiting ? 0.54 : 0.36, 1.0]
            strokeStart.keyTimes = [0.0, 0.34, 0.64, 1.0]

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [0.0, exiting ? 0.66 : 0.78, 0.58, 0.0]
            opacity.keyTimes = [0.0, 0.18, 0.72, 1.0]

            let group = CAAnimationGroup()
            group.animations = [strokeEnd, strokeStart, opacity]
            group.duration = exiting ? 0.38 : 0.46
            group.beginTime = shape.convertTime(CACurrentMediaTime(), from: nil)
                + Double(index) * 0.055
            group.timingFunction = CAMediaTimingFunction(name: exiting ? .easeIn : .easeOut)
            shape.add(group, forKey: "edge-directional-stroke")
        }
    }

    private func playAmbientScan(edge: EdgeIdleBehavior.Edge) {
        guard phase == .ambient(edge) else { return }
        removeEffectSublayers()

        guard let scan = EdgeMotionEffectGeometry.ambientScan(
            in: effectLayer.bounds,
            edge: edge
        ) else {
            scheduleAmbientScan(edge: edge, after: Self.ambientInterval)
            return
        }

        let trail = makeShapeLayer(
            path: scan.path,
            color: Self.paleBlue,
            lineWidth: 1.25
        )
        trail.lineDashPattern = [5, 4]
        addEffectSublayer(trail)

        let reveal = CAKeyframeAnimation(keyPath: "strokeEnd")
        reveal.values = [0.0, 0.76, 1.0, 1.0]
        reveal.keyTimes = [0.0, 0.42, 0.64, 1.0]

        let retract = CAKeyframeAnimation(keyPath: "strokeStart")
        retract.values = [0.0, 0.0, 0.18, 1.0]
        retract.keyTimes = [0.0, 0.44, 0.68, 1.0]

        let trailOpacity = CAKeyframeAnimation(keyPath: "opacity")
        trailOpacity.values = [0.0, 0.52, 0.42, 0.0]
        trailOpacity.keyTimes = [0.0, 0.18, 0.72, 1.0]

        let trailGroup = CAAnimationGroup()
        trailGroup.animations = [reveal, retract, trailOpacity]
        trailGroup.duration = Self.ambientDuration
        trailGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        trail.add(trailGroup, forKey: "edge-ambient-trail")

        let marker = CAShapeLayer()
        marker.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        marker.path = CGPath(ellipseIn: CGRect(x: 1.25, y: 1.25, width: 3.5, height: 3.5), transform: nil)
        marker.fillColor = Self.mutedGold
        marker.opacity = 0
        addEffectSublayer(marker)

        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = scan.path
        travel.calculationMode = .paced

        let markerOpacity = CAKeyframeAnimation(keyPath: "opacity")
        markerOpacity.values = [0.0, 0.78, 0.72, 0.0]
        markerOpacity.keyTimes = [0.0, 0.16, 0.78, 1.0]

        let markerGroup = CAAnimationGroup()
        markerGroup.animations = [travel, markerOpacity]
        markerGroup.duration = Self.ambientDuration * 0.86
        markerGroup.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        marker.add(markerGroup, forKey: "edge-ambient-marker")

        let currentGeneration = generation
        let cleanup = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == currentGeneration,
                  self.phase == .ambient(edge)
            else { return }
            self.cleanupWorkItem = nil
            self.removeEffectSublayers()
        }
        cleanupWorkItem = cleanup
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.ambientDuration,
            execute: cleanup
        )

        scheduleAmbientScan(edge: edge, after: Self.ambientInterval)
    }

    private func scheduleAmbientScan(
        edge: EdgeIdleBehavior.Edge,
        after delay: TimeInterval
    ) {
        ambientWorkItem?.cancel()
        let currentGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == currentGeneration,
                  self.phase == .ambient(edge)
            else { return }
            self.ambientWorkItem = nil
            self.playAmbientScan(edge: edge)
        }
        ambientWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeShapeLayer(
        path: CGPath,
        color: CGColor,
        lineWidth: CGFloat
    ) -> CAShapeLayer {
        let shape = CAShapeLayer()
        shape.frame = effectLayer.bounds
        shape.path = path
        shape.fillColor = NSColor.clear.cgColor
        shape.strokeColor = color
        shape.lineWidth = lineWidth
        shape.lineCap = .round
        shape.lineJoin = .round
        shape.opacity = 0
        return shape
    }

    private func addEffectSublayer(_ sublayer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectLayer.addSublayer(sublayer)
        CATransaction.commit()
    }

    private func removeEffectSublayers() {
        effectLayer.sublayers?.forEach {
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
    }

    private static let paleBlue = NSColor(
        calibratedRed: 0.66,
        green: 0.84,
        blue: 1.0,
        alpha: 0.72
    ).cgColor

    private static let iceBlue = NSColor(
        calibratedRed: 0.90,
        green: 0.96,
        blue: 1.0,
        alpha: 0.78
    ).cgColor

    private static let mutedGold = NSColor(
        calibratedRed: 0.94,
        green: 0.72,
        blue: 0.27,
        alpha: 0.70
    ).cgColor
}

enum EdgeMotionPathDirection {
    case entrance
    case exit
}

/// A quadratic stroke kept as data so geometry can be tested without rendering.
struct EdgeMotionStroke {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    var path: CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    func reversed() -> EdgeMotionStroke {
        EdgeMotionStroke(start: end, control: control, end: start)
    }
}

/// Pure path construction shared by the renderer and the command-line self-test.
enum EdgeMotionEffectGeometry {
    static let drawingCeiling: CGFloat = 189

    static func directionalStrokes(
        in bounds: CGRect,
        edge: EdgeIdleBehavior.Edge,
        direction: EdgeMotionPathDirection
    ) -> [EdgeMotionStroke] {
        guard let rect = usableRect(in: bounds) else { return [] }

        let normalized: [(CGPoint, CGPoint, CGPoint)]
        switch edge {
        case .left:
            normalized = [
                (CGPoint(x: 0.56, y: 0.68), CGPoint(x: 0.31, y: 0.78), CGPoint(x: 0.07, y: 0.72)),
                (CGPoint(x: 0.48, y: 0.49), CGPoint(x: 0.25, y: 0.55), CGPoint(x: 0.05, y: 0.46)),
                (CGPoint(x: 0.43, y: 0.31), CGPoint(x: 0.22, y: 0.27), CGPoint(x: 0.09, y: 0.20)),
            ]
        case .right:
            normalized = [
                (CGPoint(x: 0.44, y: 0.68), CGPoint(x: 0.69, y: 0.78), CGPoint(x: 0.93, y: 0.72)),
                (CGPoint(x: 0.52, y: 0.49), CGPoint(x: 0.75, y: 0.55), CGPoint(x: 0.95, y: 0.46)),
                (CGPoint(x: 0.57, y: 0.31), CGPoint(x: 0.78, y: 0.27), CGPoint(x: 0.91, y: 0.20)),
            ]
        case .bottom:
            normalized = [
                (CGPoint(x: 0.30, y: 0.72), CGPoint(x: 0.24, y: 0.42), CGPoint(x: 0.20, y: 0.08)),
                (CGPoint(x: 0.50, y: 0.82), CGPoint(x: 0.53, y: 0.46), CGPoint(x: 0.50, y: 0.06)),
                (CGPoint(x: 0.70, y: 0.70), CGPoint(x: 0.77, y: 0.38), CGPoint(x: 0.81, y: 0.10)),
            ]
        }

        let entrance = normalized.map { start, control, end in
            EdgeMotionStroke(
                start: point(start, in: rect),
                control: point(control, in: rect),
                end: point(end, in: rect)
            )
        }
        switch direction {
        case .entrance:
            return entrance
        case .exit:
            return entrance.map { $0.reversed() }
        }
    }

    static func ambientScan(
        in bounds: CGRect,
        edge: EdgeIdleBehavior.Edge
    ) -> EdgeMotionStroke? {
        guard let rect = usableRect(in: bounds) else { return nil }

        let normalized: (CGPoint, CGPoint, CGPoint)
        switch edge {
        case .left:
            normalized = (
                CGPoint(x: 0.11, y: 0.22),
                CGPoint(x: 0.45, y: 0.52),
                CGPoint(x: 0.13, y: 0.82)
            )
        case .right:
            normalized = (
                CGPoint(x: 0.89, y: 0.22),
                CGPoint(x: 0.55, y: 0.52),
                CGPoint(x: 0.87, y: 0.82)
            )
        case .bottom:
            normalized = (
                CGPoint(x: 0.20, y: 0.13),
                CGPoint(x: 0.50, y: 0.54),
                CGPoint(x: 0.80, y: 0.13)
            )
        }

        return EdgeMotionStroke(
            start: point(normalized.0, in: rect),
            control: point(normalized.1, in: rect),
            end: point(normalized.2, in: rect)
        )
    }

    private static func usableRect(in bounds: CGRect) -> CGRect? {
        guard !bounds.isNull,
              !bounds.isEmpty,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.minX.isFinite,
              bounds.minY.isFinite
        else { return nil }

        let maximumY = min(bounds.maxY, drawingCeiling)
        guard maximumY > bounds.minY else { return nil }
        return CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: maximumY - bounds.minY
        )
    }

    private static func point(_ normalized: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }
}
