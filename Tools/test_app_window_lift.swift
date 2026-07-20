import AppKit

@MainActor
private final class FakeAppWindowLiftSystemProvider: AppWindowLiftSystemProviding {
    var isAccessibilityTrusted = true
    var candidates: [AppWindowLiftCandidate] = []
    var moveShouldSucceed = true
    var moveResults: [Bool] = []
    private(set) var moves: [(CGWindowID, NSPoint)] = []
    private(set) var releasedWindowIDs: [CGWindowID] = []
    private(set) var releaseAllCount = 0

    func candidateWindows(
        excludingProcessID: pid_t,
        primaryScreenMaxY: CGFloat,
        screenFrames: [NSRect]
    ) -> [AppWindowLiftCandidate] {
        candidates
    }

    func moveWindow(
        windowID: CGWindowID,
        toAppKitOrigin origin: NSPoint,
        primaryScreenMaxY: CGFloat
    ) -> Bool {
        moves.append((windowID, origin))
        if !moveResults.isEmpty {
            return moveResults.removeFirst()
        }
        return moveShouldSucceed
    }

    func retainOnlyWindow(_ windowID: CGWindowID) {}

    func releaseWindow(_ windowID: CGWindowID) {
        releasedWindowIDs.append(windowID)
    }

    func releaseAllWindows() {
        releaseAllCount += 1
    }
}

@main
@MainActor
private enum AppWindowLiftTestMain {
    private static let ownPID: pid_t = 100
    private static let petFrame = NSRect(x: 300, y: 100, width: 120, height: 160)
    private static let visibleFrame = NSRect(x: 0, y: 0, width: 1_000, height: 800)

    static func main() {
        testCandidateSelection()
        testAmbiguousGeometryMatching()
        testBoundaryClamping()
        testPermissionAndDefaultOff()
        testLifecycleAndRelease()
        testCancellationRestoresOrigin()
        testMoveFailureRestoration()
        testPermissionLossRetainsRestoration()
        testInvalidGeometryRestoresOrigin()
        print("外部窗口托举几何、权限门禁与生命周期自检通过。")
    }

    private static func testCandidateSelection() {
        let touching = candidate(id: 1, frame: NSRect(x: 260, y: 266, width: 300, height: 300))
        let nearerFront = candidate(
            id: 2,
            frame: NSRect(x: 350, y: 260, width: 280, height: 300),
            zOrder: 0
        )
        let ownWindow = candidate(
            id: 3,
            ownerPID: ownPID,
            frame: NSRect(x: 300, y: 260, width: 200, height: 200)
        )
        let fullScreen = candidate(
            id: 4,
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 800),
            isFullScreen: true
        )
        let minimized = candidate(
            id: 5,
            frame: NSRect(x: 300, y: 260, width: 200, height: 200),
            isMinimized: true
        )
        let immovable = candidate(
            id: 6,
            frame: NSRect(x: 300, y: 260, width: 200, height: 200),
            isMovable: false
        )
        let nonNormal = candidate(
            id: 7,
            frame: NSRect(x: 300, y: 260, width: 200, height: 200),
            isNormalWindow: false
        )
        let invisible = candidate(
            id: 8,
            frame: NSRect(x: 300, y: 260, width: 200, height: 200),
            isVisible: false
        )
        let noHorizontalContact = candidate(
            id: 9,
            frame: NSRect(x: 600, y: 260, width: 200, height: 200)
        )

        let selected = AppWindowLiftGeometry.selectCandidate(
            petFrame: petFrame,
            candidates: [
                touching, nearerFront, ownWindow, fullScreen, minimized,
                immovable, nonNormal, invisible, noHorizontalContact,
            ],
            excludingProcessID: ownPID
        )
        precondition(selected?.candidate.windowID == nearerFront.windowID)
        precondition(selected?.verticalGap == 0)

