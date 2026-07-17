import AppKit

@main
struct AccessoryReclaimTestMain {
    static func main() {
        testReclaimGate()
        testScatterSessionTokens()
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

    private static func testScatterSessionTokens() {
        var sessions = AccessoryScatterSessionState()

        let firstSessionID = sessions.beginSession()
        var firstItemState = AccessoryReclaimState()
        precondition(
            !sessions.permitsPreviewReclaim(
                requestedSessionID: firstSessionID,
                itemSessionID: firstSessionID,
                reclaimState: firstItemState
            ),
            "同轮道具未落地时预览回收必须失败"
        )
        precondition(firstItemState.markLanded())
        precondition(
            sessions.permitsPreviewReclaim(
                requestedSessionID: firstSessionID,
                itemSessionID: firstSessionID,
                reclaimState: firstItemState
            ),
            "当前轮 token 对已落地道具应合法"
        )
        precondition(
            !sessions.permitsPreviewReclaim(
                requestedSessionID: nil,
                itemSessionID: firstSessionID,
                reclaimState: firstItemState
            ),
            "兼容入口缺少 token 时必须失败关闭"
        )

        let secondSessionID = sessions.beginSession()
        precondition(firstSessionID < secondSessionID, "连续两轮 token 必须单调递增且可比较")
        var secondItemState = AccessoryReclaimState()
        precondition(secondItemState.markLanded())
        precondition(
            !sessions.permitsPreviewReclaim(
                requestedSessionID: firstSessionID,
                itemSessionID: secondSessionID,
                reclaimState: secondItemState
            ),
            "上一轮预览任务绝不能回收新一轮道具"
        )
        precondition(
            !sessions.finishSession(firstSessionID),
            "旧轮次结束回调不得结束当前轮次"
        )
        precondition(sessions.activeSessionID == secondSessionID)

        sessions.cancelActiveSession()
        precondition(sessions.activeSessionID == nil)
        precondition(
            !sessions.permitsPreviewReclaim(
                requestedSessionID: secondSessionID,
                itemSessionID: secondSessionID,
                reclaimState: secondItemState
            ),
            "取消后旧 token 必须失效"
        )

        let thirdSessionID = sessions.beginSession()
        precondition(secondSessionID < thirdSessionID, "取消不得重置 token 序列")
        var thirdItemState = AccessoryReclaimState()
        precondition(thirdItemState.markLanded())
        precondition(sessions.finishSession(thirdSessionID), "当前轮正常结束应清空 active token")
        precondition(
            !sessions.permitsPreviewReclaim(
                requestedSessionID: thirdSessionID,
                itemSessionID: thirdSessionID,
                reclaimState: thirdItemState
            ),
            "结束后旧 token 必须失效"
        )
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
