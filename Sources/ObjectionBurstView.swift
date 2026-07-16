import AppKit
import QuartzCore

/// “異議あり！”专用视觉演出。
///
/// 这是一个纯绘制的透明覆盖层，不使用 NSTextField 或普通对话气泡。
/// 推荐由 PetView 长期持有，在触发 `.objection` 时调用 `show(in:)`。
final class ObjectionBurstView: NSView {
    private static let title = "異議あり！"
    private static let visibleDuration: TimeInterval = 1.30
    private static let exitDuration: TimeInterval = 0.16

    private var autoHideWorkItem: DispatchWorkItem?
    private var finishHideWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    deinit {
        autoHideWorkItem?.cancel()
        finishHideWorkItem?.cancel()
    }

    /// 把演出覆盖到指定容器最上层并立即播放。
    func show(in container: NSView) {
        if superview !== container {
            removeFromSuperview()
            frame = container.bounds
            autoresizingMask = [.width, .height]
            container.addSubview(self, positioned: .above, relativeTo: nil)
        } else {
            frame = container.bounds
        }
        show()
    }

    /// 在当前父视图内播放；约 1.46 秒后完全消失。
    func show() {
        autoHideWorkItem?.cancel()
        finishHideWorkItem?.cancel()

        guard let layer else { return }
        layer.removeAllAnimations()
        layer.setAffineTransform(.identity)
        layer.opacity = 1
        alphaValue = 1
        isHidden = false
        needsDisplay = true

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.16, 1.22, 0.92, 1.06, 1.0]
        scale.keyTimes = [0, 0.40, 0.66, 0.84, 1]

        let impact = CAKeyframeAnimation(keyPath: "transform.translation.x")
        impact.values = [-15, 9, -7, 5, -2, 0]
        impact.keyTimes = [0, 0.24, 0.43, 0.62, 0.80, 1]