        let equalBack = candidate(
            id: 10,
            frame: nearerFront.frame,
            zOrder: 5
        )
        let frontTie = AppWindowLiftGeometry.selectCandidate(
            petFrame: petFrame,
            candidates: [equalBack, nearerFront],
            excludingProcessID: ownPID
        )
        precondition(frontTie?.candidate.windowID == nearerFront.windowID)
    }

    private static func testBoundaryClamping() {
        let lowerLeft = AppWindowLiftGeometry.clampedOrigin(
            windowSize: NSSize(width: 300, height: 240),
            desiredOrigin: NSPoint(x: -80, y: -40),
            visibleFrames: [visibleFrame]
        )
        precondition(lowerLeft == NSPoint(x: 0, y: 0))

        let upperRight = AppWindowLiftGeometry.clampedOrigin(
            windowSize: NSSize(width: 300, height: 240),
            desiredOrigin: NSPoint(x: 900, y: 700),
            visibleFrames: [visibleFrame]
        )
        precondition(upperRight == NSPoint(x: 700, y: 560))

        let leftScreen = NSRect(x: -800, y: 0, width: 800, height: 700)
        let multiScreen = AppWindowLiftGeometry.clampedOrigin(
            windowSize: NSSize(width: 200, height: 200),
            desiredOrigin: NSPoint(x: -760, y: 600),
            visibleFrames: [visibleFrame, leftScreen]
        )
        precondition(multiScreen == NSPoint(x: -760, y: 500))
    }

    private static func testAmbiguousGeometryMatching() {
        let target = CGRect(x: 100, y: 80, width: 420, height: 300)
        precondition(
            AppWindowLiftGeometry.uniqueMatchingFrameIndex(
                targetFrame: target,
                candidateFrames: [target]
            ) == 0,
            "唯一精确 AX 几何候选应被接受"
        )

        let exactDuplicate = target
        precondition(
            AppWindowLiftGeometry.uniqueMatchingFrameIndex(
                targetFrame: target,
                candidateFrames: [target, exactDuplicate]
            ) == nil,
            "两个同位置窗口不得猜测绑定"
        )

        let nearDuplicate = target.offsetBy(dx: 2, dy: 1)
        precondition(
            AppWindowLiftGeometry.uniqueMatchingFrameIndex(
                targetFrame: target,
                candidateFrames: [target, nearDuplicate]
            ) == nil,
            "最佳与次佳距离接近时应保守拒绝"
        )

        let clearlyWorse = target.offsetBy(dx: 10, dy: 0)
        precondition(
            AppWindowLiftGeometry.uniqueMatchingFrameIndex(
                targetFrame: target,
                candidateFrames: [clearlyWorse, target]
            ) == 1,
            "第二候选明显更差时应保留唯一最佳匹配"
        )

        let outsideTolerance = target.offsetBy(dx: 20, dy: 0)
        precondition(
            AppWindowLiftGeometry.uniqueMatchingFrameIndex(
                targetFrame: target,
                candidateFrames: [outsideTolerance]
            ) == nil
        )
    }

    private static func testPermissionAndDefaultOff() {
        let provider = FakeAppWindowLiftSystemProvider()
        provider.candidates = [candidate(id: 20, frame: NSRect(x: 300, y: 260, width: 300, height: 300))]
        let controller = AppWindowLiftController(
            ownProcessID: ownPID,
            systemProvider: provider
        )
        precondition(
            controller.begin(
                petFrame: petFrame,
                visibleFrames: [visibleFrame],
                screenFrames: [visibleFrame]
            ) == .disabled
        )
        precondition(provider.moves.isEmpty)

        controller.isEnabled = true
        provider.isAccessibilityTrusted = false
        precondition(
            controller.begin(
                petFrame: petFrame,
                visibleFrames: [visibleFrame],
                screenFrames: [visibleFrame]
            ) == .accessibilityPermissionDenied
        )
        precondition(!controller.isLifting && provider.moves.isEmpty)
        precondition(provider.releaseAllCount == 1)
    }

    private static func testLifecycleAndRelease() {
        let provider = FakeAppWindowLiftSystemProvider()
        let lifted = candidate(
            id: 30,
            frame: NSRect(x: 250, y: 260, width: 400, height: 300)
        )
        provider.candidates = [lifted]
        let controller = AppWindowLiftController(
            ownProcessID: ownPID,
            systemProvider: provider
        )
        controller.isEnabled = true
        guard case .started = controller.begin(
            petFrame: petFrame,
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        ) else {
            preconditionFailure("接触窗口应开始托举")
        }
        precondition(controller.isLifting && controller.activeWindowID == lifted.windowID)

        let movedPet = petFrame.offsetBy(dx: 500, dy: 500)
        let update = controller.update(
            petFrame: movedPet,
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        precondition(update == .moved(windowID: lifted.windowID, origin: NSPoint(x: 600, y: 500)))
        precondition(provider.moves.last?.1 == NSPoint(x: 600, y: 500))

        precondition(
            controller.end() == .released(
                windowID: lifted.windowID,
                restoration: .notRequested
            )
        )
        precondition(!controller.isLifting)
        precondition(provider.releasedWindowIDs == [lifted.windowID])
        precondition(
            controller.update(
                petFrame: movedPet,
                visibleFrames: [visibleFrame],
                screenFrames: [visibleFrame]
            ) == .inactive
        )
    }

    private static func testCancellationRestoresOrigin() {
        let provider = FakeAppWindowLiftSystemProvider()
        let lifted = candidate(
            id: 40,
            frame: NSRect(x: 250, y: 260, width: 320, height: 300)
        )
        provider.candidates = [lifted]
        let controller = AppWindowLiftController(
            ownProcessID: ownPID,
            systemProvider: provider
        )
        controller.isEnabled = true
        _ = controller.begin(
            petFrame: petFrame,
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        _ = controller.update(
            petFrame: petFrame.offsetBy(dx: 100, dy: 80),
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        precondition(
            controller.cancel() == .released(
                windowID: lifted.windowID,
                restoration: .restored
            )
        )
        precondition(provider.moves.last?.1 == lifted.frame.origin)
        precondition(!controller.isLifting)
    }

    private static func testMoveFailureRestoration() {
        let provider = FakeAppWindowLiftSystemProvider()
        let lifted = candidate(
            id: 50,
            frame: NSRect(x: 250, y: 260, width: 320, height: 300)
        )
        provider.candidates = [lifted]
        let controller = AppWindowLiftController(
            ownProcessID: ownPID,
            systemProvider: provider
        )
        controller.isEnabled = true
        _ = controller.begin(
            petFrame: petFrame,
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        provider.moveResults = [false, true]

        let result = controller.update(
            petFrame: petFrame.offsetBy(dx: 40, dy: 40),
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        precondition(
            result == .moveFailedAndReleased(
                windowID: lifted.windowID,
                restoration: .restored
            )
        )
        precondition(!controller.isLifting && controller.activeWindowID == nil)
        precondition(provider.releasedWindowIDs == [lifted.windowID])
        precondition(provider.moves.last?.1 == lifted.frame.origin)
        precondition(controller.end() == .inactive)

        let pendingProvider = FakeAppWindowLiftSystemProvider()
        pendingProvider.candidates = [lifted]
        pendingProvider.moveResults = [false, false]
        let pendingController = AppWindowLiftController(
            ownProcessID: ownPID,
            systemProvider: pendingProvider
        )
        pendingController.isEnabled = true
        _ = pendingController.begin(
            petFrame: petFrame,
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        let pendingResult = pendingController.update(
            petFrame: petFrame.offsetBy(dx: 40, dy: 40),
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        precondition(
            pendingResult == .moveFailedAndReleased(
                windowID: lifted.windowID,
                restoration: .pending
            )
        )
        precondition(!pendingController.isLifting)
        precondition(pendingController.pendingRestorationWindowID == lifted.windowID)
        precondition(pendingProvider.releasedWindowIDs.isEmpty)

        pendingProvider.moveResults = [true]
        precondition(
            pendingController.retryPendingRestoration() == .released(
                windowID: lifted.windowID,
                restoration: .restored
            )
        )
        precondition(pendingController.pendingRestorationWindowID == nil)
        precondition(pendingProvider.releasedWindowIDs == [lifted.windowID])
    }

    private static func testPermissionLossRetainsRestoration() {
        let provider = FakeAppWindowLiftSystemProvider()
        let lifted = candidate(
            id: 60,
            frame: NSRect(x: 250, y: 260, width: 320, height: 300)
        )
        provider.candidates = [lifted]
        let controller = AppWindowLiftController(
            ownProcessID: ownPID,
            systemProvider: provider
        )
        controller.isEnabled = true
        _ = controller.begin(
            petFrame: petFrame,
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        _ = controller.update(
            petFrame: petFrame.offsetBy(dx: 30, dy: 30),
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        provider.isAccessibilityTrusted = false

        let result = controller.update(
            petFrame: petFrame.offsetBy(dx: 60, dy: 60),
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )
        precondition(
            result == .accessibilityPermissionLost(
                windowID: lifted.windowID,
                restoration: .pending
            )
        )
        precondition(!controller.isLifting)
        precondition(controller.pendingRestorationWindowID == lifted.windowID)
        precondition(provider.releasedWindowIDs.isEmpty)
        precondition(
            controller.end() == .restorationPending(windowID: lifted.windowID)
        )
        precondition(controller.pendingRestorationWindowID == lifted.windowID)
        precondition(provider.releasedWindowIDs.isEmpty)

        provider.isAccessibilityTrusted = true
        precondition(
            controller.retryPendingRestoration() == .released(
                windowID: lifted.windowID,
                restoration: .restored
            )
        )
        precondition(provider.moves.last?.1 == lifted.frame.origin)
        precondition(provider.releasedWindowIDs == [lifted.windowID])
    }

    private static func testInvalidGeometryRestoresOrigin() {
        let provider = FakeAppWindowLiftSystemProvider()
        let lifted = candidate(
            id: 70,
            frame: NSRect(x: 250, y: 260, width: 320, height: 300)
        )
        provider.candidates = [lifted]
        let controller = AppWindowLiftController(
            ownProcessID: ownPID,
            systemProvider: provider
        )
        controller.isEnabled = true
        _ = controller.begin(
            petFrame: petFrame,
            visibleFrames: [visibleFrame],
            screenFrames: [visibleFrame]
        )

        let result = controller.update(
            petFrame: petFrame.offsetBy(dx: 20, dy: 20),
            visibleFrames: [],
            screenFrames: [visibleFrame]
        )
        precondition(
            result == .invalidGeometryAndReleased(
                windowID: lifted.windowID,
                restoration: .restored
            )
        )
        precondition(provider.moves.count == 1)
        precondition(provider.moves.first?.0 == lifted.windowID)
        precondition(provider.moves.first?.1 == lifted.frame.origin)
        precondition(provider.releasedWindowIDs == [lifted.windowID])
    }

    private static func candidate(
        id: CGWindowID,
        ownerPID: pid_t = 200,
        frame: NSRect,
        zOrder: Int = 1,
        isVisible: Bool = true,
        isNormalWindow: Bool = true,
        isMinimized: Bool = false,
        isFullScreen: Bool = false,
        isMovable: Bool = true
    ) -> AppWindowLiftCandidate {
        AppWindowLiftCandidate(
            windowID: id,
            ownerProcessID: ownerPID,
            frame: frame,
            zOrder: zOrder,
            isVisible: isVisible,
            isNormalWindow: isNormalWindow,
            isMinimized: isMinimized,
            isFullScreen: isFullScreen,
            isMovable: isMovable
        )
    }
}
