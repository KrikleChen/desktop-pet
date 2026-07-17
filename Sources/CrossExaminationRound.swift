struct CrossExaminationQuestion: Hashable {
    let id: String
    let title: String
    let statements: [String]
    let contradictionIndex: Int
    let conclusion: String

    init(
        id: String,
        title: String,
        statements: [String],
        contradictionIndex: Int,
        conclusion: String
    ) {
        self.id = id
        self.title = title
        self.statements = statements
        self.contradictionIndex = contradictionIndex
        self.conclusion = conclusion
        precondition(isValid, "交叉询问题目必须包含 3 句短证言、合法矛盾索引和结论")
    }

    var isValid: Bool {
        !id.isEmpty
            && !title.isEmpty
            && statements.count == 3
            && statements.allSatisfy { !$0.isEmpty && $0.count <= 24 }
            && statements.indices.contains(contradictionIndex)
            && !conclusion.isEmpty
    }
}

enum CrossExaminationQuestionBank {
    static let questions: [CrossExaminationQuestion] = [
        CrossExaminationQuestion(
            id: "blackout-label",
            title: "停电后的标签",
            statements: [
                "停电时仓库里没有任何光源。",
                "停电后我看清了红色标签。",
                "那次停电持续了十分钟。",
            ],
            contradictionIndex: 1,
            conclusion: "一片黑暗时不可能看清标签颜色。"
        ),
        CrossExaminationQuestion(
            id: "borrowed-key",
            title: "借出的钥匙",
            statements: [
                "钥匙始终没离开我的口袋。",
                "我把钥匙借给保安十分钟。",
                "保安随后把钥匙还给了我。",
            ],
            contradictionIndex: 0,
            conclusion: "既然借给过保安，钥匙就离开过口袋。"
        ),
        CrossExaminationQuestion(
            id: "warehouse-door",
            title: "唯一的出口",
            statements: [
                "仓库只有一扇可通行的门。",
                "我全程守在那扇门的外面。",
                "那个人从另一扇门逃走了。",
            ],
            contradictionIndex: 2,
            conclusion: "既然只有一扇门，就不存在另一个出口。"
        ),
        CrossExaminationQuestion(
            id: "fresh-tea",
            title: "刚沏的茶",
            statements: [
                "那杯茶刚刚沏好。",
                "我摸到杯壁时它冰凉刺手。",
                "旁边的水壶还在冒热气。",
            ],
            contradictionIndex: 1,
            conclusion: "刚用热水沏好的茶杯不会冰凉。"
        ),
        CrossExaminationQuestion(
            id: "stopped-elevator",
            title: "停运的电梯",
            statements: [
                "停电后电梯立刻停运。",
                "我停电后坐电梯去了五楼。",
                "维修记录确认没有备用电源。",
            ],
            contradictionIndex: 1,
            conclusion: "没有备用电源时，停运电梯无法上楼。"
        ),
        CrossExaminationQuestion(
            id: "sealed-envelope",
            title: "封住的信封",
            statements: [
                "信封到会议开始才被拆开。",
                "会议前封口和蜡印都完好。",
                "会议前我已经读过信里的内容。",
            ],
            contradictionIndex: 2,
            conclusion: "封口完好时不可能提前读到信件内容。"
        ),
        CrossExaminationQuestion(
            id: "short-recording",
            title: "超出的录音",
            statements: [
                "这段录音总长只有三十秒。",
                "开头十秒能听见钟声。",
                "第四十秒时出现了咳嗽声。",
            ],
            contradictionIndex: 2,
            conclusion: "三十秒的录音不会有第四十秒。"
        ),
        CrossExaminationQuestion(
            id: "fast-clock",
            title: "照片里的钟",
            statements: [
                "现场的钟比标准时间慢一小时。",
                "照片文件记录的标准时间是两点。",
                "同一张照片里的现场钟指向三点。",
            ],
            contradictionIndex: 0,
            conclusion: "现场钟显示三点，它应该快一小时。"
        ),
    ]
}

struct CrossExaminationQuestionBag {
    private let questions: [CrossExaminationQuestion]
    private var remaining: [CrossExaminationQuestion] = []
    private var lastQuestionID: String?
    private var randomNumberGenerator: any RandomNumberGenerator

    init(questions: [CrossExaminationQuestion] = CrossExaminationQuestionBank.questions) {
        precondition(Self.hasUniqueIDs(questions), "交叉询问题库 ID 必须唯一")
        self.questions = questions
        randomNumberGenerator = SystemRandomNumberGenerator()
    }

    init<Generator: RandomNumberGenerator>(
        questions: [CrossExaminationQuestion] = CrossExaminationQuestionBank.questions,
        randomNumberGenerator: Generator
    ) {
        precondition(Self.hasUniqueIDs(questions), "交叉询问题库 ID 必须唯一")
        self.questions = questions
        self.randomNumberGenerator = randomNumberGenerator
    }

