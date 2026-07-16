import AppKit

private final class FollowUpControl: NSView {
    enum Style {
        case hotspot
        case choice
        case close
    }

    var onActivate: (() -> Void)?
    var onRightMouseDown: ((NSEvent) -> Void)?
    var onDragBegan: ((NSEvent, NSEvent) -> Void)?
    var onDragChanged: ((NSEvent) -> Void)?
    var onDragEnded: ((NSEvent) -> Void)?

    private let title: String
    private let style: Style
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var mouseDownPoint: NSPoint?
    private var mouseDownEvent: NSEvent?
    private var isForwardingDrag = false

    init(title: String, style: Style, accessibilityLabel: String) {
        self.title = title
        self.style = style
        super.init(frame: .zero)

        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.02, hitPath.contains(point) else { return nil }
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if mouseDownEvent == nil {
            isPressed = false
            mouseDownPoint = nil
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else { return }
        isPressed = true
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownEvent = event
        isForwardingDrag = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if isForwardingDrag {
            onDragChanged?(event)
            return
        }
        guard let mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) > 3,
              let mouseDownEvent else { return }
        isPressed = false
        isForwardingDrag = true
        needsDisplay = true
        onDragBegan?(mouseDownEvent, event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            isPressed = false
            mouseDownPoint = nil
            mouseDownEvent = nil
            isForwardingDrag = false
            needsDisplay = true
        }
        if isForwardingDrag {
            onDragEnded?(event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        guard isPressed, hitPath.contains(point) else { return }
        onActivate?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let path = hitPath
        NSGraphicsContext.saveGraphicsState()

        if style == .hotspot {
            NSColor.black.withAlphaComponent(0.16).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 0.5).offsetBy(dx: 0, dy: -1)).fill()
        }

        fillColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = style == .hotspot ? 1.25 : 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph
        ]
        let textSize = title.size(withAttributes: attributes)
        let textRect = NSRect(
            x: bounds.minX,
            y: floor(bounds.midY - textSize.height / 2) + textBaselineAdjustment,
            width: bounds.width,
            height: ceil(textSize.height)
        )
        title.draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private var hitPath: NSBezierPath {
        switch style {
        case .hotspot:
            return NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
        case .choice:
            return NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        case .close:
            return NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        }
    }

    private var fillColor: NSColor {
        switch style {
        case .hotspot:
            if isPressed { return NSColor.systemRed.withAlphaComponent(0.92) }
            if isHovered { return NSColor.white.withAlphaComponent(0.98) }
            return NSColor.white.withAlphaComponent(0.88)
        case .choice:
            if isPressed { return NSColor.controlAccentColor.withAlphaComponent(0.24) }
            if isHovered { return NSColor.controlAccentColor.withAlphaComponent(0.13) }
            return NSColor.controlBackgroundColor.withAlphaComponent(0.92)
        case .close:
            if isPressed { return NSColor.systemRed.withAlphaComponent(0.30) }
            if isHovered { return NSColor.systemRed.withAlphaComponent(0.16) }
            return NSColor.clear
        }
    }

    private var borderColor: NSColor {
        switch style {
        case .hotspot:
            return NSColor.systemRed.withAlphaComponent(isHovered ? 0.82 : 0.58)
        case .choice:
            return NSColor.separatorColor.withAlphaComponent(0.78)
        case .close:
            return NSColor.separatorColor.withAlphaComponent(isHovered ? 0.62 : 0.30)
        }
    }

    private var textColor: NSColor {
        if style == .hotspot, isPressed {
            return .white
        }
        return style == .close ? .secondaryLabelColor : .labelColor
    }

    private var font: NSFont {
        switch style {
        case .hotspot:
            return .systemFont(ofSize: 13, weight: .black)
        case .choice:
            return .systemFont(ofSize: 11, weight: .semibold)
        case .close:
            return .systemFont(ofSize: 13, weight: .medium)
        }
    }

    private var textBaselineAdjustment: CGFloat {
        style == .hotspot ? 0.5 : 0
    }
}

