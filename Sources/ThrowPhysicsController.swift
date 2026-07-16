import AppKit

/// Tracks a short tail of global mouse positions and derives a release velocity in
/// AppKit's point coordinate space. Points are independent of a display's Retina
/// backing scale, so one threshold behaves consistently across displays.
final class DragVelocityTracker {
    private struct Sample {
        let position: NSPoint
        let timestamp: TimeInterval
    }

    private let historyDuration: TimeInterval
    private let minimumMovement: CGFloat
    private let maximumEstimatedSpeed: CGFloat
    private var samples: [Sample] = []

    init(
        historyDuration: TimeInterval = 0.16,
        minimumMovement: CGFloat = 0.75,
        maximumEstimatedSpeed: CGFloat = 6_000
    ) {
        self.historyDuration = min(max(historyDuration, 0.12), 0.18)
        self.minimumMovement = max(0, minimumMovement)
        self.maximumEstimatedSpeed = max(1, maximumEstimatedSpeed)
    }

    func reset(
        at position: NSPoint? = nil,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        samples.removeAll(keepingCapacity: true)
        if let position {
            samples.append(Sample(position: position, timestamp: timestamp))
        }
    }

    func add(
        position: NSPoint,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if let last = samples.last, timestamp < last.timestamp {
            // NSEvent timestamps and systemUptime share a monotonic clock on macOS,
            // but reset defensively if a caller mixes clock sources.
            reset(at: position, timestamp: timestamp)
            return
        }

        if let last = samples.last,
           timestamp - last.timestamp < 1.0 / 240.0,
           distance(from: last.position, to: position) < minimumMovement {
            samples[samples.count - 1] = Sample(position: position, timestamp: timestamp)
        } else {
            samples.append(Sample(position: position, timestamp: timestamp))
        }

        prune(relativeTo: timestamp)
    }

    /// Robust release velocity in points per second. Pairwise median slopes make a
    /// single bad mouse sample much less influential than a first/last estimate.
    func estimatedVelocity(
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> CGVector {
        prune(relativeTo: timestamp)
        guard samples.count >= 3,
              let first = samples.first,
              let last = samples.last,
              last.timestamp - first.timestamp >= 0.025
        else {
            return .zero
        }

        var xSlopes: [CGFloat] = []
        var ySlopes: [CGFloat] = []
        xSlopes.reserveCapacity(samples.count * 2)
        ySlopes.reserveCapacity(samples.count * 2)

        for startIndex in 0..<(samples.count - 1) {
            for endIndex in (startIndex + 1)..<samples.count {
                let start = samples[startIndex]
                let end = samples[endIndex]
                let deltaTime = end.timestamp - start.timestamp
                guard deltaTime >= 1.0 / 120.0 else { continue }

                xSlopes.append((end.position.x - start.position.x) / CGFloat(deltaTime))
                ySlopes.append((end.position.y - start.position.y) / CGFloat(deltaTime))
            }
        }

        guard !xSlopes.isEmpty else { return .zero }

        let displacement = distance(from: first.position, to: last.position)
        let pathLength = zip(samples, samples.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + distance(from: pair.0.position, to: pair.1.position)
        }
        guard displacement >= minimumMovement * 2 || pathLength >= minimumMovement * 5 else {
            return .zero
        }

        var result = CGVector(dx: median(xSlopes), dy: median(ySlopes))
        let speed = hypot(result.dx, result.dy)
        if speed > maximumEstimatedSpeed {
            let scale = maximumEstimatedSpeed / speed
            result.dx *= scale
            result.dy *= scale
        }
        return result
    }

    var velocity: CGVector {
        estimatedVelocity()
    }

    private func prune(relativeTo timestamp: TimeInterval) {
        let cutoff = timestamp - historyDuration
        while samples.count > 2, samples[1].timestamp < cutoff {
            samples.removeFirst()
        }
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    private func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        hypot(end.x - start.x, end.y - start.y)
    }
}

struct ThrowCollisionEdges: OptionSet {
    let rawValue: Int

