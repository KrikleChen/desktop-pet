import AppKit

/// Compact, non-interactive presentation of the six-item archive order.
/// The host owns placement and lifetime; this view never creates a window.
final class OrderedEvidenceArchiveHUDView: NSView {
    private var snapshot: OrderedEvidenceArchiveSnapshot?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 224, height: 32)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("有序证物归档未开始")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(_ snapshot: OrderedEvidenceArchiveSnapshot) {
        self.snapshot = snapshot
        isHidden = false
        setAccessibilityLabel(Self.accessibilityDescription(for: snapshot))
        needsDisplay = true
    }

    func hide() {
        snapshot = nil
        isHidden = true
        setAccessibilityLabel("有序证物归档未开始")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let snapshot else { return }

        let panelRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let panel = NSBezierPath(roundedRect: panelRect, xRadius: 8, yRadius: 8)
        Self.panelColor(for: snapshot.phase).setFill()
        panel.fill()
        NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        let itemWidth: CGFloat = 24
        let itemHeight: CGFloat = 24
        let itemGap: CGFloat = 3
        let itemStartX: CGFloat = 5
        let itemY = (bounds.height - itemHeight) * 0.5

        for (index, kind) in snapshot.order.enumerated() {
            let rect = NSRect(
                x: itemStartX + CGFloat(index) * (itemWidth + itemGap),
                y: itemY,
                width: itemWidth,
                height: itemHeight
            )
            let state = Self.itemState(index: index, snapshot: snapshot)
            Self.drawItem(kind: kind, state: state, in: rect)
        }

        let statusRect = NSRect(x: 169, y: 5, width: 50, height: 22)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byClipping
        let status = NSAttributedString(
            string: Self.statusText(for: snapshot),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        status.draw(in: statusRect)
    }

    private enum ItemState {
        case completed
        case current
        case pending
        case failed
    }

    private static func itemState(
        index: Int,
        snapshot: OrderedEvidenceArchiveSnapshot
    ) -> ItemState {
        switch snapshot.phase {
        case .failed:
            return .failed
        case .completed:
            return .completed
        case .active:
            if index < snapshot.completedCount { return .completed }
            if index == snapshot.completedCount { return .current }
            return .pending
        }
    }

    private static func drawItem(
        kind: AccessoryKind,
        state: ItemState,
        in rect: NSRect
    ) {
        let fill: NSColor
        let stroke: NSColor
        switch state {
        case .completed:
            fill = NSColor.systemGreen.withAlphaComponent(0.82)
            stroke = NSColor.systemGreen
        case .current:
            fill = NSColor.systemBlue.withAlphaComponent(0.88)
            stroke = NSColor.white.withAlphaComponent(0.95)
        case .pending:
            fill = NSColor.white.withAlphaComponent(0.10)
            stroke = NSColor.white.withAlphaComponent(0.24)
        case .failed:
            fill = NSColor.systemRed.withAlphaComponent(0.28)
            stroke = NSColor.systemRed.withAlphaComponent(0.68)
        }

        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = state == .current ? 1.5 : 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(
            string: shortLabel(for: kind),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        text.draw(in: rect.offsetBy(dx: 0, dy: 5))
    }

    private static func panelColor(
        for phase: OrderedEvidenceArchivePhase
    ) -> NSColor {
        switch phase {
        case .active:
            return NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.18, alpha: 0.94)
        case .failed:
            return NSColor(calibratedRed: 0.25, green: 0.05, blue: 0.06, alpha: 0.94)
        case .completed:
            return NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.11, alpha: 0.94)
        }
    }

    private static func statusText(
        for snapshot: OrderedEvidenceArchiveSnapshot
    ) -> String {
        switch snapshot.phase {
        case .active:
            return "\(snapshot.completedCount)/\(snapshot.order.count)"
        case .failed:
            return "错序"
        case .completed:
            return "完成"
        }
    }

    private static func shortLabel(for kind: AccessoryKind) -> String {
        switch kind {
        case .attorneyBadge: return "徽"
        case .caseFile: return "卷"
        case .magatama: return "玉"
        case .evidence: return "证"
        case .pen: return "笔"
        case .stickyNote: return "签"
        }
    }

    private static func accessibilityDescription(
        for snapshot: OrderedEvidenceArchiveSnapshot
    ) -> String {
        let orderText = snapshot.order.map(\.displayName).joined(separator: "、")
        switch snapshot.phase {
        case .active:
            let nextText = snapshot.nextExpectedKind?.displayName ?? "无"
            return "有序证物归档，顺序：\(orderText)，已完成 \(snapshot.completedCount) 件，下一件：\(nextText)"
        case .failed:
            return "有序证物归档失败，已完成 \(snapshot.completedCount) 件，顺序：\(orderText)"
        case .completed:
            return "有序证物归档完成，六件证物顺序：\(orderText)"
        }
    }
}
