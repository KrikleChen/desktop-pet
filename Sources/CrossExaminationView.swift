import AppKit

/// Deterministic geometry shared by the view and compile-only QA.
enum CrossExaminationViewLayout {
    struct Frames: Equatable {
        let previous: NSRect
        let next: NSRect
        let object: NSRect
        let close: NSRect

        var all: [NSRect] { [previous, next, object, close] }
    }

    static let preferredSize = NSSize(width: 224, height: 35)
    static let minimumButtonHeight: CGFloat = 25

    static func frames(in bounds: NSRect) -> Frames {
        let horizontalInset: CGFloat = 5
        let gap: CGFloat = 4
        let closeWidth: CGFloat = 26
        let buttonHeight = minimumButtonHeight
        let originY = max(bounds.minY, floor(bounds.midY - buttonHeight * 0.5))

        let usableWidth = max(
            0,
            bounds.width - horizontalInset * 2 - gap * 3 - closeWidth
        )
        let navigationWidth = floor(min(52, usableWidth * 0.28))
        let objectWidth = max(0, usableWidth - navigationWidth * 2)
        var originX = bounds.minX + horizontalInset

        let previous = NSRect(
            x: originX,
            y: originY,
            width: navigationWidth,
            height: buttonHeight
        )
        originX = previous.maxX + gap
        let next = NSRect(
            x: originX,
            y: originY,
            width: navigationWidth,
            height: buttonHeight
        )
        originX = next.maxX + gap
        let object = NSRect(
            x: originX,
            y: originY,
            width: objectWidth,
            height: buttonHeight
        )
        originX = object.maxX + gap
        let close = NSRect(
            x: originX,
            y: originY,
            width: closeWidth,
            height: buttonHeight
        )
        return Frames(previous: previous, next: next, object: object, close: close)
    }

    /// Can be called from a tiny `swiftc` smoke test without constructing a window.
    static func preferredLayoutPassesSelfCheck() -> Bool {
        let bounds = NSRect(origin: .zero, size: preferredSize)
        let result = frames(in: bounds)
        let frames = result.all
        guard frames.allSatisfy({
            $0.height >= minimumButtonHeight
                && $0.minX >= bounds.minX
                && $0.maxX <= bounds.maxX
                && $0.minY >= bounds.minY
                && $0.maxY <= bounds.maxY
        }) else {
            return false
        }

        for index in frames.indices {
            for otherIndex in frames.indices where index < otherIndex {
                if frames[index].intersects(frames[otherIndex]) {
                    return false
                }
            }
        }
        return result.previous.width >= 48
            && result.next.width >= 48
            && result.object.width >= 70
            && result.close.width >= 25
    }
}

/// Bottom-row controls for a lightweight cross-examination round.
///
/// The view owns no window and knows nothing about the game model. It deliberately
/// consumes drags inside its bounds instead of forwarding them to `PetView`, so a
/// missed button gesture cannot turn into a pet throw.
final class CrossExaminationView: NSView {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onObject: (() -> Void)?
    var onCancel: (() -> Void)?
    var onRightMouseDown: ((NSEvent) -> Void)?

    private let previousButton = CrossExaminationButton(
        title: "上一句",
        accessibilityLabel: "查看上一句证言"
    )
    private let nextButton = CrossExaminationButton(
        title: "下一句",
        accessibilityLabel: "查看下一句证言"
    )
    private let objectButton = CrossExaminationButton(
        title: "异议",
        accessibilityLabel: "对当前证言提出异议",
        emphasized: true
    )
    private let closeButton = CrossExaminationButton(
        title: "×",
        accessibilityLabel: "结束交叉询问",
        compact: true
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.75).cgColor
        super.isHidden = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("交叉询问控制")

        previousButton.onActivate = { [weak self] in self?.onPrevious?() }
        nextButton.onActivate = { [weak self] in self?.onNext?() }
        objectButton.onActivate = { [weak self] in self?.onObject?() }
        closeButton.onActivate = { [weak self] in self?.onCancel?() }

