import Foundation

private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        // xorshift64*: compact, deterministic, and sufficient for model tests.
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }
}

@main
struct PetActionBagTestMain {
    static func main() {
        testEmptyAndSingleElementCollections()
        testFixedSeedIsReproducible()
        testEveryRoundCoversCandidatesWithoutDuplicates()
        testRoundBoundaryNeverRepeats()
        testDynamicCandidateChanges()
        testDuplicateCandidatesAreNormalized()
        testInstancesAreIndependent()
        testResetRound()
        testPerformance()
        print("智能随机动作袋自检通过。")
    }

    private static func testEmptyAndSingleElementCollections() {
        var bag = makeBag(seed: 1)
        precondition(bag.next(from: [Int]()) == nil, "空集合应返回 nil")

        for _ in 0..<20 {
            precondition(bag.next(from: [7]) == 7, "单元素集合只能返回该元素")
        }

        precondition(bag.next(from: [Int]()) == nil, "从单元素切换到空集合应安全")
        precondition(bag.next(from: [8]) == 8, "空集合后应能恢复抽取")
    }

    private static func testFixedSeedIsReproducible() {
        var first = makeBag(seed: 0xC0FFEE)
        var second = makeBag(seed: 0xC0FFEE)
        let candidates = Array(0..<11)

        let firstSequence = (0..<200).map { _ in first.next(from: candidates)! }
        let secondSequence = (0..<200).map { _ in second.next(from: candidates)! }
        precondition(firstSequence == secondSequence, "相同 seed 应产生相同序列")
    }

    private static func testEveryRoundCoversCandidatesWithoutDuplicates() {
        let candidates = Array(0..<17)

        for seed in 1...128 {
            var bag = makeBag(seed: UInt64(seed))
            for round in 0..<12 {
                let draws = (0..<candidates.count).map { _ in
                    bag.next(from: candidates)!
                }
                precondition(
                    Set(draws) == Set(candidates),
                    "seed \(seed) 第 \(round) 轮未覆盖全部候选项"
                )
                precondition(
                    Set(draws).count == draws.count,
                    "seed \(seed) 第 \(round) 轮出现重复"
                )
            }
        }
    }

    private static func testRoundBoundaryNeverRepeats() {
        for candidateCount in [2, 3, 7, 25] {
            let candidates = Array(0..<candidateCount)
            for seed in 1...100 {
                var bag = makeBag(seed: UInt64(seed))
                var previous: Int?
                for drawIndex in 0..<(candidateCount * 15) {
                    let result = bag.next(from: candidates)!
                    if drawIndex % candidateCount == 0, let previous {
                        precondition(
                            result != previous,
                            "seed \(seed) 的 \(candidateCount) 元素袋在跨轮边界重复"
                        )
                    }
                    previous = result
                }
            }
        }
    }

    private static func testDynamicCandidateChanges() {
        var bag = makeBag(seed: 42)
        let initial = [1, 2, 3, 4]
        let first = bag.next(from: initial)!

        // Remove everything except the drawn item, then replace the set. No
        // stale item from the old pending round may escape.
        precondition(bag.next(from: [first]) == first)
        for _ in 0..<20 {
            let value = bag.next(from: [10, 11, 12])!
            precondition([10, 11, 12].contains(value), "动态替换后返回了失效项")
        }

        // A new item joins the unfinished round; an item removed before being
        // drawn must disappear immediately.
        bag.resetRound()
        let base = [20, 21, 22]
        let drawn = bag.next(from: base)!
        let retained = base.first { $0 != drawn }!
        let changed = [drawn, retained, 99]
        let restOfRound = (0..<2).map { _ in bag.next(from: changed)! }
        precondition(Set(restOfRound) == Set([retained, 99]), "新增/删除项未正确合并到当前轮")
    }

    private static func testDuplicateCandidatesAreNormalized() {
        var bag = makeBag(seed: 19)
        let duplicated = [1, 1, 2, 2, 3, 3, 3]
        let round = (0..<3).map { _ in bag.next(from: duplicated)! }
        precondition(Set(round) == Set([1, 2, 3]), "候选重复值应归一化")
    }

    private static func testInstancesAreIndependent() {
        let candidates = Array(0..<9)
        var reference = makeBag(seed: 1234)
        let expected = (0..<60).map { _ in reference.next(from: candidates)! }

        var first = makeBag(seed: 1234)
        var noisyNeighbor = makeBag(seed: 9876)
        var actual: [Int] = []
        for _ in 0..<60 {
            actual.append(first.next(from: candidates)!)
            for _ in 0..<7 {
                _ = noisyNeighbor.next(from: candidates)
            }
        }
        precondition(actual == expected, "一个实例的抽取不应干扰另一实例")
    }

    private static func testResetRound() {
        var bag = makeBag(seed: 77)
        let candidates = [1, 2, 3, 4]
        let beforeReset = bag.next(from: candidates)!
        bag.resetRound()
        let afterReset = bag.next(from: candidates)!
        precondition(beforeReset != afterReset, "重置后的新轮不应紧邻重复")
    }

    private static func testPerformance() {
        var bag = makeBag(seed: 0xDEADBEEF)
        let candidates = Array(0..<64)
        let drawCount = 50_000
        var checksum = 0
        let startedAt = CFAbsoluteTimeGetCurrent()

        for _ in 0..<drawCount {
            checksum &+= bag.next(from: candidates)!
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        precondition(checksum > 0, "性能抽样应实际执行")
        precondition(elapsed < 4, "5 万次抽取耗时过长：\(elapsed)s")
        print(String(format: "性能抽样：%d 次 / %.3f 秒", drawCount, elapsed))
    }

    private static func makeBag(seed: UInt64) -> PetActionBag<Int> {
        PetActionBag(randomNumberGenerator: SeededRandomNumberGenerator(seed: seed))
    }
}
