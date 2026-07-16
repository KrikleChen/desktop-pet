import Foundation

struct CaseTestimony: Equatable {
    let id: String
    let text: String
}

struct CaseEvidence: Equatable {
    let id: String
    let name: String
    let detail: String
}

struct DailyCaseSolution: Equatable {
    let testimonyID: String
    let evidenceID: String
}

struct DailyCase: Equatable {
    let id: String
    let title: String
    let recordTitle: String
    let witness: String
    let introduction: String
    let testimony: [CaseTestimony]
    let evidence: [CaseEvidence]
    let solution: DailyCaseSolution
    let resolution: String

    // 保留清晰的只读入口，方便面板和后续玩法读取唯一答案。
    var correctTestimonyID: String { solution.testimonyID }
    var correctEvidenceID: String { solution.evidenceID }

    func isCorrect(testimonyID: String, evidenceID: String) -> Bool {
        solution == DailyCaseSolution(
            testimonyID: testimonyID,
            evidenceID: evidenceID
        )
    }
}

enum DailyCaseState: String, Equatable {
    case briefing
    case testimony
    case evidenceSelection
    case correct
    case wrong
    case completed
}

/// 与 PetAction 的动作名保持一致，但模型层不依赖 AppKit 或桌宠 UI。
enum DailyCaseReaction: String, Equatable {
    case decisiveEvidence
    case objection
    case think
    case sweat
}

extension DailyCaseState {
    var suggestedReactions: [DailyCaseReaction] {
        switch self {
        case .correct:
            return [.decisiveEvidence, .objection]
        case .wrong:
            return [.think, .sweat]
        default:
            return []
        }
    }
}

struct DailyCaseEvaluation: Equatable {
    let state: DailyCaseState
    let reactions: [DailyCaseReaction]
    let explanation: String
}

/// “今日一案”的纯 Swift 状态机。创建实例不会展示面板或请求权限。
struct DailyCaseSession: Equatable {
    let dailyCase: DailyCase
    private(set) var state: DailyCaseState = .briefing
    private(set) var selectedTestimonyID: String?
    private(set) var selectedEvidenceID: String?

    @discardableResult
    mutating func begin() -> Bool {
        guard state == .briefing else { return false }
        state = .testimony
        return true
    }

    @discardableResult
    mutating func selectTestimony(id: String) -> Bool {
        guard [.testimony, .evidenceSelection, .wrong].contains(state),
              dailyCase.testimony.contains(where: { $0.id == id }) else {
            return false
        }

        if selectedTestimonyID != id {
            selectedEvidenceID = nil
        }
        selectedTestimonyID = id
        state = .evidenceSelection
        return true
    }

    @discardableResult
    mutating func selectEvidence(id: String) -> Bool {
        guard [.evidenceSelection, .wrong].contains(state),
              selectedTestimonyID != nil,
              dailyCase.evidence.contains(where: { $0.id == id }) else {
            return false
        }

        selectedEvidenceID = id
        state = .evidenceSelection
        return true
    }

    /// 错误答案只进入 wrong 状态，不清空选择、不计次数，用户可直接改选重试。
    mutating func evaluate() -> DailyCaseEvaluation? {
        guard [.evidenceSelection, .wrong].contains(state),
              let testimonyID = selectedTestimonyID,
              let evidenceID = selectedEvidenceID else {
            return nil
        }

        if dailyCase.isCorrect(testimonyID: testimonyID, evidenceID: evidenceID) {
            state = .correct
            return DailyCaseEvaluation(
                state: .correct,
                reactions: DailyCaseState.correct.suggestedReactions,
                explanation: dailyCase.resolution
            )
        }

        state = .wrong
        return DailyCaseEvaluation(
            state: .wrong,
            reactions: DailyCaseState.wrong.suggestedReactions,
            explanation: "这组证言与证物还不能形成直接矛盾，可以马上重试。"
        )
    }

    @discardableResult
    mutating func complete() -> Bool {
        guard state == .correct else { return false }
        state = .completed
        return true
    }
}

struct DailyCaseRotation {
    let date: Date
    let calendar: Calendar
    private(set) var manualAdvance: Int = 0

    init(date: Date = Date(), calendar: Calendar = .current) {
        self.date = date
        self.calendar = calendar
    }

