import CoreGraphics
import Foundation
import ImageIO

@main
struct CropSpriteSheet {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 7 else {
            fputs(
                "usage: crop_sprite_sheet <sheet> <top-left> <top-center> <top-right> <bottom-left> <bottom-center> <bottom-right>\n",
                stderr
            )
            Foundation.exit(2)
        }

        let sourceURL = URL(fileURLWithPath: arguments[0]) as CFURL
        guard
            let source = CGImageSourceCreateWithURL(sourceURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw failure("无法读取精灵总图：\(arguments[0])")
        }
        guard image.width == 1_536, image.height == 1_024 else {
            throw failure("精灵总图必须是 1536×1024：\(arguments[0])")
        }

        let cells = [
            CGRect(x: 0, y: 0, width: 512, height: 512),
            CGRect(x: 512, y: 0, width: 512, height: 512),
            CGRect(x: 1_024, y: 0, width: 512, height: 512),
            CGRect(x: 0, y: 512, width: 512, height: 512),
            CGRect(x: 512, y: 512, width: 512, height: 512),
            CGRect(x: 1_024, y: 512, width: 512, height: 512),
        ]

        for (index, rect) in cells.enumerated() {
            guard let cropped = image.cropping(to: rect) else {
                throw failure("无法裁切第 \(index + 1) 个单元格")
            }
            let outputURL = URL(fileURLWithPath: arguments[index + 1])
            guard let destination = CGImageDestinationCreateWithURL(
                outputURL as CFURL,
                "public.png" as CFString,
                1,
                nil
            ) else {
                throw failure("无法创建输出：\(outputURL.path)")
            }
            CGImageDestinationAddImage(destination, cropped, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw failure("无法写入输出：\(outputURL.path)")
            }
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "CropSpriteSheet",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
