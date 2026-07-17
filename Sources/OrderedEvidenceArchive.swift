/// Visible state of one eligible ordered-archive round.
enum OrderedEvidenceArchivePhase: Equatable {
    case active
    case failed
    case completed
}

struct OrderedEvidenceArchiveSnapshot: Equatable {
    let order: [AccessoryKind]
    let completedCount: Int
    let phase: OrderedEvidenceArchivePhase

    var nextExpectedKind: AccessoryKind? {
        guard phase == .active, order.indices.contains(completedCount) else {
            return nil
        }
        return order[completedCount]
    }
}

enum OrderedEvidenceArchiveStartResult: Equatable {
    case started(OrderedEvidenceArchiveSnapshot)
    case ineligible
}

enum OrderedEvidenceArchiveReclaimResult: Equatable {
    /// A stale session, an ineligible round, or a callback received after the
    /// challenge had already failed.
    case ignored

    /// The controller repeated a callback for an item already observed in this
    /// round. It neither advances nor fails the ordered challenge.
    case duplicate(OrderedEvidenceArchiveSnapshot)

    case advanced(OrderedEvidenceArchiveSnapshot)
    case failed(OrderedEvidenceArchiveSnapshot)
    case completed(OrderedEvidenceArchiveSnapshot)
}

enum OrderedEvidenceArchiveFinishResult: Equatable {
    case ignored
    case noReward
    case reward
}

/// Pure ordered-archive state layered on the existing accessory scatter ID.
///
/// Only a real round containing exactly all six stable accessory kinds may
/// start. A wrong click fails this optional challenge but deliberately does not
/// affect `AccessoryScatterController`, so ordinary reclaim can continue.
struct OrderedEvidenceArchive {
    private struct Round {
        let sessionID: AccessoryScatterSessionID
        let order: [AccessoryKind]
        var observedKinds: Set<AccessoryKind> = []
        var completedCount = 0
        var phase: OrderedEvidenceArchivePhase = .active

        var snapshot: OrderedEvidenceArchiveSnapshot {
            OrderedEvidenceArchiveSnapshot(
                order: order,
                completedCount: completedCount,
                phase: phase
            )
        }
    }

    private static let completeKindSet = Set(AccessoryKind.allCases)
    private var activeRound: Round?

    var activeSessionID: AccessoryScatterSessionID? {
        activeRound?.sessionID
    }

    var snapshot: OrderedEvidenceArchiveSnapshot? {
        activeRound?.snapshot
    }

    /// Starting any controller round first invalidates the previous challenge.
    /// Preview, missing-asset and malformed-order rounds remain ineligible.
    @discardableResult
    mutating func begin(
        sessionID: AccessoryScatterSessionID,
        mode: AccessoryCollectionRoundMode,
        expectedKinds: Set<AccessoryKind>,
        order: [AccessoryKind]
    ) -> OrderedEvidenceArchiveStartResult {
        activeRound = nil
        guard mode == .real,
              expectedKinds == Self.completeKindSet,
              order.count == AccessoryKind.allCases.count,
              Set(order) == Self.completeKindSet
        else {
            return .ineligible
        }

        let round = Round(sessionID: sessionID, order: order)
        activeRound = round
        return .started(round.snapshot)
    }

    /// Records the accessory controller's reclaim-start event for this session.
    /// Reward is never emitted here; even a completed order must wait for the
    /// matching scatter session's `finish` callback.
    mutating func recordReclaimed(
        _ kind: AccessoryKind,
        sessionID: AccessoryScatterSessionID
    ) -> OrderedEvidenceArchiveReclaimResult {
        guard var round = activeRound, round.sessionID == sessionID else {
            return .ignored
        }

        if round.observedKinds.contains(kind) {
            return .duplicate(round.snapshot)
        }
        guard round.phase == .active,
              round.order.indices.contains(round.completedCount)
        else {
            return .ignored
        }

        round.observedKinds.insert(kind)
        let expectedKind = round.order[round.completedCount]
        guard kind == expectedKind else {
            round.phase = .failed
            activeRound = round
            return .failed(round.snapshot)
        }

        round.completedCount += 1
        if round.completedCount == round.order.count {
            round.phase = .completed
            activeRound = round
            return .completed(round.snapshot)
        }

        activeRound = round
        return .advanced(round.snapshot)
    }

    /// Consumes the matching round. Only a fully completed round returns the
    /// one-shot enhanced reward; partial/faded and failed rounds return none.
    mutating func finish(
        sessionID: AccessoryScatterSessionID
    ) -> OrderedEvidenceArchiveFinishResult {
        guard let round = activeRound, round.sessionID == sessionID else {
            return .ignored
        }
        activeRound = nil
        return round.phase == .completed ? .reward : .noReward
    }

    /// Cancels only the matching session. Stale cancellation cannot disturb a
    /// newer scatter round.
    @discardableResult
    mutating func cancel(sessionID: AccessoryScatterSessionID) -> Bool {
        guard activeRound?.sessionID == sessionID else { return false }
        activeRound = nil
        return true
    }
}

/// Produces complete random six-item orders while preventing the first item of
/// two consecutive rounds from being identical.
struct OrderedEvidenceArchiveOrderGenerator {
    private var randomNumberGenerator: any RandomNumberGenerator
    private var previousFirstKind: AccessoryKind?

    init() {
        randomNumberGenerator = SystemRandomNumberGenerator()
    }

    init<Generator: RandomNumberGenerator>(
        randomNumberGenerator: Generator
    ) {
        self.randomNumberGenerator = randomNumberGenerator
    }

    mutating func nextOrder() -> [AccessoryKind] {
        var order = AccessoryKind.allCases
        order.shuffle(using: &randomNumberGenerator)

        if order.first == previousFirstKind, order.count > 1 {
            let replacementIndex = Int.random(
                in: 1..<order.count,
                using: &randomNumberGenerator
            )
            order.swapAt(0, replacementIndex)
        }
        previousFirstKind = order.first
        return order
    }
}