    var current: DailyCase {
        DailyCaseLibrary.caseForToday(
            date: date,
            calendar: calendar,
            manualAdvance: manualAdvance
        )
    }

    @discardableResult
    mutating func advance() -> DailyCase {
        manualAdvance += 1
        return current
    }
}

struct DailyCaseSelfCheckReport: Equatable {
    let checkedCaseCount: Int
    let failures: [String]

    var passed: Bool { failures.isEmpty }
}

enum DailyCaseLibrary {
    static let all: [DailyCase] = [
        DailyCase(
            id: "dark-bakery",
            title: "熄灯后的面包店",
            recordTitle: "面包店的灯光证言",
            witness: "夜班店员",
            introduction: "有人声称在打烊后看清了闯入者。",
            testimony: [
                CaseTestimony(id: "bakery-1", text: "① 我在后门听见了纸袋掉地的声音。"),
                CaseTestimony(id: "bakery-2", text: "② 那时店门已经上锁，我没有离开柜台。"),
                CaseTestimony(id: "bakery-3", text: "③ 我一眼看清那人穿着鲜红色外套。"),
            ],
            evidence: [
                CaseEvidence(id: "bakery-key", name: "备用钥匙", detail: "一直封在经理办公室。"),
                CaseEvidence(id: "bakery-light", name: "照明检修单", detail: "打烊后卷帘关闭，店内又停电一小时。"),
                CaseEvidence(id: "bakery-bag", name: "破损纸袋", detail: "袋口沾着少量面粉。"),
            ],
            solution: DailyCaseSolution(testimonyID: "bakery-3", evidenceID: "bakery-light"),
            resolution: "卷帘关闭且店内停电时，不可能一眼辨出外套颜色。"
        ),
        DailyCase(
            id: "rainy-platform",
            title: "雨夜站台的脚印",
            recordTitle: "站台边缘的水迹",
            witness: "匆忙的乘客",
            introduction: "一只遗失的文件袋最后出现在雨夜车站。",
            testimony: [
                CaseTestimony(id: "rain-1", text: "① 我整晚都在有顶棚的候车区等车。"),
                CaseTestimony(id: "rain-2", text: "② 文件袋掉在最外侧的露天长椅旁。"),
                CaseTestimony(id: "rain-3", text: "③ 我从没走到雨里的长椅附近。"),
            ],
            evidence: [
                CaseEvidence(id: "rain-ticket", name: "折角车票", detail: "检票时间是晚上九点十分。"),
                CaseEvidence(id: "rain-shoe", name: "鞋印照片", detail: "长椅旁泥印的缺口与证人鞋底完全吻合。"),
                CaseEvidence(id: "rain-map", name: "站台图", detail: "候车区与出口相隔二十米。"),
            ],
            solution: DailyCaseSolution(testimonyID: "rain-3", evidenceID: "rain-shoe"),
            resolution: "吻合的缺口鞋印证明证人到过露天长椅旁。"
        ),
        DailyCase(
            id: "silent-clock",
            title: "沉默的会议室时钟",
            recordTitle: "停止的会议室时钟",
            witness: "项目助理",
            introduction: "会议资料失踪，证人用墙上时钟确定了时间。",
            testimony: [
                CaseTestimony(id: "clock-1", text: "① 我进会议室时，桌上还放着蓝色文件夹。"),
                CaseTestimony(id: "clock-2", text: "② 墙上时钟刚好指向六点四十分。"),
                CaseTestimony(id: "clock-3", text: "③ 我关灯后就直接离开了公司。"),
            ],
            evidence: [
                CaseEvidence(id: "clock-card", name: "门禁记录", detail: "证人六点四十二分刷卡离开。"),
                CaseEvidence(id: "clock-battery", name: "报修照片", detail: "下午五点拍摄时，坏钟已停在六点四十分。"),
                CaseEvidence(id: "clock-folder", name: "文件夹标签", detail: "标签边缘有一道蓝墨水。"),
            ],
            solution: DailyCaseSolution(testimonyID: "clock-2", evidenceID: "clock-battery"),
            resolution: "进入会议室前就停住的时钟，不能用来判断当时的时间。"
        ),
        DailyCase(
            id: "warm-lunchbox",
            title: "消失的热便当",
            recordTitle: "仍然温热的便当盒",
            witness: "办公室同事",
            introduction: "午休前，一份便当从茶水间不见了。",
            testimony: [
                CaseTestimony(id: "lunch-1", text: "① 我十点就看见便当放进了冰箱。"),
                CaseTestimony(id: "lunch-2", text: "② 中午我拿错盒子，但马上放回原处。"),
                CaseTestimony(id: "lunch-3", text: "③ 我没有碰过茶水间里的微波炉。"),
            ],
            evidence: [
                CaseEvidence(id: "lunch-label", name: "姓名贴", detail: "姓名贴被贴在盒盖内侧。"),
                CaseEvidence(id: "lunch-log", name: "门锁记录", detail: "微波炉在十一点五十八分由证人工牌解锁。"),
                CaseEvidence(id: "lunch-photo", name: "冰箱照片", detail: "照片里能看到三个相似饭盒。"),
            ],
            solution: DailyCaseSolution(testimonyID: "lunch-3", evidenceID: "lunch-log"),
            resolution: "证人的工牌解锁了微波炉，与“没有碰过”的说法冲突。"
        ),
        DailyCase(
            id: "library-return",
            title: "闭馆后的还书箱",
            recordTitle: "还书箱的时间戳",
            witness: "读书会成员",
            introduction: "一本夹有手稿的书，在闭馆夜晚被归还。",
            testimony: [
                CaseTestimony(id: "book-1", text: "① 我在闭馆广播前就把书投入还书箱。"),
                CaseTestimony(id: "book-2", text: "② 投书时大厅里还有不少读者。"),
                CaseTestimony(id: "book-3", text: "③ 我回家后才发现手稿可能夹在书里。"),
            ],
            evidence: [
                CaseEvidence(id: "book-receipt", name: "自动回执", detail: "该书的唯一编号记录在闭馆后二十五分钟。"),
                CaseEvidence(id: "book-card", name: "借阅证", detail: "卡面有一处新折痕。"),
                CaseEvidence(id: "book-note", name: "广播表", detail: "闭馆广播按计划播放了两遍。"),
            ],
            solution: DailyCaseSolution(testimonyID: "book-1", evidenceID: "book-receipt"),
            resolution: "唯一编号的回执表明书是在闭馆后才投入还书箱。"
        ),
        DailyCase(
            id: "mirrored-studio",
            title: "镜面摄影棚的便签",
            recordTitle: "左右颠倒的摄影棚",
            witness: "广告摄影师",
            introduction: "证人用一张现场照片说明便签的位置。",
            testimony: [
                CaseTestimony(id: "studio-1", text: "① 我从门口拍下了整张化妆台。"),
                CaseTestimony(id: "studio-2", text: "② 照片证明便签贴在镜子的左下角。"),
                CaseTestimony(id: "studio-3", text: "③ 拍完后我没有移动任何道具。"),
            ],
            evidence: [
                CaseEvidence(id: "studio-photo", name: "现场照片", detail: "照片里的门牌文字呈左右反向。"),
                CaseEvidence(id: "studio-tape", name: "透明胶带", detail: "胶带卷少了很短的一截。"),
                CaseEvidence(id: "studio-list", name: "道具清单", detail: "清单登记了两面大型镜子。"),
            ],
            solution: DailyCaseSolution(testimonyID: "studio-2", evidenceID: "studio-photo"),
            resolution: "照片拍到的是镜中倒影，便签的实际位置应当左右相反。"
        ),
    ]