    static let left = ThrowCollisionEdges(rawValue: 1 << 0)
    static let right = ThrowCollisionEdges(rawValue: 1 << 1)
    static let bottom = ThrowCollisionEdges(rawValue: 1 << 2)
    static let top = ThrowCollisionEdges(rawValue: 1 << 3)
}

/// Lightweight inertial motion for a borderless AppKit pet window.
///
/// All methods that move the window are intended to be called on the main thread.
final class ThrowPhysicsController {
    enum ImpactSeverity: String, CaseIterable {
        case light
        case medium
        case heavy
    }

    struct Configuration {
        /// A deliberate flick should exceed this; ordinary drag releases should not.
        var minimumThrowSpeed: CGFloat = 850
        var maximumInitialSpeed: CGFloat = 4_200
        var gravity: CGFloat = -1_350
        var airResistancePerSecond: CGFloat = 0.9
        var edgeRestitution: CGFloat = 0.56
        var tangentialDamping: CGFloat = 0.84
        var settlementSpeed: CGFloat = 85
        var normalizationSpeed: CGFloat = 2_200
        var frameInterval: TimeInterval = 1.0 / 60.0
        var maximumFlightDuration: TimeInterval = 8.0
        var maximumSubstepDistance: CGFloat = 18

        /// Incoming speed normal to the contacted edge. With the app's 720 pt/s
        /// throw threshold, a direct minimum-speed throw is medium, while a fall
        /// accelerated by 1,600 pt/s² across a typical desktop reaches heavy.
        var mediumImpactSpeed: CGFloat = 420
        var heavyImpactSpeed: CGFloat = 1_100

        func impactSeverity(forPreCollisionNormalSpeed speed: CGFloat) -> ImpactSeverity {
            let mediumThreshold = max(0, mediumImpactSpeed)
            let heavyThreshold = max(mediumThreshold, heavyImpactSpeed)
            let clampedSpeed = max(0, speed)

            if clampedSpeed >= heavyThreshold {
                return .heavy
            }
            if clampedSpeed >= mediumThreshold {
                return .medium
            }
            return .light
        }
    }

    struct MotionState {
        let velocity: CGVector
        let normalizedVelocity: CGVector
        let normalizedSpeed: CGFloat
        let normalizedRotation: CGFloat
        let windowFrame: NSRect
    }

    /// Collision information captured before restitution and tangential damping
    /// mutate the velocity. `normalSpeed` is the strongest incoming normal
    /// component if one timer tick contains a corner or multiple contacts.
    struct BounceImpact {
        let edges: ThrowCollisionEdges
        let preCollisionVelocity: CGVector
        let normalSpeed: CGFloat
        let severity: ImpactSeverity

        init?(
            edges: ThrowCollisionEdges,
            preCollisionVelocity: CGVector,
            configuration: Configuration
        ) {
            let normalSpeed = Self.preCollisionNormalSpeed(
                for: preCollisionVelocity,
                against: edges
            )
            guard !edges.isEmpty, normalSpeed > 0 else { return nil }

            self.edges = edges
            self.preCollisionVelocity = preCollisionVelocity
            self.normalSpeed = normalSpeed
            severity = configuration.impactSeverity(forPreCollisionNormalSpeed: normalSpeed)
        }

        /// Returns only velocity directed into the supplied desktop edge. Motion
        /// away from an edge contributes zero instead of being misread as impact.
        static func preCollisionNormalSpeed(
            for velocity: CGVector,
            against edges: ThrowCollisionEdges
        ) -> CGFloat {
            var strongest: CGFloat = 0
            if edges.contains(.left) {
                strongest = max(strongest, -velocity.dx)
            }
            if edges.contains(.right) {
                strongest = max(strongest, velocity.dx)
            }
            if edges.contains(.bottom) {
                strongest = max(strongest, -velocity.dy)
            }
            if edges.contains(.top) {
                strongest = max(strongest, velocity.dy)
            }
            return max(0, strongest)
        }

