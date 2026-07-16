import AppKit

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PetPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let windowSize = NSSize(width: 240, height: 260)
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let screenFrame = targetScreen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: max(screenFrame.minX, screenFrame.maxX - windowSize.width - 24),
            y: screenFrame.minY + 18
        )

        let panel = PetPanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.sharingType = .readOnly
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let images = loadImages()
        let petView = PetView(
            frame: NSRect(origin: .zero, size: windowSize),
            images: images
        )
        panel.contentView = petView
        panel.orderFrontRegardless()
        self.panel = panel

        let launchArguments = ProcessInfo.processInfo.arguments
        if let flagIndex = launchArguments.firstIndex(of: "--preview-action"),
           launchArguments.indices.contains(flagIndex + 1),
           let action = PetAction(rawValue: launchArguments[flagIndex + 1]) {
            NSLog("桌宠验收预览：%@", action.rawValue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                petView.preview(action)
            }
        }
        if let flagIndex = launchArguments.firstIndex(of: "--preview-edge-idle"),
           launchArguments.indices.contains(flagIndex + 1),
           let edge = EdgeIdleBehavior.Edge(rawValue: launchArguments[flagIndex + 1]) {
            NSLog("桌宠验收预览边缘待机：%@", edge.rawValue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                petView.previewEdgeIdle(edge)
            }
        }

        NSApp.activate(ignoringOtherApps: false)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func loadImages() -> [PetAction: NSImage] {
        var result: [PetAction: NSImage] = [:]
        for action in PetAction.allCases {
            guard
                let url = Bundle.main.url(forResource: "\(action.rawValue)-cg", withExtension: "png"),
                let image = NSImage(contentsOf: url)
            else {
                fatalError("缺少动作素材：\(action.rawValue)-cg.png")
            }
            result[action] = image
        }
        return result
    }
}
