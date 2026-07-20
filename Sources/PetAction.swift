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
    case careCheckTime = "care-check-time"
    case careEncourage = "care-encourage"
    case careOfferMug = "care-offer-mug"
    case careOfferWater = "care-offer-water"
    case careStretch = "care-stretch"
    case careTiredEye = "care-tired-eye"
    case courtConcentrate = "court-concentrate"
    case courtExplain = "court-explain"
    case courtInspectClue = "court-inspect-clue"
    case courtInspectDetail = "court-inspect-detail"
    case courtReady = "court-ready"
    case courtSurprised = "court-surprised"
    case workCarryFiles = "work-carry-files"
    case workGatherPapers = "work-gather-papers"
    case workPolishBadge = "work-polish-badge"
    case workReadCase = "work-read-case"
    case workSmallVictory = "work-small-victory"
    case workTakeNotes = "work-take-notes"
    case headPetFlattened = "head-pet-flattened"
    case headPetRebound = "head-pet-rebound"
    case appLiftSupport = "app-lift-support"
    case mouseFollowRunStrideA = "mouse-follow-run-stride-a"
    case mouseFollowRunPass = "mouse-follow-run-pass"
    case mouseFollowRunStrideB = "mouse-follow-run-stride-b"

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
        case .careCheckTime: return "看看时间"
        case .careEncourage: return "鼓励一下"
        case .careOfferMug: return "递来热饮"
        case .careOfferWater: return "递来水壶"
        case .careStretch: return "伸个懒腰"
        case .careTiredEye: return "揉揉眼睛"
        case .courtConcentrate: return "凝神思考"
        case .courtExplain: return "冷静说明"
        case .courtInspectClue: return "蹲下查线索"
        case .courtInspectDetail: return "仔细看细节"
        case .courtReady: return "整理领带"
        case .courtSurprised: return "发现意外"
        case .workCarryFiles: return "搬运卷宗"
        case .workGatherPapers: return "收拾文件"
        case .workPolishBadge: return "擦拭律师徽章"
        case .workReadCase: return "阅读卷宗"
        case .workSmallVictory: return "小小庆祝"
        case .workTakeNotes: return "记录线索"
        case .headPetFlattened: return "头发被压扁"
        case .headPetRebound: return "头发弹回"
        case .appLiftSupport: return "托起 App 窗口"
        case .mouseFollowRunStrideA, .mouseFollowRunPass, .mouseFollowRunStrideB:
            return "跟随鼠标奔跑"
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
        case .careCheckTime, .careEncourage, .careOfferMug, .careOfferWater,
             .careStretch, .careTiredEye, .courtConcentrate, .courtExplain,
             .courtInspectClue, .courtInspectDetail, .courtReady, .courtSurprised,
             .workCarryFiles, .workGatherPapers, .workPolishBadge, .workReadCase,
             .workSmallVictory, .workTakeNotes, .headPetFlattened,
             .headPetRebound, .appLiftSupport, .mouseFollowRunStrideA,
             .mouseFollowRunPass, .mouseFollowRunStrideB:
            return nil
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
        case .careCheckTime, .careEncourage, .careOfferMug, .careOfferWater,
             .careStretch, .careTiredEye:
            return 3.4
        case .courtConcentrate, .courtExplain, .courtInspectClue,
             .courtInspectDetail, .courtReady, .courtSurprised:
            return 3.0
        case .workCarryFiles, .workGatherPapers, .workPolishBadge,
             .workReadCase, .workSmallVictory, .workTakeNotes:
            return 3.2
        case .headPetFlattened: return 0.72
        case .headPetRebound: return 0.68
        case .appLiftSupport, .mouseFollowRunStrideA, .mouseFollowRunPass,
             .mouseFollowRunStrideB:
            return 0
        }
    }

    static var interactiveActions: [PetAction] {
        [
            .think, .objection, .slam, .sweat, .evidence,
            .badgeToss, .magatama, .stepladder, .thinker, .decisiveEvidence,
        ]
    }

    static var lowFrequencyIdleActions: [PetAction] {
        [.think, .sleepy, .badgeToss, .evidence] + automaticCompanionActions
    }

    /// macOS 首发的无台词自动动作。通过待机动作袋逐轮播放，避免连续重复。
    static let automaticCompanionActions: [PetAction] = [
        .careCheckTime, .careEncourage, .careOfferMug, .careOfferWater,
        .careStretch, .careTiredEye,
        .courtConcentrate, .courtExplain, .courtInspectClue, .courtInspectDetail,
        .courtReady, .courtSurprised,
        .workCarryFiles, .workGatherPapers, .workPolishBadge, .workReadCase,
        .workSmallVictory, .workTakeNotes,
    ]
}
