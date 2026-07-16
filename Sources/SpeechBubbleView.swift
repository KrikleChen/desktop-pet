import AppKit

final class SpeechBubbleView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        alphaValue = 0
        isHidden = true

        label.alignment = .center
        label.font = .systemFont(ofSize: 12.5, weight: .bold)
        label.textColor = NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.24, alpha: 1)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: 10, dy: 9).offsetBy(dx: 0, dy: 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bodyRect = NSRect(x: 2, y: 8, width: bounds.width - 4, height: bounds.height - 10)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 11, yRadius: 11)
        NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
        body.fill()
        NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.24, alpha: 0.9).setStroke()
        body.lineWidth = 2
        body.stroke()

        let tail = NSBezierPath()
        let center = bounds.midX
        tail.move(to: NSPoint(x: center - 8, y: 9))
        tail.line(to: NSPoint(x: center, y: 2))
        tail.line(to: NSPoint(x: center + 6, y: 9))
        tail.close()
        NSColor(calibratedWhite: 1, alpha: 0.95).setFill()
        tail.fill()
    }

    func show(_ text: String) {
        label.stringValue = text
        isHidden = false
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard !isHidden else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.isHidden = true
        })
    }
}