        fileprivate func merging(
            _ other: BounceImpact,
            configuration: Configuration
        ) -> BounceImpact {
            let strongest = other.normalSpeed > normalSpeed ? other : self
            let mergedSpeed = max(normalSpeed, other.normalSpeed)
            return BounceImpact(
                edges: edges.union(other.edges),
                preCollisionVelocity: strongest.preCollisionVelocity,
                normalSpeed: mergedSpeed,
                severity: configuration.impactSeverity(
                    forPreCollisionNormalSpeed: mergedSpeed
                )
            )
        }

        private init(
            edges: ThrowCollisionEdges,
            preCollisionVelocity: CGVector,
            normalSpeed: CGFloat,
            severity: ImpactSeverity
        ) {
            self.edges = edges
            self.preCollisionVelocity = preCollisionVelocity
            self.normalSpeed = normalSpeed
            self.severity = severity
        }
    }

    var onStarted: ((MotionState) -> Void)?
    /// The motion state reflects the rebound; BounceImpact preserves the incoming
    /// normal velocity so impact reactions never have to infer it from restitution.
    var onBounce: ((MotionState, BounceImpact) -> Void)?
    var onSettled: ((MotionState) -> Void)?

    private(set) var isRunning = false
    private(set) var velocity = CGVector.zero
    private(set) var normalizedVelocity = CGVector.zero
    private(set) var normalizedSpeed: CGFloat = 0
    private(set) var normalizedRotation: CGFloat = 0

    private weak var window: NSWindow?
    private let configuration: Configuration
    private var visibleFrames: [NSRect] = []
    private var timer: Timer?
    private var lastTick: TimeInterval = 0
    private var flightStartedAt: TimeInterval = 0

    init(window: NSWindow, configuration: Configuration = Configuration()) {
        self.window = window
        self.configuration = configuration
    }

    deinit {
        timer?.invalidate()
    }

    func shouldThrow(velocity: CGVector) -> Bool {
        hypot(velocity.dx, velocity.dy) >= configuration.minimumThrowSpeed
    }

    /// Starts a throw using the supplied screens' visible frames. Adjacent displays
    /// are treated as one traversable desktop where their visible areas touch.
    @discardableResult
    func start(
        initialVelocity: CGVector,
        availableScreens: [NSScreen] = NSScreen.screens
    ) -> Bool {
        start(
            initialVelocity: initialVelocity,
            visibleFrames: availableScreens.map(\.visibleFrame)
        )
    }

    /// Rect-based overload is convenient for deterministic tests and callers that
    /// already snapshot NSScreen.visibleFrame values.
    @discardableResult
    func start(initialVelocity: CGVector, visibleFrames: [NSRect]) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()

        guard let window, shouldThrow(velocity: initialVelocity) else { return false }
        let usableFrames = visibleFrames.filter { !$0.isEmpty && !$0.isNull }
        guard !usableFrames.isEmpty else { return false }

        self.visibleFrames = usableFrames
        clampWindowFullyOnScreen(window)
        velocity = limited(initialVelocity, to: configuration.maximumInitialSpeed)
        updateNormalizedValues()

        let now = ProcessInfo.processInfo.systemUptime
        lastTick = now
        flightStartedAt = now
        isRunning = true

        let timer = Timer(timeInterval: configuration.frameInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = min(configuration.frameInterval * 0.2, 1.0 / 240.0)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        onStarted?(motionState(for: window))
        return isRunning
    }

    /// Stops flight immediately without firing `onSettled`, allowing a fresh grab.
    func cancel() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        velocity = .zero
        normalizedVelocity = .zero
        normalizedSpeed = 0
        normalizedRotation = 0
        visibleFrames.removeAll(keepingCapacity: true)
    }

