import AppKit
import Foundation

@main
struct HeadPettingGestureTestMain {
    static func main() {
        testGentleBackAndForthTriggers()
        testClickAndDragAreRejected()
        testOnlyHairRegionCounts()
        testFastAndVerticalMovementAreRejected()
        testInsufficientMovementDoesNotTrigger()
        testLeavingHairResetsProgress()
        testSampleGapResetsProgress()
        testCooldownAndRecovery()
        print("头发抚摸手势边界自检通过。")
    }

    private static func testGentleBackAndForthTriggers() {
        let detector = HeadPettingGesture()
        let events = feedCompletePetting(to: detector, startTime: 10)

        precondition(events.first == .trackingStarted, "首个头发样本应开始跟踪")
        precondition(events.filter(\.isTriggered).count == 1, "轻柔往返应且只应触发一次")
        precondition(!detector.isTracking, "触发后应清空当前手势")
    }

    private static func testClickAndDragAreRejected() {
        let click = HeadPettingGesture()
        let clickDown = click.addSample(
            timestamp: 20,
            position: NSPoint(x: 100, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: true
        )
        precondition(clickDown == .none, "仅按下不应开始抚摸")

        _ = click.addSample(
            timestamp: 20.1,
            position: NSPoint(x: 100, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        let drag = click.addSample(
            timestamp: 20.2,
            position: NSPoint(x: 110, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: true
        )
        precondition(drag == .reset(.primaryButtonPressed), "按键拖拽应取消抚摸进度")
        precondition(!click.isTracking, "按键拖拽后不应保留进度")
    }

    private static func testOnlyHairRegionCounts() {
        for region in [GrabRegion.arm, .collarTorso, .leg] {
            let detector = HeadPettingGesture()
            var triggered = false
            for (index, x) in pettingXs.enumerated() {
                let event = detector.addSample(
                    timestamp: 30 + Double(index) * 0.10,
                    position: NSPoint(x: x, y: 120),
                    region: region,
                    isPrimaryButtonDown: false
                )
                triggered = triggered || event.isTriggered
            }
            precondition(!triggered && !detector.isTracking, "\(region.rawValue) 不应累计抚摸")
        }

        let transparent = HeadPettingGesture()
        let event = transparent.addSample(
            timestamp: 31,
            position: NSPoint(x: 1, y: 1),
            region: nil,
            isPrimaryButtonDown: false
        )
        precondition(event == .none, "透明区不应开始抚摸")
    }

    private static func testFastAndVerticalMovementAreRejected() {
        let fast = HeadPettingGesture()
        _ = fast.addSample(
            timestamp: 40,
            position: NSPoint(x: 90, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        let fastEvent = fast.addSample(
            timestamp: 40.02,
            position: NSPoint(x: 120, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        precondition(fastEvent == .reset(.movedTooFast), "快速甩动应被拒绝")

        let vertical = HeadPettingGesture()
        _ = vertical.addSample(
            timestamp: 41,
            position: NSPoint(x: 100, y: 170),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        let verticalEvent = vertical.addSample(
            timestamp: 41.1,
            position: NSPoint(x: 103, y: 184),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        precondition(verticalEvent == .reset(.verticalMotion), "纵向擦过不应当作抚摸")
    }

    private static func testInsufficientMovementDoesNotTrigger() {
        let oneWay = HeadPettingGesture()
        var oneWayTriggered = false
        for index in 0...12 {
            let event = oneWay.addSample(
                timestamp: 50 + Double(index) * 0.10,
                position: NSPoint(x: 80 + CGFloat(index) * 5, y: 180),
                region: .hairHead,
                isPrimaryButtonDown: false
            )
            oneWayTriggered = oneWayTriggered || event.isTriggered
        }
        precondition(!oneWayTriggered, "单向慢移不能触发")

        let jitter = HeadPettingGesture()
        var jitterTriggered = false
        for index in 0...40 {
            let x: CGFloat = index.isMultiple(of: 2) ? 100 : 103
            let event = jitter.addSample(
                timestamp: 52 + Double(index) * 0.05,
                position: NSPoint(x: x, y: 180),
                region: .hairHead,
                isPrimaryButtonDown: false
            )
            jitterTriggered = jitterTriggered || event.isTriggered
        }
        precondition(!jitterTriggered, "小范围抖动不能触发")
    }

    private static func testLeavingHairResetsProgress() {
        let detector = HeadPettingGesture()
        let prefix: [CGFloat] = [90, 100, 110, 120, 112, 102, 92]
        for (index, x) in prefix.enumerated() {
            _ = detector.addSample(
                timestamp: 60 + Double(index) * 0.10,
                position: NSPoint(x: x, y: 180),
                region: .hairHead,
                isPrimaryButtonDown: false
            )
        }
        let leave = detector.addSample(
            timestamp: 60.7,
            position: NSPoint(x: 90, y: 160),
            region: .collarTorso,
            isPrimaryButtonDown: false
        )
        precondition(leave == .reset(.leftHairRegion), "离开头发区应清空进度")

        var triggered = false
        for (index, x) in [100, 110, 120, 112, 102].enumerated() {
            let event = detector.addSample(
                timestamp: 60.8 + Double(index) * 0.10,
                position: NSPoint(x: CGFloat(x), y: 180),
                region: .hairHead,
                isPrimaryButtonDown: false
            )
            triggered = triggered || event.isTriggered
        }
        precondition(!triggered, "离开前后的轨迹不应拼接触发")
    }

    private static func testSampleGapResetsProgress() {
        let detector = HeadPettingGesture()
        _ = detector.addSample(
            timestamp: 70,
            position: NSPoint(x: 90, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        _ = detector.addSample(
            timestamp: 70.1,
            position: NSPoint(x: 105, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        let gap = detector.addSample(
            timestamp: 70.6,
            position: NSPoint(x: 120, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        precondition(gap == .reset(.sampleGap), "过长样本间隔应重开跟踪")
        precondition(detector.isTracking, "断档后当前样本应作为新起点")

        let invalid = detector.addSample(
            timestamp: 70.5,
            position: NSPoint(x: 118, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        precondition(invalid == .reset(.invalidTimestamp), "非递增时间戳应重置")
    }

    private static func testCooldownAndRecovery() {
        let detector = HeadPettingGesture()
        let first = feedCompletePetting(to: detector, startTime: 80)
        precondition(first.contains(where: \.isTriggered), "第一次完整抚摸未触发")

        let cooling = detector.addSample(
            timestamp: 82,
            position: NSPoint(x: 90, y: 180),
            region: .hairHead,
            isPrimaryButtonDown: false
        )
        guard case let .coolingDown(remaining) = cooling else {
            preconditionFailure("冷却期应返回明确事件")
        }
        precondition(remaining > 0, "冷却剩余时间应为正")

        let second = feedCompletePetting(to: detector, startTime: 90)
        precondition(second.filter(\.isTriggered).count == 1, "冷却结束后应可再次触发")
    }

    @discardableResult
    private static func feedCompletePetting(
        to detector: HeadPettingGesture,
        startTime: TimeInterval
    ) -> [HeadPettingGesture.Event] {
        pettingXs.enumerated().map { index, x in
            detector.addSample(
                timestamp: startTime + Double(index) * 0.10,
                position: NSPoint(x: x, y: 180),
                region: .hairHead,
                isPrimaryButtonDown: false
            )
        }
    }

    private static let pettingXs: [CGFloat] = [
        90, 100, 110, 120,
        112, 102, 92,
        100, 110, 120,
        112, 102, 92,
    ]
}

private extension HeadPettingGesture.Event {
    var isTriggered: Bool {
        self == .triggered
    }
}
