import AppKit

@main
struct BackgroundDiagnosticMain {
    static func main() {
        let arguments = CommandLine.arguments
        let point: NSPoint

        if arguments.count >= 3,
           let x = Double(arguments[1]),
           let y = Double(arguments[2]) {
            point = NSPoint(x: x, y: y)
        } else {
            point = NSEvent.mouseLocation
        }

        print(BackgroundBrightnessDetector.shared.diagnose(atDesktopPoint: point))
    }
}
