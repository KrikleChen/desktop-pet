import AppKit

@main
struct MouseFollowControllerTestMain {
    private static let windowSize = NSSize(width: 120, height: 140)
    private static let primaryScreen = NSRect(x: 0, y: 0, width: 1_200, height: 800)

    static func main() {
        testAccelerationMaximumSpeedAndFacing()
        testBrakingStopAndJitterHysteresis()
        testPauseResumeAndDisable()
        testVisibleFrameClamping()
        testMultipleScreenSwitching()
        testDeterministicTargetInjection()
        testInvalidTimingAndMissingScreensAreSafe()
        print("鼠标跟随运动控制器自检通过。")
    }

    private static func testAccelerationMaximumSpeedAndFacing() {
        let configuration = MouseFollowConfiguration(
            acceleration: 600,
            maximumSpeed: 300,
            deceleration: 900,
            stopRadius: 12,
            restartRadius: 24,
            targetUpdateThreshold: 0,
            maximumTimeStep: 1.0 / 30.0
        )
        let controller = MouseFollowController(
            configuration: configuration,
            initialWindowOrigin: NSPoint(x: 40, y: 200)
        )
        controller.enable()

        var previousSpeed: CGFloat = 0
        var sawCruising = false
        for _ in 0..<150 {
            let frame = controller.step(
                deltaTime: 1.0 / 60.0,
                targetPoint: NSPoint(x: 1_100, y: 270),
                windowSize: windowSize,
                visibleFrames: [primaryScreen]
            )
            precondition(frame.speed <= configuration.maximumSpeed + 0.001)
            if frame.motionState == .accelerating {
                precondition(frame.speed + 0.001 >= previousSpeed)
            }
            sawCruising = sawCruising || frame.motionState == .cruising
            previousSpeed = frame.speed
        }
        precondition(sawCruising, "长距离跟随必须到达巡航状态")
        precondition(controller.facing == .right)

        controller.synchronizeWindowOrigin(NSPoint(x: 700, y: 200))
        _ = controller.step(
            deltaTime: 1.0 / 30.0,
            targetPoint: NSPoint(x: 100, y: 270),
            windowSize: windowSize,
            visibleFrames: [primaryScreen]
        )
        precondition(controller.facing == .left)
    }

    private static func testBrakingStopAndJitterHysteresis() {
        let configuration = MouseFollowConfiguration(
            acceleration: 900,
            maximumSpeed: 420,
            deceleration: 1_200,
            stopRadius: 14,
            restartRadius: 30,
            targetUpdateThreshold: 5,
            idleSpeedThreshold: 5,
            maximumTimeStep: 1.0 / 30.0
        )
        let controller = MouseFollowController(
            configuration: configuration,
            initialWindowOrigin: NSPoint(x: 40, y: 160)
        )
        controller.enable()

        let target = NSPoint(x: 520, y: 300)
        var sawDecelerating = false
        var finalFrame: MouseFollowFrame?
        for _ in 0..<600 {
            let frame = controller.step(
                deltaTime: 1.0 / 60.0,
                targetPoint: target,
                windowSize: windowSize,
                visibleFrames: [primaryScreen]
            )
            sawDecelerating = sawDecelerating || frame.motionState == .decelerating
            finalFrame = frame
            if frame.motionState == .stopped { break }
        }
        guard let stopped = finalFrame else { preconditionFailure("缺少输出帧") }
        precondition(sawDecelerating, "接近鼠标时必须进入减速阶段")
        precondition(stopped.motionState == .stopped)
        precondition(stopped.speed == 0)
        let stoppedOrigin = stopped.windowOrigin

        // Each sample stays below the target filter and restart hysteresis.
        for jitter in [
            NSPoint(x: 522, y: 299),
            NSPoint(x: 517, y: 303),
            NSPoint(x: 524, y: 297),
            NSPoint(x: 519, y: 301),
        ] {
            let frame = controller.step(
                deltaTime: 1.0 / 60.0,
                targetPoint: jitter,
                windowSize: windowSize,
                visibleFrames: [primaryScreen]
            )
            precondition(frame.motionState == .stopped)
            assertPoint(frame.windowOrigin, equals: stoppedOrigin, tolerance: 0.0001)
        }

        let restarted = controller.step(
            deltaTime: 1.0 / 60.0,
            targetPoint: NSPoint(x: target.x + 90, y: target.y),
            windowSize: windowSize,
            visibleFrames: [primaryScreen]
        )
        precondition(restarted.motionState == .accelerating)
        precondition(restarted.speed > 0)
    }

