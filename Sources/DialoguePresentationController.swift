import AppKit
import QuartzCore

/// 成步堂桌宠的轻量台词舞台类型。
///
/// `.objection` 刻意不在这里：经典“異議あり！”继续由 `ObjectionBurstView` 独立负责。
enum DialogueStyle: CaseIterable {
    case thought
    case nervous
    case courtroom
    case badge
    case spiritual
    case darkWhisper
    case flashlight
    case dragProtest
    case resigned
    case heardName
    case impact
    case friendly
}

/// 在桌宠容器上方管理台词自绘、进入/停留/退出动画与自动消失。
///
/// 控制器长期持有一个透明覆盖层，不创建窗口，也不会截获鼠标事件。
/// 所有调用都应发生在主线程。
final class DialoguePresentationController {
    private let presentationView = DialoguePresentationView(frame: .zero)
    private weak var containerView: NSView?
    private var autoDismissWorkItem: DispatchWorkItem?
    private var phaseWorkItem: DispatchWorkItem?
    private var typewriterTimer: Timer?
    private var finishWorkItem: DispatchWorkItem?
    private var currentCompletion: (() -> Void)?
    private var generation = 0

    private(set) var currentStyle: DialogueStyle?

    deinit {
        cancelScheduledWork()
    }

    /// 播放一种台词演出。
    ///
    /// - Parameters:
    ///   - text: 要显示的完整文字。
    ///   - style: 演出类型；异议演出不属于本控制器。
    ///   - container: 通常传入 240×260 的 `PetView`。
    ///   - anchor: 容器坐标中的语义锚点。为空时按演出类型自动定位。
    ///   - duration: 从开始到自动退场的时间；最短会保留 0.8 秒。
    ///   - completion: 退场并移除覆盖层后回调。
    func show(
        text: String,
        style: DialogueStyle,
        in container: NSView,
        anchor: NSPoint? = nil,
        duration: TimeInterval = 2.2,
        completion: (() -> Void)? = nil
    ) {
        precondition(Thread.isMainThread, "DialoguePresentationController 必须在主线程使用")

        finishPresentation(callCompletion: true)
        generation += 1
        let activeGeneration = generation

        currentStyle = style
        currentCompletion = completion
        containerView = container

        presentationView.removeFromSuperview()
        presentationView.frame = container.bounds
        presentationView.autoresizingMask = [.width, .height]
        presentationView.configure(
            text: text,
            style: style,
            anchor: anchor ?? defaultAnchor(for: style, in: container.bounds)
        )
        container.addSubview(presentationView, positioned: .above, relativeTo: nil)
        presentationView.beginEntrance()

        if style == .thought {
            beginTypewriter(text: text, generation: activeGeneration)
        } else if style == .heardName {
            presentationView.setPhase(.cue)
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.presentationView.setPhase(.message)
            }
            phaseWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: workItem)
        }

        let visibleDuration = max(0.8, duration)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == activeGeneration else { return }
            self.dismiss()
        }
        autoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: workItem)
    }

    /// 提前结束当前演出。重复调用安全。
    func dismiss(completion: (() -> Void)? = nil) {
        precondition(Thread.isMainThread, "DialoguePresentationController 必须在主线程使用")
        guard let style = currentStyle else {
            completion?()
            return
        }

        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
        phaseWorkItem?.cancel()
        phaseWorkItem = nil
        typewriterTimer?.invalidate()
        typewriterTimer = nil
        finishWorkItem?.cancel()

        generation += 1
        let activeGeneration = generation
        let exitDuration = presentationView.beginExit(for: style)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == activeGeneration else { return }
            self.finishPresentation(callCompletion: true)
            completion?()
        }
        finishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + exitDuration, execute: workItem)
    }

    /// 拖拽过程中更新语义锚点；主要供 `.dragProtest` 和 `.flashlight` 使用。
    func updateAnchor(_ anchor: NSPoint) {
        guard currentStyle != nil else { return }
        presentationView.updateAnchor(anchor)
    }

    private func beginTypewriter(text: String, generation activeGeneration: Int) {
        let characters = Array(text)
        guard !characters.isEmpty else { return }

        presentationView.setVisibleText("")
        var index = 0
        let timer = Timer(timeInterval: 0.055, repeats: true) { [weak self] timer in
            guard let self, self.generation == activeGeneration else {
                timer.invalidate()
                return
            }
            index += 1
            self.presentationView.setVisibleText(String(characters.prefix(index)))
            if index >= characters.count {
                timer.invalidate()
                self.typewriterTimer = nil
            }
        }
        typewriterTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func defaultAnchor(for style: DialogueStyle, in bounds: NSRect) -> NSPoint {
        switch style {
        case .courtroom, .resigned:
            return NSPoint(x: bounds.midX, y: 42)
        case .impact:
            return NSPoint(x: bounds.midX, y: bounds.midY + 14)
        case .badge, .spiritual:
            return NSPoint(x: bounds.midX, y: bounds.height * 0.66)
        case .flashlight:
            return NSPoint(x: bounds.width * 0.43, y: bounds.height * 0.42)
        case .dragProtest:
            return NSPoint(x: bounds.midX, y: bounds.height * 0.78)
        case .darkWhisper:
            return NSPoint(x: bounds.width * 0.58, y: bounds.height * 0.76)
        case .heardName:
            return NSPoint(x: bounds.width * 0.66, y: bounds.height * 0.80)
        case .thought, .nervous, .friendly:
            return NSPoint(x: bounds.midX, y: bounds.height * 0.82)
        }
    }

    private func cancelScheduledWork() {
        autoDismissWorkItem?.cancel()
        phaseWorkItem?.cancel()
        finishWorkItem?.cancel()
        typewriterTimer?.invalidate()
        autoDismissWorkItem = nil
        phaseWorkItem = nil
        finishWorkItem = nil
        typewriterTimer = nil
    }

    private func finishPresentation(callCompletion: Bool) {
        cancelScheduledWork()
        presentationView.removeFromSuperview()
        presentationView.reset()
        currentStyle = nil
        containerView = nil
        let completion = currentCompletion
        currentCompletion = nil
        if callCompletion {
            completion?()
        }
    }
}

