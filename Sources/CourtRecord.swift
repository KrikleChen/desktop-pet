import Foundation

struct CourtRecordEntryProgress: Codable, Equatable {
    var unlockedAt: Date
    var count: Int
    var lastSeen: Date
}

struct CourtRecordProgress: Codable, Equatable {
    var entriesByID: [String: CourtRecordEntryProgress] = [:]

    /// 兼容半成品时期的数据形状，只用于迁移和旧调用方读取。
    var discoveredAtByID: [String: Date] {
        entriesByID.mapValues(\.unlockedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case entriesByID
        case discoveredAtByID
    }

    init(entriesByID: [String: CourtRecordEntryProgress] = [:]) {
        self.entriesByID = entriesByID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let entries = try container.decodeIfPresent(
            [String: CourtRecordEntryProgress].self,
            forKey: .entriesByID
        ) {
            entriesByID = entries.mapValues { entry in
                CourtRecordEntryProgress(
                    unlockedAt: entry.unlockedAt,
                    count: max(0, entry.count),
                    lastSeen: max(entry.unlockedAt, entry.lastSeen)
                )
            }
            return
        }

        let legacyDates = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .discoveredAtByID
        ) ?? [:]
        entriesByID = legacyDates.mapValues { date in
            CourtRecordEntryProgress(unlockedAt: date, count: 1, lastSeen: date)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entriesByID, forKey: .entriesByID)
    }
}

enum CourtRecordCategory: String {
    case classic = "经典动作"
    case easterEgg = "彩蛋"
    case grabReaction = "抓取反应"
    case environment = "环境反应"
    case nameResponse = "名字回应"
    case physics = "桌面互动"
    case caseCompletion = "今日一案"

    var icon: String {
        switch self {
        case .classic: return "!"
        case .easterEgg: return "★"
        case .grabReaction: return "↕"
        case .environment: return "☾"
        case .nameResponse: return "♪"
        case .physics: return "↗"
        case .caseCompletion: return "§"
        }
    }
}

struct CourtRecordDefinition {
    let id: String
    let category: CourtRecordCategory
    let title: String
    let detail: String
    let lockedHint: String
}

enum CourtRecordID {
    static let darkPlace = "environment.dark-place"
    static let nameResponse = "response.heard-name"
    static let thrown = "physics.thrown"
    static let upsideDownScatter = "physics.upside-down-scatter"
    static let dailyCase = "case.daily"

    static func action(_ action: PetAction) -> String? {
        switch action {
        case .think, .objection, .slam, .sweat, .evidence:
            return "action.\(action.rawValue)"
        case .badgeToss, .magatama, .stepladder, .thinker, .decisiveEvidence:
            return "easter-egg.\(action.rawValue)"
        case .thrown:
            return thrown
        case .heardName:
            return nameResponse
        case .afraidDark, .flashlight:
            return darkPlace
        default:
            return nil
        }
    }

    static func grab(_ region: GrabRegion) -> String {
        "grab.\(region.rawValue)"
    }

    static func caseCompletion(_ caseID: String) -> String {
        "case.\(caseID).completed"
    }
}

enum CourtRecordCatalog {
    static let all: [CourtRecordDefinition] = {
        let classics: [CourtRecordDefinition] = [
            entry(.think, category: .classic, detail: "认真梳理过一次线索。", hint: "也许安静片刻会有头绪。"),
            entry(.objection, category: .classic, detail: "让那句响亮的反驳划破了安静。", hint: "有些矛盾需要被大声指出。"),
            entry(.slam, category: .classic, detail: "以律师的气势拍下了桌面。", hint: "关键时刻，需要一点气势。"),
            entry(.sweat, category: .classic, detail: "见过他措手不及的一面。", hint: "失误有时也会带来新反应。"),
            entry(.evidence, category: .classic, detail: "请他仔细查看过证物。", hint: "真相常藏在纸面细节里。"),
        ]

        let easterEggs: [CourtRecordDefinition] = [
            entry(.badgeToss, category: .easterEgg, detail: "律师身份用一种轻快的方式登场。", hint: "那枚小小的身份象征还会出现。"),
            entry(.magatama, category: .easterEgg, detail: "察觉到话语背后隐藏的心事。", hint: "秘密不会永远沉默。"),
            entry(.stepladder, category: .easterEgg, detail: "认真争论了某件工具的准确叫法。", hint: "同一样东西，也可能有两种称呼。"),
            entry(.thinker, category: .easterEgg, detail: "一件造型特别的摆设进入了记录。", hint: "某件会报时的摆设值得留意。"),
            entry(.decisiveEvidence, category: .easterEgg, detail: "终于举起了足以改变局面的证据。", hint: "继续寻找能让局势翻转的东西。"),
        ]

        let grabs = GrabRegion.allCases.map { region in
            let discoveredTitle: String
            let detail: String
            switch region {
            case .hairHead:
                discoveredTitle = "发型保卫战"
                detail = "真的从头发附近把他拎了起来。"
            case .arm:
                discoveredTitle = "律师的手臂"
                detail = "从手臂附近触发了专属挣扎。"
            case .collarTorso:
                discoveredTitle = "领口悬案"
                detail = "从领口或躯干处把他提了起来。"
            case .leg:
                discoveredTitle = "倒吊的辩护人"
                detail = "从腿脚附近触发了完全不同的反应。"
            }
            return CourtRecordDefinition(
                id: CourtRecordID.grab(region),
                category: .grabReaction,
                title: discoveredTitle,
                detail: detail,
                lockedHint: "角色身上还有一处不同的抓取反应。"
            )
        }

        let reactions: [CourtRecordDefinition] = [
            CourtRecordDefinition(
                id: CourtRecordID.darkPlace,
                category: .environment,
                title: "黑暗中的调查",
                detail: "在真正昏暗的壁纸落点见到了怕黑反应。",
                lockedHint: "周围环境偶尔也会影响调查。"
            ),
            CourtRecordDefinition(
                id: CourtRecordID.nameResponse,
                category: .nameResponse,
                title: "听见呼唤",
                detail: "聊天输入框里新出现名字时，他作出了回应。",
                lockedHint: "一声恰当的呼唤也许会被听见。"
            ),
            CourtRecordDefinition(
                id: CourtRecordID.thrown,
                category: .physics,
                title: "空中的辩护人",
                detail: "快速拖动后松手，让他经历了一次完整的甩飞。",
                lockedHint: "拖动速度也可能改变松手后的结果。"
            ),
            CourtRecordDefinition(
                id: CourtRecordID.upsideDownScatter,
                category: .physics,
                title: "散落的法庭记录",
                detail: "倒吊摇摆时，律师随身的道具散落了一地。",
                lockedHint: "倒吊以后，试着让他左右摇摆。"
            ),
            CourtRecordDefinition(
                id: CourtRecordID.dailyCase,
                category: .caseCompletion,
                title: "今日一案",
                detail: "接受过一份桌面上的短委托。",
                lockedHint: "法庭记录里也许会出现新的委托。"
            ),
        ]

        let cases = DailyCaseLibrary.all.map { dailyCase in
            CourtRecordDefinition(
                id: CourtRecordID.caseCompletion(dailyCase.id),
                category: .caseCompletion,
                title: dailyCase.recordTitle,
                detail: "成功指出了“\(dailyCase.title)”中的关键矛盾。",
                lockedHint: "还有一份短委托等待找出矛盾。"
            )
        }

        let catalog = classics + easterEggs + grabs + reactions + cases
        assert(Set(catalog.map(\.id)).count == catalog.count, "法庭记录条目 ID 不可重复")
        return catalog
    }()

