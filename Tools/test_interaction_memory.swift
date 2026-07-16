import Foundation

@main
struct InteractionMemoryTestMain {
    static func main() {
        testTeasingThresholds()
        testTeasingDecayAndBoundary()
        testTeasingResetAndClockRewind()
        testNameCallProgression()
        testNameCallTimeoutAndBoundary()
        testIndependentReset()
        print("交互记忆自检通过。")
    }

    private static func testTeasingThresholds() {
        var memory = InteractionMemory()

        expectEqual(memory.recordTeasing(.legDrag, at: 100), .normal, "第 1 次捉弄")
        expectEqual(memory.recordTeasing(.thrown, at: 101), .normal, "第 2 次捉弄")
        expectEqual(memory.recordTeasing(.grab, at: 102), .irritated, "第 3 次捉弄")
        expectEqual(memory.recordTeasing(.legDrag, at: 103), .irritated, "第 4 次捉弄")
        expectEqual(memory.recordTeasing(.thrown, at: 104), .resigned, "第 5 次捉弄")
        expectEqual(memory.recordTeasing(.grab, at: 105), .resigned, "超过放弃阈值")
    }

    private static func testTeasingDecayAndBoundary() {
        let configuration = InteractionMemory.Configuration(teasingWindow: 10)
        var memory = InteractionMemory(configuration: configuration)

        _ = memory.recordTeasing(.legDrag, at: 200)
        _ = memory.recordTeasing(.thrown, at: 201)
        _ = memory.recordTeasing(.grab, at: 202)
        _ = memory.recordTeasing(.legDrag, at: 203)
        expectEqual(memory.recordTeasing(.thrown, at: 204), .resigned, "衰减前达到放弃阶段")

        expectEqual(memory.teasingStage(at: 210), .resigned, "窗口边界仍包含最早事件")
        expectEqual(memory.teasingStage(at: 210.001), .irritated, "最早事件过期后回落一阶")
        expectEqual(memory.teasingStage(at: 214.001), .normal, "全部事件过期后恢复正常")
        expectEqual(memory.recordTeasing(.thrown, at: 215), .normal, "过期后的新捉弄从头计数")
    }

    private static func testTeasingResetAndClockRewind() {
        var memory = InteractionMemory()
        _ = memory.recordTeasing(.legDrag, at: 300)
        _ = memory.recordTeasing(.thrown, at: 301)
        expectEqual(memory.recordTeasing(.grab, at: 302), .irritated, "重置前达到烦躁阈值")

        memory.resetTeasing()
        expectEqual(memory.teasingStage(at: 303), .normal, "显式重置捉弄记忆")
        expectEqual(memory.recordTeasing(.legDrag, at: 304), .normal, "重置后重新计数")

        _ = memory.recordTeasing(.thrown, at: 305)
        expectEqual(memory.recordTeasing(.grab, at: 100), .normal, "时钟回退时丢弃旧基准")
    }

    private static func testNameCallProgression() {
        var memory = InteractionMemory()

        expectEqual(memory.recordNameCall(at: 400), .first, "首次名字呼叫")
        expectEqual(memory.recordNameCall(at: 402), .again, "第二次连续呼叫")
        expectEqual(memory.recordNameCall(at: 404), .exasperated, "第三次连续呼叫")
        expectEqual(memory.recordNameCall(at: 406), .exasperated, "第四次连续呼叫")
    }

    private static func testNameCallTimeoutAndBoundary() {
        let configuration = InteractionMemory.Configuration(nameCallWindow: 10)
        var memory = InteractionMemory(configuration: configuration)

        expectEqual(memory.recordNameCall(at: 500), .first, "边界测试的首次呼叫")
        expectEqual(memory.recordNameCall(at: 510), .again, "正好位于名字窗口边界")
        expectEqual(memory.recordNameCall(at: 520.001), .first, "超出名字窗口后恢复首次回应")
        expectEqual(memory.recordNameCall(at: 521), .again, "超时后建立新的连续呼叫")
        expectEqual(memory.recordNameCall(at: 100), .first, "名字时钟回退后恢复首次回应")
    }

    private static func testIndependentReset() {
        var memory = InteractionMemory()
        _ = memory.recordTeasing(.legDrag, at: 600)
        _ = memory.recordNameCall(at: 600)
        _ = memory.recordNameCall(at: 601)

        memory.resetTeasing()
        expectEqual(memory.recordNameCall(at: 602), .exasperated, "捉弄重置不影响名字记忆")

        memory.resetNameCalls()
        expectEqual(memory.recordNameCall(at: 603), .first, "独立重置名字记忆")

        _ = memory.recordTeasing(.thrown, at: 603)
        memory.reset()
        expectEqual(memory.teasingStage(at: 604), .normal, "整体重置捉弄记忆")
        expectEqual(memory.recordNameCall(at: 604), .first, "整体重置名字记忆")
    }

    private static func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ context: String
    ) {
        precondition(
            actual == expected,
            "\(context)：期望 \(expected)，实际 \(actual)"
        )
    }
}
