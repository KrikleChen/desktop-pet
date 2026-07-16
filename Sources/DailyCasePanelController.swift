import AppKit

private final class DailyCasePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CaseChoiceButton: NSButton {
    var choiceID = ""
}

final class DailyCasePanelController: NSObject, NSWindowDelegate {
    var onCorrect: ((DailyCase) -> Void)?
    var onIncorrect: ((DailyCase) -> Void)?
    var onClose: (() -> Void)?
    var onStateChange: ((DailyCaseState) -> Void)?
    var onReaction: ((DailyCaseReaction) -> Void)?
    var onCaseChanged: ((DailyCase) -> Void)?
    var isCasePreviouslyCompleted: ((DailyCase) -> Bool)?

    private var dailyCase: DailyCase
    private var previouslyCompleted: Bool
    private var session: DailyCaseSession
    private let panel: DailyCasePanel
    private let introductionLabel = NSTextField(labelWithString: "")
    private let witnessLabel = NSTextField(labelWithString: "")
    private let testimonySectionLabel = NSTextField(labelWithString: "")
    private let evidenceSectionLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let primaryButton = CaseChoiceButton(
        title: "查看证言",
        target: nil,
        action: nil
    )
    private var testimonyButtons: [CaseChoiceButton] = []
    private var evidenceButtons: [CaseChoiceButton] = []
    private var didFinish = false

    init(dailyCase: DailyCase, isPreviouslyCompleted: Bool) {
        self.dailyCase = dailyCase
        previouslyCompleted = isPreviouslyCompleted
        session = DailyCaseSession(dailyCase: dailyCase)
        panel = DailyCasePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        applyCaseContent()
        renderState()
    }

    /// 只有调用方主动调用 show 才展示；没有计时器、通知或权限请求。
    func show(relativeTo owner: NSWindow?) {
        position(relativeTo: owner)
        panel.orderFrontRegardless()
        onStateChange?(session.state)
    }

    func close() {
        guard !didFinish else { return }
        didFinish = true
        panel.orderOut(nil)
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didFinish else { return }
        didFinish = true
        onClose?()
    }