    static let allIDs = Set(all.map(\.id))

    private static func entry(
        _ action: PetAction,
        category: CourtRecordCategory,
        detail: String,
        hint: String
    ) -> CourtRecordDefinition {
        guard let id = CourtRecordID.action(action) else {
            preconditionFailure("动作 \(action.rawValue) 没有对应的法庭记录 ID")
        }
        return CourtRecordDefinition(
            id: id,
            category: category,
            title: action.menuTitle,
            detail: detail,
            lockedHint: hint
        )
    }
}

extension Notification.Name {
    static let courtRecordStoreDidChange = Notification.Name("CourtRecordStoreDidChange")
}

final class CourtRecordStore {
    static let storageKey = "courtRecord.progress.v2"
    static let legacyStorageKey = "courtRecord.progress.v1"
    static let shared = CourtRecordStore()

    private let defaults: UserDefaults
    private(set) var progress: CourtRecordProgress

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(CourtRecordProgress.self, from: data) {
            progress = decoded
        } else if let data = defaults.data(forKey: Self.legacyStorageKey),
                  let decoded = try? JSONDecoder().decode(CourtRecordProgress.self, from: data) {
            progress = decoded
            persist(notify: false)
        } else {
            progress = CourtRecordProgress()
        }
    }

    var discoveredCount: Int {
        CourtRecordCatalog.all.reduce(into: 0) { count, definition in
            if progress.entriesByID[definition.id] != nil {
                count += 1
            }
        }
    }

    var totalCount: Int {
        CourtRecordCatalog.all.count
    }

    func entry(for id: String) -> CourtRecordEntryProgress? {
        progress.entriesByID[id]
    }

    func discoveredAt(for id: String) -> Date? {
        entry(for: id)?.unlockedAt
    }

    func count(for id: String) -> Int {
        entry(for: id)?.count ?? 0
    }

    func lastSeen(for id: String) -> Date? {
        entry(for: id)?.lastSeen
    }

    /// 只负责解锁。相同 ID 重复调用不会改时间或次数。
    @discardableResult
    func unlock(_ id: String, at date: Date = Date()) -> Bool {
        guard CourtRecordCatalog.allIDs.contains(id) else { return false }
        guard progress.entriesByID[id] == nil else { return false }

        progress.entriesByID[id] = CourtRecordEntryProgress(
            unlockedAt: date,
            count: 0,
            lastSeen: date
        )
        persist()
        return true
    }

    /// 记录一次真实触发；首次记录会自动解锁，后续记录只累计次数和最近时间。
    @discardableResult
    func record(_ id: String, at date: Date = Date()) -> Bool {
        guard CourtRecordCatalog.allIDs.contains(id) else { return false }
        let wasNew = progress.entriesByID[id] == nil

        if var entry = progress.entriesByID[id] {
            entry.unlockedAt = min(entry.unlockedAt, date)
            entry.count = entry.count == Int.max ? Int.max : entry.count + 1
            entry.lastSeen = max(entry.lastSeen, date)
            progress.entriesByID[id] = entry
        } else {
            progress.entriesByID[id] = CourtRecordEntryProgress(
                unlockedAt: date,
                count: 1,
                lastSeen: date
            )
        }

        persist()
        return wasNew
    }

    /// 保留半成品已经接入 PetView 的名字；语义等同于记录一次真实触发。
    @discardableResult
    func discover(_ id: String, at date: Date = Date()) -> Bool {
        record(id, at: date)
    }

    private func persist(notify: Bool = true) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.storageKey)
        guard notify else { return }

        if Thread.isMainThread {
            NotificationCenter.default.post(name: .courtRecordStoreDidChange, object: self)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                NotificationCenter.default.post(name: .courtRecordStoreDidChange, object: self)
            }
        }
    }
}