final class FollowUpHotspotView: NSView {
    var onActivate: (() -> Void)?
    var onRightMouseDown: ((NSEvent) -> Void)?

    private let control = FollowUpControl(
        title: "?",
        style: .hotspot,
        accessibilityLabel: "追问刚才的想法"
    )
    private var visibilityGeneration = 0
    private var acceptsPointerEvents = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.isHidden = true
        alphaValue = 0

        control.onActivate = { [weak self] in
            self?.onActivate?()
        }
        control.onRightMouseDown = { [weak self] event in
            self?.onRightMouseDown?(event)
        }
        control.onDragBegan = { [weak self] mouseDownEvent, dragEvent in
            guard let self else { return }
            self.isHidden = true
            self.superview?.mouseDown(with: mouseDownEvent)
            self.superview?.mouseDragged(with: dragEvent)
        }
        control.onDragChanged = { [weak self] event in
            self?.superview?.mouseDragged(with: event)
        }
        control.onDragEnded = { [weak self] event in
            self?.superview?.mouseUp(with: event)
        }
        addSubview(control)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override var isHidden: Bool {
        get { super.isHidden }
        set { setHidden(newValue, animated: window != nil) }
    }

    override func layout() {
        super.layout()
        control.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard acceptsPointerEvents, !super.isHidden, alphaValue > 0.02 else { return nil }
        let controlPoint = control.convert(point, from: self)
        return control.hitTest(controlPoint)
    }

    private func setHidden(_ hidden: Bool, animated: Bool) {
        visibilityGeneration += 1
        let generation = visibilityGeneration

        if !hidden {
            acceptsPointerEvents = true
            super.isHidden = false
            alphaValue = animated ? 0 : 1
            guard animated else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
            return
        }

        acceptsPointerEvents = false
        guard !super.isHidden else {
            alphaValue = 0
            return
        }
        guard animated else {
            alphaValue = 0
            super.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.alphaValue = 0
            self.superview?.needsDisplay = true
            self.setActuallyHidden()
        }
    }

    private func setActuallyHidden() {
        super.isHidden = true
    }
}

final class FollowUpChoiceView: NSView {
    var onChoose: ((FollowUpBranch) -> Void)?
    var onCancel: (() -> Void)?
    var onRightMouseDown: ((NSEvent) -> Void)?

    private let caseButton = FollowUpControl(
        title: "追问案情",
        style: .choice,
        accessibilityLabel: "追问案情"
    )
    private let badgeButton = FollowUpControl(
        title: "出示徽章",
        style: .choice,
        accessibilityLabel: "出示律师徽章"
    )
    private let closeButton = FollowUpControl(
        title: "×",
        style: .close,
        accessibilityLabel: "暂不追问"
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.75).cgColor
        isHidden = true

        caseButton.onActivate = { [weak self] in self?.onChoose?(.askAboutCase) }
        badgeButton.onActivate = { [weak self] in self?.onChoose?(.presentBadge) }
        closeButton.onActivate = { [weak self] in self?.onCancel?() }

        for control in [caseButton, badgeButton, closeButton] {
            control.onRightMouseDown = { [weak self] event in
                self?.onRightMouseDown?(event)
            }
            control.onDragBegan = { [weak self] _, _ in
                self?.onCancel?()
            }
            addSubview(control)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: bounds.width - 26, y: 5, width: 21, height: 25)
        let availableWidth = bounds.width - 35
        let buttonWidth = (availableWidth - 5) / 2
        caseButton.frame = NSRect(x: 5, y: 5, width: buttonWidth, height: 25)
        badgeButton.frame = NSRect(x: 10 + buttonWidth, y: 5, width: buttonWidth, height: 25)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.02 else { return nil }
        for control in [closeButton, badgeButton, caseButton] {
            let controlPoint = control.convert(point, from: self)
            if let hit = control.hitTest(controlPoint) {
                return hit
            }
        }
        return nil
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(event)
    }
}
