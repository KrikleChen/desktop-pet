import AppKit

private final class CourtRecordPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class CourtRecordRowView: NSView {
    private let iconLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    init(definition: CourtRecordDefinition, progress: CourtRecordEntryProgress?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1

        iconLabel.alignment = .center
        iconLabel.font = .systemFont(ofSize: 20, weight: .bold)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 11.5)
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byWordWrapping

        if let progress = progress {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
            layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.25).cgColor
            iconLabel.stringValue = definition.category.icon
            iconLabel.textColor = .systemBlue
            titleLabel.stringValue = definition.title
            titleLabel.textColor = .labelColor

            let countText = progress.count > 0 ? "触发 \(progress.count) 次" : "已解锁"
            let dateText: String
            if progress.lastSeen > progress.unlockedAt.addingTimeInterval(60) {
                dateText = "首次 \(Self.dayFormatter.string(from: progress.unlockedAt)) · 最近 \(Self.recentFormatter.string(from: progress.lastSeen))"
            } else {
                dateText = "发现于 \(Self.dayFormatter.string(from: progress.unlockedAt))"
            }
            detailLabel.stringValue = "\(definition.category.rawValue) · \(definition.detail)\n\(countText) · \(dateText)"
            detailLabel.textColor = .secondaryLabelColor
        } else {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.50).cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
            iconLabel.stringValue = "?"
            iconLabel.textColor = .tertiaryLabelColor
            titleLabel.stringValue = "尚未发现"
            titleLabel.textColor = .tertiaryLabelColor
            detailLabel.stringValue = "\(definition.category.rawValue) · \(definition.lockedHint)"
            detailLabel.textColor = .tertiaryLabelColor
        }

        addSubview(iconLabel)
        addSubview(titleLabel)
        addSubview(detailLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(progress == nil ? "尚未发现的法庭记录" : definition.title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        iconLabel.frame = NSRect(x: 10, y: 20, width: 36, height: 30)
        titleLabel.frame = NSRect(x: 54, y: bounds.height - 28, width: bounds.width - 66, height: 18)
        detailLabel.frame = NSRect(x: 54, y: 7, width: bounds.width - 66, height: 39)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    private static let recentFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("MMMd HHmm")
        return formatter
    }()
}

final class CourtRecordPanelController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let store: CourtRecordStore
    private let panel: CourtRecordPanel
    private let summaryLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private var storeObserver: NSObjectProtocol?

    init(store: CourtRecordStore) {
        self.store = store
        panel = CourtRecordPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 520),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        storeObserver = NotificationCenter.default.addObserver(
            forName: .courtRecordStoreDidChange,
            object: store,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            self.refresh()
        }
    }

    deinit {
        if let storeObserver = storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
    }

    func show(relativeTo owner: NSWindow?) {
        refresh()
        position(relativeTo: owner)
        panel.orderFrontRegardless()
    }

    func close() {
        guard panel.isVisible else { return }
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    private func configurePanel() {
        panel.title = "法庭记录"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isExcludedFromWindowsMenu = true
        panel.delegate = self
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        guard let contentView = panel.contentView else { return }
        summaryLabel.frame = NSRect(x: 16, y: 482, width: 398, height: 22)
        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.textColor = .labelColor
        summaryLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(summaryLabel)

        scrollView.frame = NSRect(x: 12, y: 12, width: 406, height: 460)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        contentView.addSubview(scrollView)
    }

    private func refresh() {
        summaryLabel.stringValue = "已发现 \(store.discoveredCount) / \(store.totalCount)  ·  只记录真实触发"

        let definitions = CourtRecordCatalog.all
        let rowHeight: CGFloat = 76
        let gap: CGFloat = 7
        let documentWidth = max(360, scrollView.contentSize.width)
        let documentHeight = CGFloat(definitions.count) * (rowHeight + gap) + 5
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: documentWidth, height: documentHeight)
        )

        for (index, definition) in definitions.enumerated() {
            let row = CourtRecordRowView(
                definition: definition,
                progress: store.entry(for: definition.id)
            )
            row.frame = NSRect(
                x: 3,
                y: CGFloat(index) * (rowHeight + gap) + 3,
                width: documentWidth - 9,
                height: rowHeight
            )
            row.autoresizingMask = [.width]
            documentView.addSubview(row)
        }
        scrollView.documentView = documentView
    }

    private func position(relativeTo owner: NSWindow?) {
        guard let owner = owner else {
            panel.center()
            return
        }
        let screenFrame = owner.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: owner.frame.minX - panel.frame.width - 14,
            y: owner.frame.midY - panel.frame.height / 2
        )
        if origin.x < screenFrame.minX + 8 {
            origin.x = owner.frame.maxX + 14
        }
        origin.x = min(max(origin.x, screenFrame.minX + 8), screenFrame.maxX - panel.frame.width - 8)
        origin.y = min(max(origin.y, screenFrame.minY + 8), screenFrame.maxY - panel.frame.height - 8)
        panel.setFrameOrigin(origin)
    }
}
