import AppKit

@main
struct GrabRegionTestMain {
    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let imageURL = root.appendingPathComponent("Assets/idle-cg.png")
        guard let image = NSImage(contentsOf: imageURL) else {
            fatalError("无法读取 \(imageURL.path)")
        }

        let imageViewFrame = NSRect(x: 6, y: 0, width: 228, height: 220)
        var counts: [GrabRegion: Int] = [:]
        var transparentCount = 0

        for y in stride(from: imageViewFrame.minY, through: imageViewFrame.maxY, by: 2) {
            for x in stride(from: imageViewFrame.minX, through: imageViewFrame.maxX, by: 2) {
                let point = NSPoint(x: x, y: y)
                if let region = GrabRegionDetector.shared.detect(
                    at: point,
                    imageViewFrame: imageViewFrame,
                    image: image
                ) {
                    counts[region, default: 0] += 1
                } else {
                    transparentCount += 1
                }
            }
        }

        for region in GrabRegion.allCases {
            print("\(region.rawValue): \(counts[region, default: 0])")
        }
        print("transparent: \(transparentCount)")

        guard GrabRegion.allCases.allSatisfy({ counts[$0, default: 0] > 0 }) else {
            fatalError("未能命中全部抓取区域")
        }
    }
}
