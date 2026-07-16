import AppKit
import Foundation

@main
struct EdgeIdleBehaviorTestMain {
    private static let screen = NSRect(x: 100, y: 50, width: 1_000, height: 700)

    static func main() {
        testSupportedEdgesAndTopExclusion()
        testStableDurationAndMinimumIdleDuration()
        testDraggingAndActionEligibility()
        testCooldown()
        testLeavingEdgeResetsCandidate()
        print("屏幕边缘低频坐下判定自检通过。")
    }

    private static func makeBehavior(
        stableDuration: TimeInterval = 5,
        minimumIdleDuration: TimeInterval = 20,
        cooldownDuration: TimeInterval = 30
    ) -> EdgeIdleBehavior {
        EdgeIdleBehavior(configuration: .init(
            edgeTolerance: 10,
            stableDuration: stableDuration,
            minimumIdleDuration: minimumIdleDuration,
            cooldownDuration: cooldownDuration
        ))
    }

    private static func testSupportedEdgesAndTopExclusion() {
        let left = NSRect(x: 105, y: 250, width: 100, height: 120)
        let right = NSRect(x: 995, y: 250, width: 100, height: 120)
        let bottom = NSRect(x: 500, y: 55, width: 100, height: 120)
        let top = NSRect(x: 500, y: 630, width: 100, height: 120)

        precondition(
            EdgeIdleBehavior.nearEdge(
                windowFrame: left,
                screenVisibleFrame: screen,
                tolerance: 10
            ) == .left,
            "左边缘未被识别"
        )
        precondition(
            EdgeIdleBehavior.nearEdge(
                windowFrame: right,
                screenVisibleFrame: screen,
                tolerance: 10
            ) == .right,
            "右边缘未被识别"
        )
        precondition(
            EdgeIdleBehavior.nearEdge(
                windowFrame: bottom,
                screenVisibleFrame: screen,
                tolerance: 10
            ) == .bottom,
            "底部边缘未被识别"
        )
        precondition(
            EdgeIdleBehavior.nearEdge(
                windowFrame: top,
                screenVisibleFrame: screen,
                tolerance: 10
            ) == nil,
            "上边缘不应成为坐下候选"
        )
    }

    private static func testStableDurationAndMinimumIdleDuration() {
        let frame = NSRect(x: 105, y: 250, width: 100, height: 120)
        var behavior = makeBehavior()

        expectNoTrigger(&behavior, frame: frame, idle: 10, now: 100)
        expectNoTrigger(&behavior, frame: frame, idle: 14.9, now: 104.9)
        precondition(
            behavior.evaluate(
                windowFrame: frame,
                screenVisibleFrame: screen,
                idleDuration: 20,
                now: 110,
                eligibility: true
            ) == .left,
            "同时满足稳定时间和最低空闲时长后应触发"
        )
    }

    private static func testDraggingAndActionEligibility() {
        let frame = NSRect(x: 995, y: 250, width: 100, height: 120)
        var behavior = makeBehavior(stableDuration: 2, minimumIdleDuration: 0)

        expectNoTrigger(&behavior, frame: frame, idle: 30, now: 200)

        let isDragging = true
        precondition(
            behavior.evaluate(
                windowFrame: frame,
                screenVisibleFrame: screen,
                idleDuration: 31,
                now: 201,
                eligibility: !isDragging
            ) == nil,
            "拖拽中不应触发"
        )

        let isPerformingAction = true
        precondition(
            behavior.evaluate(
                windowFrame: frame,
                screenVisibleFrame: screen,
                idleDuration: 32,
                now: 202,
                eligibility: !isPerformingAction
            ) == nil,
            "动作中不应触发"
        )

        // Ineligible samples broke the old candidate, so eligibility alone cannot
        // trigger until a new stable interval has elapsed.
        expectNoTrigger(&behavior, frame: frame, idle: 33, now: 203)
        precondition(
            behavior.evaluate(
                windowFrame: frame,
                screenVisibleFrame: screen,
                idleDuration: 35,
                now: 205,
                eligibility: true
            ) == .right,
            "恢复 eligibility 后应重新计算稳定时间"
        )
    }

    private static func testCooldown() {
        let frame = NSRect(x: 500, y: 55, width: 100, height: 120)
        var behavior = makeBehavior(
            stableDuration: 5,
            minimumIdleDuration: 0,
            cooldownDuration: 30
        )

        expectNoTrigger(&behavior, frame: frame, idle: 60, now: 300)
        precondition(trigger(&behavior, frame: frame, idle: 65, now: 305) == .bottom)
        expectNoTrigger(&behavior, frame: frame, idle: 94.9, now: 334.9)
        precondition(
            trigger(&behavior, frame: frame, idle: 95, now: 335) == .bottom,
            "冷却到期且再次稳定后应允许低频重复"
        )
    }

    private static func testLeavingEdgeResetsCandidate() {
        let edgeFrame = NSRect(x: 105, y: 250, width: 100, height: 120)
        let centerFrame = NSRect(x: 500, y: 250, width: 100, height: 120)
        var behavior = makeBehavior(stableDuration: 5, minimumIdleDuration: 0)

        expectNoTrigger(&behavior, frame: edgeFrame, idle: 60, now: 400)
        expectNoTrigger(&behavior, frame: edgeFrame, idle: 64, now: 404)
        expectNoTrigger(&behavior, frame: centerFrame, idle: 65, now: 405)
        expectNoTrigger(&behavior, frame: edgeFrame, idle: 66, now: 406)
        expectNoTrigger(&behavior, frame: edgeFrame, idle: 70.9, now: 410.9)
        precondition(
            trigger(&behavior, frame: edgeFrame, idle: 71, now: 411) == .left,
            "离开边缘后应重新完成整段稳定停留"
        )
    }

    private static func expectNoTrigger(
        _ behavior: inout EdgeIdleBehavior,
        frame: NSRect,
        idle: TimeInterval,
        now: TimeInterval
    ) {
        precondition(
            trigger(&behavior, frame: frame, idle: idle, now: now) == nil,
            "预期不触发，但得到了边缘"
        )
    }

    private static func trigger(
        _ behavior: inout EdgeIdleBehavior,
        frame: NSRect,
        idle: TimeInterval,
        now: TimeInterval
    ) -> EdgeIdleBehavior.Edge? {
        behavior.evaluate(
            windowFrame: frame,
            screenVisibleFrame: screen,
            idleDuration: idle,
            now: now,
            eligibility: true
        )
    }
}
