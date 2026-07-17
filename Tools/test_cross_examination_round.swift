import Foundation

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

@main
struct CrossExaminationRoundTestMain {
    static func main() {
        testQuestionBankValidity()
        testEveryContradictionPositionCanSucceed()
        testNavigationBoundaries()
        testIncorrectObjectionKeepsRoundActive()
        testSuccessIsExactlyOnce()
        testTimeoutCancelAndStaleTokens()
        testQuestionBagCyclesAndReproducibility()
        testQuestionBagPerformance()
        print("轻量交叉询问回合自检通过。")
    }

    private static func testQuestionBankValidity() {
        let questions = CrossExaminationQuestionBank.questions
        precondition(questions.count == 8, "本地题库必须恰好有 8 题")
        precondition(Set(questions.map(\.id)).count == questions.count, "题目 ID 必须唯一")

        for question in questions {
            precondition(question.isValid, "\(question.id) 不合法")
            precondition(question.statements.count == 3, "\(question.id) 必须恰好 3 句证言")
            precondition(question.statements.allSatisfy { $0.count <= 24 }, "\(question.id) 证言过长")
            precondition(question.statements.indices.contains(question.contradictionIndex))
            precondition(!question.conclusion.isEmpty)
        }

        precondition(
            Set(questions.map(\.contradictionIndex)) == Set([0, 1, 2]),
            "题库必须覆盖三个矛盾位置"
        )
    }

    private static func testEveryContradictionPositionCanSucceed() {
        for question in CrossExaminationQuestionBank.questions {
            var round = CrossExaminationRound()
            let token = round.start(question: question)
            if question.contradictionIndex > 0 {
                for expectedIndex in 1...question.contradictionIndex {
                    precondition(round.next(sessionToken: token) == .moved(to: expectedIndex))
                }
            }
            precondition(
                round.object(sessionToken: token)
                    == .succeeded(conclusion: question.conclusion),
                "\(question.id) 在合法矛盾位置未成功"
            )
        }
    }

    private static func testNavigationBoundaries() {
        var round = CrossExaminationRound()
        let question = CrossExaminationQuestionBank.questions[0]
        let token = round.start(question: question)

        precondition(round.snapshot?.currentStatement == question.statements[0])
        precondition(round.previous(sessionToken: token) == .atBeginning(index: 0))
        precondition(round.next(sessionToken: token) == .moved(to: 1))
        precondition(round.next(sessionToken: token) == .moved(to: 2))
        precondition(round.next(sessionToken: token) == .atEnd(index: 2))
        precondition(round.previous(sessionToken: token) == .moved(to: 1))
        precondition(round.previous(sessionToken: token) == .moved(to: 0))
        precondition(round.previous(sessionToken: token) == .atBeginning(index: 0))
    }

    private static func testIncorrectObjectionKeepsRoundActive() {
        let question = CrossExaminationQuestionBank.questions.first {
            $0.contradictionIndex == 2
        }!
        var round = CrossExaminationRound()
        let token = round.start(question: question)

        precondition(
            round.object(sessionToken: token)
                == .incorrect(selectedIndex: 0, hint: CrossExaminationRound.incorrectHint)
        )
        precondition(round.snapshot?.phase == .active, "错选后应继续本轮")
        precondition(round.snapshot?.currentIndex == 0, "错选不应暗中跳转")
        precondition(round.next(sessionToken: token) == .moved(to: 1))
        precondition(
            round.object(sessionToken: token)
                == .incorrect(selectedIndex: 1, hint: CrossExaminationRound.incorrectHint)
        )
        precondition(round.next(sessionToken: token) == .moved(to: 2))
        precondition(
            round.object(sessionToken: token)
                == .succeeded(conclusion: question.conclusion)
        )
    }

