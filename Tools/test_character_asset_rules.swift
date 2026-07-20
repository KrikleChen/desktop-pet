import AppKit
import Foundation

@main
struct CharacterAssetRulesTestMain {
    private static let actionNames = [
        "care-check-time", "care-encourage", "care-offer-mug",
        "care-offer-water", "care-stretch", "care-tired-eye",
        "court-concentrate", "court-explain", "court-inspect-clue",
        "court-inspect-detail", "court-ready", "court-surprised",
        "work-carry-files", "work-gather-papers", "work-polish-badge",
        "work-read-case", "work-small-victory", "work-take-notes",
        "head-pet-flattened", "head-pet-rebound", "app-lift-support",
        "mouse-follow-run-stride-a", "mouse-follow-run-pass",
        "mouse-follow-run-stride-b",
    ]

    static func main() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetDirectory = repositoryRoot
            .appendingPathComponent("Assets/generated-actions", isDirectory: true)

        for actionName in actionNames {
            let url = assetDirectory.appendingPathComponent("\(actionName)-cg.png")
            guard
                let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url)),
                bitmap.pixelsWide == 512,
                bitmap.pixelsHigh == 512
            else {
                preconditionFailure("\(actionName) 必须是 512×512 PNG")
            }

            var visiblePixelCount = 0
            var canonicalRedPixelCount = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard
                        let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.alphaComponent > 0
                    else { continue }
                    visiblePixelCount += 1

                    let red = color.redComponent
                    let green = color.greenComponent
                    let blue = color.blueComponent
                    if red >= 0.47,
                       green <= 0.38,
                       blue <= 0.57,
                       red >= green * 1.7 {
                        canonicalRedPixelCount += 1
                    }
                }
            }

            precondition(
                visiblePixelCount >= 1_000,
                "\(actionName) 不能是空白或裁切残片"
            )
            precondition(
                canonicalRedPixelCount >= 100,
                "\(actionName) 未检测到足量红色领带像素"
            )
        }

        print("24 张新动作素材的尺寸、非空与红领带门禁自检通过。")
    }
}