    private static func testPauseResumeAndDisable() {
        let controller = MouseFollowController(
            initialWindowOrigin: NSPoint(x: 50, y: 60)
        )
        controller.enable()
        for _ in 0..<20 {
            _ = controller.step(
                deltaTime: 1.0 / 60.0,
                targetPoint: NSPoint(x: 900, y: 500),
                windowSize: windowSize,
                visibleFrames: [primaryScreen]
            )
        }

        controller.pause()
        let pausedOrigin = controller.currentOrigin
        let paused = controller.step(
            deltaTime: 1,
            targetPoint: NSPoint(x: 1_100, y: 700),
            windowSize: windowSize,
            visibleFrames: [primaryScreen]
        )
        precondition(paused.motionState == .paused && paused.speed == 0)
        assertPoint(paused.windowOrigin, equals: pausedOrigin, tolerance: 0)

        controller.resume()
        let resumed = controller.step(
            deltaTime: 1.0 / 60.0,
            targetPoint: NSPoint(x: 1_100, y: 700),
            windowSize: windowSize,
            visibleFrames: [primaryScreen]
        )
        precondition(resumed.motionState == .accelerating && resumed.speed > 0)

        controller.disable()
        let disabledOrigin = controller.currentOrigin
        let disabled = controller.step(
            deltaTime: 1,
            targetPoint: NSPoint(x: 100, y: 100),
            windowSize: windowSize,
            visibleFrames: [primaryScreen]
        )
        precondition(disabled.motionState == .disabled && disabled.speed == 0)
        assertPoint(disabled.windowOrigin, equals: disabledOrigin, tolerance: 0)
    }

    private static func testVisibleFrameClamping() {
        let screen = NSRect(x: -700, y: 30, width: 700, height: 500)
        let nearEdgeController = MouseFollowController(
            initialWindowOrigin: NSPoint(x: -710, y: 100)
        )
        nearEdgeController.enable()
        let clippedWhileStopped = nearEdgeController.step(
            deltaTime: 1.0 / 60.0,
            targetPoint: NSPoint(x: -800, y: 170),
            windowSize: windowSize,
            visibleFrames: [screen]
        )
        precondition(clippedWhileStopped.motionState == .stopped)
        precondition(
            windowRect(clippedWhileStopped.windowOrigin, size: windowSize).isContained(in: screen)
        )

        let controller = MouseFollowController(
            initialWindowOrigin: NSPoint(x: -900, y: -100)
        )
        controller.enable()

        var lastFrame: MouseFollowFrame?
        for _ in 0..<500 {
            let frame = controller.step(
                deltaTime: 1.0 / 60.0,
                targetPoint: NSPoint(x: 100, y: 900),
                windowSize: windowSize,
                visibleFrames: [screen]
            )
            precondition(windowRect(frame.windowOrigin, size: windowSize).isContained(in: screen))
            lastFrame = frame
        }
        guard let lastFrame else { preconditionFailure("缺少夹取输出") }
        let clampedTarget = NSPoint(
            x: screen.maxX - windowSize.width,
            y: screen.maxY - windowSize.height
        )
        precondition(
            hypot(
                lastFrame.windowOrigin.x - clampedTarget.x,
                lastFrame.windowOrigin.y - clampedTarget.y
            ) <= controller.configuration.stopRadius + 0.01
        )
    }

