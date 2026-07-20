import AppKit
import Foundation

/// 只清理透明边界附近的紫色溢色，不改动人物内部色块。
@main
struct StripPurpleFringe {
    static func main() throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            fputs("usage: strip_purple_fringe <png> [png ...]\n", stderr)
            Foundation.exit(2)
        }

        for path in paths {
            try clean(path: path)
        }
    }

    private static func clean(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let sourceData = try Data(contentsOf: url)
        guard let bitmap = NSBitmapImageRep(data: sourceData) else {
            throw NSError(
                domain: "StripPurpleFringe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法解码 PNG：\(path)"]
            )
        }

        var replacements: [(x: Int, y: Int, color: NSColor)] = []
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    color.alphaComponent > 0,
                    isPurpleFringe(color),
                    touchesTransparency(x: x, y: y, in: bitmap)
                else { continue }

                let red = color.redComponent
                let green = color.greenComponent
                let blue = color.blueComponent
                let neutral = min(0.22, max(0.035, (red + green + blue) / 7.5))
                replacements.append((
                    x,
                    y,
                    NSColor(
                        deviceRed: neutral,
                        green: neutral,
                        blue: min(0.24, neutral + 0.012),
                        alpha: color.alphaComponent
                    )
                ))
            }
        }

        for replacement in replacements {
            bitmap.setColor(
                replacement.color,
                atX: replacement.x,
                y: replacement.y
            )
        }

        guard let output = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "StripPurpleFringe",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG：\(path)"]
            )
        }
        try output.write(to: url, options: .atomic)
        print("\(path): 清理 \(replacements.count) 个边缘紫色像素")
    }

    private static func isPurpleFringe(_ color: NSColor) -> Bool {
        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        return red >= 0.04
            && blue >= 0.04
            && blue >= red * 0.30
            && green <= min(red, blue) * 0.92
    }

    private static func touchesTransparency(
        x: Int,
        y: Int,
        in bitmap: NSBitmapImageRep
    ) -> Bool {
        let radius = 5
        for offsetY in -radius...radius {
            for offsetX in -radius...radius where offsetX != 0 || offsetY != 0 {
                let neighborX = x + offsetX
                let neighborY = y + offsetY
                guard
                    neighborX >= 0,
                    neighborY >= 0,
                    neighborX < bitmap.pixelsWide,
                    neighborY < bitmap.pixelsHigh
                else { return true }

                if (bitmap.colorAt(x: neighborX, y: neighborY)?.alphaComponent ?? 0) == 0 {
                    return true
                }
            }
        }
        return false
    }
}
