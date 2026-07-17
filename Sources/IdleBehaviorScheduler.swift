import Foundation

/// Schedules deliberately infrequent opportunities for ambient idle behavior.
///
/// The owner remains the source of truth for whether the pet is truly idle. The
/// predicate and callback are evaluated on the main run loop. Capture the owner
/// weakly in both closures when the owner also retains this scheduler.
final class IdleBehaviorScheduler {
    typealias IdlePredicate = () -> Bool
    typealias IdleOpportunityHandler = () -> Void

    /// Called only when a scheduled opportunity arrives and `isTrulyIdle`
    /// reports that the pet is still completely idle.
    var onIdleOpportunity: IdleOpportunityHandler?

    private let isTrulyIdle: IdlePredicate
    private let profileProvider: () -> CompanionIdleProfile
    private var timer: Timer?
    private var isRunning = false

    init(
        profileProvider: @escaping () -> CompanionIdleProfile = {
            .profile(for: .balanced)
        },
        isTrulyIdle: @escaping IdlePredicate
    ) {
        self.profileProvider = profileProvider
        self.isTrulyIdle = isTrulyIdle
    }

    /// Starts scheduling. Repeated calls while already running are ignored.
    /// The first opportunity is no earlier than 75 seconds from this call.
    func start() {
        precondition(Thread.isMainThread, "IdleBehaviorScheduler must be used on the main thread")
        guard !isRunning else { return }

        isRunning = true
        refreshProfile()
    }

    /// Stops scheduling and invalidates any pending opportunity.
    func stop() {
        precondition(Thread.isMainThread, "IdleBehaviorScheduler must be used on the main thread")
        isRunning = false
        invalidateTimer()
    }

    /// Resets the cooldown after a click, drag, menu command, or other explicit
    /// user interaction. A fresh opportunity is chosen 120...240 seconds later.
    func noteUserInteraction() {
        precondition(Thread.isMainThread, "IdleBehaviorScheduler must be used on the main thread")
        guard isRunning else { return }

        let profile = profileProvider()
        guard profile.isSchedulingEnabled else {
            invalidateTimer()
            return
        }
        schedule(after: Self.randomDelay(in: profile.subsequentDelayRange))
    }

    /// Re-evaluates the current activity profile after a user-facing mode
    /// change or a temporary quiet period expires.
    func refreshProfile() {
        precondition(Thread.isMainThread, "IdleBehaviorScheduler must be used on the main thread")
        guard isRunning else { return }

        let profile = profileProvider()
        guard profile.isSchedulingEnabled else {
            invalidateTimer()
            return
        }
        schedule(after: profile.initialDelay)
    }

    deinit {
        timer?.invalidate()
    }

    private func schedule(after delay: TimeInterval) {
        invalidateTimer()

        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.handleTimerFired()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func handleTimerFired() {
        timer = nil
        guard isRunning else { return }

        let profile = profileProvider()
        guard profile.isSchedulingEnabled else { return }

        if isTrulyIdle(), Double.random(in: 0...1) < profile.opportunityProbability {
            onIdleOpportunity?()
        }

        // The callback may stop the scheduler or reset the cooldown itself.
        guard isRunning, timer == nil else { return }
        let nextProfile = profileProvider()
        guard nextProfile.isSchedulingEnabled else { return }
        schedule(after: Self.randomDelay(in: nextProfile.subsequentDelayRange))
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private static func randomDelay(
        in range: ClosedRange<TimeInterval>
    ) -> TimeInterval {
        TimeInterval.random(in: range)
    }
}
