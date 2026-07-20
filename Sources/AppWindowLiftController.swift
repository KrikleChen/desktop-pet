import AppKit
import ApplicationServices

/// Read-only metadata used by the pure lift geometry. No window title, contents,
/// keyboard state, or accessibility text is ever requested.
struct AppWindowLiftCandidate: Equatable {
    let windowID: CGWindowID
    let ownerProcessID: pid_t
    let frame: NSRect
    let zOrder: Int
    let isVisible: Bool
    let isNormalWindow: Bool
    let isMinimized: Bool
    let isFullScreen: Bool
    let isMovable: Bool
}

struct AppWindowLiftSelection: Equatable {
    let candidate: AppWindowLiftCandidate
    let horizontalOverlap: CGFloat
    let verticalGap: CGFloat
}

/// Geometry-only policy for finding a normal window resting immediately above
/// the pet and for keeping a lifted window inside a visible screen boundary.
enum AppWindowLiftGeometry {
    struct Configuration {
        var maximumGapAbovePet: CGFloat = 14
        var maximumPetOverlap: CGFloat = 8
        var minimumHorizontalOverlap: CGFloat = 12

        init(
            maximumGapAbovePet: CGFloat = 14,
            maximumPetOverlap: CGFloat = 8,
            minimumHorizontalOverlap: CGFloat = 12
        ) {
            self.maximumGapAbovePet = max(0, maximumGapAbovePet)
            self.maximumPetOverlap = max(0, maximumPetOverlap)
            self.minimumHorizontalOverlap = max(0, minimumHorizontalOverlap)
        }
    }

    static func selectCandidate(
        petFrame: NSRect,
        candidates: [AppWindowLiftCandidate],
        excludingProcessID: pid_t,
        configuration: Configuration = Configuration()
    ) -> AppWindowLiftSelection? {
        guard isUsable(petFrame) else { return nil }

        let eligible = candidates.compactMap { candidate -> AppWindowLiftSelection? in
            guard candidate.ownerProcessID != excludingProcessID,
                  candidate.windowID != 0,
                  candidate.isVisible,
                  candidate.isNormalWindow,
                  !candidate.isMinimized,
                  !candidate.isFullScreen,
                  candidate.isMovable,
                  isUsable(candidate.frame) else {
                return nil
            }

            let overlap = horizontalOverlap(petFrame, candidate.frame)
            guard overlap >= configuration.minimumHorizontalOverlap else { return nil }

            // AppKit desktop coordinates use a bottom-left origin. A window being
            // carried has its bottom edge close to the pet's top edge.
            let gap = candidate.frame.minY - petFrame.maxY
            guard gap >= -configuration.maximumPetOverlap,
                  gap <= configuration.maximumGapAbovePet else {
                return nil
            }
            return AppWindowLiftSelection(
                candidate: candidate,
                horizontalOverlap: overlap,
                verticalGap: gap
            )
        }

        return eligible.min { lhs, rhs in
            let lhsDistance = abs(lhs.verticalGap)
            let rhsDistance = abs(rhs.verticalGap)
            if abs(lhsDistance - rhsDistance) > 0.001 {
                return lhsDistance < rhsDistance
            }
            if abs(lhs.horizontalOverlap - rhs.horizontalOverlap) > 0.001 {
                return lhs.horizontalOverlap > rhs.horizontalOverlap
            }
            if lhs.candidate.zOrder != rhs.candidate.zOrder {
                return lhs.candidate.zOrder < rhs.candidate.zOrder
            }
            return lhs.candidate.windowID < rhs.candidate.windowID
        }
    }