    private func configurePanel() {
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        guard let content = panel.contentView else { return }

        configureLabel(
            introductionLabel,
            frame: NSRect(x: 22, y: 548, width: 576, height: 25),
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: .labelColor
        )
        content.addSubview(introductionLabel)

        configureLabel(
            witnessLabel,
            frame: NSRect(x: 22, y: 521, width: 576, height: 20),
            font: .systemFont(ofSize: 12),
            color: .secondaryLabelColor
        )
        content.addSubview(witnessLabel)

        configureLabel(
            testimonySectionLabel,
            frame: NSRect(x: 22, y: 486, width: 576, height: 22),
            font: .systemFont(ofSize: 13, weight: .bold),
            color: .labelColor
        )
        content.addSubview(testimonySectionLabel)

        for index in 0..<3 {
            let button = makeChoiceButton(action: #selector(selectTestimony(_:)))
            button.frame = NSRect(x: 26, y: 437 - CGFloat(index) * 43, width: 568, height: 36)
            content.addSubview(button)
            testimonyButtons.append(button)
        }

        configureLabel(
            evidenceSectionLabel,
            frame: NSRect(x: 22, y: 300, width: 576, height: 22),
            font: .systemFont(ofSize: 13, weight: .bold),
            color: .labelColor
        )
        content.addSubview(evidenceSectionLabel)

        for index in 0..<3 {
            let button = makeChoiceButton(action: #selector(selectEvidence(_:)))
            button.frame = NSRect(x: 26, y: 251 - CGFloat(index) * 43, width: 568, height: 36)
            content.addSubview(button)
            evidenceButtons.append(button)
        }

        statusLabel.frame = NSRect(x: 26, y: 91, width: 568, height: 38)
        statusLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.refusesFirstResponder = true
        content.addSubview(statusLabel)

        let nextButton = CaseChoiceButton(
            title: "换一案",
            target: self,
            action: #selector(showNextCase)
        )
        nextButton.frame = NSRect(x: 22, y: 30, width: 90, height: 36)
        styleCommandButton(nextButton, emphasized: false)
        content.addSubview(nextButton)

        primaryButton.target = self
        primaryButton.action = #selector(performPrimaryAction)
        primaryButton.frame = NSRect(x: 365, y: 30, width: 140, height: 36)
        styleCommandButton(primaryButton, emphasized: true)
        content.addSubview(primaryButton)

        let cancelButton = CaseChoiceButton(
            title: "取消",
            target: self,
            action: #selector(cancel)
        )
        cancelButton.frame = NSRect(x: 513, y: 30, width: 82, height: 36)
        styleCommandButton(cancelButton, emphasized: false)
        content.addSubview(cancelButton)
    }

    private func configureLabel(
        _ label: NSTextField,
        frame: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        label.frame = frame
        label.font = font
        label.textColor = color
        label.refusesFirstResponder = true
    }

    private func makeChoiceButton(action: Selector) -> CaseChoiceButton {
        let button = CaseChoiceButton(title: "", target: self, action: action)
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.alignment = .left
        button.font = .systemFont(ofSize: 12.5)
        button.focusRingType = .none
        button.keyEquivalent = ""
        button.refusesFirstResponder = true
        return button
    }

    private func styleCommandButton(_ button: NSButton, emphasized: Bool) {
        button.bezelStyle = .rounded
        button.keyEquivalent = ""
        button.font = .systemFont(
            ofSize: emphasized ? 14 : 13,
            weight: emphasized ? .semibold : .regular
        )
        button.focusRingType = .none
        button.refusesFirstResponder = true
    }

    private func applyCaseContent() {
        panel.title = "今日一案 · \(dailyCase.title)"
        introductionLabel.stringValue = "委托：\(dailyCase.introduction)"
        let replayText = previouslyCompleted ? " · 已完成，可重玩" : ""
        witnessLabel.stringValue = "证人：\(dailyCase.witness)\(replayText)"

        for (button, testimony) in zip(testimonyButtons, dailyCase.testimony) {
            button.title = testimony.text
            button.choiceID = testimony.id
            button.state = .off
        }
        for (button, evidence) in zip(evidenceButtons, dailyCase.evidence) {
            button.title = "\(evidence.name)  ·  \(evidence.detail)"
            button.choiceID = evidence.id
            button.state = .off
        }
    }

    private func renderState() {
        let state = session.state
        let canChooseTestimony = [.testimony, .evidenceSelection, .wrong].contains(state)
        let canChooseEvidence = [.evidenceSelection, .wrong].contains(state)

        testimonySectionLabel.stringValue = state == .briefing
            ? "第一步 · 阅读案情"
            : "第一步 · 选择有矛盾的证言"
        evidenceSectionLabel.stringValue = "第二步 · 选择决定性证物"

        testimonyButtons.forEach { $0.isEnabled = canChooseTestimony }
        evidenceButtons.forEach { $0.isEnabled = canChooseEvidence }

        switch state {
        case .briefing:
            statusLabel.stringValue = "这是主动开启的小案件。准备好后查看三句证言。"
            statusLabel.textColor = .secondaryLabelColor
            primaryButton.title = "查看证言"
            primaryButton.isEnabled = true
        case .testimony:
            statusLabel.stringValue = "先选出唯一一句存在矛盾的证言。"
            statusLabel.textColor = .secondaryLabelColor
            primaryButton.title = "先选证言"
            primaryButton.isEnabled = false
        case .evidenceSelection:
            statusLabel.stringValue = session.selectedEvidenceID == nil
                ? "证言已锁定。请选择能直接推翻它的证物。"
                : "证言和证物均已选择，准备好就出示。"
            statusLabel.textColor = .secondaryLabelColor
            primaryButton.title = "出示证物"
            primaryButton.isEnabled = session.selectedEvidenceID != nil
        case .wrong:
            statusLabel.stringValue = "这组证言与证物还不能形成直接矛盾。改选后可立即重试。"
            statusLabel.textColor = .systemOrange
            primaryButton.title = "重新出示"
            primaryButton.isEnabled = true
        case .correct:
            statusLabel.stringValue = dailyCase.resolution
            statusLabel.textColor = .systemGreen
            primaryButton.title = "异议成立"
            primaryButton.isEnabled = false
        case .completed:
            primaryButton.isEnabled = false
        }
    }

    private func notifyStateChange() {
        renderState()
        onStateChange?(session.state)
    }

    @objc private func selectTestimony(_ sender: CaseChoiceButton) {
        guard session.selectTestimony(id: sender.choiceID) else { return }
        updateSelection(
            buttons: testimonyButtons,
            selectedID: session.selectedTestimonyID
        )
        updateSelection(buttons: evidenceButtons, selectedID: nil)
        notifyStateChange()
    }

    @objc private func selectEvidence(_ sender: CaseChoiceButton) {
        guard session.selectEvidence(id: sender.choiceID) else { return }
        updateSelection(
            buttons: evidenceButtons,
            selectedID: session.selectedEvidenceID
        )
        notifyStateChange()
    }

    private func updateSelection(buttons: [CaseChoiceButton], selectedID: String?) {
        for button in buttons {
            button.state = button.choiceID == selectedID ? .on : .off
        }
    }

    @objc private func performPrimaryAction() {
        if session.state == .briefing {
            if session.begin() {
                notifyStateChange()
            }
            return
        }

        guard let evaluation = session.evaluate() else { return }
        notifyStateChange()

        evaluation.reactions.forEach { onReaction?($0) }

        if evaluation.state == .correct {
            _ = session.complete()
            onStateChange?(session.state)
            didFinish = true
            panel.orderOut(nil)
            onCorrect?(dailyCase)
        } else {
            onIncorrect?(dailyCase)
        }
    }

    @objc private func showNextCase() {
        dailyCase = DailyCaseLibrary.nextCase(after: dailyCase)
        previouslyCompleted = isCasePreviouslyCompleted?(dailyCase) ?? false
        session = DailyCaseSession(dailyCase: dailyCase)
        applyCaseContent()
        notifyStateChange()
        onCaseChanged?(dailyCase)
    }

    @objc private func cancel() {
        close()
    }

    private func position(relativeTo owner: NSWindow?) {
        guard let owner else {
            panel.center()
            return
        }
        let screenFrame = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: owner.frame.midX - panel.frame.width / 2,
            y: owner.frame.midY - panel.frame.height / 2
        )
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
    }
}