        let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotation.values = [-0.075, 0.035, -0.022, 0.012, 0]
        rotation.keyTimes = [0, 0.34, 0.58, 0.78, 1]

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 1, 0.72, 1]
        flash.keyTimes = [0, 0.18, 0.27, 1]

        let entrance = CAAnimationGroup()
        entrance.animations = [scale, impact, rotation, flash]
        entrance.duration = 0.38
        entrance.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(entrance, forKey: "objection-entrance")

        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.visibleDuration,
            execute: workItem
        )
    }

    /// 提前收起演出。重复调用是安全的。
    func hide() {
        autoHideWorkItem?.cancel()
        finishHideWorkItem?.cancel()
        guard !isHidden, let layer else { return }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1
        fade.toValue = 0

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 0.88

        let exit = CAAnimationGroup()
        exit.animations = [fade, scale]
        exit.duration = Self.exitDuration
        exit.timingFunction = CAMediaTimingFunction(name: .easeIn)
        exit.fillMode = .forwards
        exit.isRemovedOnCompletion = false
        layer.add(exit, forKey: "objection-exit")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.layer?.removeAllAnimations()
            self.layer?.setAffineTransform(.identity)
            self.layer?.opacity = 1
            self.alphaValue = 0
            self.isHidden = true
        }
        finishHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.exitDuration,
            execute: workItem
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let center = NSPoint(x: bounds.midX, y: bounds.midY + 2)
        drawSpeedLines(around: center)
        drawBurst(around: center)
        drawTitle(around: center)
    }

    /// 覆盖层不截获桌宠原本的点击、右键或拖动事件。
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 1_000
        alphaValue = 0
        isHidden = true
    }

    private func drawSpeedLines(around center: NSPoint) {
        let outerRadius = hypot(bounds.width, bounds.height) * 0.62
        let shortRadius = min(bounds.width, bounds.height) * 0.31

        for index in 0..<34 {
            let indexValue = CGFloat(index)
            let baseAngle = (.pi * 2 * indexValue / 34) - 0.08
            let angle = baseAngle + sin(indexValue * 2.17) * 0.035
            let innerRadius = shortRadius + CGFloat(index % 4) * 4
            let rayWidth = 0.011 + CGFloat(index % 3) * 0.005

            let ray = NSBezierPath()
            ray.move(to: point(from: center, radius: innerRadius, angle: angle - rayWidth))
            ray.line(to: point(from: center, radius: outerRadius, angle: angle))
            ray.line(to: point(from: center, radius: innerRadius, angle: angle + rayWidth))
            ray.close()

            if index.isMultiple(of: 4) {
                NSColor(calibratedRed: 0.78, green: 0.03, blue: 0.02, alpha: 0.88).setFill()
            } else if index.isMultiple(of: 3) {
                NSColor(calibratedWhite: 1, alpha: 0.90).setFill()
            } else {
                NSColor(calibratedWhite: 0.03, alpha: 0.78).setFill()
            }
            ray.fill()
        }
    }

    private func drawBurst(around center: NSPoint) {
        let maxOuterX = min(116, bounds.width * 0.49)
        let maxOuterY = min(82, bounds.height * 0.34)

        let shadowCenter = NSPoint(x: center.x + 5, y: center.y - 6)
        let shadow = burstPath(
            center: shadowCenter,
            outerX: maxOuterX,
            outerY: maxOuterY,
            innerRatio: 0.73,
            teeth: 42
        )
        NSColor(calibratedWhite: 0.02, alpha: 0.92).setFill()
        shadow.fill()

        let redBurst = burstPath(
            center: center,
            outerX: maxOuterX,
            outerY: maxOuterY,
            innerRatio: 0.70,
            teeth: 42
        )
        NSColor(calibratedRed: 0.78, green: 0.025, blue: 0.015, alpha: 0.98).setFill()
        redBurst.fill()
        NSColor(calibratedWhite: 0.02, alpha: 0.96).setStroke()
        redBurst.lineWidth = 2.5
        redBurst.stroke()

        let paperBurst = burstPath(
            center: center,
            outerX: maxOuterX * 0.90,
            outerY: maxOuterY * 0.76,
            innerRatio: 0.77,
            teeth: 38
        )
        NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.86, alpha: 0.98).setFill()
        paperBurst.fill()
        NSColor(calibratedWhite: 0.04, alpha: 0.98).setStroke()
        paperBurst.lineWidth = 2.2
        paperBurst.stroke()

        let accent = burstPath(
            center: center,
            outerX: maxOuterX * 0.82,
            outerY: maxOuterY * 0.59,
            innerRatio: 0.88,
            teeth: 32
        )
        NSColor(calibratedRed: 0.78, green: 0.025, blue: 0.015, alpha: 0.65).setStroke()
        accent.lineWidth = 1.8
        accent.stroke()
    }

    private func drawTitle(around center: NSPoint) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let horizontalScale: CGFloat = 0.80
        let maximumWidth = max(80, bounds.width - 26)
        var pointSize = min(56, max(34, bounds.height * 0.225))
        var font = Self.classicFont(ofSize: pointSize, text: Self.title)
        var titleSize = measuredTitleSize(using: font)

        while titleSize.width * horizontalScale > maximumWidth, pointSize > 29 {
            pointSize -= 1
            font = Self.classicFont(ofSize: pointSize, text: Self.title)
            titleSize = measuredTitleSize(using: font)
        }

        context.saveGState()
        context.translateBy(x: center.x, y: center.y - 1)
        context.rotate(by: -4.5 * .pi / 180)
        context.scaleBy(x: horizontalScale, y: 1)

        let origin = NSPoint(x: -titleSize.width / 2, y: -titleSize.height / 2)
        let fontAttributes: [NSAttributedString.Key: Any] = [.font: font]

        // 偏移黑影：既提供原作式厚重立体感，也保证浅色桌面上仍有轮廓。
        let shadowAttributes = fontAttributes.merging([
            .foregroundColor: NSColor(calibratedWhite: 0.015, alpha: 1),
            .strokeColor: NSColor(calibratedWhite: 0.015, alpha: 1),
            .strokeWidth: -16.0,
        ]) { _, new in new }
        (Self.title as NSString).draw(
            at: NSPoint(x: origin.x + 5, y: origin.y - 5),
            withAttributes: shadowAttributes
        )

        // 宽白描边是“異議あり！”画面的主要识别特征之一。
        let outlineAttributes = fontAttributes.merging([
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.white,
            .strokeWidth: -12.0,
        ]) { _, new in new }
        (Self.title as NSString).draw(at: origin, withAttributes: outlineAttributes)

        // 红色主体配一圈极细深红内缘，避免缩小后笔画糊成一片。
        let faceAttributes = fontAttributes.merging([
            .foregroundColor: NSColor(calibratedRed: 0.90, green: 0.025, blue: 0.012, alpha: 1),
            .strokeColor: NSColor(calibratedRed: 0.38, green: 0.005, blue: 0.003, alpha: 1),
            .strokeWidth: -2.2,
        ]) { _, new in new }
        (Self.title as NSString).draw(at: origin, withAttributes: faceAttributes)

        context.restoreGState()
    }

    private func measuredTitleSize(using font: NSFont) -> NSSize {
        (Self.title as NSString).size(withAttributes: [.font: font])
    }

    private func burstPath(
        center: NSPoint,
        outerX: CGFloat,
        outerY: CGFloat,
        innerRatio: CGFloat,
        teeth: Int
    ) -> NSBezierPath {
        let path = NSBezierPath()
        let vertexCount = teeth * 2

        for index in 0..<vertexCount {
            let angle = (.pi * 2 * CGFloat(index) / CGFloat(vertexCount))
            let baseRatio = index.isMultiple(of: 2) ? 1 : innerRatio
            let irregularity = 1 + sin(CGFloat(index) * 1.73) * 0.045
            let point = NSPoint(
                x: center.x + cos(angle) * outerX * baseRatio * irregularity,
                y: center.y + sin(angle) * outerY * baseRatio * irregularity
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.close()
        path.lineJoinStyle = .miter
        return path
    }

    private func point(from center: NSPoint, radius: CGFloat, angle: CGFloat) -> NSPoint {
        NSPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }

    private static func classicFont(ofSize size: CGFloat, text: String) -> NSFont {
        // 优先标题/教科书体，再退到粗黑日文字体；每个候选都验证完整字形覆盖。
        let candidates = [
            "YuKyokasho-Bold",
            "YuKyokasho-Demibold",
            "HiraginoSans-W8",
            "HiraginoSans-W7",
            "HiraKakuProN-W6",
            "PingFangTC-Semibold",
            "PingFangHK-Semibold",
        ]
        let requiredCharacters = CharacterSet(charactersIn: text)

        for name in candidates {
            guard let font = NSFont(name: name, size: size) else { continue }
            if font.coveredCharacterSet.isSuperset(of: requiredCharacters) {
                return font
            }
        }

        // 系统粗黑字体作为最终兜底；AppKit 绘制时仍会为缺失字形做系统级联。
        return NSFont.systemFont(ofSize: size, weight: .black)
    }
}
