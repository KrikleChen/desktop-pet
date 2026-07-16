import AppKit
import Foundation

/// Decides when a pet that remains near a usable screen edge may sit down.
///
/// The type owns only deterministic timing state. It does not schedule timers or
/// inspect `PetView`/`PetAction`; the caller supplies eligibility and a monotonic
/// timestamp (for example, `ProcessInfo.processInfo.systemUptime`).
struct EdgeIdleBehavior {
    enum Edge: String, Equatable {
        case left
        case right
        case bottom
    }

    struct Configuration {
        /// Maximum distance, in screen points, between matching window/screen edges.
        var edgeTolerance: CGFloat = 24

        /// Continuous time at the same edge before an opportunity can be emitted.
        var stableDuration: TimeInterval = 8

        /// The pet must have been idle for at least this long.
        var minimumIdleDuration: TimeInterval = 60

        /// Minimum interval between two emitted opportunities, including after
        /// leaving one edge and moving to another.
        var cooldownDuration: TimeInterval = 180

        init(
            edgeTolerance: CGFloat = 24,
            stableDuration: TimeInterval = 8,
            minimumIdleDuration: TimeInterval = 60,
            cooldownDuration: TimeInterval = 180
        ) {
            precondition(edgeTolerance >= 0 && edgeTolerance.isFinite)
            precondition(stableDuration >= 0 && stableDuration.isFinite)
            precondition(minimumIdleDuration >= 0 && minimumIdleDuration.isFinite)
            precondition(cooldownDuration >= 0 && cooldownDuration.isFinite)

            self.edgeTolerance = edgeTolerance
            self.stableDuration = stableDuration
            self.minimumIdleDuration = minimumIdleDuration
            self.cooldownDuration = cooldownDuration
        }
    }

    private struct Candidate {
        var edge: Edge
        var startedAt: TimeInterval
    }

    private let configuration: Configuration
    private var candidate: Candidate?
    private var lastTriggerTime: TimeInterval?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Evaluates one caller-driven sample and returns an edge only when a new
    /// low-frequency sitting opportunity is due.
    ///
    /// Pass `eligibility: false` while dragging, while another action is active,
    /// or whenever the owner is otherwise unable to begin the sitting action.
    /// Doing so breaks the current stable-edge candidate.
    mutating func evaluate(
        windowFrame: NSRect,
        screenVisibleFrame: NSRect,
        idleDuration: TimeInterval,
        now: TimeInterval,
        eligibility: Bool
    ) -> Edge? {
        guard eligibility,
              idleDuration >= 0,
              idleDuration.isFinite,
              now.isFinite,
              let edge = Self.nearEdge(
                  windowFrame: windowFrame,
                  screenVisibleFrame: screenVisibleFrame,
                  tolerance: configuration.edgeTolerance
              )
        else {
            resetCandidate()
            return nil
        }

        // Clamp candidate time to the current idle session. This prevents an
        // interaction between samples from reusing stability accumulated before it.
        let idleSessionStartedAt = now - idleDuration
        if var current = candidate, current.edge == edge, now >= current.startedAt {
            current.startedAt = max(current.startedAt, idleSessionStartedAt)
            candidate = current
        } else {
            candidate = Candidate(
                edge: edge,
                startedAt: max(now, idleSessionStartedAt)
            )
        }

        guard idleDuration >= configuration.minimumIdleDuration,
              let candidate,
              now - candidate.startedAt >= configuration.stableDuration
        else {
            return nil
        }

        if let lastTriggerTime,
           now - lastTriggerTime < configuration.cooldownDuration {
            return nil
        }

        self.lastTriggerTime = now
        // Require fresh stable residence as well as cooldown before any repeat.
        self.candidate = Candidate(edge: edge, startedAt: now)
        return edge
    }

    /// Clears edge residence without bypassing the global trigger cooldown.
    mutating func resetCandidate() {
        candidate = nil
    }

    /// Pure geometric classification used by `evaluate`.
    ///
    /// The top edge is intentionally absent. At corners, the physically nearest
    /// supported edge wins; exact ties prefer the bottom edge, then left, then right.
    static func nearEdge(
        windowFrame: NSRect,
        screenVisibleFrame: NSRect,
        tolerance: CGFloat
    ) -> Edge? {
        guard tolerance >= 0,
              tolerance.isFinite,
              Self.isUsable(windowFrame),
              Self.isUsable(screenVisibleFrame)
        else {
            return nil
        }

        let distances: [(edge: Edge, distance: CGFloat)] = [
            (.bottom, abs(windowFrame.minY - screenVisibleFrame.minY)),
            (.left, abs(windowFrame.minX - screenVisibleFrame.minX)),
            (.right, abs(windowFrame.maxX - screenVisibleFrame.maxX)),
        ]

        var nearest: (edge: Edge, distance: CGFloat)?
        for item in distances where item.distance <= tolerance {
            if nearest == nil || item.distance < nearest!.distance {
                nearest = item
            }
        }
        return nearest?.edge
    }

    private static func isUsable(_ rect: NSRect) -> Bool {
        !rect.isNull
            && !rect.isEmpty
            && rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
    }
}
