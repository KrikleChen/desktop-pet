import Foundation

@main
struct ChatNameMentionTestMain {
    static func main() {
        let detector = ChatNameMentionDetector()

        precondition(
            detector.containsTarget(in: "成步堂龙一，这份证据怎么看？"),
            "完整姓名应触发监听"
        )
        precondition(
            detector.containsTarget(in: "成步堂，该你了。"),
            "桌宠简称应触发监听"
        )
        precondition(
            !detector.containsTarget(in: "御剑怜侍，这份证据怎么看？"),
            "无关姓名不应触发监听"
        )

        print("名字监听触发词自检通过。")
    }
}
