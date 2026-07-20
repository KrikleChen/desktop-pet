import AppKit

enum MouseFollowFacing: Equatable {
    case left
    case right
}

enum MouseFollowMotionState: Equatable {
    case disabled
    case paused
    case stopped
    case accelerating
    case cruising
    case decelerating
}

struct MouseFollowFrame {
    /// Global AppKit screen coordinates suitable for `NSWindow.setFrameOrigin`.
    let windowOrigin: NSPoint
    let velocity: CGVector
    let facing: MouseFollowFacing
    let motionState: MouseFollowMotionState
    /// Stabilized cursor/host target used for this step.
    let targetPoint: NSPoint
    /// Visible frame selected from the target, including negative-coordinate screens.
    let targetVisibleFrame: NSRect?

    var speed: CGFloat {
        hypot(velocity.dx, velocity.dy)
    }

    var isMoving: Bool {
        switch motionState {
        case .accelerating, .cruising, .decelerating:
            return speed > 0
        case .disabled, .paused, .stopped:
            return false
        }
    }
}

struct MouseFollowConfiguration {
    var acceleration: CGFloat = 1_250
    var maximumSpeed: CGFloat = 760
    var deceleration: CGFloat = 1_650
    var stopRadius: CGFloat = 20
    /// Hysteresis: a stopped pet does not restart until the cursor leaves this radius.
    var restartRadius: CGFloat = 34
    /// Cursor samples smaller than this accumulate instead of moving the target every frame.
    var targetUpdateThreshold: CGFloat = 4
    var idleSpeedThreshold: CGFloat = 7
    var facingVelocityThreshold: CGFloat = 10
    /// Prevents a delayed host timer from teleporting the pet in one update.
    var maximumTimeStep: TimeInterval = 1.0 / 20.0

    init(
        acceleration: CGFloat = 1_250,
        maximumSpeed: CGFloat = 760,
        deceleration: CGFloat = 1_650,
        stopRadius: CGFloat = 20,
        restartRadius: CGFloat = 34,
        targetUpdateThreshold: CGFloat = 4,
        idleSpeedThreshold: CGFloat = 7,
        facingVelocityThreshold: CGFloat = 10,
        maximumTimeStep: TimeInterval = 1.0 / 20.0
    ) {
        precondition(acceleration > 0 && acceleration.isFinite)
        precondition(maximumSpeed > 0 && maximumSpeed.isFinite)
        precondition(deceleration > 0 && deceleration.isFinite)
        precondition(stopRadius >= 0 && stopRadius.isFinite)
        precondition(restartRadius > stopRadius && restartRadius.isFinite)
        precondition(targetUpdateThreshold >= 0 && targetUpdateThreshold.isFinite)
        precondition(idleSpeedThreshold >= 0 && idleSpeedThreshold.isFinite)
        precondition(facingVelocityThreshold >= 0 && facingVelocityThreshold.isFinite)
        precondition(maximumTimeStep > 0 && maximumTimeStep.isFinite)

        self.acceleration = acceleration
        self.maximumSpeed = maximumSpeed
        self.deceleration = deceleration
        self.stopRadius = stopRadius
        self.restartRadius = restartRadius
        self.targetUpdateThreshold = targetUpdateThreshold
        self.idleSpeedThreshold = idleSpeedThreshold
        self.facingVelocityThreshold = facingVelocityThreshold
        self.maximumTimeStep = maximumTimeStep
    }
}

/// Host-driven mouse following motion. It owns no timer, event monitor, window,
/// permission request, or injected input. `PetView` can call `stepUsingCurrentMouse`
/// from its existing frame loop, or supply a target to `step` directly.
final class MouseFollowController {
    let configuration: MouseFollowConfiguration

    private(set) var isEnabled = false
    private(set) var isPaused = false
    private(set) var currentOrigin: NSPoint
    private(set) var velocity = CGVector.zero
    private(set) var facing: MouseFollowFacing = .right
    private(set) var motionState: MouseFollowMotionState = .disabled

    private var unconstrainedOrigin: NSPoint
    private var stabilizedTargetPoint: NSPoint?
    private var isStoppedByHysteresis = true

    init(
        configuration: MouseFollowConfiguration = MouseFollowConfiguration(),
        initialWindowOrigin: NSPoint = .zero
    ) {
        self.configuration = configuration
        currentOrigin = initialWindowOrigin
        unconstrainedOrigin = initialWindowOrigin
    }

