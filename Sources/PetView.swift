import AppKit
import QuartzCore

final class PetView: NSView {
    private let imageView = NSImageView()
    private let bubbleView = SpeechBubbleView()
    private let objectionBurstView = ObjectionBurstView(frame: .zero)
    private let dialogueController = DialoguePresentationController()
    private let followUpHotspotView = FollowUpHotspotView(frame: .zero)
    private let followUpChoiceView = FollowUpChoiceView(frame: .zero)
    private let images: [PetAction: NSImage]
    private let chatNameListener = ChatNameListener()
    private let courtRecordStore = CourtRecordStore.shared
    private let dragVelocityTracker = DragVelocityTracker()
    private let shakeGestureDetector = ShakeGestureDetector()
    private let accessoryScatterController = AccessoryScatterController()

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
    private var idleScheduler: IdleBehaviorScheduler!
    private var throwPhysicsController: ThrowPhysicsController?
    private var courtRecordPanelController: CourtRecordPanelController?
    private var dailyCasePanelController: DailyCasePanelController?
    private var petTrackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var followUpOriginAction: PetAction?
    private var accessoryImages: [NSImage] = []
    private var lastThrowImpactTimestamp: TimeInterval = 0
    private var lastNameListenerStatus: ChatNameListener.Status = .stopped
    private var environmentDetectionGeneration = 0

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
        addSubview(imageView)
        addSubview(bubbleView)
        addSubview(followUpHotspotView)
        addSubview(followUpChoiceView)

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

        accessoryImages = Self.loadAccessoryImages()

        showIdle()
        showTemporaryMessage("单击随机动作 · 双击异议 · 右键菜单", duration: 4.0)

        idleScheduler = IdleBehaviorScheduler { [weak self] in
            guard let self else { return false }
            return self.currentAction == .idle
                && self.interactionMode == .ordinary
                && !self.didDrag
        }
        idleScheduler.onIdleOpportunity = { [weak self] in
            guard let action = PetAction.lowFrequencyIdleActions.randomElement() else { return }
            self?.performAmbientIdleAction(action)
        }
        idleScheduler.start()

        chatNameListener.onNameDetected = { [weak self] in
            guard let self, !self.didDrag else { return }
            self.cancelFollowUp(returnToIdle: false)
            self.courtRecordStore.record(CourtRecordID.nameResponse)
            self.perform(.heardName, countAsInteraction: true)
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
        idleScheduler?.stop()
        resetWorkItem?.cancel()
        bubbleWorkItem?.cancel()
        clickWorkItem?.cancel()
        dragResignWorkItem?.cancel()
        environmentWorkItem?.cancel()
        followUpExpirationWorkItem?.cancel()
        followUpSequenceWorkItems.forEach { $0.cancel() }
        throwRecoveryWorkItems.forEach { $0.cancel() }
        throwPhysicsController?.cancel()
        shakeGestureDetector.cancelCurrentGrab()
        accessoryScatterController.cancelAndRemoveAll()
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
        controller.onStarted = { [weak self] state in
            guard let self else { return }
            self.cancelThrowRecovery()
            self.courtRecordStore.record(CourtRecordID.thrown)
            self.perform(
                .thrown,
                autoReset: false,
                messageOverride: PetAction.thrown.phrase,
                countAsInteraction: true
            )
            self.applyThrowPose(state)
        }
        controller.onUpdated = { [weak self] state in
            guard let self, self.currentAction == .thrown else { return }
            self.applyThrowPose(state)
        }
        controller.onBounce = { [weak self, weak controller] _, _ in
            guard let self, let controller, controller.isRunning else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastThrowImpactTimestamp >= 0.28 else { return }
            self.lastThrowImpactTimestamp = now
            self.perform(.impact, autoReset: false)
            self.scheduleThrowRecovery(after: 0.30) { [weak self, weak controller] in
                guard let self, let controller, controller.isRunning else { return }
                self.perform(.thrown, autoReset: false, messageOverride: "好痛……！")
                self.applyThrowPose(
                    ThrowPhysicsController.MotionState(
                        velocity: controller.velocity,
                        normalizedVelocity: controller.normalizedVelocity,
                        normalizedSpeed: controller.normalizedSpeed,
                        normalizedRotation: controller.normalizedRotation,
                        windowFrame: self.window?.frame ?? .zero
                    )
                )
            }
        }
        controller.onSettled = { [weak self] _ in
            self?.beginThrowLandingRecovery()
        }
        throwPhysicsController = controller
    }

    override func layout() {
        super.layout()
        // 顶部留出独立字幕区，任何普通台词都不覆盖人物本体。
        imageView.frame = NSRect(x: 18, y: 0, width: bounds.width - 36, height: 180)
        bubbleView.frame = NSRect(x: 8, y: bounds.height - 51, width: bounds.width - 16, height: 49)
        followUpHotspotView.frame = NSRect(x: bounds.midX + 31, y: 145, width: 25, height: 25)
        followUpChoiceView.frame = NSRect(x: 8, y: 3, width: bounds.width - 16, height: 35)
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
        guard interactionMode != .casePanel, interactionMode != .courtRecordPanel else { return }
        clickWorkItem?.cancel()
        environmentWorkItem?.cancel()
        environmentDetectionGeneration &+= 1
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
            return
        }