    private static func testSuccessIsExactlyOnce() {
        let question = CrossExaminationQuestionBank.questions.first {
            $0.contradictionIndex == 0
        }!
        var round = CrossExaminationRound()
        let token = round.start(question: question)

        precondition(round.object(sessionToken: token) == .succeeded(conclusion: question.conclusion))
        for _ in 0..<100 {
            precondition(round.object(sessionToken: token) == .ignored)
        }
        precondition(round.next(sessionToken: token) == .ignored)
        precondition(round.previous(sessionToken: token) == .ignored)
        precondition(round.timeout(sessionToken: token) == .ignored)
        precondition(round.cancel(sessionToken: token) == .ignored)
        precondition(round.snapshot?.phase == .succeeded)
    }

    private static func testTimeoutCancelAndStaleTokens() {
        let questions = CrossExaminationQuestionBank.questions
        var round = CrossExaminationRound()
        let oldToken = round.start(question: questions[0])
        let timeoutToken = round.start(question: questions[1])
        precondition(oldToken < timeoutToken, "session token 必须单调递增")

        precondition(round.next(sessionToken: oldToken) == .ignored)
        precondition(round.previous(sessionToken: oldToken) == .ignored)
        precondition(round.object(sessionToken: oldToken) == .ignored)
        precondition(round.timeout(sessionToken: oldToken) == .ignored)
        precondition(round.cancel(sessionToken: oldToken) == .ignored)

        precondition(round.timeout(sessionToken: timeoutToken) == .timedOut)
        precondition(round.timeout(sessionToken: timeoutToken) == .ignored)
        precondition(round.object(sessionToken: timeoutToken) == .ignored)

        let cancelToken = round.start(question: questions[2])
        precondition(timeoutToken < cancelToken)
        precondition(round.cancel(sessionToken: cancelToken) == .cancelled)
        precondition(round.cancel(sessionToken: cancelToken) == .ignored)
        precondition(round.object(sessionToken: cancelToken) == .ignored)

        let activeToken = round.start(question: questions[3])
        precondition(round.object(sessionToken: oldToken) == .ignored)
        precondition(round.snapshot?.sessionToken == activeToken, "旧 token 不得污染新回合")
        precondition(round.snapshot?.phase == .active)
    }

    private static func testQuestionBagCyclesAndReproducibility() {
        let questions = CrossExaminationQuestionBank.questions
        for seed in 1...100 {
            var bag = makeBag(seed: UInt64(seed))
            var previousID: String?
            for _ in 0..<30 {
                let cycle = (0..<questions.count).map { _ in bag.next()! }
                precondition(Set(cycle.map(\.id)) == Set(questions.map(\.id)))
                precondition(Set(cycle.map(\.id)).count == cycle.count)
                if let previousID {
                    precondition(cycle.first?.id != previousID, "seed \(seed) 跨轮相邻重复")
                }
                previousID = cycle.last?.id
            }
        }

        var first = makeBag(seed: 0xC0FFEE)
        var second = makeBag(seed: 0xC0FFEE)
        let firstIDs = (0..<500).map { _ in first.next()!.id }
        let secondIDs = (0..<500).map { _ in second.next()!.id }
        precondition(firstIDs == secondIDs, "相同 seed 应产生相同题目序列")

        var emptyBag = CrossExaminationQuestionBag(
            questions: [],
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 1)
        )
        precondition(emptyBag.next() == nil)

        let onlyQuestion = questions[0]
        var singleBag = CrossExaminationQuestionBag(
            questions: [onlyQuestion],
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 2)
        )
        for _ in 0..<10 {
            precondition(singleBag.next() == onlyQuestion)
        }
    }

    private static func testQuestionBagPerformance() {
        var bag = makeBag(seed: 0xDEADBEEF)
        let drawCount = 50_000
        var checksum = 0
        let startedAt = CFAbsoluteTimeGetCurrent()
        for _ in 0..<drawCount {
            checksum &+= bag.next()!.id.count
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        precondition(checksum > 0)
        precondition(elapsed < 4, "5 万次题目选择耗时过长：\(elapsed)s")
        print(String(format: "题目袋性能：%d 次 / %.3f 秒", drawCount, elapsed))
    }

    private static func makeBag(seed: UInt64) -> CrossExaminationQuestionBag {
        CrossExaminationQuestionBag(
            randomNumberGenerator: SeededRandomNumberGenerator(seed: seed)
        )
    }
}
