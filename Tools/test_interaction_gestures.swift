import AppKit
import Foundation

@main
struct InteractionGestureTestMain {
    static func main() {
        testThrowVelocity()
        testUpsideDownShake()
        print("交互手势自检通过。")
    }

    private static func testThrowVelocity() {
        let tracker = DragVelocityTracker()
        tracker.reset(at: NSPoint(x: 0, y: 0), timestamp: 10.00)
        tracker.add(position: NSPoint(x: 35, y: 8), timestamp: 10.03)
        tracker.add(position: NSPoint(x: 78, y: 17), timestamp: 10.06)
        tracker.add(position: NSPoint(x: 126, y: 25), timestamp: 10.09)
        let fast = tracker.estimatedVelocity(at: 10.09)

        tracker.reset(at: NSPoint(x: 0, y: 0), timestamp: 20.00)
        tracker.add(position: NSPoint(x: 8, y: 1), timestamp: 20.06)
        tracker.add(position: NSPoint(x: 16, y: 2), timestamp: 20.12)
        tracker.add(position: NSPoint(x: 24, y: 3), timestamp: 20.18)
        let slow = tracker.estimatedVelocity(at: 20.18)

        precondition(hypot(fast.dx, fast.dy) > 720, "快速甩动没有超过触发阈值")
        precondition(fast.dx > 0 && fast.dy > 0, "甩动方向未继承鼠标轨迹")
        precondition(hypot(slow.dx, slow.dy) < 720, "普通慢拖被误判为甩飞")
    }

    private static func testUpsideDownShake() {
        let detector = ShakeGestureDetector()
        detector.beginLegGrab(
            timestamp: 30.00,
            globalPosition: NSPoint(x: 100, y: 100)
        )
        let samples: [(TimeInterval, CGFloat)] = [
            (30.20, 205),
            (30.40, 95),
            (30.60, 210),
            (30.80, 90),
        ]
        var didTrigger = false
        for sample in samples {
            didTrigger = detector.addSample(
                timestamp: sample.0,
                globalPosition: NSPoint(x: sample.1, y: 100)
            ) || didTrigger
        }

        precondition(didTrigger, "倒吊左右摇摆没有触发道具散落")
        precondition(detector.didTriggerCurrentGrab, "散落触发状态没有锁定")
        detector.endLegGrab()
    }
}
