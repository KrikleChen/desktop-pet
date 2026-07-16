import AppKit
import QuartzCore

final class PetView: NSView {
    private let imageView = NSImageView()
    private let bubbleView = SpeechBubbleView()
    private let objectionBurstView = ObjectionBurstView(frame: .zero)
    private let followUpHotspotView = FollowUpHotspotView(frame: .zero)
    private let followUpChoiceView = FollowUpChoiceView(frame: .zero)
    private let images: [PetAction: NSImage]
    private let chatNameListener = ChatNameListener()
    private let courtRecordStore = CourtRecordStore.shared

    private var currentAction: PetAction = .idle
    private var interactionMode: PetInteractionMode = .ordinary
    private var resetWorkItem: DispatchWorkItem?
    private var bubbleWorkItem: DispatchWorkItem?
    private var clickWorkItem: DispatchWorkItem?
    private var dragResignWorkItem: DispatchWorkItem?
    private var environmentWorkItem: DispatchWorkItem?
    private var followUpExpirationWorkItem: DispatchWorkItem?
    private var followUpSequenceWorkItems: [DispatchWorkItem] = []
    private var idleScheduler: IdleBehaviorScheduler!
    private var courtRecordPanelController: CourtRecordPanelController?
    private var dailyCasePanelController: DailyCasePanelController?
    private var petTrackingArea: NSTrackingArea?
    private var isMouseInside = false
    private var followUpOriginAction: PetAction?

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
            self.courtRecordStore.discover(CourtRecordID.nameResponse)
            self.perform(.heardName, countAsInteraction: true)
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
    }

    override func layout() {
        super.layout()
        imageView.frame = NSRect(x: 6, y: 0, width: bounds.width - 12, height: bounds.height - 40)
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

        idleScheduler.noteUserInteraction()
        transition(to: .mousePressed)
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginOnMouseDown = window?.frame.origin ?? .zero
        didDrag = false
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
        window.setFrameOrigin(NSPoint(
            x: windowOriginOnMouseDown.x + deltaX,
            y: windowOriginOnMouseDown.y + deltaY
        ))

    }

    override func mouseUp(with event: NSEvent) {
        guard activeGrabRegion != nil else { return }
        NSCursor.openHand.set()

        if didDrag {
            dragResignWorkItem?.cancel()
            imageView.layer?.setAffineTransform(.identity)
            didDrag = false
            handleDrop()
            activeGrabRegion = nil
            return
        }

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

        let listenerTitle = chatNameListener.isRunning
            ? "关闭聊天名字监听"
            : "开启聊天名字监听…"
        let listenerItem = NSMenuItem(
            title: listenerTitle,
            action: #selector(toggleChatNameListener),
            keyEquivalent: ""
        )
        listenerItem.target = self
        listenerItem.state = chatNameListener.isRunning ? .on : .off
        menu.addItem(listenerItem)

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
        if chatNameListener.isRunning {
            chatNameListener.stop()
            UserDefaults.standard.set(false, forKey: "chatNameListeningEnabled")
            showTemporaryMessage("已关闭名字监听。", duration: 2.0)
            return
        }

        if chatNameListener.start(promptIfNeeded: true) {
            UserDefaults.standard.set(true, forKey: "chatNameListeningEnabled")
            perform(.heardName, messageOverride: "听到名字，我就会回应。", countAsInteraction: true)
        } else {
            UserDefaults.standard.set(true, forKey: "chatNameListeningEnabled")
            showTemporaryMessage("请在系统设置里允许“辅助功能”，再点一次。", duration: 5.0)
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

    @objc private func showDailyCase() {
        cancelFollowUp(returnToIdle: true)
        courtRecordPanelController?.close()
        courtRecordPanelController = nil
        dailyCasePanelController?.close()
        dailyCasePanelController = nil
        idleScheduler.noteUserInteraction()

        let dailyCase = DailyCaseLibrary.caseForToday()
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
            self.courtRecordStore.discover(CourtRecordID.caseCompletion(solvedCase.id))
            self.perform(.objection, countAsInteraction: true, mode: .objectionBurst)
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
            courtRecordStore.discover(recordID)
        }

        if action == .objection {
            bubbleView.hide()
            objectionBurstView.show(in: self)
        } else if let phrase = messageOverride ?? action.phrase {
            objectionBurstView.hide()
            bubbleView.show(phrase)
        } else {
            objectionBurstView.hide()
            bubbleView.hide()
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
        courtRecordStore.discover(CourtRecordID.grab(region))
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

    private func handleDrop() {
        guard let window else {
            perform(.dropped, countAsInteraction: true)
            return
        }

        let background = BackgroundBrightnessDetector.shared.detect(window: window)
        guard background.isDark else {
            perform(.dropped, countAsInteraction: true)
            return
        }

        courtRecordStore.discover(CourtRecordID.darkPlace)
        perform(.afraidDark, autoReset: false, countAsInteraction: true)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.didDrag, self.currentAction == .afraidDark else { return }
            self.perform(.flashlight)
        }
        environmentWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: workItem)
    }

    private func showTemporaryMessage(_ text: String, duration: TimeInterval) {
        bubbleWorkItem?.cancel()
        bubbleView.show(text)
        let workItem = DispatchWorkItem { [weak self] in
            self?.bubbleView.hide()
        }
        bubbleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
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
