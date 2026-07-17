import AppKit
import QuartzCore

/// 不依赖 AppKit 的预览所有权策略，供隐藏预览生命周期和无 UI 自检共用。
struct AccessoryPreviewLifecycleState {
    private(set) var activePreviewID: UInt64?
    private var nextPreviewID: UInt64 = 0

    mutating func begin() -> UInt64 {
        nextPreviewID &+= 1
        if nextPreviewID == 0 {
            nextPreviewID = 1
        }
        activePreviewID = nextPreviewID
        return nextPreviewID
    }

    func isCurrent(_ previewID: UInt64) -> Bool {
        activePreviewID == previewID
    }

    @discardableResult
    mutating func cancel(_ previewID: UInt64) -> Bool {
        guard activePreviewID == previewID else { return false }
        activePreviewID = nil
        return true
    }

    /// 只有预览请求和控制器 session 都匹配时才消费完成事件。
    /// 返回值仅表示调用方此时可以安全恢复 ordinary/idle。
    mutating func finish(
        previewID: UInt64,
        belongsToControllerSession: Bool,
        isPreviewDragging: Bool
    ) -> Bool {
        consumeIfOwned(
            previewID: previewID,
            belongsToControllerSession: belongsToControllerSession,
            isPreviewDragging: isPreviewDragging
        )
    }

    /// 明确交互取消预览时使用同一所有权门闩；只有尚未被用户动作替换的
    /// 预览拖拽姿态才允许调用方恢复 ordinary/idle。
    mutating func cancelAndShouldRestore(
        previewID: UInt64,
        belongsToControllerSession: Bool,
        isPreviewDragging: Bool
    ) -> Bool {
        consumeIfOwned(
            previewID: previewID,
            belongsToControllerSession: belongsToControllerSession,
            isPreviewDragging: isPreviewDragging
        )
    }

    private mutating func consumeIfOwned(
        previewID: UInt64,
        belongsToControllerSession: Bool,
        isPreviewDragging: Bool
    ) -> Bool {
        guard
            activePreviewID == previewID,
            belongsToControllerSession
        else { return false }
        activePreviewID = nil
        return isPreviewDragging
    }
}

private enum AccessoryCompletionReward: Equatable {
    case standard
    case ordered

    var message: String {
        switch self {
        case .standard:
            return "六件证物全部归档。这就是完整的证据链！"
        case .ordered:
            return "顺序也完全吻合。现在，证据链没有缺口了！"
        }
    }
}

final class PetView: NSView {
    private let imageView = NSImageView()
    private let bubbleView = SpeechBubbleView()
    private let courtRecordUnlockToastView = CourtRecordUnlockToastView(frame: .zero)
    private let objectionBurstView = ObjectionBurstView(frame: .zero)
    private let dialogueController = DialoguePresentationController()
    private let edgeMotionEffectView = EdgeMotionEffectView(frame: .zero)
    private let followUpHotspotView = FollowUpHotspotView(frame: .zero)
    private let followUpChoiceView = FollowUpChoiceView(frame: .zero)
    private let crossExaminationView = CrossExaminationView(frame: .zero)
    private let orderedEvidenceArchiveHUDView = OrderedEvidenceArchiveHUDView(frame: .zero)
    private let images: [PetAction: NSImage]
    private let chatNameListener = ChatNameListener()
    private let courtRecordStore = CourtRecordStore.shared
    private let companionActivityPolicy = CompanionActivityPolicy()
    private let dragVelocityTracker = DragVelocityTracker()
    private let shakeGestureDetector = ShakeGestureDetector()
    private let accessoryScatterController = AccessoryScatterController()
    private var interactionMemory = InteractionMemory()
    private var interactiveActionBag = PetActionBag<PetAction>()
    private var idleActionBag = PetActionBag<PetAction>()
    private var accessoryCollectionProgress = AccessoryCollectionProgress()
    private var orderedEvidenceArchive = OrderedEvidenceArchive()
    private var orderedEvidenceOrderGenerator = OrderedEvidenceArchiveOrderGenerator()
    private var crossExaminationQuestionBag = CrossExaminationQuestionBag()
    private var crossExaminationRound = CrossExaminationRound()
    private var courtRecordUnlockQueue = CourtRecordUnlockAnnouncementQueue()
    private var edgeIdleBehavior = EdgeIdleBehavior(configuration: .init(
        stableDuration: 0,
        minimumIdleDuration: 60,
        cooldownDuration: 180
    ))

    private var currentAction: PetAction = .idle
    private var interactionMode: PetInteractionMode = .ordinary
    private var resetWorkItem: DispatchWorkItem?
    private var bubbleWorkItem: DispatchWorkItem?
    private var clickWorkItem: DispatchWorkItem?
    private var dragResignWorkItem: DispatchWorkItem?
    private var environmentWorkItem: DispatchWorkItem?
    private var followUpExpirationWorkItem: DispatchWorkItem?
    private var followUpSequenceWorkItems: [DispatchWorkItem] = []
    private var throwRecoveryWorkItems: [DispatchWorkItem] = []
    private var accessoryPreviewLaunchWorkItem: DispatchWorkItem?
    private var accessoryPreviewReclaimWorkItem: DispatchWorkItem?
    private var accessoryCompletionRewardWorkItem: DispatchWorkItem?
    private var pendingAccessoryCompletionReward: AccessoryCompletionReward?
    private var crossExaminationFeedbackWorkItem: DispatchWorkItem?
    private var courtRecordUnlockWorkItem: DispatchWorkItem?
    private var companionModeExpirationWorkItem: DispatchWorkItem?
    private var idleScheduler: IdleBehaviorScheduler!
    private var throwPhysicsController: ThrowPhysicsController?
    private var courtRecordPanelController: CourtRecordPanelController?
    private var petTrackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var isContextMenuOpen = false
    private var followUpOriginAction: PetAction?
    private var accessoryImages: [NSImage] = []
    private var lastThrowImpactTimestamp: TimeInterval = 0
    private var strongestThrowImpact: ThrowPhysicsController.ImpactSeverity = .light
    private var lastExplicitInteractionTimestamp = ProcessInfo.processInfo.systemUptime
    private var lastNameListenerStatus: ChatNameListener.Status = .stopped
    private var environmentDetectionGeneration = 0
    private var temporaryMessageGeneration: UInt64 = 0
    private var accessoryScatterRecordsDiscovery = true
    private var accessoryPreviewLifecycle = AccessoryPreviewLifecycleState()
    private var accessoryPreviewReclaimGeneration: UInt64 = 0
    private var accessoryPreviewSessionIsCurrent: (() -> Bool)?
    private var accessoryPreviewSessionIsCurrentOrFinished: (() -> Bool)?
    private var courtRecordUnlockObserver: NSObjectProtocol?
    private var presentedCourtRecordUnlock: CourtRecordUnlockAnnouncement?
    private var activeCrossExaminationToken: CrossExaminationSessionToken?

    private var mouseDownLocation = NSPoint.zero
    private var windowOriginOnMouseDown = NSPoint.zero
    private var didDrag = false
    private var activeGrabRegion: GrabRegion?