    mutating func next() -> CrossExaminationQuestion? {
        guard !questions.isEmpty else { return nil }
        if remaining.isEmpty {
            remaining = questions
            remaining.shuffle(using: &randomNumberGenerator)
            avoidAdjacentRoundRepeat()
        }

        let question = remaining.removeLast()
        lastQuestionID = question.id
        return question
    }

    private mutating func avoidAdjacentRoundRepeat() {
        guard
            remaining.count > 1,
            remaining.last?.id == lastQuestionID,
            let replacementIndex = remaining.firstIndex(where: { $0.id != lastQuestionID })
        else { return }
        remaining.swapAt(replacementIndex, remaining.index(before: remaining.endIndex))
    }

    private static func hasUniqueIDs(_ questions: [CrossExaminationQuestion]) -> Bool {
        Set(questions.map(\.id)).count == questions.count
    }
}

struct CrossExaminationSessionToken: Hashable, Comparable {
    fileprivate let rawValue: UInt64

    static func < (
        lhs: CrossExaminationSessionToken,
        rhs: CrossExaminationSessionToken
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CrossExaminationRoundPhase: Equatable {
    case active
    case succeeded
    case timedOut
    case cancelled
}

struct CrossExaminationRoundSnapshot: Equatable {
    let sessionToken: CrossExaminationSessionToken
    let question: CrossExaminationQuestion
    fileprivate(set) var currentIndex: Int
    fileprivate(set) var phase: CrossExaminationRoundPhase

    var currentStatement: String {
        question.statements[currentIndex]
    }
}

enum CrossExaminationNavigationResult: Equatable {
    case moved(to: Int)
    case atBeginning(index: Int)
    case atEnd(index: Int)
    case ignored
}

enum CrossExaminationObjectionResult: Equatable {
    case incorrect(selectedIndex: Int, hint: String)
    case succeeded(conclusion: String)
    case ignored
}

enum CrossExaminationTerminationResult: Equatable {
    case timedOut
    case cancelled
    case ignored
}

struct CrossExaminationRound {
    static let incorrectHint = "这句暂时解释得通，再看看前后证言。"

    private(set) var snapshot: CrossExaminationRoundSnapshot?
    private var lastIssuedSessionRawValue: UInt64 = 0

    @discardableResult
    mutating func start(
        question: CrossExaminationQuestion
    ) -> CrossExaminationSessionToken {
        precondition(question.isValid, "不能启动无效的交叉询问题目")
        precondition(lastIssuedSessionRawValue < UInt64.max, "交叉询问 session token 已耗尽")
        lastIssuedSessionRawValue += 1
        let token = CrossExaminationSessionToken(rawValue: lastIssuedSessionRawValue)
        snapshot = CrossExaminationRoundSnapshot(
            sessionToken: token,
            question: question,
            currentIndex: 0,
            phase: .active
        )
        return token
    }

    mutating func previous(
        sessionToken: CrossExaminationSessionToken
    ) -> CrossExaminationNavigationResult {
        guard var active = activeSnapshot(for: sessionToken) else { return .ignored }
        guard active.currentIndex > 0 else {
            return .atBeginning(index: active.currentIndex)
        }
        active.currentIndex -= 1
        snapshot = active
        return .moved(to: active.currentIndex)
    }

    mutating func next(
        sessionToken: CrossExaminationSessionToken
    ) -> CrossExaminationNavigationResult {
        guard var active = activeSnapshot(for: sessionToken) else { return .ignored }
        let lastIndex = active.question.statements.index(before: active.question.statements.endIndex)
        guard active.currentIndex < lastIndex else {
            return .atEnd(index: active.currentIndex)
        }
        active.currentIndex += 1
        snapshot = active
        return .moved(to: active.currentIndex)
    }

    mutating func object(
        sessionToken: CrossExaminationSessionToken
    ) -> CrossExaminationObjectionResult {
        guard var active = activeSnapshot(for: sessionToken) else { return .ignored }
        guard active.currentIndex == active.question.contradictionIndex else {
            return .incorrect(
                selectedIndex: active.currentIndex,
                hint: Self.incorrectHint
            )
        }

        active.phase = .succeeded
        snapshot = active
        return .succeeded(conclusion: active.question.conclusion)
    }

    mutating func timeout(
        sessionToken: CrossExaminationSessionToken
    ) -> CrossExaminationTerminationResult {
        guard var active = activeSnapshot(for: sessionToken) else { return .ignored }
        active.phase = .timedOut
        snapshot = active
        return .timedOut
    }

    mutating func cancel(
        sessionToken: CrossExaminationSessionToken
    ) -> CrossExaminationTerminationResult {
        guard var active = activeSnapshot(for: sessionToken) else { return .ignored }
        active.phase = .cancelled
        snapshot = active
        return .cancelled
    }

    private func activeSnapshot(
        for sessionToken: CrossExaminationSessionToken
    ) -> CrossExaminationRoundSnapshot? {
        guard
            let snapshot,
            snapshot.sessionToken == sessionToken,
            snapshot.phase == .active
        else { return nil }
        return snapshot
    }
}