    func enable(windowOrigin: NSPoint? = nil) {
        if let windowOrigin, Self.isFinite(windowOrigin) {
            currentOrigin = windowOrigin
            unconstrainedOrigin = windowOrigin
        } else {
            unconstrainedOrigin = currentOrigin
        }
        isEnabled = true
        isPaused = false
        velocity = .zero
        motionState = .stopped
        stabilizedTargetPoint = nil
        isStoppedByHysteresis = true
    }

    func disable() {
        isEnabled = false
        isPaused = false
        velocity = .zero
        unconstrainedOrigin = currentOrigin
        motionState = .disabled
        stabilizedTargetPoint = nil
        isStoppedByHysteresis = true
    }

    func pause() {
        guard isEnabled else { return }
        isPaused = true
        velocity = .zero
        unconstrainedOrigin = currentOrigin
        motionState = .paused
        isStoppedByHysteresis = true
    }

    func resume() {
        guard isEnabled, isPaused else { return }
        isPaused = false
        velocity = .zero
        motionState = .stopped
        isStoppedByHysteresis = true
    }

    /// Call after a manual drag or another feature has authoritatively moved the window.
    func synchronizeWindowOrigin(_ origin: NSPoint) {
        guard Self.isFinite(origin) else { return }
        currentOrigin = origin
        unconstrainedOrigin = origin
        velocity = .zero
        isStoppedByHysteresis = true
        if isEnabled {
            motionState = isPaused ? .paused : .stopped
        }
    }

    /// Samples the macOS global mouse position without installing any event monitor.
    @discardableResult
    func stepUsingCurrentMouse(
        deltaTime: TimeInterval,
        windowSize: NSSize,
        visibleFrames: [NSRect]
    ) -> MouseFollowFrame {
        step(
            deltaTime: deltaTime,
            targetPoint: NSEvent.mouseLocation,
            windowSize: windowSize,
            visibleFrames: visibleFrames
        )
    }

    /// Deterministic motion entry point. `targetPoint` is a global screen point;
    /// the pet window follows it with its center while remaining in visible screen space.
    @discardableResult
    func step(
        deltaTime: TimeInterval,
        targetPoint rawTargetPoint: NSPoint,
        windowSize rawWindowSize: NSSize,
        visibleFrames rawVisibleFrames: [NSRect]
    ) -> MouseFollowFrame {
        let targetPoint = stabilizedTarget(for: rawTargetPoint)
        let windowSize = Self.sanitizedWindowSize(rawWindowSize)
        let visibleFrames = rawVisibleFrames.filter(Self.isUsableVisibleFrame)
        let targetFrame = Self.visibleFrame(containingOrNearestTo: targetPoint, in: visibleFrames)

        guard isEnabled else {
            motionState = .disabled
            return makeFrame(targetPoint: targetPoint, targetVisibleFrame: targetFrame)
        }
        guard !isPaused else {
            velocity = .zero
            motionState = .paused
            return makeFrame(targetPoint: targetPoint, targetVisibleFrame: targetFrame)
        }
        guard let targetFrame else {
            velocity = .zero
            motionState = .stopped
            isStoppedByHysteresis = true
            return makeFrame(targetPoint: targetPoint, targetVisibleFrame: nil)
        }

        let centeredTargetOrigin = NSPoint(
            x: targetPoint.x - windowSize.width * 0.5,
            y: targetPoint.y - windowSize.height * 0.5
        )
        let desiredOrigin = Self.clampedWindowOrigin(
            centeredTargetOrigin,
            windowSize: windowSize,
            inside: targetFrame
        )
        var offset = Self.vector(from: unconstrainedOrigin, to: desiredOrigin)
        var distance = Self.length(offset)

        if isStoppedByHysteresis {
            guard distance >= configuration.restartRadius else {
                velocity = .zero
                motionState = .stopped
                currentOrigin = Self.clampedToVisibleUnion(
                    unconstrainedOrigin,
                    windowSize: windowSize,
                    visibleFrames: visibleFrames,
                    preferredFrame: targetFrame
                )
                unconstrainedOrigin = currentOrigin
                return makeFrame(targetPoint: targetPoint, targetVisibleFrame: targetFrame)
            }
            isStoppedByHysteresis = false
        }

        let timeStep = Self.sanitizedTimeStep(
            deltaTime,
            maximum: configuration.maximumTimeStep
        )
        guard timeStep > 0 else {
            currentOrigin = Self.clampedToVisibleUnion(
                unconstrainedOrigin,
                windowSize: windowSize,
                visibleFrames: visibleFrames,
                preferredFrame: targetFrame
            )
            unconstrainedOrigin = currentOrigin
            return makeFrame(targetPoint: targetPoint, targetVisibleFrame: targetFrame)
        }

        let oldSpeed = Self.length(velocity)
        let remainingDistance = max(0, distance - configuration.stopRadius)
        let brakingSpeed = sqrt(2 * configuration.deceleration * remainingDistance)
        let desiredSpeed = min(configuration.maximumSpeed, brakingSpeed)
        let direction = distance > 0 ? Self.scaled(offset, by: 1 / distance) : .zero
        let desiredVelocity = Self.scaled(direction, by: desiredSpeed)
        let alignment = Self.dot(velocity, direction)
        let shouldUseDeceleration = oldSpeed > desiredSpeed + 0.5 || alignment < 0
        let rate = shouldUseDeceleration
            ? configuration.deceleration
            : configuration.acceleration
        velocity = Self.approach(
            velocity,
            toward: desiredVelocity,
            maximumDelta: rate * CGFloat(timeStep)
        )
        velocity = Self.limited(velocity, to: configuration.maximumSpeed)
        updateFacing(intent: offset)

        let proposedOrigin = NSPoint(
            x: unconstrainedOrigin.x + velocity.dx * CGFloat(timeStep),
            y: unconstrainedOrigin.y + velocity.dy * CGFloat(timeStep)
        )
        let remainingAfterStep = Self.vector(from: proposedOrigin, to: desiredOrigin)
        let didPassTarget = Self.dot(offset, remainingAfterStep) <= 0
        if didPassTarget {
            unconstrainedOrigin = desiredOrigin
            velocity = .zero
            isStoppedByHysteresis = true
            motionState = .stopped
        } else {
            unconstrainedOrigin = proposedOrigin
            offset = remainingAfterStep
            distance = Self.length(offset)
            let newSpeed = Self.length(velocity)
            if distance <= configuration.stopRadius,
               newSpeed <= max(
                   configuration.idleSpeedThreshold,
                   configuration.deceleration * CGFloat(timeStep)
               ) {
                velocity = .zero
                isStoppedByHysteresis = true
                motionState = .stopped
            } else if desiredSpeed < configuration.maximumSpeed - 0.5 {
                motionState = .decelerating
            } else if newSpeed >= configuration.maximumSpeed * 0.96 {
                motionState = .cruising
            } else {
                motionState = .accelerating
            }
        }

        currentOrigin = Self.clampedToVisibleUnion(
            unconstrainedOrigin,
            windowSize: windowSize,
            visibleFrames: visibleFrames,
            preferredFrame: targetFrame
        )
        return makeFrame(targetPoint: targetPoint, targetVisibleFrame: targetFrame)
    }