    init(frame frameRect: NSRect, images: [PetAction: NSImage]) {
        self.images = images
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        addSubview(edgeMotionEffectView)
        addSubview(imageView)
        addSubview(bubbleView)
        addSubview(courtRecordUnlockToastView)
        addSubview(orderedEvidenceArchiveHUDView)
        addSubview(followUpHotspotView)
        addSubview(followUpChoiceView)
        addSubview(crossExaminationView)

        followUpHotspotView.onActivate = { [weak self] in
            self?.activateFollowUp()
        }
        followUpHotspotView.onRightMouseDown = { [weak self] event in
            self?.rightMouseDown(with: event)
        }
        followUpChoiceView.onChoose = { [weak self] branch in
            self?.playFollowUp(branch)
        }
        followUpChoiceView.onCancel = { [weak self] in
            self?.cancelFollowUp(returnToIdle: true)
        }
        followUpChoiceView.onRightMouseDown = { [weak self] event in
            self?.rightMouseDown(with: event)
        }
        crossExaminationView.onPrevious = { [weak self] in
            self?.navigateCrossExamination(previous: true)
        }
        crossExaminationView.onNext = { [weak self] in
            self?.navigateCrossExamination(previous: false)
        }
        crossExaminationView.onObject = { [weak self] in
            self?.objectDuringCrossExamination()
        }
        crossExaminationView.onCancel = { [weak self] in
            self?.cancelFollowUp(returnToIdle: true)
        }
        crossExaminationView.onRightMouseDown = { [weak self] event in
            guard let self else { return }
            self.cancelFollowUp(returnToIdle: true)
            self.rightMouseDown(with: event)
        }

        accessoryImages = Self.loadAccessoryImages()
        accessoryScatterController.reclaimTargetProvider = { [weak self] in
            guard let frame = self?.window?.frame else { return nil }
            return NSPoint(x: frame.midX + 28, y: frame.minY + 108)
        }
        accessoryScatterController.onTriggered = { [weak self] count in
            guard
                let self,
                let sessionID = self.accessoryScatterController.activeSessionID
            else { return }
            self.accessoryCompletionRewardWorkItem?.cancel()
            self.accessoryCompletionRewardWorkItem = nil
            self.pendingAccessoryCompletionReward = nil
            let expectedKinds = Set(AccessoryKind.allCases.prefix(max(0, count)))
            let roundMode: AccessoryCollectionRoundMode = self.accessoryScatterRecordsDiscovery
                ? .real
                : .preview
            self.accessoryCollectionProgress.begin(
                sessionID: sessionID,
                mode: roundMode,
                expectedKinds: expectedKinds
            )
            let orderedStart = self.orderedEvidenceArchive.begin(
                sessionID: sessionID,
                mode: roundMode,
                expectedKinds: expectedKinds,
                order: roundMode == .real && expectedKinds == Set(AccessoryKind.allCases)
                    ? self.orderedEvidenceOrderGenerator.nextOrder()
                    : []
            )
            switch orderedStart {
            case let .started(snapshot):
                self.orderedEvidenceArchiveHUDView.show(snapshot)
            case .ineligible:
                self.orderedEvidenceArchiveHUDView.hide()
            }
        }
        accessoryScatterController.onAccessoryReclaimedEvent = { [weak self] event in
            guard let self, !self.didDrag else { return }
            self.cancelFollowUp(returnToIdle: false)
            let recordsDiscovery = self.accessoryScatterRecordsDiscovery
            if !recordsDiscovery, self.accessoryPreviewReclaimWorkItem != nil {
                // 用户先点了预览道具时，取消尚未执行的自动回收，避免稍后再抢画面。
                self.cancelAccessoryPreviewReclaimTask()
            }
            var progressParts: [String] = []
            if let sessionID = self.accessoryScatterController.activeSessionID {
                switch self.accessoryCollectionProgress.recordReclaimed(
                    event.kind,
                    sessionID: sessionID
                ) {
                case let .recorded(collectedCount, _):
                    progressParts.append(
                        "已归档 \(collectedCount)/\(AccessoryKind.allCases.count)"
                    )
                case .duplicate, .ignored:
                    break
                }

                switch self.orderedEvidenceArchive.recordReclaimed(
                    event.kind,
                    sessionID: sessionID
                ) {
                case let .advanced(snapshot):
                    self.orderedEvidenceArchiveHUDView.show(snapshot)
                    progressParts.append("有序 \(snapshot.completedCount)/\(snapshot.order.count)")
                case let .failed(snapshot):
                    self.orderedEvidenceArchiveHUDView.show(snapshot)
                    progressParts.append("顺序断了，继续普通归档")
                case let .completed(snapshot):
                    self.orderedEvidenceArchiveHUDView.show(snapshot)
                    progressParts.append("顺序完全吻合")
                case .duplicate, .ignored:
                    break
                }
            }
            let progressSuffix = progressParts.isEmpty
                ? ""
                : "  " + progressParts.joined(separator: " · ")

            let response: (action: PetAction, message: String)
            switch event.kind {
            case .attorneyBadge:
                response = (.badgeToss, "律师徽章可不能弄丢……接住了！")
            case .caseFile:
                response = (.evidence, "案件资料，一页也不能少。")
            case .magatama:
                response = (.magatama, "勾玉也回来了。得好好收着。")
            case .evidence:
                response = (.decisiveEvidence, "这份证物很关键，归档。")
            case .pen:
                response = (.think, "我的笔！刚才的思路还没记完。")
            case .stickyNote:
                response = (.evidence, "便签也要按顺序整理。")
            }
            self.perform(
                response.action,
                messageOverride: response.message + progressSuffix,
                countAsInteraction: recordsDiscovery,
                recordsInCourtRecord: recordsDiscovery
            )
        }
        accessoryScatterController.onFinished = { [weak self] in
            guard let self else { return }
            let wasPreview = !self.accessoryScatterRecordsDiscovery
            let collectionSessionID = self.accessoryCollectionProgress.activeSessionID
            let collectionResult = collectionSessionID.map {
                self.accessoryCollectionProgress.finish(sessionID: $0)
            } ?? .ignored
            let orderedResult = collectionSessionID.map {
                self.orderedEvidenceArchive.finish(sessionID: $0)
            } ?? .ignored
            self.orderedEvidenceArchiveHUDView.hide()
            self.accessoryScatterRecordsDiscovery = true

            if collectionResult == .reward, !wasPreview {
                if orderedResult == .reward {
                    self.courtRecordStore.record(CourtRecordID.orderedEvidenceArchive)
                    self.scheduleAccessoryCollectionReward(.ordered)
                } else {
                    self.scheduleAccessoryCollectionReward(.standard)
                }
            }
            guard
                wasPreview,
                let previewID = self.accessoryPreviewLifecycle.activePreviewID,
                self.accessoryPreviewSessionIsCurrentOrFinished?() == true
            else { return }
            self.finishAccessoryPreview(
                previewID: previewID,
                belongsToControllerSession: true
            )
        }

        courtRecordUnlockObserver = NotificationCenter.default.addObserver(
            forName: .courtRecordStoreDidUnlock,
            object: courtRecordStore,
            queue: .main
        ) { [weak self] notification in
            guard let event = CourtRecordUnlockEvent(notification: notification) else { return }
            self?.enqueueCourtRecordUnlock(recordID: event.recordID)
        }

        showIdle()
        showTemporaryMessage("单击随机动作 · 双击异议 · 右键菜单", duration: 4.0)

        idleScheduler = IdleBehaviorScheduler(
            profileProvider: { [weak self] in
                self?.companionActivityPolicy.idleProfile()
                    ?? .profile(for: .balanced)
            },
            isTrulyIdle: { [weak self] in
                guard let self else { return false }
                return self.companionActivityPolicy.allows(.ambient)
                    && self.currentAction == .idle
                    && self.interactionMode == .ordinary
                    && !self.didDrag
            }
        )
        idleScheduler.onIdleOpportunity = { [weak self] in
            self?.performScheduledIdleOpportunity()
        }
        idleScheduler.start()
        applyCompanionActivityPolicy()

        chatNameListener.onNameDetected = { [weak self] in
            guard let self, !self.didDrag else { return }
            self.cancelFollowUp(returnToIdle: false)
            let response = self.interactionMemory.recordNameCall(
                at: ProcessInfo.processInfo.systemUptime
            )
            let message: String
            switch response {
            case .first:
                message = "你在叫我吗？"
            case .again:
                message = "又在叫我？我听见了。"
            case .exasperated:
                message = "……我真的听见了，不用一直叫。"
            }
            self.perform(
                .heardName,
                messageOverride: message,
                countAsInteraction: true
            )
        }
        chatNameListener.onStatusChanged = { [weak self] status in
            guard let self, status != self.lastNameListenerStatus else { return }
            self.lastNameListenerStatus = status

            switch status {
            case .waitingForPermission:
                self.showTemporaryMessage(
                    self.chatNameListener.lastDiagnostic
                        ?? "等待辅助功能权限，授权后会自动开始。",
                    duration: 4.5
                )
            case .running:
                self.showTemporaryMessage("聊天名字监听已开始。", duration: 2.4)
            case .stopped, .unsupportedFocusedElement:
                break
            }
        }
        if UserDefaults.standard.bool(forKey: "chatNameListeningEnabled") {
            _ = chatNameListener.start(promptIfNeeded: false)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let courtRecordUnlockObserver {
            NotificationCenter.default.removeObserver(courtRecordUnlockObserver)
        }
        idleScheduler?.stop()
        resetWorkItem?.cancel()
        bubbleWorkItem?.cancel()
        clickWorkItem?.cancel()
        dragResignWorkItem?.cancel()
        environmentWorkItem?.cancel()
        followUpExpirationWorkItem?.cancel()
        followUpSequenceWorkItems.forEach { $0.cancel() }
        crossExaminationFeedbackWorkItem?.cancel()
        throwRecoveryWorkItems.forEach { $0.cancel() }
        accessoryPreviewLaunchWorkItem?.cancel()
        accessoryPreviewReclaimWorkItem?.cancel()
        accessoryCompletionRewardWorkItem?.cancel()
        courtRecordUnlockWorkItem?.cancel()
        companionModeExpirationWorkItem?.cancel()
        throwPhysicsController?.cancel()
        shakeGestureDetector.cancelCurrentGrab()
        cancelTrackedAccessoryCollection()
        accessoryScatterController.cancelAndRemoveAll()
        edgeMotionEffectView.stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        throwPhysicsController?.cancel()
        guard let window else {
            throwPhysicsController = nil
            return
        }

        var throwConfiguration = ThrowPhysicsController.Configuration()
        throwConfiguration.minimumThrowSpeed = 720
        throwConfiguration.gravity = -1_600
        throwConfiguration.airResistancePerSecond = 0.60
        throwConfiguration.edgeRestitution = 0.20
        throwConfiguration.tangentialDamping = 0.68
        throwConfiguration.settlementSpeed = 175
        throwConfiguration.maximumFlightDuration = 4.5
        let controller = ThrowPhysicsController(
            window: window,
            configuration: throwConfiguration
        )
        controller.onStarted = { [weak self] _ in
            guard let self else { return }
            self.cancelThrowRecovery()
            self.strongestThrowImpact = .light
            self.lastThrowImpactTimestamp = 0
            let teasingStage = self.interactionMemory.teasingStage(
                at: ProcessInfo.processInfo.systemUptime
            )
            let message: String
            switch teasingStage {
            case .normal:
                message = "哇啊——！"
            case .irritated:
                message = "又扔？！我正式抗议！"
            case .resigned:
                message = "……我就知道最后会被扔出去。"
            }
            self.perform(
                .thrown,
                autoReset: false,
                messageOverride: message,
                countAsInteraction: true
            )
        }
        controller.onBounce = { [weak self, weak controller] _, impact in
            guard let self, let controller, controller.isRunning else { return }
            self.rememberStrongestImpact(impact.severity)
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastThrowImpactTimestamp >= 0.28 else { return }
            self.lastThrowImpactTimestamp = now
            self.cancelThrowRecovery()
            let impactAction: PetAction = impact.severity == .light ? .dropped : .impact
            let impactMessage: String
            let afterMessage: String
            switch impact.severity {
            case .light:
                impactMessage = "唔！"
                afterMessage = "只是轻轻碰了一下……"
            case .medium:
                impactMessage = "痛！"
                afterMessage = "好痛……！"
            case .heavy:
                impactMessage = "痛——！"
                afterMessage = "这已经不是搬家了吧？！"
            }
            self.perform(
                impactAction,
                autoReset: false,
                messageOverride: impactMessage
            )
            // 碰撞台词至少稳定停留一小段时间，不能刚出现就被下一句替换。
            self.scheduleThrowRecovery(after: 0.65) { [weak self, weak controller] in
                guard let self, let controller, controller.isRunning else { return }
                self.perform(
                    .thrown,
                    autoReset: false,
                    messageOverride: afterMessage,
                    recordsInCourtRecord: false
                )
            }
        }
        controller.onSettled = { [weak self] _ in
            guard let self else { return }
            self.beginThrowLandingRecovery(severity: self.strongestThrowImpact)
        }
        throwPhysicsController = controller
    }

    override func layout() {
        super.layout()
        // 顶部留出独立字幕区，任何普通台词都不覆盖人物本体。
        edgeMotionEffectView.frame = bounds
        imageView.frame = NSRect(x: 18, y: 0, width: bounds.width - 36, height: 180)
        bubbleView.frame = NSRect(x: 8, y: bounds.height - 51, width: bounds.width - 16, height: 49)
        courtRecordUnlockToastView.frame = NSRect(
            x: 14,
            y: 182,
            width: bounds.width - 28,
            height: 24
        )
        orderedEvidenceArchiveHUDView.frame = NSRect(
            x: 8,
            y: 3,
            width: bounds.width - 16,
            height: 32
        )
        followUpHotspotView.frame = NSRect(x: bounds.midX + 31, y: 145, width: 25, height: 25)
        followUpChoiceView.frame = NSRect(x: 8, y: 3, width: bounds.width - 16, height: 35)
        crossExaminationView.frame = NSRect(x: 8, y: 3, width: bounds.width - 16, height: 35)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let petTrackingArea {
            removeTrackingArea(petTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        petTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        updateFollowUpHotspotVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        updateFollowUpHotspotVisibility()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard interactionMode != .courtRecordPanel else { return }
        clickWorkItem?.cancel()
        environmentWorkItem?.cancel()
        environmentDetectionGeneration &+= 1
        let cancelledFollowUp = interactionMode.isFollowUp
            || followUpOriginAction != nil
            || activeCrossExaminationToken != nil
        cancelFollowUp(returnToIdle: false)
        let pointInPetView = convert(event.locationInWindow, from: nil)
        activeGrabRegion = imageView.image.flatMap { image in
            GrabRegionDetector.shared.detect(
                at: pointInPetView,
                imageViewFrame: imageView.frame,
                image: image
            )
        }

        guard activeGrabRegion != nil else {
            didDrag = false
            if cancelledFollowUp {
                showIdle()
            }
            return
        }

        let wasBeingThrown = throwPhysicsController?.isRunning == true
        if wasBeingThrown {
            throwPhysicsController?.cancel()
            showIdle(mode: .mousePressed)
        }
        cancelThrowRecovery()

        noteExplicitInteraction()
        transition(to: .mousePressed)
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginOnMouseDown = window?.frame.origin ?? .zero
        didDrag = false
        dragVelocityTracker.reset(at: mouseDownLocation, timestamp: event.timestamp)
        if activeGrabRegion == .leg {
            shakeGestureDetector.beginLegGrab(
                timestamp: event.timestamp,
                globalPosition: mouseDownLocation
            )
        } else {
            shakeGestureDetector.cancelCurrentGrab()
        }
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard activeGrabRegion != nil, let window else { return }

        let current = NSEvent.mouseLocation
        let deltaX = current.x - mouseDownLocation.x
        let deltaY = current.y - mouseDownLocation.y
        if !didDrag, abs(deltaX) + abs(deltaY) > 4 {
            didDrag = true
            transition(to: .dragging)
            beginBeingHeld()
        }

        guard didDrag else { return }
        clickWorkItem?.cancel()
        dragVelocityTracker.add(position: current, timestamp: event.timestamp)
        window.setFrameOrigin(NSPoint(
            x: windowOriginOnMouseDown.x + deltaX,
            y: windowOriginOnMouseDown.y + deltaY
        ))
        dialogueController.updateAnchor(
            convert(event.locationInWindow, from: nil)
        )

        if activeGrabRegion == .leg,
           shakeGestureDetector.addSample(
               timestamp: event.timestamp,
               globalPosition: current
           ) {
            triggerAccessoryScatter()
        }

    }

    override func mouseUp(with event: NSEvent) {
        guard activeGrabRegion != nil else { return }
        NSCursor.openHand.set()

        if didDrag {
            let releasePosition = NSEvent.mouseLocation
            dragVelocityTracker.add(position: releasePosition, timestamp: event.timestamp)
            let releaseVelocity = dragVelocityTracker.estimatedVelocity(at: event.timestamp)
            let didScatter = shakeGestureDetector.didTriggerCurrentGrab
            shakeGestureDetector.endLegGrab()
            dragResignWorkItem?.cancel()
            imageView.layer?.setAffineTransform(.identity)
            didDrag = false

            if !didScatter,
               throwPhysicsController?.start(initialVelocity: releaseVelocity) == true {
                activeGrabRegion = nil
                return
            }

            handleDrop()
            activeGrabRegion = nil
            return
        }

        shakeGestureDetector.endLegGrab()

        if event.clickCount >= 2 {
            clickWorkItem?.cancel()
            perform(.objection, countAsInteraction: true)
            activeGrabRegion = nil
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let action = self.interactiveActionBag.next(
                from: PetAction.interactiveActions
            ) else { return }
            self.perform(action, countAsInteraction: true)
        }
        clickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
        activeGrabRegion = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        clickWorkItem?.cancel()
        cancelFollowUp(returnToIdle: true)
        closeOpenFeaturePanels()
        noteExplicitInteraction()
        let menu = NSMenu(title: "成步堂桌宠")

        for action in [PetAction.objection, .slam, .think, .sweat, .evidence, .idle] {
            let item = NSMenuItem(
                title: action.menuTitle,
                action: #selector(selectActionFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        for action in [PetAction.badgeToss, .magatama, .stepladder, .thinker, .decisiveEvidence, .flashlight] {
            let item = NSMenuItem(
                title: action.menuTitle,
                action: #selector(selectActionFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let randomItem = NSMenuItem(title: "随机动作", action: #selector(performRandomAction), keyEquivalent: "")
        randomItem.target = self
        menu.addItem(randomItem)

        let helpItem = NSMenuItem(title: "操作提示", action: #selector(showHelp), keyEquivalent: "")
        helpItem.target = self
        menu.addItem(helpItem)

        let crossExaminationItem = NSMenuItem(
            title: "开始交叉询问",
            action: #selector(startCrossExaminationFromMenu),
            keyEquivalent: ""
        )
        crossExaminationItem.target = self
        menu.addItem(crossExaminationItem)

        let companionItem = NSMenuItem(
            title: "陪伴节奏",
            action: nil,
            keyEquivalent: ""
        )
        companionItem.submenu = makeCompanionActivityMenu()
        menu.addItem(companionItem)

        menu.addItem(.separator())
        let courtRecordItem = NSMenuItem(
            title: "法庭记录…",
            action: #selector(showCourtRecord),
            keyEquivalent: ""
        )
        courtRecordItem.target = self
        menu.addItem(courtRecordItem)

        let listenerEnabled = chatNameListener.status != .stopped
        let listenerTitle = listenerEnabled
            ? "关闭聊天名字监听"
            : "开启聊天名字监听…"
        let listenerItem = NSMenuItem(
            title: listenerTitle,
            action: #selector(toggleChatNameListener),
            keyEquivalent: ""
        )
        listenerItem.target = self
        listenerItem.state = listenerEnabled ? .on : .off
        menu.addItem(listenerItem)

        let backgroundDetector = BackgroundBrightnessDetector.shared
        let hasBackgroundPermission = backgroundDetector.preflightPermission()
        let backgroundItem = NSMenuItem(
            title: hasBackgroundPermission
                ? "背景感知录屏：已授权"
                : "授权背景感知录屏…",
            action: hasBackgroundPermission
                ? nil
                : #selector(requestBackgroundPermission),
            keyEquivalent: ""
        )
        backgroundItem.target = hasBackgroundPermission ? nil : self
        backgroundItem.state = hasBackgroundPermission ? .on : .off
        menu.addItem(backgroundItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出桌宠", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        isContextMenuOpen = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        isContextMenuOpen = false
        presentDeferredAnnouncementsIfPossible()
    }

    @objc private func selectActionFromMenu(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let action = PetAction(rawValue: rawValue)
        else { return }
        cancelFollowUp(returnToIdle: false)
        perform(action, countAsInteraction: true)
    }

    @objc private func performRandomAction() {
        cancelFollowUp(returnToIdle: false)
        guard let action = interactiveActionBag.next(from: PetAction.interactiveActions) else {
            return
        }
        perform(action, countAsInteraction: true)
    }

    @objc private func startCrossExaminationFromMenu() {
        cancelFollowUp(returnToIdle: true)
        cancelTrackedAccessoryCollection()
        accessoryScatterController.cancelAndRemoveAll()
        beginCrossExamination()
    }

    @objc private func showHelp() {
        cancelFollowUp(returnToIdle: false)
        showIdle()
        noteExplicitInteraction()
        showTemporaryMessage("单击随机 · 双击异议 · 拖动搬家", duration: 3.5)
    }

    private func makeCompanionActivityMenu() -> NSMenu {
        let menu = NSMenu(title: "陪伴节奏")
        let snapshot = companionActivityPolicy.resolve()
        let titles: [(CompanionActivityLevel, String)] = [
            (.focused, "专注（无自动动作）"),
            (.balanced, "轻陪伴"),
            (.lively, "活跃"),
        ]
        for (level, title) in titles {
            let item = NSMenuItem(
                title: title,
                action: #selector(selectCompanionActivityLevel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = level.rawValue
            item.state = snapshot.baseLevel == level ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if let quietUntil = snapshot.quietUntil {
            let remainingMinutes = max(
                1,
                Int(ceil(quietUntil.timeIntervalSinceNow / 60))
            )
            let cancelItem = NSMenuItem(
                title: "取消安静（剩余约 \(remainingMinutes) 分钟）",
                action: #selector(cancelTemporaryQuiet),
                keyEquivalent: ""
            )
            cancelItem.target = self
            menu.addItem(cancelItem)
        } else {
            let quietItem = NSMenuItem(
                title: "安静 30 分钟",
                action: #selector(beginTemporaryQuiet),
                keyEquivalent: ""
            )
            quietItem.target = self
            menu.addItem(quietItem)
        }
        return menu
    }

    @objc private func selectCompanionActivityLevel(_ sender: NSMenuItem) {
        guard
            let rawValue = sender.representedObject as? String,
            let level = CompanionActivityLevel(rawValue: rawValue)
        else { return }

        noteExplicitInteraction()
        companionActivityPolicy.setBaseLevel(level)
        applyCompanionActivityPolicy()
        let title: String
        switch level {
        case .focused: title = "已切换为专注：不再自动演出。"
        case .balanced: title = "已切换为轻陪伴。"
        case .lively: title = "已切换为活跃陪伴。"
        }
        showTemporaryMessage(title, duration: 2.6)
    }

    @objc private func beginTemporaryQuiet() {
        noteExplicitInteraction()
        _ = companionActivityPolicy.beginQuiet()
        applyCompanionActivityPolicy()
        cancelFollowUp(returnToIdle: true)
        showTemporaryMessage("好，30 分钟内我会安静待着。", duration: 2.8)
    }

    @objc private func cancelTemporaryQuiet() {
        noteExplicitInteraction()
        companionActivityPolicy.cancelQuiet()
        applyCompanionActivityPolicy()
        showTemporaryMessage("安静模式已结束。", duration: 2.2)
    }

    @objc private func toggleChatNameListener() {
        cancelFollowUp(returnToIdle: false)
        if chatNameListener.status != .stopped {
            chatNameListener.stop()
            UserDefaults.standard.set(false, forKey: "chatNameListeningEnabled")
            showTemporaryMessage("已关闭名字监听。", duration: 2.0)
            return
        }

        UserDefaults.standard.set(true, forKey: "chatNameListeningEnabled")
        let started = chatNameListener.start(promptIfNeeded: true)
        if started {
            perform(.heardName, messageOverride: "听到名字，我就会回应。", countAsInteraction: true)
        } else {
            showTemporaryMessage(
                chatNameListener.lastDiagnostic
                    ?? "请允许辅助功能；授权后会自动开始，不需要再次点击。",
                duration: 5.0
            )
        }
    }

    @objc private func showCourtRecord() {
        cancelFollowUp(returnToIdle: true)
        noteExplicitInteraction()

        if let controller = courtRecordPanelController {
            transition(to: .courtRecordPanel)
            controller.show(relativeTo: window)
            return
        }

        let controller = CourtRecordPanelController(store: courtRecordStore)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            if self.courtRecordPanelController === controller {
                self.courtRecordPanelController = nil
            }
            if self.interactionMode == .courtRecordPanel {
                self.showIdle()
            }
        }
        courtRecordPanelController = controller
        showIdle(mode: .courtRecordPanel)
        controller.show(relativeTo: window)
    }

    @objc private func requestBackgroundPermission() {
        cancelFollowUp(returnToIdle: false)
        noteExplicitInteraction()
        let granted = BackgroundBrightnessDetector.shared.requestPermission()
        showTemporaryMessage(
            granted
                ? "背景感知已授权，只会在落地时读取一小块区域。"
                : "请在系统设置中允许录屏；之后拖到深色窗口即可测试。",
            duration: 5.0
        )
    }

    @objc private func quitApplication() {
        cancelFollowUp(returnToIdle: false)
        NSApp.terminate(nil)
    }

    /// 仅供本地构建验收时通过启动参数直接预览指定动作。
    func preview(_ action: PetAction) {
        cancelAccessoryPreview(restoreIfOwned: false, removeAccessories: false)
        NSLog("桌宠执行预览动作：%@", action.rawValue)
        perform(action, recordsInCourtRecord: false)
    }

    /// 仅供本地构建验收预览低频边缘待机，不加入用户右键菜单。
    func previewEdgeIdle(_ edge: EdgeIdleBehavior.Edge) {
        cancelAccessoryPreview(restoreIfOwned: false, removeAccessories: false)
        performEdgeIdle(edge, recordsDiscovery: false)
    }

    /// 仅供本地构建验收六件道具的散落与回收，不写入图鉴。
    func previewAccessoryScatter() {
        scheduleAccessoryPreview(after: 0, reclaimKind: nil)
    }

    /// 仅供本地构建验收指定道具的独立回收轨迹。
    func previewAccessoryReclaim(_ kind: AccessoryKind) {
        scheduleAccessoryPreview(after: 0, reclaimKind: kind)
    }

    /// 将启动参数触发的隐藏预览延迟也交给 PetView，真实交互可在执行前取消它。
    func schedulePreviewAccessoryScatter(after delay: TimeInterval) {
        scheduleAccessoryPreview(after: delay, reclaimKind: nil)
    }

    /// 将启动参数触发的隐藏预览延迟也交给 PetView，真实交互可在执行前取消它。
    func schedulePreviewAccessoryReclaim(
        _ kind: AccessoryKind,
        after delay: TimeInterval
    ) {
        scheduleAccessoryPreview(after: delay, reclaimKind: kind)
    }

    private func scheduleAccessoryPreview(
        after delay: TimeInterval,
        reclaimKind: AccessoryKind?
    ) {
        cancelAccessoryPreview(restoreIfOwned: true, removeAccessories: true)
        let previewID = accessoryPreviewLifecycle.begin()

        guard delay > 0 else {
            startAccessoryPreview(previewID: previewID, reclaimKind: reclaimKind)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.accessoryPreviewLifecycle.isCurrent(previewID)
            else { return }
            self.accessoryPreviewLaunchWorkItem = nil
            self.startAccessoryPreview(previewID: previewID, reclaimKind: reclaimKind)
        }
        accessoryPreviewLaunchWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func startAccessoryPreview(
        previewID: UInt64,
        reclaimKind: AccessoryKind?
    ) {
        guard accessoryPreviewLifecycle.isCurrent(previewID) else { return }
        guard triggerAccessoryScatter(recordsDiscovery: false) else {
            finishAccessoryPreview(
                previewID: previewID,
                belongsToControllerSession: true
            )
            return
        }

        let controller = accessoryScatterController
        guard let sessionID = controller.activeSessionID else {
            finishAccessoryPreview(
                previewID: previewID,
                belongsToControllerSession: true
            )
            cancelTrackedAccessoryCollection()
            controller.cancelAndRemoveAll()
            return
        }

        accessoryPreviewSessionIsCurrent = { [weak controller] in
            controller?.activeSessionID == sessionID
        }
        accessoryPreviewSessionIsCurrentOrFinished = { [weak controller] in
            guard let activeSessionID = controller?.activeSessionID else { return true }
            return activeSessionID == sessionID
        }

        guard let reclaimKind else { return }
        cancelAccessoryPreviewReclaimTask()
        accessoryPreviewReclaimGeneration &+= 1
        let reclaimGeneration = accessoryPreviewReclaimGeneration
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard
                let self,
                let controller,
                self.accessoryPreviewLifecycle.isCurrent(previewID),
                self.accessoryPreviewReclaimGeneration == reclaimGeneration
            else { return }
            guard controller.activeSessionID == sessionID else {
                self.cancelAccessoryPreview(
                    restoreIfOwned: false,
                    removeAccessories: false
                )
                return
            }

            self.accessoryPreviewReclaimWorkItem = nil
            let didReclaim = controller.reclaimForPreview(
                kind: reclaimKind,
                sessionID: sessionID
            )
            guard !didReclaim else { return }

            let stillOwnsControllerSession = controller.activeSessionID == sessionID
            self.finishAccessoryPreview(
                previewID: previewID,
                belongsToControllerSession: stillOwnsControllerSession
            )
            if stillOwnsControllerSession {
                self.cancelTrackedAccessoryCollection()
                controller.cancelAndRemoveAll()
            }
        }
        accessoryPreviewReclaimWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: workItem)
    }

    private func cancelAccessoryPreviewReclaimTask() {
        accessoryPreviewReclaimWorkItem?.cancel()
        accessoryPreviewReclaimWorkItem = nil
        accessoryPreviewReclaimGeneration &+= 1
    }

    private func cancelAccessoryPreview(
        restoreIfOwned: Bool,
        removeAccessories: Bool
    ) {
        accessoryPreviewLaunchWorkItem?.cancel()
        accessoryPreviewLaunchWorkItem = nil
        cancelAccessoryPreviewReclaimTask()

        guard let previewID = accessoryPreviewLifecycle.activePreviewID else { return }
        let hadControllerSession = accessoryPreviewSessionIsCurrent != nil
        let belongsToControllerSession = accessoryPreviewSessionIsCurrent?() ?? true
        let shouldRestore: Bool
        if restoreIfOwned {
            shouldRestore = accessoryPreviewLifecycle.cancelAndShouldRestore(
                previewID: previewID,
                belongsToControllerSession: belongsToControllerSession,
                isPreviewDragging: isInAccessoryPreviewDraggingState
            )
            if !belongsToControllerSession {
                _ = accessoryPreviewLifecycle.cancel(previewID)
            }
        } else {
            _ = accessoryPreviewLifecycle.cancel(previewID)
            shouldRestore = false
        }

        accessoryPreviewSessionIsCurrent = nil
        accessoryPreviewSessionIsCurrentOrFinished = nil
        if removeAccessories, hadControllerSession, belongsToControllerSession {
            cancelTrackedAccessoryCollection()
            accessoryScatterController.cancelAndRemoveAll()
        }
        if shouldRestore {
            showIdle()
        }
    }

    private func finishAccessoryPreview(
        previewID: UInt64,
        belongsToControllerSession: Bool
    ) {
        let shouldRestore = accessoryPreviewLifecycle.finish(
            previewID: previewID,
            belongsToControllerSession: belongsToControllerSession,
            isPreviewDragging: isInAccessoryPreviewDraggingState
        )
        guard !accessoryPreviewLifecycle.isCurrent(previewID) else { return }

        accessoryPreviewLaunchWorkItem?.cancel()
        accessoryPreviewLaunchWorkItem = nil
        cancelAccessoryPreviewReclaimTask()
        accessoryPreviewSessionIsCurrent = nil
        accessoryPreviewSessionIsCurrentOrFinished = nil
        if shouldRestore {
            showIdle()
        }
    }

    private var isInAccessoryPreviewDraggingState: Bool {
        interactionMode == .dragging
            && currentAction == .legStruggle
            && !didDrag
    }

    private func perform(
        _ action: PetAction,
        autoReset: Bool = true,
        messageOverride: String? = nil,
        countAsInteraction: Bool = false,
        mode: PetInteractionMode? = nil,
        recordsInCourtRecord: Bool = true
    ) {
        if countAsInteraction {
            noteExplicitInteraction()
        }
        edgeMotionEffectView.stop()
        resetWorkItem?.cancel()
        cancelTemporaryMessage()
        let nextMode = mode ?? (action == .objection ? .objectionBurst : .action)
        transition(to: nextMode)
        currentAction = action
        imageView.image = images[action]
        imageView.isHidden = false
        imageView.alphaValue = 1
        animate(action)

        CourtRecordActionRecorder.record(
            action,
            in: courtRecordStore,
            enabled: recordsInCourtRecord
        )

        if action == .objection {
            bubbleView.hide()
            dialogueController.dismiss()
            objectionBurstView.show(in: self)
        } else if let phrase = messageOverride ?? action.phrase {
            objectionBurstView.hide()
            bubbleView.hide()
            dialogueController.show(
                text: phrase,
                style: dialogueStyle(for: action),
                in: self,
                duration: max(1.2, action.duration)
            )
        } else {
            objectionBurstView.hide()
            bubbleView.hide()
            dialogueController.dismiss()
        }

        guard action != .idle, autoReset, action.duration > 0 else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.didDrag else { return }
            switch self.interactionMode {
            case .followUpPending:
                self.showIdle(mode: .followUpPending)
            case .courtRecordPanel:
                self.showIdle(mode: .courtRecordPanel)
            default:
                self.showIdle()
            }
        }
        resetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + action.duration, execute: workItem)
    }

    private func showIdle(mode: PetInteractionMode = .ordinary) {
        resetWorkItem?.cancel()
        cancelTemporaryMessage()
        transition(to: mode)
        currentAction = .idle
        imageView.image = images[.idle]
        objectionBurstView.hide()
        bubbleView.hide()
        dialogueController.dismiss()
        edgeMotionEffectView.stop()
        animate(.idle)
        presentDeferredAnnouncementsIfPossible()
    }

    private func noteExplicitInteraction() {
        suspendCourtRecordUnlockAnnouncements()
        accessoryCompletionRewardWorkItem?.cancel()
        accessoryCompletionRewardWorkItem = nil
        cancelAccessoryPreview(restoreIfOwned: true, removeAccessories: false)
        lastExplicitInteractionTimestamp = ProcessInfo.processInfo.systemUptime
        edgeIdleBehavior.resetCandidate()
        idleScheduler?.noteUserInteraction()
    }

    private func applyCompanionActivityPolicy() {
        companionModeExpirationWorkItem?.cancel()
        companionModeExpirationWorkItem = nil

        let snapshot = companionActivityPolicy.resolve()
        idleScheduler?.refreshProfile()
        guard let quietUntil = snapshot.quietUntil else { return }

        let delay = max(0, quietUntil.timeIntervalSinceNow)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.companionModeExpirationWorkItem = nil
            self.applyCompanionActivityPolicy()
        }
        companionModeExpirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performScheduledIdleOpportunity() {
        guard
            companionActivityPolicy.allows(.ambient),
            interactionMode == .ordinary,
            currentAction == .idle,
            !didDrag
        else { return }

        let now = ProcessInfo.processInfo.systemUptime
        if let window,
           let screen = window.screen ?? NSScreen.screens.first,
           let edge = edgeIdleBehavior.evaluate(
               windowFrame: window.frame,
               screenVisibleFrame: screen.visibleFrame,
               idleDuration: max(0, now - lastExplicitInteractionTimestamp),
               now: now,
               eligibility: true
           ) {
            performEdgeIdle(edge)
            return
        }

        guard let action = idleActionBag.next(from: PetAction.lowFrequencyIdleActions) else {
            return
        }
        performAmbientIdleAction(action)
    }

    private func performEdgeIdle(
        _ edge: EdgeIdleBehavior.Edge,
        recordsDiscovery: Bool = true
    ) {
        if recordsDiscovery {
            courtRecordStore.record(CourtRecordID.edgeRest)
        }
        let message: String
        let xOffset: CGFloat
        let yOffset: CGFloat
        let rotation: CGFloat
        let scaleY: CGFloat
        switch edge {
        case .left:
            message = "从左边观察一下。"
            xOffset = -34
            yOffset = -12
            rotation = -0.035
            scaleY = 0.94
        case .right:
            message = "从右边观察一下。"
            xOffset = 34
            yOffset = -12
            rotation = 0.035
            scaleY = 0.94
        case .bottom:
            message = "这里视野不错。"
            xOffset = 0
            // 让窗口底边遮住腿部，现有思考立姿才会读成“坐在桌面边缘”。
            yOffset = -38
            rotation = 0
            scaleY = 0.82
        }

        perform(
            .think,
            autoReset: false,
            messageOverride: message,
            recordsInCourtRecord: recordsDiscovery
        )
        imageView.layer?.removeAllAnimations()
        addKeyframes(
            keyPath: "transform.translation.x",
            values: [0, xOffset * 1.12, xOffset],
            duration: 0.55,
            holdFinalValue: true
        )
        addKeyframes(
            keyPath: "transform.translation.y",
            values: [0, yOffset * 1.08, yOffset],
            duration: 0.55,
            holdFinalValue: true
        )
        addKeyframes(
            keyPath: "transform.scale.y",
            values: [1, scaleY * 0.97, scaleY],
            duration: 0.55,
            holdFinalValue: true
        )
        if rotation != 0 {
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [0, rotation, rotation],
                duration: 0.55,
                holdFinalValue: true
            )
        }
        edgeMotionEffectView.playEntrance(edge: edge)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.didDrag else { return }
            self.edgeMotionEffectView.playExit(edge: edge) { [weak self] in
                guard let self, !self.didDrag else { return }
                self.showIdle()
            }
        }
        resetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: workItem)
    }

    private func performAmbientIdleAction(_ action: PetAction) {
        guard interactionMode == .ordinary, currentAction == .idle, !didDrag else { return }
        perform(action)

        switch action {
        case .think, .evidence, .badgeToss:
            beginPendingFollowUp(after: action)
        default:
            break
        }
    }

    private func beginPendingFollowUp(after action: PetAction) {
        followUpExpirationWorkItem?.cancel()
        followUpSequenceWorkItems.forEach { $0.cancel() }
        followUpSequenceWorkItems.removeAll()
        followUpOriginAction = action
        transition(to: .followUpPending)
        updateFollowUpHotspotVisibility()

        let workItem = DispatchWorkItem { [weak self] in
            self?.cancelFollowUp(returnToIdle: true)
        }
        followUpExpirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: workItem)
    }

    private func activateFollowUp() {
        guard interactionMode == .followUpPending, followUpOriginAction != nil else { return }
        clickWorkItem?.cancel()
        followUpExpirationWorkItem?.cancel()
        resetWorkItem?.cancel()
        noteExplicitInteraction()
        followUpHotspotView.isHidden = true
        followUpChoiceView.isHidden = false
        perform(
            .think,
            autoReset: false,
            messageOverride: "刚才的线索……想追问哪一边？",
            mode: .followUpChoosing
        )

        let workItem = DispatchWorkItem { [weak self] in
            self?.cancelFollowUp(returnToIdle: true)
        }
        followUpExpirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0, execute: workItem)
    }

    private func playFollowUp(_ branch: FollowUpBranch) {
        guard interactionMode == .followUpChoosing else { return }
        followUpExpirationWorkItem?.cancel()
        followUpChoiceView.isHidden = true
        noteExplicitInteraction()

        if case .askAboutCase = branch {
            beginCrossExamination()
            return
        }

        transition(to: .followUpBranch)

        switch branch {
        case .presentBadge:
            perform(
                .badgeToss,
                autoReset: false,
                messageOverride: "这是我的律师徽章。货真价实！",
                mode: .followUpBranch
            )
            scheduleFollowUpStep(after: 5.2) { [weak self] in
                self?.perform(
                    .think,
                    autoReset: false,
                    messageOverride: "不过，徽章本身可不能代替证据。",
                    mode: .followUpBranch
                )
            }
        case .askAboutCase:
            break
        }

        scheduleFollowUpStep(after: 11.4) { [weak self] in
            self?.cancelFollowUp(returnToIdle: true)
        }
    }

    private func beginCrossExamination() {
        followUpExpirationWorkItem?.cancel()
        followUpExpirationWorkItem = nil
        followUpSequenceWorkItems.forEach { $0.cancel() }
        followUpSequenceWorkItems.removeAll()
        cancelCrossExaminationState()
        noteExplicitInteraction()

        guard let question = crossExaminationQuestionBag.next() else {
            showIdle()
            return
        }

        followUpOriginAction = .evidence
        transition(to: .followUpBranch)
        let token = crossExaminationRound.start(question: question)
        activeCrossExaminationToken = token
        presentCurrentCrossExaminationStatement()

        let workItem = DispatchWorkItem { [weak self] in
            self?.timeoutCrossExamination(sessionToken: token)
        }
        followUpExpirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 15.0, execute: workItem)
    }

