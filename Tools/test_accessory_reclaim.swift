import AppKit

@main
struct AccessoryReclaimTestMain {
    static func main() {
        testReclaimGate()
        testDestinationClamping()
        print("道具回收无 UI 自检通过。")
    }

    private static func testReclaimGate() {
        var state = AccessoryReclaimState()

        precondition(!state.beginReclaim(), "未落地道具不应可回收")
        precondition(state.markLanded(), "首次落地应生效")
        precondition(!state.markLanded(), "重复落地不应重复通知")
        precondition(state.beginReclaim(), "落地后首次回收应生效")
        precondition(!state.beginReclaim(), "重复点击不应重复回收")
    }

    private static func testDestinationClamping() {
        let visibleFrame = NSRect(x: -1_920, y: 24, width: 1_920, height: 1_031)
        let itemSize = NSSize(width: 40, height: 30)

        let ordinary = AccessoryReclaimGeometry.destinationOrigin(
            itemSize: itemSize,
            near: NSPoint(x: -320, y: 500),
            inside: visibleFrame
        )
        precondition(ordinary == NSPoint(x: -340, y: 485), "普通回收终点应对齐道具中心")

        let belowLeft = AccessoryReclaimGeometry.destinationOrigin(
            itemSize: itemSize,
            near: NSPoint(x: -3_000, y: -500),
            inside: visibleFrame
        )
        precondition(
            belowLeft == NSPoint(x: visibleFrame.minX, y: visibleFrame.minY),
            "负坐标屏幕的左下边界失效"
        )

        let aboveRight = AccessoryReclaimGeometry.destinationOrigin(
            itemSize: itemSize,
            near: NSPoint(x: 600, y: 1_800),
            inside: visibleFrame
        )
        precondition(
            aboveRight == NSPoint(
                x: visibleFrame.maxX - itemSize.width,
                y: visibleFrame.maxY - itemSize.height
            ),
            "右上边界失效"
        )
    }
}
