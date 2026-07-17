/// A shuffle bag that returns each currently eligible element once per round.
///
/// Supply the current eligible collection on every draw. Removed elements are
/// discarded before a result is returned, while newly added elements join the
/// current round if they have not already appeared in it.
struct PetActionBag<Element: Hashable> {
    private var randomNumberGenerator: any RandomNumberGenerator
    private var remaining: [Element] = []
    private var seenInRound: Set<Element> = []
    private var lastReturned: Element?
    private var eligibleSnapshot: [Element] = []

    init() {
        randomNumberGenerator = SystemRandomNumberGenerator()
    }

    init<Generator: RandomNumberGenerator>(
        randomNumberGenerator: Generator
    ) {
        self.randomNumberGenerator = randomNumberGenerator
    }

    /// Returns a random eligible element, or `nil` when `eligible` is empty.
    ///
    /// Duplicate values in `eligible` are treated as one candidate. When a
    /// round rolls over and at least two candidates are available, the first
    /// result of the new round is guaranteed to differ from the previous one.
    mutating func next(from eligible: [Element]) -> Element? {
        if eligible == eligibleSnapshot {
            return drawFromCurrentCandidates()
        }
        return updateCandidatesAndDraw(uniqueElements(in: eligible))
    }

    mutating func next<Eligible: Sequence>(
        from eligible: Eligible
    ) -> Element? where Eligible.Element == Element {
        updateCandidatesAndDraw(uniqueElements(in: eligible))
    }

    private mutating func updateCandidatesAndDraw(
        _ candidates: [Element]
    ) -> Element? {
        guard !candidates.isEmpty else {
            remaining.removeAll(keepingCapacity: true)
            seenInRound.removeAll(keepingCapacity: true)
            eligibleSnapshot.removeAll(keepingCapacity: true)
            return nil
        }

        let candidateSet = Set(candidates)
        remaining.removeAll { !candidateSet.contains($0) }

        let remainingSet = Set(remaining)
        let additions = candidates.filter {
            !seenInRound.contains($0) && !remainingSet.contains($0)
        }
        if !additions.isEmpty {
            remaining.append(contentsOf: additions)
            remaining.shuffle(using: &randomNumberGenerator)
        }
        eligibleSnapshot = candidates

        return drawFromCurrentCandidates()
    }

    private mutating func drawFromCurrentCandidates() -> Element? {
        guard !eligibleSnapshot.isEmpty else {
            return nil
        }
        // All currently eligible candidates have appeared. Begin a new round.
        if remaining.isEmpty {
            seenInRound.removeAll(keepingCapacity: true)
            remaining = eligibleSnapshot
            remaining.shuffle(using: &randomNumberGenerator)
            moveNonRepeatingCandidateToDrawPosition()
        }

        guard let result = remaining.popLast() else {
            return nil
        }
        seenInRound.insert(result)
        lastReturned = result
        return result
    }

    /// Discards the current round. The next draw still avoids `lastReturned`
    /// at the new round boundary when more than one candidate is available.
    mutating func resetRound() {
        remaining.removeAll(keepingCapacity: true)
        seenInRound.removeAll(keepingCapacity: true)
    }

    private func uniqueElements<Eligible: Sequence>(
        in eligible: Eligible
    ) -> [Element] where Eligible.Element == Element {
        var seen: Set<Element> = []
        return eligible.filter { seen.insert($0).inserted }
    }

    private mutating func moveNonRepeatingCandidateToDrawPosition() {
        guard
            remaining.count > 1,
            let lastReturned,
            remaining.last == lastReturned,
            let replacementIndex = remaining.firstIndex(where: { $0 != lastReturned })
        else {
            return
        }
        remaining.swapAt(replacementIndex, remaining.index(before: remaining.endIndex))
    }
}