private final class DialoguePresentationView: NSView {
    enum Phase {
        case message
        case cue
    }

    private var style: DialogueStyle = .friendly
    private var fullText = ""
    private var visibleText = ""
    private var anchor = NSPoint.zero
    private var phase: Phase = .message

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 900
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 900
        alphaValue = 0
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(text: String, style: DialogueStyle, anchor: NSPoint) {
        self.fullText = text
        self.visibleText = text
        self.style = style
        self.anchor = anchor
        phase = .message
        isHidden = false
        alphaValue = 1
        layer?.removeAllAnimations()
        layer?.setAffineTransform(.identity)
        layer?.opacity = 1
        needsDisplay = true
    }

    func reset() {
        layer?.removeAllAnimations()
        layer?.setAffineTransform(.identity)
        layer?.opacity = 1
        alphaValue = 0
        isHidden = true
        fullText = ""
        visibleText = ""
        phase = .message
    }

    func setVisibleText(_ text: String) {
        visibleText = text
        needsDisplay = true
    }

    func setPhase(_ phase: Phase) {
        self.phase = phase
        needsDisplay = true
        guard phase == .message else { return }

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.88, 1.08, 1.0]
        pop.duration = 0.26
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(pop, forKey: "heard-name-message")
    }

    func updateAnchor(_ point: NSPoint) {
        anchor = point
        needsDisplay = true
    }

    func beginEntrance() {
        guard let layer else { return }
        layer.removeAllAnimations()
        layer.opacity = 1
        layer.setAffineTransform(.identity)

        switch style {
        case .thought:
            addEntrance(opacity: [0, 1], x: [0, 0], y: [-8, 1, 0], scale: [0.96, 1], duration: 0.34)

        case .nervous:
            addEntrance(opacity: [0, 1], x: [-7, 6, -5, 4, 0], y: [1, -1, 0], scale: [0.86, 1.04, 1], duration: 0.42)

        case .courtroom:
            addEntrance(
                opacity: [0, 1],
                x: [-bounds.width, 12, -4, 0],
                y: [10, -4, 0],
                scale: [1, 1],
                duration: 0.38
            )

        case .badge:
            addEntrance(
                opacity: [0, 1, 1],
                x: [0, 0],
                y: [7, -2, 0],
                scale: [1.55, 0.86, 1.04, 1],
                rotation: [-0.18, 0.045, 0],
                duration: 0.44
            )

        case .spiritual:
            addEntrance(opacity: [0, 0.9, 1], x: [0, 0], y: [-4, 3, 0], scale: [0.82, 1.03, 1], duration: 0.55)

        case .darkWhisper:
            addEntrance(opacity: [0, 0.58, 1], x: [-3, 0], y: [-2, 0], scale: [1, 1], duration: 0.72)

        case .flashlight:
            let direction: CGFloat = anchor.x < bounds.midX ? -1 : 1
            addEntrance(opacity: [0, 0.35, 1], x: [-direction * 15, 0], y: [-6, 0], scale: [0.72, 1.02, 1], duration: 0.46)

        case .dragProtest:
            addEntrance(opacity: [0, 1], x: [-5, 4, 0], y: [5, -2, 0], scale: [0.88, 1.05, 1], duration: 0.28)
            // 人物继续挣扎，但文字停稳，避免跟随角色抖动而难以阅读。

        case .resigned:
            addEntrance(opacity: [0, 0.78, 1], x: [0, 0], y: [13, -2, 0], scale: [0.98, 1], duration: 0.52)

        case .heardName:
            addEntrance(opacity: [0, 1], x: [5, -2, 0], y: [-4, 1, 0], scale: [0.55, 1.12, 1], duration: 0.32)

        case .impact:
            // 碰撞的冲击感交给人物与特效；字幕层只快速淡入并保持稳定，
            // 避免缩放、旋转和位移导致短句也无法读清。
            addEntrance(
                opacity: [0, 1],
                x: [0, 0],
                y: [0, 0],
                scale: [1, 1],
                duration: 0.08
            )

        case .friendly:
            addEntrance(opacity: [0, 1], x: [0, 0], y: [-7, 2, 0], scale: [0.94, 1], duration: 0.26)
        }
    }

    @discardableResult
    func beginExit(for style: DialogueStyle) -> TimeInterval {
        guard let layer else { return 0 }
        layer.removeAllAnimations()

        let duration: TimeInterval
        switch style {
        case .thought:
            duration = 0.34
            addExit(opacity: [1, 0], x: [0, 2], y: [0, 10], scale: [1, 0.97], duration: duration)
        case .nervous:
            duration = 0.28
            addExit(opacity: [1, 0], x: [0, -8, 7], y: [0, 4], scale: [1, 0.82], duration: duration)
        case .courtroom:
            duration = 0.25
            addExit(opacity: [1, 1, 0], x: [0, 10, bounds.width], y: [0, 0], scale: [1, 1], duration: duration)
        case .badge:
            duration = 0.32
            addExit(opacity: [1, 0.8, 0], x: [0, 3], y: [0, -3], scale: [1, 1.12, 0.45], rotation: [0, 0.12, 0.28], duration: duration)
        case .spiritual:
            duration = 0.48
            addExit(opacity: [1, 0.45, 0], x: [0, 0], y: [0, 16], scale: [1, 1.10, 0.92], duration: duration)
        case .darkWhisper:
            duration = 0.58
            addExit(opacity: [1, 0], x: [0, 5], y: [0, 7], scale: [1, 1], duration: duration)
        case .flashlight:
            let direction: CGFloat = anchor.x < bounds.midX ? -1 : 1
            duration = 0.22
            addExit(opacity: [1, 0.15, 0], x: [0, direction * 22], y: [0, -4], scale: [1, 0.65], duration: duration)
        case .dragProtest:
            duration = 0.30
            addExit(opacity: [1, 0], x: [0, 10], y: [0, -18], scale: [1, 0.86], rotation: [0, -0.12], duration: duration)
        case .resigned:
            duration = 0.62
            addExit(opacity: [1, 0.65, 0], x: [0, 0], y: [0, -22], scale: [1, 0.96], duration: duration)
        case .heardName:
            duration = 0.28
            addExit(opacity: [1, 0], x: [0, 4], y: [0, 5], scale: [1, 0.72], duration: duration)
        case .impact:
            duration = 0.14
            addExit(opacity: [1, 0], x: [0, 0], y: [0, 0], scale: [1, 1], duration: duration)
        case .friendly:
            duration = 0.24
            addExit(opacity: [1, 0], x: [0, 0], y: [0, 8], scale: [1, 0.97], duration: duration)
        }
        return duration
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 2, bounds.height > 2 else { return }
        drawUnifiedCaption()
    }

    private func drawUnifiedCaption() {
        let displayedText = style == .heardName && phase == .cue ? "？" : visibleText
        let layout = makeTextLayout(
            text: displayedText,
            baseFont: .systemFont(ofSize: 13, weight: .semibold),
            color: NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.25, alpha: 0.98),
            alignment: .center,
            maximum: NSSize(width: 164, height: 38)
        )
        let rect = positionedRect(
            size: NSSize(
                width: min(226, max(176, layout.size.width + 62)),
                height: min(57, max(45, layout.size.height + 18))
            ),
            around: anchor,
            preference: .above
        )

        let shadow = NSBezierPath(
            roundedRect: rect.offsetBy(dx: 2, dy: -2),
            xRadius: 11,
            yRadius: 11
        )
        NSColor(calibratedWhite: 0, alpha: 0.24).setFill()
        shadow.fill()

        let panel = NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11)
        NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.86, alpha: 0.97).setFill()
        panel.fill()
        NSColor(calibratedRed: 0.08, green: 0.16, blue: 0.30, alpha: 0.92).setStroke()
        panel.lineWidth = 1.7
        panel.stroke()

        let accent = accentColor(for: style)
        accent.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX + 4, y: rect.minY + 6, width: 5, height: rect.height - 12),
            xRadius: 2.5,
            yRadius: 2.5
        ).fill()

        let markerRect = NSRect(x: rect.minX + 14, y: rect.midY - 14, width: 28, height: 28)
        accent.setFill()
        NSBezierPath(ovalIn: markerRect).fill()
        let marker = NSAttributedString(
            string: markerText(for: style),
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .heavy),
                .foregroundColor: markerForegroundColor(for: style),
            ]
        )
        marker.draw(
            at: NSPoint(
                x: markerRect.midX - marker.size().width / 2,
                y: markerRect.midY - marker.size().height / 2
            )
        )

        let textRect = NSRect(
            x: markerRect.maxX + 5,
            y: rect.minY + 7,
            width: rect.maxX - markerRect.maxX - 12,
            height: rect.height - 14
        )
        layout.drawCentered(in: textRect)

        let tail = NSBezierPath()
        let tailX = min(rect.maxX - 18, max(rect.minX + 18, anchor.x))
        tail.move(to: NSPoint(x: tailX - 5, y: rect.minY + 1))
        tail.line(to: NSPoint(x: tailX, y: rect.minY - 6))
        tail.line(to: NSPoint(x: tailX + 5, y: rect.minY + 1))
        tail.close()
        NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.86, alpha: 0.97).setFill()
        tail.fill()
    }

    private func accentColor(for style: DialogueStyle) -> NSColor {
        switch style {
        case .thought, .friendly:
            return NSColor(calibratedRed: 0.17, green: 0.34, blue: 0.58, alpha: 1)
        case .nervous:
            return NSColor(calibratedRed: 0.12, green: 0.57, blue: 0.72, alpha: 1)
        case .courtroom, .impact:
            return NSColor(calibratedRed: 0.72, green: 0.10, blue: 0.05, alpha: 1)
        case .badge:
            return NSColor(calibratedRed: 0.91, green: 0.61, blue: 0.10, alpha: 1)
        case .spiritual:
            return NSColor(calibratedRed: 0.10, green: 0.58, blue: 0.27, alpha: 1)
        case .darkWhisper, .resigned:
            return NSColor(calibratedWhite: 0.33, alpha: 1)
        case .flashlight:
            return NSColor(calibratedRed: 0.94, green: 0.72, blue: 0.12, alpha: 1)
        case .dragProtest:
            return NSColor(calibratedRed: 0.90, green: 0.34, blue: 0.06, alpha: 1)
        case .heardName:
            return NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.79, alpha: 1)
        }
    }

    private func markerText(for style: DialogueStyle) -> String {
        switch style {
        case .thought, .darkWhisper, .resigned:
            return "…"
        case .nervous, .courtroom, .dragProtest, .impact:
            return "!"
        case .badge:
            return "律"
        case .spiritual:
            return "勾"
        case .flashlight:
            return "✦"
        case .heardName:
            return "?"
        case .friendly:
            return "●"
        }
    }

    private func markerForegroundColor(for style: DialogueStyle) -> NSColor {
        switch style {
        case .badge, .flashlight:
            return NSColor(calibratedRed: 0.19, green: 0.13, blue: 0.03, alpha: 1)
        default:
            return .white
        }
    }

    private func drawThought() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 12.5, weight: .medium),
            color: NSColor(calibratedWhite: 0.16, alpha: 0.94),
            alignment: .left,
            maximum: NSSize(width: 154, height: 112)
        )
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 27, height: layout.size.height + 22),
            around: anchor,
            preference: .above
        )

        drawCloud(in: rect, fill: NSColor(calibratedWhite: 0.98, alpha: 0.93), stroke: NSColor(calibratedWhite: 0.28, alpha: 0.75))
        let dotOne = NSRect(x: rect.minX + 15, y: rect.minY - 8, width: 9, height: 9)
        let dotTwo = NSRect(x: rect.minX + 5, y: rect.minY - 15, width: 6, height: 6)
        NSColor(calibratedWhite: 0.98, alpha: 0.88).setFill()
        NSBezierPath(ovalIn: dotOne).fill()
        NSBezierPath(ovalIn: dotTwo).fill()
        layout.draw(in: rect.insetBy(dx: 13, dy: 10))
    }

    private func drawNervous() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 12.5, weight: .semibold),
            color: NSColor(calibratedRed: 0.05, green: 0.24, blue: 0.36, alpha: 1),
            alignment: .center,
            maximum: NSSize(width: 160, height: 92)
        )
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 30, height: layout.size.height + 21),
            around: anchor,
            preference: .above
        )
        let path = jaggedPath(in: rect, teeth: 12, depth: 4)
        NSColor(calibratedRed: 0.78, green: 0.94, blue: 1.0, alpha: 0.94).setFill()
        path.fill()
        NSColor(calibratedRed: 0.10, green: 0.45, blue: 0.62, alpha: 0.94).setStroke()
        path.lineWidth = 2
        path.stroke()
        drawMotionMarks(around: rect, color: NSColor(calibratedRed: 0.12, green: 0.55, blue: 0.73, alpha: 0.72))
        layout.draw(in: rect.insetBy(dx: 14, dy: 9))
    }

    private func drawCourtroom() {
        let height = min(57, max(50, bounds.height * 0.22))
        let rect = NSRect(
            x: 5,
            y: bounds.maxY - 7 - height,
            width: max(1, bounds.width - 10),
            height: height
        )
        let shadow = rect.offsetBy(dx: 3, dy: -3)
        NSColor(calibratedWhite: 0, alpha: 0.58).setFill()
        NSBezierPath(rect: shadow).fill()

        let panel = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor(calibratedRed: 0.16, green: 0.05, blue: 0.035, alpha: 0.97).setFill()
        panel.fill()
        NSColor(calibratedRed: 0.92, green: 0.66, blue: 0.20, alpha: 1).setStroke()
        panel.lineWidth = 2.5
        panel.stroke()

        NSColor(calibratedRed: 0.72, green: 0.09, blue: 0.05, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: rect.minX + 5, y: rect.maxY - 8, width: rect.width - 10, height: 3)).fill()

        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 14, weight: .heavy),
            color: NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.78, alpha: 1),
            alignment: .center,
            maximum: NSSize(width: rect.width - 24, height: rect.height - 18),
            strokeColor: NSColor(calibratedWhite: 0, alpha: 0.72),
            strokeWidth: -1.8
        )
        layout.drawCentered(in: rect.insetBy(dx: 12, dy: 8))
    }

    private func drawBadge() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 12.5, weight: .bold),
            color: NSColor(calibratedRed: 0.28, green: 0.15, blue: 0.02, alpha: 1),
            alignment: .center,
            maximum: NSSize(width: 142, height: 74)
        )
        let rect = positionedRect(
            size: NSSize(width: min(216, layout.size.width + 74), height: max(62, layout.size.height + 24)),
            around: anchor,
            preference: .centered
        )

        let banner = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.46, alpha: 0.96).setFill()
        banner.fill()
        NSColor(calibratedRed: 0.55, green: 0.31, blue: 0.04, alpha: 1).setStroke()
        banner.lineWidth = 2.2
        banner.stroke()

        let sealRect = NSRect(x: rect.minX + 5, y: rect.midY - 25, width: 50, height: 50)
        NSColor(calibratedRed: 0.96, green: 0.68, blue: 0.13, alpha: 1).setFill()
        NSBezierPath(ovalIn: sealRect).fill()
        NSColor(calibratedRed: 0.45, green: 0.24, blue: 0.03, alpha: 1).setStroke()
        let ring = NSBezierPath(ovalIn: sealRect.insetBy(dx: 4, dy: 4))
        ring.lineWidth = 2
        ring.stroke()
        drawScales(ofJusticeIn: sealRect.insetBy(dx: 10, dy: 10))

        let textRect = NSRect(x: sealRect.maxX + 5, y: rect.minY + 8, width: rect.maxX - sealRect.maxX - 12, height: rect.height - 16)
        layout.drawCentered(in: textRect)
    }

    private func drawSpiritual() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 12.5, weight: .semibold),
            color: NSColor(calibratedRed: 0.77, green: 1.0, blue: 0.80, alpha: 1),
            alignment: .center,
            maximum: NSSize(width: 166, height: 92),
            strokeColor: NSColor(calibratedRed: 0.01, green: 0.18, blue: 0.08, alpha: 0.9),
            strokeWidth: -1.6
        )
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 35, height: layout.size.height + 25),
            around: anchor,
            preference: .above
        )

        for inset in stride(from: CGFloat(10), through: 2, by: -4) {
            let aura = NSBezierPath(roundedRect: rect.insetBy(dx: -inset, dy: -inset * 0.55), xRadius: 16, yRadius: 16)
            NSColor(calibratedRed: 0.06, green: 0.95, blue: 0.34, alpha: 0.035 + (10 - inset) * 0.011).setFill()
            aura.fill()
        }
        let panel = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor(calibratedRed: 0.01, green: 0.20, blue: 0.10, alpha: 0.91).setFill()
        panel.fill()
        NSColor(calibratedRed: 0.20, green: 1.0, blue: 0.43, alpha: 0.85).setStroke()
        panel.lineWidth = 1.8
        panel.stroke()

        drawMagatama(at: NSPoint(x: rect.minX + 17, y: rect.midY), radius: 9)
        layout.drawCentered(in: rect.insetBy(dx: 18, dy: 10))
    }

    private func drawDarkWhisper() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 10.5, weight: .medium),
            color: NSColor(calibratedWhite: 0.80, alpha: 0.72),
            alignment: .left,
            maximum: NSSize(width: 150, height: 104)
        )
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 28, height: layout.size.height + 18),
            around: anchor,
            preference: .above
        )

        let panel = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor(calibratedWhite: 0.015, alpha: 0.55).setFill()
        panel.fill()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX + 9, y: rect.minY + 5))
        line.line(to: NSPoint(x: rect.maxX - 12, y: rect.minY + 5))
        NSColor(calibratedWhite: 0.6, alpha: 0.20).setStroke()
        line.lineWidth = 1
        line.stroke()

        let prefix = NSAttributedString(
            string: "…",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .light),
                .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 0.46),
            ]
        )
        prefix.draw(at: NSPoint(x: rect.minX + 8, y: rect.maxY - 21))
        layout.draw(in: rect.insetBy(dx: 13, dy: 8))
    }

    private func drawFlashlight() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 11.5, weight: .semibold),
            color: NSColor(calibratedRed: 0.15, green: 0.13, blue: 0.04, alpha: 0.96),
            alignment: .center,
            maximum: NSSize(width: 132, height: 80)
        )
        let targetX = anchor.x < bounds.midX ? bounds.width * 0.68 : bounds.width * 0.32
        let target = NSPoint(x: targetX, y: min(bounds.height - 40, max(65, anchor.y + 58)))
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 27, height: layout.size.height + 19),
            around: target,
            preference: .centered
        )

        let beam = NSBezierPath()
        beam.move(to: anchor)
        beam.line(to: NSPoint(x: rect.minX + 5, y: rect.minY + 3))
        beam.line(to: NSPoint(x: rect.maxX - 5, y: rect.minY + 3))
        beam.close()
        NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.56, alpha: 0.19).setFill()
        beam.fill()

        let panel = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor(calibratedRed: 1.0, green: 0.96, blue: 0.68, alpha: 0.94).setFill()
        panel.fill()
        NSColor(calibratedRed: 0.75, green: 0.61, blue: 0.20, alpha: 0.94).setStroke()
        panel.lineWidth = 1.5
        panel.stroke()
        layout.drawCentered(in: rect.insetBy(dx: 12, dy: 8))
    }

    private func drawDragProtest() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 12, weight: .heavy),
            color: NSColor(calibratedRed: 0.34, green: 0.06, blue: 0.015, alpha: 1),
            alignment: .center,
            maximum: NSSize(width: 148, height: 88)
        )
        let point = NSPoint(x: anchor.x, y: min(bounds.height - 25, anchor.y + 35))
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 30, height: layout.size.height + 20),
            around: point,
            preference: .centered
        )
        let placard = jaggedPath(in: rect, teeth: 14, depth: 3)
        NSColor(calibratedRed: 1.0, green: 0.67, blue: 0.24, alpha: 0.97).setFill()
        placard.fill()
        NSColor(calibratedRed: 0.49, green: 0.08, blue: 0.025, alpha: 0.95).setStroke()
        placard.lineWidth = 2
        placard.stroke()
        drawMotionMarks(around: rect, color: NSColor(calibratedRed: 0.75, green: 0.12, blue: 0.02, alpha: 0.76))
        layout.drawCentered(in: rect.insetBy(dx: 12, dy: 8))
    }

    private func drawResigned() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 11, weight: .regular),
            color: NSColor(calibratedWhite: 0.88, alpha: 0.82),
            alignment: .center,
            maximum: NSSize(width: 178, height: 72)
        )
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 28, height: layout.size.height + 18),
            around: anchor,
            preference: .centered
        )
        let panel = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(calibratedWhite: 0.10, alpha: 0.67).setFill()
        panel.fill()
        NSColor(calibratedWhite: 0.55, alpha: 0.32).setStroke()
        panel.lineWidth = 1
        panel.stroke()

        for index in 0..<3 {
            let y = rect.minY - CGFloat(index * 5 + 4)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: rect.midX - 10 + CGFloat(index * 3), y: y))
            line.line(to: NSPoint(x: rect.midX + 10 - CGFloat(index * 3), y: y))
            NSColor(calibratedWhite: 0.55, alpha: 0.26 - CGFloat(index) * 0.06).setStroke()
            line.lineWidth = 1
            line.stroke()
        }
        layout.drawCentered(in: rect.insetBy(dx: 12, dy: 7))
    }

    private func drawHeardName() {
        if phase == .cue {
            let question = NSAttributedString(
                string: "？",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 36, weight: .black),
                    .foregroundColor: NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.63, alpha: 1),
                    .strokeColor: NSColor.white,
                    .strokeWidth: -3.4,
                ]
            )
            let size = question.size()
            let x = min(bounds.width - size.width - 8, max(8, anchor.x - size.width * 0.5))
            let y = bounds.height - size.height - 7
            question.draw(at: NSPoint(x: x, y: y))
            return
        }

        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 12.5, weight: .semibold),
            color: NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.38, alpha: 1),
            alignment: .center,
            maximum: NSSize(width: 156, height: 84)
        )
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 32, height: layout.size.height + 21),
            around: NSPoint(x: anchor.x, y: anchor.y - 18),
            preference: .above
        )
        let panel = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor(calibratedRed: 0.91, green: 0.96, blue: 1.0, alpha: 0.96).setFill()
        panel.fill()
        NSColor(calibratedRed: 0.19, green: 0.39, blue: 0.68, alpha: 0.94).setStroke()
        panel.lineWidth = 1.8
        panel.stroke()

        let markerRect = NSRect(x: rect.minX - 8, y: rect.maxY - 15, width: 24, height: 24)
        NSColor(calibratedRed: 0.22, green: 0.47, blue: 0.78, alpha: 1).setFill()
        NSBezierPath(ovalIn: markerRect).fill()
        let marker = NSAttributedString(
            string: "?",
            attributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .black),
                .foregroundColor: NSColor.white,
            ]
        )
        marker.draw(at: NSPoint(x: markerRect.midX - marker.size().width / 2, y: markerRect.midY - marker.size().height / 2))
        layout.drawCentered(in: rect.insetBy(dx: 13, dy: 8))
    }

    private func drawImpact() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 18, weight: .black),
            color: NSColor(calibratedRed: 0.96, green: 0.92, blue: 0.75, alpha: 1),
            alignment: .center,
            maximum: NSSize(width: 152, height: 86),
            strokeColor: NSColor(calibratedRed: 0.30, green: 0.02, blue: 0.01, alpha: 1),
            strokeWidth: -2.2
        )
        let side = min(194, max(72, max(layout.size.width + 36, layout.size.height + 30)))
        let rect = positionedRect(
            size: NSSize(width: side, height: min(92, side * 0.64)),
            around: anchor,
            preference: .centered
        )
        let stamp = jaggedPath(in: rect, teeth: 18, depth: 5)
        NSColor(calibratedRed: 0.68, green: 0.035, blue: 0.02, alpha: 0.96).setFill()
        stamp.fill()
        NSColor(calibratedRed: 0.99, green: 0.78, blue: 0.31, alpha: 1).setStroke()
        stamp.lineWidth = 2.8
        stamp.stroke()
        layout.drawCentered(in: rect.insetBy(dx: 12, dy: 9))
    }

    private func drawFriendly() {
        let layout = makeTextLayout(
            text: visibleText,
            baseFont: .systemFont(ofSize: 11.5, weight: .medium),
            color: NSColor(calibratedRed: 0.09, green: 0.17, blue: 0.29, alpha: 0.94),
            alignment: .center,
            maximum: NSSize(width: 160, height: 88)
        )
        let rect = positionedRect(
            size: NSSize(width: layout.size.width + 28, height: layout.size.height + 20),
            around: anchor,
            preference: .above
        )
        let panel = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.90, alpha: 0.91).setFill()
        panel.fill()
        NSColor(calibratedRed: 0.16, green: 0.28, blue: 0.44, alpha: 0.58).setStroke()
        panel.lineWidth = 1.2
        panel.stroke()

        let tail = NSBezierPath()
        let tailX = min(rect.maxX - 18, max(rect.minX + 18, anchor.x))
        tail.move(to: NSPoint(x: tailX - 5, y: rect.minY + 1))
        tail.line(to: NSPoint(x: tailX, y: rect.minY - 6))
        tail.line(to: NSPoint(x: tailX + 5, y: rect.minY + 1))
        tail.close()
        NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.90, alpha: 0.91).setFill()
        tail.fill()
        layout.drawCentered(in: rect.insetBy(dx: 12, dy: 8))
    }

    private enum PlacementPreference {
        case above
        case centered
    }

    private func positionedRect(size requestedSize: NSSize, around point: NSPoint, preference: PlacementPreference) -> NSRect {
        let margin: CGFloat = 7
        // PetView 的人物最高到 y=180。普通台词统一待在顶部字幕带；
        // 云朵尾巴等装饰最多向下延伸约 15pt，因此正文从 y=196 开始。
        let dialogueFloor = min(bounds.maxY - margin - 1, max(bounds.minY + margin, 196))
        let safeWidth = max(1, bounds.width - margin * 2)
        let safeHeight = max(1, bounds.maxY - margin - dialogueFloor)
        let size = NSSize(
            width: min(requestedSize.width, safeWidth),
            height: min(requestedSize.height, safeHeight)
        )

        var originX = point.x - size.width * 0.5
        var originY: CGFloat
        switch preference {
        case .above:
            originY = point.y - size.height * 0.35
        case .centered:
            originY = point.y - size.height * 0.5
        }
        originX = min(bounds.maxX - margin - size.width, max(bounds.minX + margin, originX))
        originY = min(bounds.maxY - margin - size.height, max(dialogueFloor, originY))
        return NSRect(origin: NSPoint(x: originX, y: originY), size: size)
    }

    private func drawCloud(in rect: NSRect, fill: NSColor, stroke: NSColor) {
        let body = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 17, yRadius: 17)
        fill.setFill()
        body.fill()
        stroke.setStroke()
        body.lineWidth = 1.4
        body.stroke()

        let lobes = [
            NSRect(x: rect.minX + rect.width * 0.12, y: rect.maxY - 11, width: 27, height: 18),
            NSRect(x: rect.minX + rect.width * 0.38, y: rect.maxY - 8, width: 34, height: 21),
            NSRect(x: rect.minX + rect.width * 0.68, y: rect.maxY - 11, width: 28, height: 18),
        ]
        for lobe in lobes {
            fill.setFill()
            NSBezierPath(ovalIn: lobe).fill()
        }
    }

    private func jaggedPath(in rect: NSRect, teeth: Int, depth: CGFloat) -> NSBezierPath {
        let count = max(4, teeth)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + depth, y: rect.minY))

        for index in 0...count {
            let ratio = CGFloat(index) / CGFloat(count)
            let y = index.isMultiple(of: 2) ? rect.minY : rect.minY + depth
            path.line(to: NSPoint(x: rect.minX + ratio * rect.width, y: y))
        }
        for index in 0...count {
            let ratio = CGFloat(index) / CGFloat(count)
            let x = index.isMultiple(of: 2) ? rect.maxX : rect.maxX - depth
            path.line(to: NSPoint(x: x, y: rect.minY + ratio * rect.height))
        }
        for index in 0...count {
            let ratio = CGFloat(index) / CGFloat(count)
            let y = index.isMultiple(of: 2) ? rect.maxY : rect.maxY - depth
            path.line(to: NSPoint(x: rect.maxX - ratio * rect.width, y: y))
        }
        for index in 0...count {
            let ratio = CGFloat(index) / CGFloat(count)
            let x = index.isMultiple(of: 2) ? rect.minX : rect.minX + depth
            path.line(to: NSPoint(x: x, y: rect.maxY - ratio * rect.height))
        }
        path.close()
        return path
    }

    private func drawMotionMarks(around rect: NSRect, color: NSColor) {
        color.setStroke()
        for side: CGFloat in [-1, 1] {
            for index in 0..<3 {
                let line = NSBezierPath()
                let x = side < 0 ? rect.minX - 5 : rect.maxX + 5
                let y = rect.midY + CGFloat(index - 1) * 8
                line.move(to: NSPoint(x: x, y: y))
                line.line(to: NSPoint(x: x + side * 7, y: y + CGFloat(index - 1) * 2))
                line.lineWidth = 1.5
                line.stroke()
            }
        }
    }

    private func drawScales(ofJusticeIn rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.midX, y: rect.minY + 3))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 4))
        path.move(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 10))
        path.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 10))
        path.move(to: NSPoint(x: rect.minX + 7, y: rect.maxY - 10))
        path.line(to: NSPoint(x: rect.minX + 3, y: rect.midY - 2))
        path.move(to: NSPoint(x: rect.maxX - 7, y: rect.maxY - 10))
        path.line(to: NSPoint(x: rect.maxX - 3, y: rect.midY - 2))
        NSColor(calibratedRed: 0.40, green: 0.21, blue: 0.025, alpha: 1).setStroke()
        path.lineWidth = 1.8
        path.stroke()

        for x in [rect.minX + 3, rect.maxX - 3] {
            let bowl = NSBezierPath()
            bowl.appendArc(withCenter: NSPoint(x: x, y: rect.midY - 2), radius: 6, startAngle: 200, endAngle: 340)
            bowl.lineWidth = 1.8
            bowl.stroke()
        }
    }

    private func drawMagatama(at center: NSPoint, radius: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius, startAngle: 30, endAngle: 326)
        path.curve(
            to: NSPoint(x: center.x + 2, y: center.y - radius * 0.2),
            controlPoint1: NSPoint(x: center.x + radius * 1.10, y: center.y - radius * 0.75),
            controlPoint2: NSPoint(x: center.x + radius * 0.15, y: center.y - radius * 1.05)
        )
        path.close()
        NSColor(calibratedRed: 0.20, green: 0.95, blue: 0.43, alpha: 0.92).setFill()
        path.fill()
        NSColor(calibratedRed: 0.02, green: 0.32, blue: 0.13, alpha: 1).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        NSColor(calibratedRed: 0.02, green: 0.28, blue: 0.12, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 2.2, y: center.y + 1.0, width: 4.4, height: 4.4)).fill()
    }

    private func makeTextLayout(
        text: String,
        baseFont: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        maximum: NSSize,
        strokeColor: NSColor? = nil,
        strokeWidth: CGFloat? = nil
    ) -> DialogueTextLayout {
        var fontSize = baseFont.pointSize
        var candidate = makeAttributedText(
            text,
            font: NSFont(descriptor: baseFont.fontDescriptor, size: fontSize) ?? baseFont,
            color: color,
            alignment: alignment,
            strokeColor: strokeColor,
            strokeWidth: strokeWidth
        )
        var size = measuredSize(of: candidate, maximumWidth: maximum.width)

        while (size.width > maximum.width + 0.5 || size.height > maximum.height + 0.5), fontSize > 5.5 {
            fontSize -= 0.5
            let font = NSFont(descriptor: baseFont.fontDescriptor, size: fontSize) ?? .systemFont(ofSize: fontSize)
            candidate = makeAttributedText(
                text,
                font: font,
                color: color,
                alignment: alignment,
                strokeColor: strokeColor,
                strokeWidth: strokeWidth
            )
            size = measuredSize(of: candidate, maximumWidth: maximum.width)
        }

        return DialogueTextLayout(attributedText: candidate, size: size)
    }

    private func makeAttributedText(
        _ text: String,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        strokeColor: NSColor?,
        strokeWidth: CGFloat?
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let strokeColor {
            attributes[.strokeColor] = strokeColor
        }
        if let strokeWidth {
            attributes[.strokeWidth] = strokeWidth
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func measuredSize(of text: NSAttributedString, maximumWidth: CGFloat) -> NSSize {
        guard text.length > 0 else { return NSSize(width: 10, height: 16) }
        let rect = text.boundingRect(
            with: NSSize(width: maximumWidth, height: 1_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: ceil(min(maximumWidth, rect.width)), height: ceil(rect.height))
    }

    private func addEntrance(
        opacity: [CGFloat],
        x: [CGFloat],
        y: [CGFloat],
        scale: [CGFloat],
        rotation: [CGFloat] = [0, 0],
        duration: TimeInterval
    ) {
        let group = CAAnimationGroup()
        group.animations = [
            keyframe("opacity", opacity),
            keyframe("transform.translation.x", x),
            keyframe("transform.translation.y", y),
            keyframe("transform.scale", scale),
            keyframe("transform.rotation.z", rotation),
        ]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(group, forKey: "dialogue-entrance")
    }

    private func addExit(
        opacity: [CGFloat],
        x: [CGFloat],
        y: [CGFloat],
        scale: [CGFloat],
        rotation: [CGFloat] = [0, 0],
        duration: TimeInterval
    ) {
        let group = CAAnimationGroup()
        group.animations = [
            keyframe("opacity", opacity),
            keyframe("transform.translation.x", x),
            keyframe("transform.translation.y", y),
            keyframe("transform.scale", scale),
            keyframe("transform.rotation.z", rotation),
        ]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer?.add(group, forKey: "dialogue-exit")
    }

    private func addStay(
        keyPath: String,
        values: [CGFloat],
        duration: TimeInterval,
        repeatCount: Float,
        autoreverses: Bool = false
    ) {
        let animation = keyframe(keyPath, values)
        animation.duration = duration
        animation.repeatCount = repeatCount
        animation.autoreverses = autoreverses
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "dialogue-stay-\(keyPath)")
    }

    private func keyframe(_ keyPath: String, _ values: [CGFloat]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        return animation
    }
}

private struct DialogueTextLayout {
    let attributedText: NSAttributedString
    let size: NSSize

    func draw(in rect: NSRect) {
        attributedText.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    func drawCentered(in rect: NSRect) {
        let target = NSRect(
            x: rect.minX,
            y: rect.midY - size.height * 0.5,
            width: rect.width,
            height: min(rect.height, size.height + 2)
        )
        draw(in: target)
    }
}