    private static func testMultipleScreenSwitching() {
        let left = NSRect(x: -900, y: 20, width: 900, height: 680)
        let right = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        let controller = MouseFollowController(
            configuration: MouseFollowConfiguration(
                acceleration: 1_500,
                maximumSpeed: 900,
                deceleration: 1_800,
                stopRadius: 12,
                restartRadius: 24,
                targetUpdateThreshold: 0,
                maximumTimeStep: 1.0 / 30.0
            ),
            initialWindowOrigin: NSPoint(x: -700, y: 180)
        )
        controller.enable()

        var lastFrame: MouseFollowFrame?
        for _ in 0..<500 {
            lastFrame = controller.step(
                deltaTime: 1.0 / 60.0,
                targetPoint: NSPoint(x: 900, y: 500),
                windowSize: windowSize,
                visibleFrames: [left, right]
            )
        }
        guard let final = lastFrame else { preconditionFailure("缺少多屏输出") }
        precondition(final.targetVisibleFrame == right)
        precondition(windowRect(final.windowOrigin, size: windowSize).isContained(in: right))
        precondition(final.motionState == .stopped)

        // A target outside every display chooses and clamps to the nearest one.
        controller.synchronizeWindowOrigin(final.windowOrigin)
        let outside = controller.step(
            deltaTime: 1.0 / 60.0,
            targetPoint: NSPoint(x: -2_000, y: 300),
            windowSize: windowSize,
            visibleFrames: [left, right]
        )
        precondition(outside.targetVisibleFrame == left)
        precondition(outside.facing == .left)
    }

    private static func testDeterministicTargetInjection() {
        let configuration = MouseFollowConfiguration(targetUpdateThreshold: 0)
        let first = MouseFollowController(
            configuration: configuration,
            initialWindowOrigin: NSPoint(x: 40, y: 50)
        )
        let second = MouseFollowController(
            configuration: configuration,
            initialWindowOrigin: NSPoint(x: 40, y: 50)
        )
        first.enable()
        second.enable()

        let targets = (0..<300).map { index in
            NSPoint(
                x: 700 + CGFloat(index % 37) * 3,
                y: 500 + CGFloat(index % 19) * 2
            )
        }
        for target in targets {
            let lhs = first.step(
                deltaTime: 1.0 / 120.0,
                targetPoint: target,
                windowSize: windowSize,
                visibleFrames: [primaryScreen]
            )
            let rhs = second.step(
                deltaTime: 1.0 / 120.0,
                targetPoint: target,
                windowSize: windowSize,
                visibleFrames: [primaryScreen]
            )
            assertPoint(lhs.windowOrigin, equals: rhs.windowOrigin, tolerance: 0)
            precondition(lhs.velocity == rhs.velocity)
            precondition(lhs.facing == rhs.facing)
            precondition(lhs.motionState == rhs.motionState)
        }
    }

    private static func testInvalidTimingAndMissingScreensAreSafe() {
        let controller = MouseFollowController(
            initialWindowOrigin: NSPoint(x: 12, y: 34)
        )
        controller.enable()
        let noScreens = controller.step(
            deltaTime: 1.0 / 60.0,
            targetPoint: NSPoint(x: 800, y: 600),
            windowSize: windowSize,
            visibleFrames: []
        )
        precondition(noScreens.motionState == .stopped)
        assertPoint(noScreens.windowOrigin, equals: NSPoint(x: 12, y: 34), tolerance: 0)

        let zeroTime = controller.step(
            deltaTime: .nan,
            targetPoint: NSPoint(x: 800, y: 600),
            windowSize: windowSize,
            visibleFrames: [primaryScreen]
        )
        precondition(zeroTime.speed == 0)
        assertPoint(zeroTime.windowOrigin, equals: NSPoint(x: 12, y: 34), tolerance: 0)
    }

    private static func windowRect(_ origin: NSPoint, size: NSSize) -> NSRect {
        NSRect(origin: origin, size: size)
    }

    private static func assertPoint(
        _ actual: NSPoint,
        equals expected: NSPoint,
        tolerance: CGFloat
    ) {
        precondition(abs(actual.x - expected.x) <= tolerance)
        precondition(abs(actual.y - expected.y) <= tolerance)
    }
}

private extension NSRect {
    func isContained(in other: NSRect) -> Bool {
        minX >= other.minX - 0.001
            && minY >= other.minY - 0.001
            && maxX <= other.maxX + 0.001
            && maxY <= other.maxY + 0.001
    }
}