    private func presentCurrentCrossExaminationStatement(feedback: String? = nil) {
        guard
            let token = activeCrossExaminationToken,
            let snapshot = crossExaminationRound.snapshot,
            snapshot.sessionToken == token,
            snapshot.phase == .active
        else { return }

        crossExaminationView.isHidden = false
        crossExaminationView.update(
            positionText: "第 \(snapshot.currentIndex + 1) 句",
            canPrevious: snapshot.currentIndex > 0,
            canNext: snapshot.currentIndex + 1 < snapshot.question.statements.count,
            feedback: feedback
        )
        perform(
            .think,
            autoReset: false,
            messageOverride: "证言 \(snapshot.currentIndex + 1)/3：\(snapshot.currentStatement)",
            mode: .followUpBranch,
            recordsInCourtRecord: false
        )
    }

    private func navigateCrossExamination(previous: Bool) {
        guard let token = activeCrossExaminationToken else { return }
        noteExplicitInteraction()
        crossExaminationFeedbackWorkItem?.cancel()
        crossExaminationFeedbackWorkItem = nil
        if previous {
            _ = crossExaminationRound.previous(sessionToken: token)
        } else {
            _ = crossExaminationRound.next(sessionToken: token)
        }
        presentCurrentCrossExaminationStatement()
    }

