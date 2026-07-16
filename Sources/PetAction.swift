import Foundation

enum PetAction: String, CaseIterable {
    case idle
    case think
    case objection
    case slam
    case sweat
    case evidence
    case heldStruggle = "held-struggle"
    case heldResigned = "held-resigned"
    case hairStruggle = "hair-struggle"
    case hairResigned = "hair-resigned"
    case armStruggle = "arm-struggle"
    case armResigned = "arm-resigned"
    case legStruggle = "leg-struggle"
    case legResigned = "leg-resigned"
    case afraidDark = "afraid-dark"
    case flashlight
    case sleepy
    case dropped
    case badgeToss = "badge-toss"
    case magatama
    case stepladder
    case thinker
    case heardName = "heard-name"
    case decisiveEvidence = "decisive-evidence"
    case thrown
    case spinning
    case impact
    case dizzy
    case dusting
    case irritated

    var menuTitle: String {
        switch self {
        case .idle: return "恢复站立"
        case .think: return "思考案情"
        case .objection: return "异议！"
        case .slam: return "拍桌"
        case .sweat: return "紧张冒汗"
        case .evidence: return "查看证物"
        case .heldStruggle: return "被拎起挣扎"
        case .heldResigned: return "被拎起放弃"
        case .hairStruggle: return "被揪头发挣扎"
        case .hairResigned: return "被揪头发认命"
        case .armStruggle: return "被拽手臂挣扎"
        case .armResigned: return "被拽手臂认命"
        case .legStruggle: return "被拽腿脚挣扎"
        case .legResigned: return "被拽腿脚认命"
        case .afraidDark: return "怕黑"
        case .flashlight: return "打开手电筒"
        case .sleepy: return "打瞌睡"
        case .dropped: return "落地"
        case .badgeToss: return "甩出律师徽章"
        case .magatama: return "勾玉与心灵枷锁"
        case .stepladder: return "梯子还是人字梯"
        case .thinker: return "出示“思考者”"
        case .heardName: return "听见名字"
        case .decisiveEvidence: return "决定性证据"
        case .thrown: return "被甩飞"
        case .spinning: return "空中旋转"
        case .impact: return "撞击"
        case .dizzy: return "眩晕"
        case .dusting: return "拍掉灰尘"
        case .irritated: return "生气恢复"
        }
    }

    var phrase: String? {
        switch self {
        case .idle: return nil
        case .think: return "唏……真相只有一个。"
        case .objection: return "异议！"
        case .slam: return "等一下！"
        case .sweat: return "糟了……"
        case .evidence: return "证据就在这里。"
        case .heldStruggle: return "放、放我下来！"
        case .heldResigned: return "……算了，随你吧。"
        case .hairStruggle: return "头发！别拽头发！"
        case .hairResigned: return "我的发型……算了。"
        case .armStruggle: return "等一下，胳膊要脱臼了！"
        case .armResigned: return "……轻一点就好。"
        case .legStruggle: return "为什么偏偏拽脚啊！"
        case .legResigned: return "我已经不想反抗了……"
        case .afraidDark: return "这里怎么这么黑……"
        case .flashlight: return "先把手电打开。"
        case .sleepy: return "就休息五分钟……"
        case .dropped: return "下次先打声招呼！"
        case .badgeToss: return "这是我的律师徽章！"
        case .magatama: return "你的心里……有锁。"
        case .stepladder: return "这明明是人字梯！"
        case .thinker: return "把“思考者”加入证物。"
        case .heardName: return "你在叫我吗？"
        case .decisiveEvidence: return "找到决定性的证据了！"
        case .thrown: return "哇啊——！"
        case .spinning: return "停下来啊！"
        case .impact: return "痛！"
        case .dizzy: return "天地都在转……"
        case .dusting: return "我的西装……"
        case .irritated: return "下次绝对不许这样！"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .idle: return 0
        case .think: return 2.4
        case .objection: return 2.0
        case .slam: return 1.8
        case .sweat: return 2.1
        case .evidence: return 2.5
        case .heldStruggle, .heldResigned,
             .hairStruggle, .hairResigned,
             .armStruggle, .armResigned,
             .legStruggle, .legResigned:
            return 0
        case .afraidDark: return 1.7
        case .flashlight: return 3.2
        case .sleepy: return 3.0
        case .dropped: return 1.5
        case .badgeToss: return 2.2
        case .magatama: return 2.8
        case .stepladder: return 2.8
        case .thinker: return 2.6
        case .heardName: return 2.4
        case .decisiveEvidence: return 2.4
        case .thrown, .spinning, .impact: return 0
        case .dizzy: return 2.2
        case .dusting: return 1.4
        case .irritated: return 2.0
        }
    }

    static var interactiveActions: [PetAction] {
        [
            .think, .objection, .slam, .sweat, .evidence,
            .badgeToss, .magatama, .stepladder, .thinker, .decisiveEvidence,
        ]
    }

    static var lowFrequencyIdleActions: [PetAction] {
        [.think, .sleepy, .badgeToss, .evidence]
    }
}