    private func tick() {
        guard isRunning, let window else {
            cancel()
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let elapsedSinceTick = now - lastTick
        guard elapsedSinceTick > 0 else { return }
        lastTick = now

        if now - flightStartedAt >= configuration.maximumFlightDuration {
            settle(window)
            return
        }

        // Cap a delayed frame and use spatial substeps to avoid tunnelling over a
        // narrow gap between displays or through a desktop edge.
        let deltaTime = min(elapsedSinceTick, 1.0 / 20.0)
        velocity.dy += configuration.gravity * CGFloat(deltaTime)
        let drag = CGFloat(exp(-Double(configuration.airResistancePerSecond) * deltaTime))
        velocity.dx *= drag
        velocity.dy *= drag

        let travelDistance = hypot(velocity.dx, velocity.dy) * CGFloat(deltaTime)
        let stepCount = max(1, min(16, Int(ceil(travelDistance / configuration.maximumSubstepDistance))))
        let substepDuration = CGFloat(deltaTime) / CGFloat(stepCount)
        var frame = window.frame
        var bounceImpact: BounceImpact?

        for _ in 0..<stepCount {
            let displacement = CGVector(
                dx: velocity.dx * substepDuration,
                dy: velocity.dy * substepDuration
            )
            if let contact = advance(frame: &frame, displacement: displacement) {
                bounceImpact = bounceImpact.map {
                    $0.merging(contact, configuration: configuration)
                } ?? contact
            }
        }

        window.setFrameOrigin(frame.origin)
        updateNormalizedValues()
        let updatedState = motionState(for: window)

        if let bounceImpact {
            let state = updatedState
            onBounce?(state, bounceImpact)
            guard isRunning else { return }

            let isOnFloor = bounceImpact.edges.contains(.bottom)
            if isOnFloor,
               abs(velocity.dy) <= configuration.settlementSpeed,
               abs(velocity.dx) <= configuration.settlementSpeed {
                settle(window, stateBeforeStopping: state)
                return
            }
        }
    }

    private func advance(frame: inout NSRect, displacement: CGVector) -> BounceImpact? {
        let proposed = frame.offsetBy(dx: displacement.dx, dy: displacement.dy)
        if isFullyCoveredByVisibleDesktop(proposed) {
            frame = proposed
            return nil
        }

        // 同一子步可能同时撞到水平和垂直边缘。先保留完整入射速度并收集
        // 所有边缘，再统一分级；不能让第一个方向的阻尼污染第二个方向。
        let preCollisionVelocity = velocity
        var collidedEdges: ThrowCollisionEdges = []
        let horizontal = frame.offsetBy(dx: displacement.dx, dy: 0)
        if isFullyCoveredByVisibleDesktop(horizontal) {
            frame = horizontal
        } else if displacement.dx != 0 {
            let edge: ThrowCollisionEdges = displacement.dx > 0 ? .right : .left
            collidedEdges.insert(edge)
            velocity.dx = -velocity.dx * configuration.edgeRestitution
            velocity.dy *= configuration.tangentialDamping
        }

        let vertical = frame.offsetBy(dx: 0, dy: displacement.dy)
        if isFullyCoveredByVisibleDesktop(vertical) {
            frame = vertical
        } else if displacement.dy != 0 {
            let edge: ThrowCollisionEdges = displacement.dy > 0 ? .top : .bottom
            collidedEdges.insert(edge)
            velocity.dy = -velocity.dy * configuration.edgeRestitution
            velocity.dx *= configuration.tangentialDamping
        }

        return BounceImpact(
            edges: collidedEdges,
            preCollisionVelocity: preCollisionVelocity,
            configuration: configuration
        )
    }

    /// Checks whether every part of the pet window is covered by the union of all
    /// screen visible frames. This permits a window to straddle adjacent displays.
    private func isFullyCoveredByVisibleDesktop(_ frame: NSRect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let clipped = visibleFrames.compactMap { screenFrame -> NSRect? in
            let intersection = frame.intersection(screenFrame)
            return intersection.isNull || intersection.isEmpty ? nil : intersection
        }
        guard !clipped.isEmpty else { return false }

        let coveredArea = unionArea(of: clipped)
        let requiredArea = frame.width * frame.height
        return coveredArea >= requiredArea - 0.5
    }

    private func unionArea(of rectangles: [NSRect]) -> CGFloat {
        let xCoordinates = Array(Set(rectangles.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xCoordinates.count >= 2 else { return 0 }
        var area: CGFloat = 0

        for index in 0..<(xCoordinates.count - 1) {
            let left = xCoordinates[index]
            let right = xCoordinates[index + 1]
            let width = right - left
            guard width > 0 else { continue }
            let midpoint = (left + right) / 2

            let intervals = rectangles
                .filter { $0.minX <= midpoint && midpoint <= $0.maxX }
                .map { ($0.minY, $0.maxY) }
                .sorted { $0.0 < $1.0 }
            guard var current = intervals.first else { continue }
            var coveredHeight: CGFloat = 0

            for interval in intervals.dropFirst() {
                if interval.0 <= current.1 {
                    current.1 = max(current.1, interval.1)
                } else {
                    coveredHeight += current.1 - current.0
                    current = interval
                }
            }
            coveredHeight += current.1 - current.0
            area += width * coveredHeight
        }
        return area
    }

    private func settle(_ window: NSWindow, stateBeforeStopping: MotionState? = nil) {
        clampWindowFullyOnScreen(window)
        let finalState = stateBeforeStopping ?? motionState(for: window)

        timer?.invalidate()
        timer = nil
        isRunning = false
        velocity = .zero
        normalizedVelocity = .zero
        normalizedSpeed = 0
        normalizedRotation = 0
        visibleFrames.removeAll(keepingCapacity: true)

        onSettled?(MotionState(
            velocity: finalState.velocity,
            normalizedVelocity: finalState.normalizedVelocity,
            normalizedSpeed: finalState.normalizedSpeed,
            normalizedRotation: finalState.normalizedRotation,
            windowFrame: window.frame
        ))
    }

    private func clampWindowFullyOnScreen(_ window: NSWindow) {
        guard !visibleFrames.isEmpty else { return }
        let frame = window.frame
        let target = visibleFrames.max { lhs, rhs in
            screenAffinity(frame: frame, screen: lhs) < screenAffinity(frame: frame, screen: rhs)
        } ?? visibleFrames[0]

        let minimumX = target.minX
        let maximumX = max(target.minX, target.maxX - frame.width)
        let minimumY = target.minY
        let maximumY = max(target.minY, target.maxY - frame.height)
        let origin = NSPoint(
            x: min(max(frame.minX, minimumX), maximumX),
            y: min(max(frame.minY, minimumY), maximumY)
        )
        window.setFrameOrigin(origin)
    }

    private func screenAffinity(frame: NSRect, screen: NSRect) -> CGFloat {
        let intersection = frame.intersection(screen)
        if !intersection.isNull, !intersection.isEmpty {
            return intersection.width * intersection.height
        }
        let frameCenter = NSPoint(x: frame.midX, y: frame.midY)
        let nearest = NSPoint(
            x: min(max(frameCenter.x, screen.minX), screen.maxX),
            y: min(max(frameCenter.y, screen.minY), screen.maxY)
        )
        return -pow(frameCenter.x - nearest.x, 2) - pow(frameCenter.y - nearest.y, 2)
    }

    private func limited(_ vector: CGVector, to maximum: CGFloat) -> CGVector {
        let magnitude = hypot(vector.dx, vector.dy)
        guard magnitude > maximum, magnitude > 0 else { return vector }
        let scale = maximum / magnitude
        return CGVector(dx: vector.dx * scale, dy: vector.dy * scale)
    }

    private func updateNormalizedValues() {
        let reference = max(1, configuration.normalizationSpeed)
        normalizedVelocity = CGVector(
            dx: clamp(velocity.dx / reference, minimum: -1, maximum: 1),
            dy: clamp(velocity.dy / reference, minimum: -1, maximum: 1)
        )
        normalizedSpeed = clamp(hypot(velocity.dx, velocity.dy) / reference, minimum: 0, maximum: 1)
        normalizedRotation = clamp(
            normalizedVelocity.dx + normalizedVelocity.dy * 0.12,
            minimum: -1,
            maximum: 1
        )
    }

    private func motionState(for window: NSWindow) -> MotionState {
        MotionState(
            velocity: velocity,
            normalizedVelocity: normalizedVelocity,
            normalizedSpeed: normalizedSpeed,
            normalizedRotation: normalizedRotation,
            windowFrame: window.frame
        )
    }

    private func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(value, minimum), maximum)
    }
}
