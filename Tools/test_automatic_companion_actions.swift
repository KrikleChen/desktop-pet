import Foundation

@main
struct AutomaticCompanionActionsTestMain {
    static func main() {
        let actions = PetAction.automaticCompanionActions
        precondition(actions.count == 18, "自动角色动画池必须包含 18 个新动作")
        precondition(Set(actions).count == actions.count, "自动角色动画池不得包含重复动作")

        let scheduled = Set(PetAction.lowFrequencyIdleActions)
        for action in actions {
            precondition(scheduled.contains(action), "新动作必须进入自动待机池：\(action.rawValue)")
            precondition(action.phrase == nil, "首批自动角色动画应保持无台词：\(action.rawValue)")
            precondition(action.duration >= 3.0, "自动角色动画展示时间过短：\(action.rawValue)")

            let assetPath = "Assets/generated-actions/\(action.rawValue)-cg.png"
            precondition(
                FileManager.default.fileExists(atPath: assetPath),
                "缺少自动角色动画素材：\(assetPath)"
            )
        }

        print("18 个 macOS 自动角色动画与素材映射自检通过。")
    }
}