    private func objectDuringCrossExamination() {
        guard let token = activeCrossExaminationToken else { return }
        noteExplicitInteraction()
        crossExaminationFeedbackWorkItem?.cancel()
        crossExaminationFeedbackWorkItem = nil

        switch crossExaminationRound.object(sessionToken: token) {
        case let .incorrect(_, hint):
            let currentIndex = crossExaminationRound.snapshot?.currentIndex ?? 0
            crossExaminationView.update(
                positionText: "再看看",
                canPrevious: currentIndex > 0,
                canNext: currentIndex < 2,
                feedback: "再看看"
            )
            perform(
                .sweat,
                autoReset: false,
                messageOverride: hint,
                mode: .followUpBranch,
                recordsInCourtRecord: false
            )
            let workItem = DispatchWorkItem { [weak self] in
                guard self?.activeCrossExaminationToken == token else { return }
                self?.crossExaminationFeedbackWorkItem = nil
                self?.presentCurrentCrossExaminationStatement()
            }
            crossExaminationFeedbackWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)

        case let .succeeded(conclusion):
            followUpExpirationWorkItem?.cancel()
            followUpExpirationWorkItem = nil
            activeCrossExaminationToken = nil
            crossExaminationView.isHidden = true
            courtRecordStore.record(CourtRecordID.crossExamination)
            perform(
                .objection,
                autoReset: false,
                mode: .followUpBranch,
                recordsInCourtRecord: false
            )
            scheduleFollowUpStep(after: 1.35) { [weak self] in
                self?.perform(
                    .decisiveEvidence,
                    autoReset: false,
                    messageOverride: conclusion,
                    mode: .followUpBranch,
                    recordsInCourtRecord: false
                )
            }
            scheduleFollowUpStep(after: 4.4) { [weak self] in
                self?.cancelFollowUp(returnToIdle: true)
            }

        case .ignored:
            break
        }
    }

    private func timeoutCrossExamination(sessionToken: CrossExaminationSessionToken) {
        guard activeCrossExaminationToken == sessionToken else { return }
        guard crossExaminationRound.timeout(sessionToken: sessionToken) == .timedOut else {
            return
        }
        followUpExpirationWorkItem = nil
        activeCrossExaminationToken = nil
        crossExaminationView.isHidden = true
        perform(
            .think,
            autoReset: false,
            messageOverride: "这句证言先记下来，下次再找矛盾。",
            mode: .followUpBranch,
            recordsInCourtRecord: false
        )
        scheduleFollowUpStep(after: 2.6) { [weak self] in
            self?.cancelFollowUp(returnToIdle: true)
        }
    }

    private func cancelCrossExaminationState() {
        crossExaminationFeedbackWorkItem?.cancel()
        crossExaminationFeedbackWorkItem = nil
        if let token = activeCrossExaminationToken {
            _ = crossExaminationRound.cancel(sessionToken: token)
        }
        activeCrossExaminationToken = nil
        crossExaminationView.isHidden = true
    }

    private func scheduleFollowUpStep(
        after delay: TimeInterval,
        operation: @escaping () -> Void
    ) {
        let workItem = DispatchWorkItem(block: operation)
        followUpSequenceWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelFollowUp(returnToIdle: Bool) {
        let hadFollowUp = interactionMode.isFollowUp
            || followUpOriginAction != nil
            || activeCrossExaminationToken != nil
        followUpExpirationWorkItem?.cancel()
        followUpExpirationWorkItem = nil
        followUpSequenceWorkItems.forEach { $0.cancel() }
        followUpSequenceWorkItems.removeAll()
        cancelCrossExaminationState()
        followUpOriginAction = nil
        followUpHotspotView.isHidden = true
        followUpChoiceView.isHidden = true

        guard hadFollowUp else { return }
        if returnToIdle, !didDrag {
            showIdle()
        } else if interactionMode.isFollowUp {
            transition(to: .ordinary)
        }
    }

    private func updateFollowUpHotspotVisibility() {
        followUpHotspotView.isHidden = !(interactionMode == .followUpPending && isMouseInside)
    }

    private func transition(to mode: PetInteractionMode) {
        if mode != .ordinary {
            suspendCourtRecordUnlockAnnouncements()
        }
        interactionMode = mode
        if mode != .followUpPending {
            followUpHotspotView.isHidden = true
        }
        if mode != .followUpChoosing {
            followUpChoiceView.isHidden = true
        }
    }

    private func closeOpenFeaturePanels() {
        if let controller = courtRecordPanelController {
            courtRecordPanelController = nil
            controller.close()
        }
        if interactionMode == .courtRecordPanel {
            showIdle()
        }
    }

    private func beginBeingHeld() {
        cancelFollowUp(returnToIdle: false)
        environmentWorkItem?.cancel()
        dragResignWorkItem?.cancel()
        let region = activeGrabRegion ?? .collarTorso
        courtRecordStore.record(CourtRecordID.grab(region))
        let actions = heldActions(for: region)
        let interaction: InteractionMemory.TeasingInteraction = region == .leg
            ? .legDrag
            : .grab
        let teasingStage = interactionMemory.recordTeasing(
            interaction,
            at: ProcessInfo.processInfo.systemUptime
        )

        switch teasingStage {
        case .normal:
            perform(actions.struggle, autoReset: false, mode: .dragging)
        case .irritated:
            perform(
                actions.struggle,
                autoReset: false,
                messageOverride: "又来？！我真的要抗议了！",
                mode: .dragging
            )
        case .resigned:
            perform(
                actions.resigned,
                autoReset: false,
                messageOverride: "……我就知道你还会来。",
                mode: .dragging
            )
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.didDrag else { return }
            let message = teasingStage == .irritated
                ? "……你到底还要闹几次。"
                : nil
            self.perform(
                actions.resigned,
                autoReset: false,
                messageOverride: message,
                mode: .dragging
            )
        }
        dragResignWorkItem = workItem
        let resignDelay: TimeInterval = teasingStage == .irritated ? 1.4 : 2.2
        DispatchQueue.main.asyncAfter(deadline: .now() + resignDelay, execute: workItem)
    }

    private func heldActions(for region: GrabRegion) -> (struggle: PetAction, resigned: PetAction) {
        switch region {
        case .hairHead:
            return (.hairStruggle, .hairResigned)
        case .arm:
            return (.armStruggle, .armResigned)
        case .collarTorso:
            return (.heldStruggle, .heldResigned)
        case .leg:
            return (.legStruggle, .legResigned)
        }
    }

    @discardableResult
    private func triggerAccessoryScatter(recordsDiscovery: Bool = true) -> Bool {
        if recordsDiscovery {
            cancelAccessoryPreview(restoreIfOwned: false, removeAccessories: false)
        }
        guard
            !accessoryImages.isEmpty,
            let window,
            let screen = window.screen ?? NSScreen.screens.first
        else { return false }

        accessoryScatterRecordsDiscovery = recordsDiscovery
        guard accessoryScatterController.scatter(
            images: accessoryImages,
            from: window.frame,
            on: screen
        ) else {
            accessoryScatterRecordsDiscovery = true
            return false
        }

        if recordsDiscovery {
            courtRecordStore.record(CourtRecordID.upsideDownScatter)
        }
        perform(
            .legStruggle,
            autoReset: false,
            messageOverride: "等一下！我的证物都掉出来了！",
            countAsInteraction: recordsDiscovery,
            mode: .dragging,
            recordsInCourtRecord: recordsDiscovery
        )
        return true
    }

    private func rememberStrongestImpact(_ candidate: ThrowPhysicsController.ImpactSeverity) {
        func rank(_ severity: ThrowPhysicsController.ImpactSeverity) -> Int {
            switch severity {
            case .light: return 0
            case .medium: return 1
            case .heavy: return 2
            }
        }
        if rank(candidate) > rank(strongestThrowImpact) {
            strongestThrowImpact = candidate
        }
    }

    private func beginThrowLandingRecovery(
        severity: ThrowPhysicsController.ImpactSeverity
    ) {
        cancelThrowRecovery()
        switch severity {
        case .light:
            // 轻碰只做短促的揉头恢复，不进入拍灰和生气链。
            perform(
                .dizzy,
                autoReset: false,
                messageOverride: "嘶……只是撞到头了。"
            )
            imageView.layer?.removeAllAnimations()
            addKeyframes(
                keyPath: "transform.translation.y",
                values: [0, -2, 1, 0],
                duration: 0.65
            )
            scheduleThrowRecovery(after: 1.8) { [weak self] in
                self?.showIdle()
            }

        case .medium:
            perform(
                .dizzy,
                autoReset: false,
                messageOverride: "有点晕……先让我缓一下。"
            )
            scheduleThrowRecovery(after: 2.0) { [weak self] in
                self?.perform(
                    .dusting,
                    autoReset: false,
                    messageOverride: "西装也沾上灰了……"
                )
            }
            scheduleThrowRecovery(after: 3.6) { [weak self] in
                self?.showIdle()
            }

        case .heavy:
            perform(
                .dizzy,
                autoReset: false,
                messageOverride: "天地都在转……这下真的很重！"
            )
            scheduleThrowRecovery(after: 2.2) { [weak self] in
                self?.perform(.dusting, autoReset: false)
            }
            scheduleThrowRecovery(after: 3.7) { [weak self] in
                self?.perform(
                    .irritated,
                    autoReset: false,
                    messageOverride: "下次绝对不许这样扔！"
                )
            }
            scheduleThrowRecovery(after: 5.7) { [weak self] in
                self?.showIdle()
            }
        }
    }

    private func scheduleThrowRecovery(
        after delay: TimeInterval,
        operation: @escaping () -> Void
    ) {
        let workItem = DispatchWorkItem(block: operation)
        throwRecoveryWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelThrowRecovery() {
        throwRecoveryWorkItems.forEach { $0.cancel() }
        throwRecoveryWorkItems.removeAll(keepingCapacity: true)
    }

    private static func loadAccessoryImages() -> [NSImage] {
        [
            "scatter-attorney-badge-cg",
            "scatter-case-file-cg",
            "scatter-magatama-cg",
            "scatter-evidence-cg",
            "scatter-pen-cg",
            "scatter-notes-cg",
        ].compactMap { name in
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else {
                return nil
            }
            return NSImage(contentsOf: url)
        }
    }

    private func handleDrop() {
        guard let window else {
            perform(.dropped, countAsInteraction: true)
            return
        }

        environmentDetectionGeneration &+= 1
        let generation = environmentDetectionGeneration
        let dropOrigin = window.frame.origin
        perform(.dropped, countAsInteraction: true)

        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            let background = await BackgroundBrightnessDetector.shared.detect(behind: window)
            guard
                self.environmentDetectionGeneration == generation,
                !self.didDrag,
                hypot(window.frame.origin.x - dropOrigin.x, window.frame.origin.y - dropOrigin.y) < 2,
                background.isDark
            else { return }

            self.perform(.afraidDark, autoReset: false, countAsInteraction: true)
            let workItem = DispatchWorkItem { [weak self] in
                guard
                    let self,
                    self.environmentDetectionGeneration == generation,
                    !self.didDrag,
                    self.currentAction == .afraidDark
                else { return }
                self.perform(.flashlight, recordsInCourtRecord: false)
            }
            self.environmentWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: workItem)
        }
    }

    private func enqueueCourtRecordUnlock(recordID: String) {
        guard CourtRecordCatalog.all.contains(where: { $0.id == recordID }) else { return }
        if case .activated = courtRecordUnlockQueue.enqueue(recordID: recordID) {
            presentPendingCourtRecordUnlockIfPossible()
        }
    }

    private func presentPendingCourtRecordUnlockIfPossible() {
        guard
            pendingAccessoryCompletionReward == nil,
            bubbleWorkItem == nil,
            !isContextMenuOpen,
            presentedCourtRecordUnlock == nil,
            let announcement = courtRecordUnlockQueue.active,
            throwPhysicsController?.isRunning != true,
            !didDrag
        else { return }

        switch interactionMode {
        case .ordinary:
            break
        case .action, .mousePressed, .dragging, .objectionBurst, .followUpPending,
             .followUpChoosing, .followUpBranch, .courtRecordPanel:
            return
        }

        guard let definition = CourtRecordCatalog.all.first(where: {
            $0.id == announcement.recordID
        }) else {
            _ = courtRecordUnlockQueue.complete(announcement)
            presentPendingCourtRecordUnlockIfPossible()
            return
        }

        presentedCourtRecordUnlock = announcement
        courtRecordUnlockToastView.show(recordTitle: definition.title)
        courtRecordUnlockWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.presentedCourtRecordUnlock == announcement else { return }
            self.courtRecordUnlockToastView.hide()
            self.presentedCourtRecordUnlock = nil
            _ = self.courtRecordUnlockQueue.complete(announcement)
            self.presentPendingCourtRecordUnlockIfPossible()
        }
        courtRecordUnlockWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    /// Explicit interaction interrupts the visual toast, but keeps its one-shot
    /// announcement queued so it can be shown again after the pet returns idle.
    private func suspendCourtRecordUnlockAnnouncements() {
        courtRecordUnlockWorkItem?.cancel()
        courtRecordUnlockWorkItem = nil
        presentedCourtRecordUnlock = nil
        courtRecordUnlockToastView.hide()
    }

    private func scheduleAccessoryCollectionReward(_ reward: AccessoryCompletionReward) {
        accessoryCompletionRewardWorkItem?.cancel()
        accessoryCompletionRewardWorkItem = nil
        pendingAccessoryCompletionReward = reward
        presentPendingAccessoryCollectionRewardIfPossible()
    }

    private func presentPendingAccessoryCollectionRewardIfPossible() {
        guard
            pendingAccessoryCompletionReward != nil,
            accessoryCompletionRewardWorkItem == nil,
            bubbleWorkItem == nil,
            !isContextMenuOpen,
            currentAction == .idle,
            interactionMode == .ordinary,
            throwPhysicsController?.isRunning != true,
            !didDrag
        else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.accessoryCompletionRewardWorkItem = nil
            guard
                let reward = self.pendingAccessoryCompletionReward,
                self.bubbleWorkItem == nil,
                !self.isContextMenuOpen,
                self.currentAction == .idle,
                self.interactionMode == .ordinary,
                self.throwPhysicsController?.isRunning != true,
                !self.didDrag
            else { return }
            self.pendingAccessoryCompletionReward = nil
            self.perform(
                .decisiveEvidence,
                messageOverride: reward.message
            )
        }
        accessoryCompletionRewardWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func presentDeferredAnnouncementsIfPossible() {
        guard
            bubbleWorkItem == nil,
            !isContextMenuOpen,
            currentAction == .idle,
            interactionMode == .ordinary,
            !didDrag
        else { return }

        if pendingAccessoryCompletionReward != nil {
            presentPendingAccessoryCollectionRewardIfPossible()
        } else {
            presentPendingCourtRecordUnlockIfPossible()
        }
    }

    private func cancelTrackedAccessoryCollection() {
        if let sessionID = accessoryCollectionProgress.activeSessionID {
            _ = accessoryCollectionProgress.cancel(sessionID: sessionID)
        }
        if let sessionID = orderedEvidenceArchive.activeSessionID {
            _ = orderedEvidenceArchive.cancel(sessionID: sessionID)
        }
        orderedEvidenceArchiveHUDView.hide()
    }

    private func showTemporaryMessage(_ text: String, duration: TimeInterval) {
        cancelTemporaryMessage()
        let generation = temporaryMessageGeneration
        suspendCourtRecordUnlockAnnouncements()
        bubbleView.hide()
        dialogueController.show(
            text: text,
            style: .friendly,
            in: self,
            duration: duration
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard
                let self,
                self.temporaryMessageGeneration == generation
            else { return }
            self.bubbleWorkItem = nil
            self.dialogueController.dismiss()
            self.presentDeferredAnnouncementsIfPossible()
        }
        bubbleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func cancelTemporaryMessage() {
        bubbleWorkItem?.cancel()
        bubbleWorkItem = nil
        temporaryMessageGeneration &+= 1
    }

    private func dialogueStyle(for action: PetAction) -> DialogueStyle {
        switch action {
        case .think:
            return .thought
        case .sweat, .dizzy, .spinning:
            return .nervous
        case .slam, .decisiveEvidence:
            return .courtroom
        case .badgeToss:
            return .badge
        case .magatama:
            return .spiritual
        case .afraidDark:
            return .darkWhisper
        case .flashlight:
            return .flashlight
        case .heldStruggle, .hairStruggle, .armStruggle, .legStruggle, .thrown:
            return .dragProtest
        case .heldResigned, .hairResigned, .armResigned, .legResigned:
            return .resigned
        case .heardName:
            return .heardName
        case .dropped, .impact:
            return .impact
        case .idle, .objection, .evidence, .sleepy, .stepladder, .thinker,
             .dusting, .irritated:
            return .friendly
        }
    }

    private func animate(_ action: PetAction) {
        guard let layer = imageView.layer else { return }
        layer.removeAllAnimations()
        layer.setAffineTransform(.identity)

        switch action {
        case .idle:
            let bob = CABasicAnimation(keyPath: "transform.translation.y")
            bob.fromValue = 0
            bob.toValue = 1.5
            bob.duration = 2.4
            bob.autoreverses = true
            bob.repeatCount = .infinity
            bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(bob, forKey: "idle-bob")

        case .think:
            addKeyframes(keyPath: "transform.rotation.z", values: [0, 0.035, -0.015, 0.025, 0], duration: 1.1)

        case .objection:
            addKeyframes(keyPath: "transform.translation.x", values: [-12, 5, -2, 0], duration: 0.34)
            addKeyframes(keyPath: "transform.scale", values: [0.90, 1.09, 0.98, 1.0], duration: 0.42)

        case .slam:
            addKeyframes(keyPath: "transform.translation.y", values: [18, -16, 5, -7, 0], duration: 0.48)

        case .sweat:
            addKeyframes(keyPath: "transform.translation.x", values: [0, -9, 9, -7, 7, -4, 4, 0], duration: 0.62)

        case .evidence:
            addKeyframes(keyPath: "transform.rotation.z", values: [-0.025, 0.025, -0.01, 0], duration: 0.72)
            addKeyframes(keyPath: "transform.translation.y", values: [0, 5, 1, 0], duration: 0.72)

        case .heldStruggle:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.08, 0.08, -0.06, 0.06, 0],
                duration: 0.42,
                repeatCount: .infinity
            )
            addKeyframes(
                keyPath: "transform.translation.x",
                values: [-4, 4, -3, 3, 0],
                duration: 0.28,
                repeatCount: .infinity
            )

        case .heldResigned:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.035, 0.035],
                duration: 1.0,
                repeatCount: .infinity,
                autoreverses: true
            )

        case .hairStruggle:
            addKeyframes(
                keyPath: "transform.translation.y",
                values: [-5, 4, -4, 3, 0],
                duration: 0.30,
                repeatCount: .infinity
            )
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.045, 0.045, 0],
                duration: 0.32,
                repeatCount: .infinity
            )

        case .hairResigned:
            addKeyframes(
                keyPath: "transform.translation.y",
                values: [-1, 2],
                duration: 1.2,
                repeatCount: .infinity,
                autoreverses: true
            )

        case .armStruggle:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.13, 0.12, -0.08, 0.07, 0],
                duration: 0.48,
                repeatCount: .infinity
            )

        case .armResigned:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.055, 0.055],
                duration: 1.05,
                repeatCount: .infinity,
                autoreverses: true
            )

        case .legStruggle:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.09, 0.09, -0.06, 0.06, 0],
                duration: 0.40,
                repeatCount: .infinity
            )
            addKeyframes(
                keyPath: "transform.translation.x",
                values: [-4, 4, -3, 3, 0],
                duration: 0.30,
                repeatCount: .infinity
            )

        case .legResigned:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.04, 0.04],
                duration: 1.15,
                repeatCount: .infinity,
                autoreverses: true
            )

        case .afraidDark:
            addKeyframes(
                keyPath: "transform.translation.x",
                values: [-3, 3, -2, 2, 0],
                duration: 0.34,
                repeatCount: 4
            )

        case .flashlight:
            addKeyframes(keyPath: "transform.rotation.z", values: [-0.025, 0.02, 0], duration: 0.7)

        case .sleepy:
            addKeyframes(
                keyPath: "transform.translation.y",
                values: [2, -3, 1, -2, 0],
                duration: 1.45,
                repeatCount: 2
            )

        case .dropped:
            addKeyframes(keyPath: "transform.translation.y", values: [12, -7, 4, 0], duration: 0.46)

        case .badgeToss:
            addKeyframes(keyPath: "transform.scale", values: [0.94, 1.07, 1.0], duration: 0.45)
            addKeyframes(keyPath: "transform.rotation.z", values: [-0.04, 0.03, 0], duration: 0.45)

        case .magatama:
            addKeyframes(keyPath: "transform.translation.y", values: [0, 4, 0], duration: 0.8)

        case .stepladder:
            addKeyframes(keyPath: "transform.translation.x", values: [-4, 4, -2, 0], duration: 0.5)

        case .thinker:
            addKeyframes(keyPath: "transform.translation.y", values: [-2, 5, 0], duration: 0.55)

        case .heardName:
            addKeyframes(keyPath: "transform.scale", values: [0.94, 1.08, 1.0], duration: 0.42)

        case .decisiveEvidence:
            addKeyframes(keyPath: "transform.translation.x", values: [-8, 3, 0], duration: 0.36)
            addKeyframes(keyPath: "transform.scale", values: [0.96, 1.05, 1.0], duration: 0.42)

        case .thrown:
            addKeyframes(keyPath: "transform.scale", values: [0.96, 1.02, 1.0], duration: 0.28)

        case .spinning:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.12, 0.10, -0.07, 0.04, 0],
                duration: 0.58
            )

        case .impact:
            addKeyframes(
                keyPath: "transform.translation.x",
                values: [-11, 7, -4, 2, 0],
                duration: 0.28
            )
            addKeyframes(
                keyPath: "transform.scale",
                values: [1.0, 0.91, 1.04, 1.0],
                duration: 0.32
            )

        case .dizzy:
            addKeyframes(
                keyPath: "transform.rotation.z",
                values: [-0.055, 0.055],
                duration: 0.72,
                repeatCount: 3,
                autoreverses: true
            )

        case .dusting:
            addKeyframes(
                keyPath: "transform.translation.x",
                values: [0, -3, 4, -2, 2, 0],
                duration: 0.55,
                repeatCount: 2
            )

        case .irritated:
            addKeyframes(
                keyPath: "transform.translation.y",
                values: [0, 5, -2, 0],
                duration: 0.42
            )
            addKeyframes(
                keyPath: "transform.scale",
                values: [0.97, 1.06, 1.0],
                duration: 0.46
            )
        }
    }

    private func addKeyframes(
        keyPath: String,
        values: [CGFloat],
        duration: TimeInterval,
        repeatCount: Float = 0,
        autoreverses: Bool = false,
        holdFinalValue: Bool = false
    ) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.repeatCount = repeatCount
        animation.autoreverses = autoreverses
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if holdFinalValue {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        imageView.layer?.add(animation, forKey: keyPath)
    }
}