    static func caseForToday(
        date: Date = Date(),
        calendar: Calendar = .current,
        manualAdvance: Int = 0
    ) -> DailyCase {
        precondition(!all.isEmpty, "今日一案至少需要一个案件")
        let startOfDay = calendar.startOfDay(for: date)
        let dayOrdinal = calendar.ordinality(of: .day, in: .era, for: startOfDay) ?? 0
        let index = positiveModulo(dayOrdinal + manualAdvance, all.count)
        return all[index]
    }

    static func nextCase(after dailyCase: DailyCase) -> DailyCase {
        guard let currentIndex = all.firstIndex(where: { $0.id == dailyCase.id }) else {
            return all[0]
        }
        return all[(currentIndex + 1) % all.count]
    }

    /// 单元式自检：枚举每案全部 3×3 组合，并走通 wrong 重试及 correct 完成流程。
    static func runSelfCheck() -> DailyCaseSelfCheckReport {
        var failures: [String] = []

        if all.count < 6 {
            failures.append("案件数量不足 6 个：当前为 \(all.count) 个")
        }

        let duplicatedCaseIDs = duplicatedValues(all.map(\.id))
        if !duplicatedCaseIDs.isEmpty {
            failures.append("案件 ID 重复：\(duplicatedCaseIDs.joined(separator: ", "))")
        }

        for dailyCase in all {
            if dailyCase.testimony.count != 3 {
                failures.append("\(dailyCase.id)：证言数量不是 3")
            }
            if dailyCase.evidence.count != 3 {
                failures.append("\(dailyCase.id)：证物数量不是 3")
            }
            if !duplicatedValues(dailyCase.testimony.map(\.id)).isEmpty {
                failures.append("\(dailyCase.id)：证言 ID 不唯一")
            }
            if !duplicatedValues(dailyCase.evidence.map(\.id)).isEmpty {
                failures.append("\(dailyCase.id)：证物 ID 不唯一")
            }

            let validPairs = dailyCase.testimony.flatMap { testimony in
                dailyCase.evidence.compactMap { evidence in
                    dailyCase.isCorrect(testimonyID: testimony.id, evidenceID: evidence.id)
                        ? DailyCaseSolution(testimonyID: testimony.id, evidenceID: evidence.id)
                        : nil
                }
            }
            if validPairs.count != 1 || validPairs.first != dailyCase.solution {
                failures.append("\(dailyCase.id)：3×3 组合中不是恰好一个唯一解")
            }

            guard let wrongEvidence = dailyCase.evidence.first(where: {
                $0.id != dailyCase.correctEvidenceID
            }) else {
                failures.append("\(dailyCase.id)：缺少可用于重试自检的错误证物")
                continue
            }

            var session = DailyCaseSession(dailyCase: dailyCase)
            let began = session.begin()
            let selectedTestimony = session.selectTestimony(id: dailyCase.correctTestimonyID)
            let selectedWrongEvidence = session.selectEvidence(id: wrongEvidence.id)
            let wrongResult = session.evaluate()
            let retried = session.selectEvidence(id: dailyCase.correctEvidenceID)
            let correctResult = session.evaluate()
            let completed = session.complete()

            if !began || !selectedTestimony || !selectedWrongEvidence
                || wrongResult?.state != .wrong
                || wrongResult?.reactions != [.think, .sweat]
                || !retried
                || correctResult?.state != .correct
                || correctResult?.reactions != [.decisiveEvidence, .objection]
                || !completed
                || session.state != .completed {
                failures.append("\(dailyCase.id)：状态机或动作映射自检失败")
            }
        }

        var rotationCalendar = Calendar(identifier: .gregorian)
        rotationCalendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60) ?? .current
        let sampleMorning = rotationCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 16, hour: 1)
        ) ?? Date(timeIntervalSince1970: 0)
        let sampleEvening = rotationCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 16, hour: 23)
        ) ?? Date(timeIntervalSince1970: 0)
        let sampleTomorrow = rotationCalendar.date(
            byAdding: .day,
            value: 1,
            to: sampleMorning
        ) ?? sampleMorning
        let morningCase = caseForToday(date: sampleMorning, calendar: rotationCalendar)
        let eveningCase = caseForToday(date: sampleEvening, calendar: rotationCalendar)
        let tomorrowCase = caseForToday(date: sampleTomorrow, calendar: rotationCalendar)
        let manuallyAdvancedCase = caseForToday(
            date: sampleMorning,
            calendar: rotationCalendar,
            manualAdvance: 1
        )
        if morningCase != eveningCase {
            failures.append("日期轮换：同一自然日内结果不稳定")
        }
        if tomorrowCase != nextCase(after: morningCase)
            || manuallyAdvancedCase != tomorrowCase {
            failures.append("日期轮换：次日或手动下一案没有前进一案")
        }

        return DailyCaseSelfCheckReport(
            checkedCaseCount: all.count,
            failures: failures
        )
    }

    private static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        ((value % divisor) + divisor) % divisor
    }

    private static func duplicatedValues(_ values: [String]) -> [String] {
        let counts = Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
        return counts.filter { $0.value > 1 }.map(\.key).sorted()
    }
}
