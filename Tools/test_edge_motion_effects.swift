import AppKit
import QuartzCore

@main
struct EdgeMotionEffectsTestMain {
    private static let bounds = CGRect(x: 0, y: 0, width: 240, height: 260)
    private static let edges: [EdgeIdleBehavior.Edge] = [.left, .right, .bottom]

    static func main() {
        testDirectionalPathGeometry()
        testAmbientPathGeometry()
        testStateReplacementAndCancellation()
        print("边缘姿态周遭动态轨迹自检通过。")
    }

    private static func testDirectionalPathGeometry() {
        for edge in edges {
            let entrance = EdgeMotionEffectGeometry.directionalStrokes(
                in: bounds,
                edge: edge,
                direction: .entrance
            )
            let exit = EdgeMotionEffectGeometry.directionalStrokes(
                in: bounds,
                edge: edge,
                direction: .exit
            )

            precondition(entrance.count == 3, "\(edge.rawValue) 进入轨迹应有 3 条")
            precondition(exit.count == entrance.count, "退出轨迹数量应与进入一致")

            for index in entrance.indices {
                assertInsideCharacterRegion(entrance[index].path)
                assertInsideCharacterRegion(exit[index].path)
                precondition(exit[index].start == entrance[index].end, "退出起点应为进入终点")
                precondition(exit[index].end == entrance[index].start, "退出终点应为进入起点")
                precondition(exit[index].control == entrance[index].control, "反向曲线应保持控制点")
            }

            guard let first = entrance.first else {
                preconditionFailure("缺少方向轨迹")
            }
            switch edge {
            case .left:
                precondition(first.end.x < first.start.x, "左边进入应指向左侧")
            case .right:
                precondition(first.end.x > first.start.x, "右边进入应指向右侧")
            case .bottom:
                precondition(first.end.y < first.start.y, "底部进入应指向下方")
            }
        }
    }

    private static func testAmbientPathGeometry() {
        for edge in edges {
            guard let scan = EdgeMotionEffectGeometry.ambientScan(in: bounds, edge: edge) else {
                preconditionFailure("\(edge.rawValue) 缺少调查扫描轨迹")
            }
            assertInsideCharacterRegion(scan.path)
        }

        precondition(
            EdgeMotionEffectGeometry.directionalStrokes(
                in: .zero,
                edge: .left,
                direction: .entrance
            ).isEmpty,
            "空区域不应产生轨迹"
        )
        precondition(
            EdgeMotionEffectGeometry.ambientScan(in: .zero, edge: .bottom) == nil,
            "空区域不应产生扫描"
        )
    }

    private static func testStateReplacementAndCancellation() {
        precondition(Thread.isMainThread)
        let view = EdgeMotionEffectView(frame: bounds)
        precondition(view.phase == .stopped)

        view.playEntrance(edge: .left)
        precondition(view.phase == .entering(.left))

        view.beginAmbient(edge: .right)
        precondition(view.phase == .ambient(.right), "新调用应取代进入动画")
        view.beginAmbient(edge: .right)
        precondition(view.phase == .ambient(.right), "同边环境动画重复调用应幂等")

        var canceledCompletionCalled = false
        view.playExit(edge: .right) {
            canceledCompletionCalled = true
        }
        precondition(view.phase == .exiting(.right))
        view.stop()
        precondition(view.phase == .stopped)

        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        precondition(!canceledCompletionCalled, "取消的退出不应回调 completion")

        var finishedCompletionCalled = false
        view.playExit(edge: .bottom) {
            finishedCompletionCalled = true
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.55))
        precondition(finishedCompletionCalled, "正常退出应回调 completion")
        precondition(view.phase == .stopped, "退出结束后应停止")
    }

    private static func assertInsideCharacterRegion(_ path: CGPath) {
        let box = path.boundingBoxOfPath
        precondition(box.minX >= bounds.minX, "轨迹超出左边界")
        precondition(box.maxX <= bounds.maxX, "轨迹超出右边界")
        precondition(box.minY >= bounds.minY, "轨迹超出底边界")
        precondition(
            box.maxY < 190,
            "轨迹不得进入顶部字幕区：\(box.maxY)"
        )
    }
}