    /// Returns an origin that keeps the window inside the most relevant visible
    /// screen. Oversized windows are pinned to that screen's minimum edge.
    static func clampedOrigin(
        windowSize: NSSize,
        desiredOrigin: NSPoint,
        visibleFrames: [NSRect]
    ) -> NSPoint? {
        guard isUsable(windowSize), isFinite(desiredOrigin) else { return nil }
        let usableFrames = visibleFrames.filter(isUsable)
        guard !usableFrames.isEmpty else { return nil }

        let desiredFrame = NSRect(origin: desiredOrigin, size: windowSize)
        let targetFrame = usableFrames.enumerated().max { lhs, rhs in
            let lhsArea = intersectionArea(desiredFrame, lhs.element)
            let rhsArea = intersectionArea(desiredFrame, rhs.element)
            if abs(lhsArea - rhsArea) > 0.001 {
                return lhsArea < rhsArea
            }

            let lhsDistance = squaredDistance(desiredFrame.center, lhs.element.center)
            let rhsDistance = squaredDistance(desiredFrame.center, rhs.element.center)
            if abs(lhsDistance - rhsDistance) > 0.001 {
                return lhsDistance > rhsDistance
            }
            return lhs.offset > rhs.offset
        }?.element

        guard let targetFrame else { return nil }
        let maximumX = max(targetFrame.minX, targetFrame.maxX - windowSize.width)
        let maximumY = max(targetFrame.minY, targetFrame.maxY - windowSize.height)
        return NSPoint(
            x: min(max(desiredOrigin.x, targetFrame.minX), maximumX),
            y: min(max(desiredOrigin.y, targetFrame.minY), maximumY)
        )
    }

    /// Returns a geometry match only when one candidate wins by a meaningful
    /// margin. AX does not expose the public CGWindowID, so two overlapping AX
    /// windows with nearly identical frames must be treated as ambiguous instead
    /// of guessing and potentially moving the wrong window.
    static func uniqueMatchingFrameIndex(
        targetFrame: CGRect,
        candidateFrames: [CGRect],
        maximumDistance: CGFloat = 16,
        minimumWinningMargin: CGFloat = 4
    ) -> Int? {
        guard isUsable(targetFrame),
              maximumDistance.isFinite,
              minimumWinningMargin.isFinite,
              maximumDistance >= 0,
              minimumWinningMargin >= 0 else {
            return nil
        }

        let ranked = candidateFrames.enumerated().compactMap { index, frame
            -> (index: Int, distance: CGFloat)? in
            guard isUsable(frame) else { return nil }
            let distance = frameDistance(frame, targetFrame)
            guard distance <= maximumDistance else { return nil }
            return (index, distance)
        }.sorted { lhs, rhs in
            if abs(lhs.distance - rhs.distance) > 0.001 {
                return lhs.distance < rhs.distance
            }
            return lhs.index < rhs.index
        }

        guard let best = ranked.first else { return nil }
        if ranked.count > 1,
           ranked[1].distance - best.distance <= minimumWinningMargin {
            return nil
        }
        return best.index
    }

    private static func horizontalOverlap(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func squaredDistance(_ lhs: NSPoint, _ rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        abs(lhs.minX - rhs.minX)
            + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width)
            + abs(lhs.height - rhs.height)
    }

    private static func isUsable(_ rect: NSRect) -> Bool {
        isFinite(rect.origin) && isUsable(rect.size) && !rect.isNull && !rect.isEmpty
    }