    private func stabilizedTarget(for candidate: NSPoint) -> NSPoint {
        guard Self.isFinite(candidate) else {
            return stabilizedTargetPoint ?? NSPoint(
                x: currentOrigin.x,
                y: currentOrigin.y
            )
        }
        guard let stabilizedTargetPoint else {
            self.stabilizedTargetPoint = candidate
            return candidate
        }
        let movement = hypot(
            candidate.x - stabilizedTargetPoint.x,
            candidate.y - stabilizedTargetPoint.y
        )
        if movement >= configuration.targetUpdateThreshold {
            self.stabilizedTargetPoint = candidate
            return candidate
        }
        return stabilizedTargetPoint
    }

    private func updateFacing(intent: CGVector) {
        let horizontal: CGFloat
        if abs(velocity.dx) >= configuration.facingVelocityThreshold {
            horizontal = velocity.dx
        } else {
            horizontal = intent.dx
        }
        guard abs(horizontal) >= configuration.facingVelocityThreshold else { return }
        facing = horizontal < 0 ? .left : .right
    }

    private func makeFrame(
        targetPoint: NSPoint,
        targetVisibleFrame: NSRect?
    ) -> MouseFollowFrame {
        MouseFollowFrame(
            windowOrigin: currentOrigin,
            velocity: velocity,
            facing: facing,
            motionState: motionState,
            targetPoint: targetPoint,
            targetVisibleFrame: targetVisibleFrame
        )
    }

    private static func sanitizedTimeStep(
        _ deltaTime: TimeInterval,
        maximum: TimeInterval
    ) -> TimeInterval {
        guard deltaTime.isFinite, deltaTime > 0 else { return 0 }
        return min(deltaTime, maximum)
    }