        for button in buttons {
            button.onRightMouseDown = { [weak self] event in
                self?.onRightMouseDown?(event)
            }
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        CrossExaminationViewLayout.preferredSize
    }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let frames = CrossExaminationViewLayout.frames(in: bounds)
        previousButton.frame = frames.previous
        nextButton.frame = frames.next
        objectButton.frame = frames.object
        closeButton.frame = frames.close
    }

    /// Updates only presentation state. Navigation and answer semantics remain
    /// entirely owned by the host model/controller.
    func update(
        positionText: String,
        canPrevious: Bool,
        canNext: Bool,
        feedback: String? = nil
    ) {
        previousButton.isControlEnabled = canPrevious
        nextButton.isControlEnabled = canNext

        let normalizedPosition = positionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFeedback = feedback?.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleFeedback = normalizedFeedback.flatMap { $0.isEmpty ? nil : $0 }
        let visibleTitle: String
        if let visibleFeedback {
            visibleTitle = visibleFeedback
        } else if normalizedPosition.isEmpty {
            visibleTitle = "异议"
        } else {
            visibleTitle = "异议 · \(normalizedPosition)"
        }

        objectButton.updatePresentation(
            title: visibleTitle,
            accessibilityLabel: normalizedPosition.isEmpty
                ? "对当前证言提出异议"
                : "对\(normalizedPosition)提出异议",
            accessibilityHelp: visibleFeedback
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.02, bounds.contains(point) else { return nil }
        for button in buttons.reversed() {
            let localPoint = button.convert(point, from: self)
            if let hit = button.hitTest(localPoint) {
                return hit
            }
        }
        // Consume gaps too: dragging in the control strip must never reach PetView.
        return self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(event)
    }

    private var buttons: [CrossExaminationButton] {
        [previousButton, nextButton, objectButton, closeButton]
    }
}

private final class CrossExaminationButton: NSView {
    var onActivate: (() -> Void)?
    var onRightMouseDown: ((NSEvent) -> Void)?

    var isControlEnabled = true {
        didSet {
            guard oldValue != isControlEnabled else { return }
            setAccessibilityEnabled(isControlEnabled)
            isPressed = false
            needsDisplay = true
        }
    }

    private var title: String
    private let emphasized: Bool
    private let compact: Bool
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false
    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    init(
        title: String,
        accessibilityLabel: String,
        emphasized: Bool = false,
        compact: Bool = false
    ) {
        self.title = title
        self.emphasized = emphasized
        self.compact = compact
        super.init(frame: .zero)

        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityEnabled(true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard isControlEnabled, let onActivate else { return false }
        onActivate()
        return true
    }

    func updatePresentation(
        title: String,
        accessibilityLabel: String,
        accessibilityHelp: String?
    ) {
        self.title = title
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp(accessibilityHelp)
        needsDisplay = true
    }

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
        addCursorRect(bounds, cursor: isControlEnabled ? .pointingHand : .arrow)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.02, bounds.contains(point) else { return nil }
        // Disabled controls still consume mouse input, preventing click-through drags.
        return self
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if mouseDownPoint == nil {
            isPressed = false
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, isControlEnabled else { return }
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didDrag = false
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        if hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) > 3 {
            didDrag = true
            isPressed = false
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownPoint = nil
            didDrag = false
            isPressed = false
            needsDisplay = true
        }
        let point = convert(event.locationInWindow, from: nil)
        guard isControlEnabled, isPressed, !didDrag, bounds.contains(point) else { return }
        onActivate?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightMouseDown?(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let path = compact
            ? NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            : NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: 5,
                yRadius: 5
            )
        fillColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = emphasized ? 1.4 : 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: compact
                ? NSFont.systemFont(ofSize: 13, weight: .medium)
                : NSFont.systemFont(ofSize: 10.5, weight: emphasized ? .bold : .semibold),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let textRect = bounds.insetBy(dx: compact ? 3 : 4, dy: 5)
        title.draw(in: textRect, withAttributes: attributes)
    }

    private var fillColor: NSColor {
        guard isControlEnabled else {
            return NSColor.controlBackgroundColor.withAlphaComponent(0.50)
        }
        if isPressed {
            return emphasized
                ? NSColor.systemRed.withAlphaComponent(0.38)
                : NSColor.controlAccentColor.withAlphaComponent(0.24)
        }
        if isHovered {
            return emphasized
                ? NSColor.systemRed.withAlphaComponent(0.22)
                : NSColor.controlAccentColor.withAlphaComponent(0.13)
        }
        return emphasized
            ? NSColor.systemRed.withAlphaComponent(0.12)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.94)
    }

    private var borderColor: NSColor {
        guard isControlEnabled else { return NSColor.separatorColor.withAlphaComponent(0.32) }
        return emphasized
            ? NSColor.systemRed.withAlphaComponent(isHovered ? 0.88 : 0.68)
            : NSColor.separatorColor.withAlphaComponent(0.76)
    }

    private var textColor: NSColor {
        guard isControlEnabled else { return .disabledControlTextColor }
        return compact ? .secondaryLabelColor : .labelColor
    }
}

#if CROSS_EXAMINATION_VIEW_SELF_CHECK
@main
private enum CrossExaminationViewSelfCheckMain {
    static func main() {
        precondition(
            CrossExaminationViewLayout.preferredLayoutPassesSelfCheck(),
            "CrossExaminationView must fit four >=25pt controls inside 224x35"
        )
        print("CrossExaminationView 224x35 layout self-check passed.")
    }
}
#endif