    private static func isUsable(_ size: NSSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func isFinite(_ point: NSPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}

@MainActor
protocol AppWindowLiftSystemProviding: AnyObject {
    var isAccessibilityTrusted: Bool { get }

    func candidateWindows(
        excludingProcessID: pid_t,
        primaryScreenMaxY: CGFloat,
        screenFrames: [NSRect]
    ) -> [AppWindowLiftCandidate]

    func moveWindow(
        windowID: CGWindowID,
        toAppKitOrigin origin: NSPoint,
        primaryScreenMaxY: CGFloat
    ) -> Bool

    func retainOnlyWindow(_ windowID: CGWindowID)
    func releaseWindow(_ windowID: CGWindowID)
    func releaseAllWindows()
}

enum AppWindowLiftBeginResult: Equatable {
    case disabled
    case alreadyActive(AppWindowLiftSelection)
    case accessibilityPermissionDenied
    case invalidDesktopGeometry
    case noCandidate
    case started(AppWindowLiftSelection)
}

enum AppWindowLiftUpdateResult: Equatable {
    case inactive
    case unchanged
    case moved(windowID: CGWindowID, origin: NSPoint)
    /// Every failure below ends the active lift. `restoration` states whether
    /// the original position was restored or retained for a later retry.
    case accessibilityPermissionLost(
        windowID: CGWindowID,
        restoration: AppWindowLiftRestorationResult
    )
    case invalidGeometryAndReleased(
        windowID: CGWindowID,
        restoration: AppWindowLiftRestorationResult
    )
    case moveFailedAndReleased(
        windowID: CGWindowID,
        restoration: AppWindowLiftRestorationResult
    )
}

enum AppWindowLiftRestorationResult: Equatable {
    case notRequested
    case restored
    /// The active lift has ended, but the controller intentionally retains the
    /// AX element and original position so restoration can be retried later.
    case pending
    case failed
}

enum AppWindowLiftEndResult: Equatable {
    case inactive
    case released(windowID: CGWindowID, restoration: AppWindowLiftRestorationResult)
    case restorationPending(windowID: CGWindowID)
}

/// Opt-in coordinator for lifting another application's ordinary window.
///
/// The controller is disabled by default and never prompts for Accessibility.
/// It only moves a selected external AX window after the caller explicitly
/// enables the feature and macOS already reports Accessibility as trusted.
@MainActor
final class AppWindowLiftController {
    private struct Session {
        let selection: AppWindowLiftSelection
        let initialPetFrame: NSRect
        let initialWindowOrigin: NSPoint
        let primaryScreenMaxY: CGFloat
        var lastAppliedOrigin: NSPoint
    }

    var isEnabled = false {
        didSet {
            if !isEnabled, oldValue != isEnabled {
                _ = end(restoreOriginalPosition: true)
            }
        }
    }

    private let ownProcessID: pid_t
    private let configuration: AppWindowLiftGeometry.Configuration
    private let systemProvider: AppWindowLiftSystemProviding
    private var session: Session?
    private var pendingRestoration: Session?

    var isLifting: Bool { session != nil }
    var activeWindowID: CGWindowID? { session?.selection.candidate.windowID }
    var pendingRestorationWindowID: CGWindowID? {
        pendingRestoration?.selection.candidate.windowID
    }

    init(
        ownProcessID: pid_t = ProcessInfo.processInfo.processIdentifier,
        configuration: AppWindowLiftGeometry.Configuration = .init(),
        systemProvider: AppWindowLiftSystemProviding? = nil
    ) {
        self.ownProcessID = ownProcessID
        self.configuration = configuration
        self.systemProvider = systemProvider ?? MacOSAppWindowLiftSystemProvider()
    }

    @discardableResult
    func begin(
        petFrame: NSRect,
        visibleFrames: [NSRect] = NSScreen.screens.map(\.visibleFrame),
        screenFrames: [NSRect] = NSScreen.screens.map(\.frame)
    ) -> AppWindowLiftBeginResult {
        guard isEnabled else { return .disabled }
        if pendingRestoration != nil {
            _ = retryPendingRestoration()
            guard pendingRestoration == nil else { return .noCandidate }
        }
        if let session {
            return .alreadyActive(session.selection)
        }
        guard systemProvider.isAccessibilityTrusted else {
            systemProvider.releaseAllWindows()
            return .accessibilityPermissionDenied
        }
        guard let primaryScreenMaxY = screenFrames.first?.maxY,
              primaryScreenMaxY.isFinite,
              !visibleFrames.isEmpty else {
            systemProvider.releaseAllWindows()
            return .invalidDesktopGeometry
        }

        let candidates = systemProvider.candidateWindows(
            excludingProcessID: ownProcessID,
            primaryScreenMaxY: primaryScreenMaxY,
            screenFrames: screenFrames
        )
        guard let selection = AppWindowLiftGeometry.selectCandidate(
            petFrame: petFrame,
            candidates: candidates,
            excludingProcessID: ownProcessID,
            configuration: configuration
        ) else {
            systemProvider.releaseAllWindows()
            return .noCandidate
        }

        systemProvider.retainOnlyWindow(selection.candidate.windowID)
        session = Session(
            selection: selection,
            initialPetFrame: petFrame,
            initialWindowOrigin: selection.candidate.frame.origin,
            primaryScreenMaxY: primaryScreenMaxY,
            lastAppliedOrigin: selection.candidate.frame.origin
        )
        return .started(selection)
    }

    @discardableResult
    func update(
        petFrame: NSRect,
        visibleFrames: [NSRect] = NSScreen.screens.map(\.visibleFrame),
        screenFrames: [NSRect] = NSScreen.screens.map(\.frame)
    ) -> AppWindowLiftUpdateResult {
        guard var session else { return .inactive }
        let windowID = session.selection.candidate.windowID
        guard isEnabled else {
            _ = finishFailedUpdate(session, attemptRestoration: true)
            return .inactive
        }
        guard systemProvider.isAccessibilityTrusted else {
            let restoration = finishFailedUpdate(session, attemptRestoration: false)
            return .accessibilityPermissionLost(
                windowID: windowID,
                restoration: restoration
            )
        }
        guard let primaryScreenMaxY = screenFrames.first?.maxY,
              primaryScreenMaxY.isFinite,
              petFrame.origin.x.isFinite,
              petFrame.origin.y.isFinite else {
            let restoration = finishFailedUpdate(session, attemptRestoration: true)
            return .invalidGeometryAndReleased(
                windowID: windowID,
                restoration: restoration
            )
        }

        let desiredOrigin = NSPoint(
            x: session.initialWindowOrigin.x + petFrame.midX - session.initialPetFrame.midX,
            y: session.initialWindowOrigin.y + petFrame.maxY - session.initialPetFrame.maxY
        )
        guard let origin = AppWindowLiftGeometry.clampedOrigin(
            windowSize: session.selection.candidate.frame.size,
            desiredOrigin: desiredOrigin,
            visibleFrames: visibleFrames
        ) else {
            let restoration = finishFailedUpdate(session, attemptRestoration: true)
            return .invalidGeometryAndReleased(
                windowID: windowID,
                restoration: restoration
            )
        }

        guard hypot(
            origin.x - session.lastAppliedOrigin.x,
            origin.y - session.lastAppliedOrigin.y
        ) >= 0.25 else {
            return .unchanged
        }
        guard systemProvider.moveWindow(
            windowID: windowID,
            toAppKitOrigin: origin,
            primaryScreenMaxY: primaryScreenMaxY
        ) else {
            let restoration = finishFailedUpdate(session, attemptRestoration: true)
            return .moveFailedAndReleased(
                windowID: windowID,
                restoration: restoration
            )
        }

        session.lastAppliedOrigin = origin
        self.session = session
        return .moved(windowID: windowID, origin: origin)
    }

    /// Normal release keeps the window where the pet carried it. Cancellation or
    /// disabling can request restoration to the pre-lift position.
    @discardableResult
    func end(restoreOriginalPosition: Bool = false) -> AppWindowLiftEndResult {
        guard let session else {
            return restoreOriginalPosition ? retryPendingRestoration() : pendingEndResult()
        }
        let windowID = session.selection.candidate.windowID

        let restoration: AppWindowLiftRestorationResult
        if restoreOriginalPosition {
            restoration = finishFailedUpdate(session, attemptRestoration: true)
            if restoration == .pending {
                return .restorationPending(windowID: windowID)
            }
        } else {
            self.session = nil
            pendingRestoration = nil
            systemProvider.releaseWindow(windowID)
            restoration = .notRequested
        }
        return .released(windowID: windowID, restoration: restoration)
    }

    @discardableResult
    func cancel() -> AppWindowLiftEndResult {
        if session != nil {
            return end(restoreOriginalPosition: true)
        }
        return retryPendingRestoration()
    }

    /// Retries a previously failed rollback without starting a new lift.
    @discardableResult
    func retryPendingRestoration() -> AppWindowLiftEndResult {
        guard let pendingRestoration else { return .inactive }
        let windowID = pendingRestoration.selection.candidate.windowID
        guard systemProvider.isAccessibilityTrusted,
              restoreOriginalPosition(for: pendingRestoration) else {
            return .restorationPending(windowID: windowID)
        }

        self.pendingRestoration = nil
        systemProvider.releaseWindow(windowID)
        return .released(windowID: windowID, restoration: .restored)
    }

    private func finishFailedUpdate(
        _ failedSession: Session,
        attemptRestoration: Bool
    ) -> AppWindowLiftRestorationResult {
        let windowID = failedSession.selection.candidate.windowID
        session = nil
        if attemptRestoration,
           systemProvider.isAccessibilityTrusted,
           restoreOriginalPosition(for: failedSession) {
            pendingRestoration = nil
            systemProvider.releaseWindow(windowID)
            return .restored
        }

        pendingRestoration = failedSession
        return .pending
    }

    private func restoreOriginalPosition(for session: Session) -> Bool {
        systemProvider.moveWindow(
            windowID: session.selection.candidate.windowID,
            toAppKitOrigin: session.initialWindowOrigin,
            primaryScreenMaxY: session.primaryScreenMaxY
        )
    }

    private func pendingEndResult() -> AppWindowLiftEndResult {
        guard let windowID = pendingRestorationWindowID else { return .inactive }
        return .restorationPending(windowID: windowID)
    }
}

/// Conservative AX implementation. It enumerates only on-screen layer-zero Core
/// Graphics windows, matches them to standard AX windows by geometry, and retains
/// only the selected AX element for the duration of one lift.
@MainActor
private final class MacOSAppWindowLiftSystemProvider: AppWindowLiftSystemProviding {
    /// Common AX window state exposed by normal macOS applications. The public
    /// SDK has no typed constant for this attribute, so keep the spelling local.
    private let fullScreenAttribute = "AXFullScreen"

    private struct ManagedWindow {
        let ownerProcessID: pid_t
        let element: AXUIElement
        let size: NSSize
    }

    private var managedWindows: [CGWindowID: ManagedWindow] = [:]

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func candidateWindows(
        excludingProcessID: pid_t,
        primaryScreenMaxY: CGFloat,
        screenFrames: [NSRect]
    ) -> [AppWindowLiftCandidate] {
        managedWindows.removeAll(keepingCapacity: true)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return []
        }

        var usedElements: Set<CFHashCode> = []
        var result: [AppWindowLiftCandidate] = []
        for (zOrder, info) in windowInfo.enumerated() {
            guard number(info[kCGWindowLayer as String])?.intValue == 0,
                  number(info[kCGWindowIsOnscreen as String])?.boolValue != false,
                  (number(info[kCGWindowAlpha as String])?.doubleValue ?? 1) > 0.01,
                  let ownerNumber = number(info[kCGWindowOwnerPID as String]),
                  ownerNumber.int32Value > 0 else {
                continue
            }
            let ownerPID = pid_t(ownerNumber.int32Value)
            guard ownerPID != excludingProcessID,
                  let windowNumber = number(info[kCGWindowNumber as String]),
                  windowNumber.uint32Value != 0,
                  let quartzFrame = windowBounds(info[kCGWindowBounds as String]),
                  quartzFrame.width > 1,
                  quartzFrame.height > 1 else {
                continue
            }

            let windowID = CGWindowID(windowNumber.uint32Value)
            let appKitFrame = appKitFrame(
                fromQuartzFrame: quartzFrame,
                primaryScreenMaxY: primaryScreenMaxY
            )
            let application = AXUIElementCreateApplication(ownerPID)
            guard let match = matchingStandardWindow(
                in: application,
                quartzFrame: quartzFrame,
                usedElements: &usedElements
            ) else {
                continue
            }

            let isFullScreen = match.isFullScreen
                || screenFrames.contains(where: { approximatelyCovers(appKitFrame, $0) })
            let candidate = AppWindowLiftCandidate(
                windowID: windowID,
                ownerProcessID: ownerPID,
                frame: appKitFrame,
                zOrder: zOrder,
                isVisible: true,
                isNormalWindow: true,
                isMinimized: match.isMinimized,
                isFullScreen: isFullScreen,
                isMovable: match.isMovable
            )
            result.append(candidate)
            guard !match.isMinimized, !isFullScreen, match.isMovable else { continue }
            managedWindows[windowID] = ManagedWindow(
                ownerProcessID: ownerPID,
                element: match.element,
                size: match.size
            )
        }
        return result
    }

    func moveWindow(
        windowID: CGWindowID,
        toAppKitOrigin origin: NSPoint,
        primaryScreenMaxY: CGFloat
    ) -> Bool {
        guard let managed = managedWindows[windowID],
              isAccessibilityTrusted,
              origin.x.isFinite,
              origin.y.isFinite,
              copyString(kAXRoleAttribute, from: managed.element) == kAXWindowRole,
              copyString(kAXSubroleAttribute, from: managed.element) == kAXStandardWindowSubrole,
              copyBool(kAXMinimizedAttribute, from: managed.element) != true,
              copyBool(fullScreenAttribute, from: managed.element) != true,
              isSettable(kAXPositionAttribute, on: managed.element) else {
            return false
        }

        var processID: pid_t = 0
        guard AXUIElementGetPid(managed.element, &processID) == .success,
              processID == managed.ownerProcessID else {
            return false
        }

        var quartzOrigin = CGPoint(
            x: origin.x,
            y: primaryScreenMaxY - origin.y - managed.size.height
        )
        guard let value = AXValueCreate(.cgPoint, &quartzOrigin) else { return false }
        return AXUIElementSetAttributeValue(
            managed.element,
            kAXPositionAttribute as CFString,
            value
        ) == .success
    }

    func retainOnlyWindow(_ windowID: CGWindowID) {
        managedWindows = managedWindows.filter { $0.key == windowID }
    }

    func releaseWindow(_ windowID: CGWindowID) {
        managedWindows.removeValue(forKey: windowID)
    }

    func releaseAllWindows() {
        managedWindows.removeAll(keepingCapacity: false)
    }

    private struct AXWindowMatch {
        let element: AXUIElement
        let size: NSSize
        let isMinimized: Bool
        let isFullScreen: Bool
        let isMovable: Bool
    }

    private func matchingStandardWindow(
        in application: AXUIElement,
        quartzFrame: CGRect,
        usedElements: inout Set<CFHashCode>
    ) -> AXWindowMatch? {
        guard let windows = copiedAttribute(kAXWindowsAttribute, from: application)
                as? [AXUIElement] else {
            return nil
        }

        let matches = windows.compactMap { element -> (CGRect, AXWindowMatch)? in
            let elementHash = CFHash(element)
            guard !usedElements.contains(elementHash),
                  copyString(kAXRoleAttribute, from: element) == kAXWindowRole,
                  copyString(kAXSubroleAttribute, from: element) == kAXStandardWindowSubrole,
                  let position = copyPoint(kAXPositionAttribute, from: element),
                  let size = copySize(kAXSizeAttribute, from: element) else {
                return nil
            }
            let frame = CGRect(origin: position, size: size)
            return (
                frame,
                AXWindowMatch(
                    element: element,
                    size: size,
                    isMinimized: copyBool(kAXMinimizedAttribute, from: element) == true,
                    isFullScreen: copyBool(fullScreenAttribute, from: element) == true,
                    isMovable: isSettable(kAXPositionAttribute, on: element)
                )
            )
        }
        guard let matchIndex = AppWindowLiftGeometry.uniqueMatchingFrameIndex(
            targetFrame: quartzFrame,
            candidateFrames: matches.map(\.0)
        ) else {
            return nil
        }
        let best = matches[matchIndex].1
        usedElements.insert(CFHash(best.element))
        return best
    }

    private func copiedAttribute(_ attribute: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return value
    }

    private func copyString(_ attribute: String, from element: AXUIElement) -> String? {
        copiedAttribute(attribute, from: element) as? String
    }

    private func copyBool(_ attribute: String, from element: AXUIElement) -> Bool? {
        (copiedAttribute(attribute, from: element) as? NSNumber)?.boolValue
    }

    private func copyPoint(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        guard let rawValue = copiedAttribute(attribute, from: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func copySize(_ attribute: String, from element: AXUIElement) -> CGSize? {
        guard let rawValue = copiedAttribute(attribute, from: element),
              CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = unsafeBitCast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    private func number(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private func windowBounds(_ value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }

    private func appKitFrame(
        fromQuartzFrame frame: CGRect,
        primaryScreenMaxY: CGFloat
    ) -> NSRect {
        NSRect(
            x: frame.minX,
            y: primaryScreenMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func approximatelyCovers(_ window: NSRect, _ screen: NSRect) -> Bool {
        abs(window.minX - screen.minX) <= 2
            && abs(window.minY - screen.minY) <= 2
            && abs(window.width - screen.width) <= 4
            && abs(window.height - screen.height) <= 4
    }
}