        let wasBeingThrown = throwPhysicsController?.isRunning == true
        if wasBeingThrown {
            throwPhysicsController?.cancel()
            showIdle(mode: .mousePressed)
        }
        cancelThrowRecovery()

        idleScheduler.noteUserInteraction()
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
            guard let action = PetAction.interactiveActions.randomElement() else { return }
            self?.perform(action, countAsInteraction: true)
        }
        clickWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
        activeGrabRegion = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        clickWorkItem?.cancel()
        cancelFollowUp(returnToIdle: true)
        closeOpenFeaturePanels()
        idleScheduler.noteUserInteraction()
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

        menu.addItem(.separator())
        let courtRecordItem = NSMenuItem(
            title: "法庭记录…",
            action: #selector(showCourtRecord),
            keyEquivalent: ""
        )
        courtRecordItem.target = self
        menu.addItem(courtRecordItem)

        let dailyCaseItem = NSMenuItem(
            title: "接受委托…",
            action: #selector(showDailyCase),
            keyEquivalent: ""
        )
        dailyCaseItem.target = self
        menu.addItem(dailyCaseItem)

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

        NSMenu.popUpContextMenu(menu, with: event, for: self)
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
        guard let action = PetAction.interactiveActions.randomElement() else { return }
        perform(action, countAsInteraction: true)
    }

    @objc private func showHelp() {
        cancelFollowUp(returnToIdle: false)
        showIdle()
        idleScheduler.noteUserInteraction()
        showTemporaryMessage("单击随机 · 双击异议 · 拖动搬家", duration: 3.5)
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
        dailyCasePanelController?.close()
        dailyCasePanelController = nil
        idleScheduler.noteUserInteraction()

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
        idleScheduler.noteUserInteraction()
        let granted = BackgroundBrightnessDetector.shared.requestPermission()
        showTemporaryMessage(
            granted
                ? "背景感知已授权，只会在落地时读取一小块区域。"
                : "请在系统设置中允许录屏；之后拖到深色窗口即可测试。",
            duration: 5.0
        )
    }

    @objc private func showDailyCase() {
        cancelFollowUp(returnToIdle: true)
        courtRecordPanelController?.close()
        courtRecordPanelController = nil
        dailyCasePanelController?.close()
        dailyCasePanelController = nil
        idleScheduler.noteUserInteraction()

        let dailyCase = DailyCaseLibrary.caseForToday()
        courtRecordStore.record(CourtRecordID.dailyCase)
        let recordID = CourtRecordID.caseCompletion(dailyCase.id)
        let controller = DailyCasePanelController(
            dailyCase: dailyCase,
            isPreviouslyCompleted: courtRecordStore.discoveredAt(for: recordID) != nil
        )
        controller.onIncorrect = { [weak self] _ in
            guard let self else { return }
            self.perform(
                .sweat,
                messageOverride: "这还不是直接矛盾，再换一组试试。",
                countAsInteraction: true,
                mode: .casePanel
            )
        }
        controller.onCorrect = { [weak self, weak controller] solvedCase in
            guard let self else { return }
            if self.dailyCasePanelController === controller {
                self.dailyCasePanelController = nil
            }
            self.courtRecordStore.record(CourtRecordID.caseCompletion(solvedCase.id))
            self.perform(.objection, countAsInteraction: true, mode: .objectionBurst)
        }
        controller.isCasePreviouslyCompleted = { [weak self] candidate in
            self?.courtRecordStore.discoveredAt(
                for: CourtRecordID.caseCompletion(candidate.id)
            ) != nil
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            if self.dailyCasePanelController === controller {
                self.dailyCasePanelController = nil
            }
            if self.interactionMode == .casePanel {
                self.showIdle()
            }
        }
        dailyCasePanelController = controller
        showIdle(mode: .casePanel)
        controller.show(relativeTo: window)
    }

    @objc private func quitApplication() {
        cancelFollowUp(returnToIdle: false)
        NSApp.terminate(nil)
    }

    /// 仅供本地构建验收时通过启动参数直接预览指定动作。
    func preview(_ action: PetAction) {
        NSLog("桌宠执行预览动作：%@", action.rawValue)
        perform(action)
    }

    private func perform(
        _ action: PetAction,
        autoReset: Bool = true,
        messageOverride: String? = nil,
        countAsInteraction: Bool = false,
        mode: PetInteractionMode? = nil
    ) {
        if countAsInteraction {
            idleScheduler.noteUserInteraction()
        }
        resetWorkItem?.cancel()
        bubbleWorkItem?.cancel()
        let nextMode = mode ?? (action == .objection ? .objectionBurst : .action)
        transition(to: nextMode)
        currentAction = action
        imageView.image = images[action]
        animate(action)

        if let recordID = CourtRecordID.action(action) {
            courtRecordStore.record(recordID)
        }

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
            case .casePanel:
                self.showIdle(mode: .casePanel)
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
        transition(to: mode)
        currentAction = .idle
        imageView.image = images[.idle]
        objectionBurstView.hide()
        bubbleView.hide()
        dialogueController.dismiss()
        animate(.idle)
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
        idleScheduler.noteUserInteraction()
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
        transition(to: .followUpBranch)
        idleScheduler.noteUserInteraction()

        switch branch {
        case .askAboutCase:
            perform(
                .evidence,
                autoReset: false,
                messageOverride: "先锁定证言里最不自然的那一句。",
                mode: .followUpBranch
            )
            scheduleFollowUpStep(after: 5.2) { [weak self] in
                self?.perform(
                    .decisiveEvidence,
                    autoReset: false,
                    messageOverride: "观察条件对不上——突破口就在这里。",
                    mode: .followUpBranch
                )
            }

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
        }

        scheduleFollowUpStep(after: 11.4) { [weak self] in
            self?.cancelFollowUp(returnToIdle: true)
        }
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
        let hadFollowUp = interactionMode.isFollowUp || followUpOriginAction != nil
        followUpExpirationWorkItem?.cancel()
        followUpExpirationWorkItem = nil
        followUpSequenceWorkItems.forEach { $0.cancel() }
        followUpSequenceWorkItems.removeAll()
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
        interactionMode = mode
        if mode != .followUpPending {
            followUpHotspotView.isHidden = true
        }
        if mode != .followUpChoosing {
            followUpChoiceView.isHidden = true
        }
    }

    private func closeOpenFeaturePanels() {
        if let controller = dailyCasePanelController {
            dailyCasePanelController = nil
            controller.close()
        }
        if let controller = courtRecordPanelController {
            courtRecordPanelController = nil
            controller.close()
        }
        if interactionMode == .casePanel || interactionMode == .courtRecordPanel {
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
        perform(actions.struggle, autoReset: false, mode: .dragging)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.didDrag else { return }
            self.perform(actions.resigned, autoReset: false, mode: .dragging)
        }
        dragResignWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: workItem)
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

    private func triggerAccessoryScatter() {
        guard
            !accessoryImages.isEmpty,
            let window,
            let screen = window.screen ?? NSScreen.screens.first
        else { return }

        guard accessoryScatterController.scatter(
            images: accessoryImages,
            from: window.frame,
            on: screen
        ) else { return }

        courtRecordStore.record(CourtRecordID.upsideDownScatter)
        perform(
            .legStruggle,
            autoReset: false,
            messageOverride: "等一下！我的证物都掉出来了！",
            countAsInteraction: true,
            mode: .dragging
        )
    }

    private func beginThrowLandingRecovery() {
        cancelThrowRecovery()
        perform(.dizzy, autoReset: false, countAsInteraction: true)
        scheduleThrowRecovery(after: 2.2) { [weak self] in
            self?.perform(.dusting, autoReset: false)
        }
        scheduleThrowRecovery(after: 3.7) { [weak self] in
            self?.perform(.irritated, autoReset: false)
        }
        scheduleThrowRecovery(after: 5.7) { [weak self] in
            self?.showIdle()
        }
    }

    private func applyThrowPose(_ state: ThrowPhysicsController.MotionState) {
        guard let layer = imageView.layer else { return }
        let directionScale: CGFloat = state.velocity.dx < -80 ? -1 : 1
        let lean = max(
            -0.12,
            min(0.12, state.normalizedVelocity.dy * 0.045 - state.normalizedVelocity.dx * 0.07)
        )
        var transform = CGAffineTransform(scaleX: directionScale, y: 1)
        transform = transform.rotated(by: lean)
        layer.setAffineTransform(transform)
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

            self.courtRecordStore.record(CourtRecordID.darkPlace)
            self.perform(.afraidDark, autoReset: false, countAsInteraction: true)
            let workItem = DispatchWorkItem { [weak self] in
                guard
                    let self,
                    self.environmentDetectionGeneration == generation,
                    !self.didDrag,
                    self.currentAction == .afraidDark
                else { return }
                self.perform(.flashlight)
            }
            self.environmentWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: workItem)
        }
    }

    private func showTemporaryMessage(_ text: String, duration: TimeInterval) {
        bubbleWorkItem?.cancel()
        bubbleView.hide()
        dialogueController.show(
            text: text,
            style: .friendly,
            in: self,
            duration: duration
        )
        let workItem = DispatchWorkItem { [weak self] in
            self?.dialogueController.dismiss()
        }
        bubbleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
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
        autoreverses: Bool = false
    ) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.repeatCount = repeatCount
        animation.autoreverses = autoreverses
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer?.add(animation, forKey: keyPath)
    }
}
