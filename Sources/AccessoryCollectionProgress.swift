/// Whether an accessory collection round came from a real user interaction or
/// from a hidden build/QA preview.
enum AccessoryCollectionRoundMode: Equatable {
    case real
    case preview
}

/// Result of feeding one reclaim callback into `AccessoryCollectionProgress`.
enum AccessoryCollectionReclaimResult: Equatable {
    /// The callback belongs to an old round, or names a kind that was not
    /// actually scattered in the active round.
    case ignored

    /// This kind had already been counted in the current round.
    case duplicate(collectedCount: Int)

    /// A new, expected kind was counted. `hasCollectedEveryExpectedKind` is
    /// progress only; rewards are decided later by `finish(sessionID:)`.
    case recorded(collectedCount: Int, hasCollectedEveryExpectedKind: Bool)
}

/// Final decision for a scatter round. A reward is emitted only once, when a
/// real round containing all six stable accessory kinds finishes after every
/// kind has produced a unique reclaim event.
enum AccessoryCollectionFinishResult: Equatable {
    case ignored
    case noReward
    case reward
}

/// Pure ownership and progress state for the "recover every accessory" reward.
///
/// `AccessoryScatterSessionID` remains the sole round identity. Beginning a new
/// round replaces the old one, so delayed reclaim/finish callbacks from the old
/// controller session are ignored without creating a parallel token system.
struct AccessoryCollectionProgress {
    private struct Round {
        let sessionID: AccessoryScatterSessionID
        let mode: AccessoryCollectionRoundMode
        let expectedKinds: Set<AccessoryKind>
        var reclaimedKinds: Set<AccessoryKind> = []
    }

    private static let completeKindSet = Set(AccessoryKind.allCases)

    private var activeRound: Round?

    var activeSessionID: AccessoryScatterSessionID? {
        activeRound?.sessionID
    }

    var collectedCount: Int {
        activeRound?.reclaimedKinds.count ?? 0
    }

    /// Starts tracking the controller's current session. Any previous round is
    /// replaced immediately; its delayed callbacks subsequently return ignored.
    mutating func begin(
        sessionID: AccessoryScatterSessionID,
        mode: AccessoryCollectionRoundMode,
        expectedKinds: Set<AccessoryKind>
    ) {
        activeRound = Round(
            sessionID: sessionID,
            mode: mode,
            expectedKinds: expectedKinds
        )
    }

    /// Counts a reclaimed kind once, but never decides or emits the reward.
    /// The integration layer should call `finish(sessionID:)` only when the
    /// corresponding scatter controller session has actually ended.
    mutating func recordReclaimed(
        _ kind: AccessoryKind,
        sessionID: AccessoryScatterSessionID
    ) -> AccessoryCollectionReclaimResult {
        guard var round = activeRound,
              round.sessionID == sessionID,
              round.expectedKinds.contains(kind)
        else {
            return .ignored
        }

        let insertion = round.reclaimedKinds.insert(kind)
        activeRound = round

        guard insertion.inserted else {
            return .duplicate(collectedCount: round.reclaimedKinds.count)
        }
        return .recorded(
            collectedCount: round.reclaimedKinds.count,
            hasCollectedEveryExpectedKind: round.reclaimedKinds == round.expectedKinds
        )
    }

    /// Consumes the matching round and returns its one-shot reward decision.
    /// A round configured with fewer than all six kinds is never eligible for
    /// an "all recovered" reward, even if every available item was reclaimed.
    mutating func finish(
        sessionID: AccessoryScatterSessionID
    ) -> AccessoryCollectionFinishResult {
        guard let round = activeRound, round.sessionID == sessionID else {
            return .ignored
        }
        activeRound = nil

        guard round.mode == .real,
              round.expectedKinds == Self.completeKindSet,
              round.reclaimedKinds == Self.completeKindSet
        else {
            return .noReward
        }
        return .reward
    }

    /// Cancels only the matching active round. Stale cancellation callbacks do
    /// not disturb a newer session.
    @discardableResult
    mutating func cancel(sessionID: AccessoryScatterSessionID) -> Bool {
        guard activeRound?.sessionID == sessionID else { return false }
        activeRound = nil
        return true
    }
}
