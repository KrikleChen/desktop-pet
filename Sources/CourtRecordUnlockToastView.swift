import AppKit

/// A small, non-interactive strip for newly unlocked court records.
///
/// It is intentionally separate from the dialogue presenter so discovery
/// feedback never replaces action dialogue, impact captions, or follow-ups.
final class CourtRecordUnlockToastView: NSView {
    private var message = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(recordTitle: String) {
        message = "★ 新记录：\(recordTitle)"
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        isHidden = true
        message = ""
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !message.isEmpty else { return }

        let panelRect = bounds.insetBy(dx: 1, dy: 1)
        let panel = NSBezierPath(roundedRect: panelRect, xRadius: 8, yRadius: 8)
        NSColor(calibratedWhite: 0.08, alpha: 0.90).setFill()
        panel.fill()
        NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.24, alpha: 0.95).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        text.draw(in: panelRect.insetBy(dx: 8, dy: 4))
    }
}