    private static func sanitizedWindowSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: size.width.isFinite ? max(1, size.width) : 1,
            height: size.height.isFinite ? max(1, size.height) : 1
        )
    }

    private static func isFinite(_ point: NSPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isUsableVisibleFrame(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
            && !frame.isNull
    }

    private static func visibleFrame(
        containingOrNearestTo point: NSPoint,
        in frames: [NSRect]
    ) -> NSRect? {
        if let containing = frames.first(where: { $0.contains(point) }) {
            return containing
        }
        return frames.min { lhs, rhs in
            squaredDistance(from: point, to: lhs)
                < squaredDistance(from: point, to: rhs)
        }
    }

    private static func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - x
        let dy = point.y - y
        return dx * dx + dy * dy
    }

    private static func clampedWindowOrigin(
        _ origin: NSPoint,
        windowSize: NSSize,
        inside frame: NSRect
    ) -> NSPoint {
        let x: CGFloat
        if windowSize.width <= frame.width {
            x = min(max(origin.x, frame.minX), frame.maxX - windowSize.width)
        } else {
            x = frame.midX - windowSize.width * 0.5
        }
        let y: CGFloat
        if windowSize.height <= frame.height {
            y = min(max(origin.y, frame.minY), frame.maxY - windowSize.height)
        } else {
            y = frame.midY - windowSize.height * 0.5
        }
        return NSPoint(x: x, y: y)
    }

    /// Accepts smooth straddling across touching displays when all four window
    /// corners remain on some display. Gapped layouts use the nearest fully
    /// contained projection until the unconstrained trajectory reaches the next screen.
    private static func clampedToVisibleUnion(
        _ origin: NSPoint,
        windowSize: NSSize,
        visibleFrames: [NSRect],
        preferredFrame: NSRect
    ) -> NSPoint {
        guard !visibleFrames.isEmpty else { return origin }
        let inset: CGFloat = 0.01
        let corners = [
            NSPoint(x: origin.x + inset, y: origin.y + inset),
            NSPoint(x: origin.x + windowSize.width - inset, y: origin.y + inset),
            NSPoint(x: origin.x + inset, y: origin.y + windowSize.height - inset),
            NSPoint(
                x: origin.x + windowSize.width - inset,
                y: origin.y + windowSize.height - inset
            ),
        ]
        if corners.allSatisfy({ corner in
            visibleFrames.contains(where: { $0.contains(corner) })
        }) {
            return origin
        }

        let candidates = visibleFrames.map {
            clampedWindowOrigin(origin, windowSize: windowSize, inside: $0)
        }
        return candidates.min { lhs, rhs in
            let lhsDistance = squaredDistance(from: lhs, to: origin)
            let rhsDistance = squaredDistance(from: rhs, to: origin)
            if abs(lhsDistance - rhsDistance) > 0.001 {
                return lhsDistance < rhsDistance
            }
            let lhsPreferred = preferredFrame.contains(NSPoint(
                x: lhs.x + windowSize.width * 0.5,
                y: lhs.y + windowSize.height * 0.5
            ))
            let rhsPreferred = preferredFrame.contains(NSPoint(
                x: rhs.x + windowSize.width * 0.5,
                y: rhs.y + windowSize.height * 0.5
            ))
            return lhsPreferred && !rhsPreferred
        } ?? origin
    }

    private static func vector(from start: NSPoint, to end: NSPoint) -> CGVector {
        CGVector(dx: end.x - start.x, dy: end.y - start.y)
    }

    private static func squaredDistance(from start: NSPoint, to end: NSPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        return dx * dx + dy * dy
    }

    private static func length(_ vector: CGVector) -> CGFloat {
        hypot(vector.dx, vector.dy)
    }

    private static func scaled(_ vector: CGVector, by scalar: CGFloat) -> CGVector {
        CGVector(dx: vector.dx * scalar, dy: vector.dy * scalar)
    }

    private static func dot(_ lhs: CGVector, _ rhs: CGVector) -> CGFloat {
        lhs.dx * rhs.dx + lhs.dy * rhs.dy
    }

    private static func approach(
        _ value: CGVector,
        toward target: CGVector,
        maximumDelta: CGFloat
    ) -> CGVector {
        let delta = CGVector(dx: target.dx - value.dx, dy: target.dy - value.dy)
        let deltaLength = length(delta)
        guard deltaLength > maximumDelta, deltaLength > 0 else { return target }
        let scale = maximumDelta / deltaLength
        return CGVector(
            dx: value.dx + delta.dx * scale,
            dy: value.dy + delta.dy * scale
        )
    }

    private static func limited(_ vector: CGVector, to maximum: CGFloat) -> CGVector {
        let vectorLength = length(vector)
        guard vectorLength > maximum, vectorLength > 0 else { return vector }
        return scaled(vector, by: maximum / vectorLength)
    }
}
