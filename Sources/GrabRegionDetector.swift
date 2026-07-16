import AppKit
import CoreGraphics

/// 桌宠被抓住的角色部位。
enum GrabRegion: String, CaseIterable {
    case hairHead = "hair/head"
    case arm
    case collarTorso = "collar/torso"
    case leg
}

/// 一次透明度命中的完整结果，便于 `PetView` 选择拖拽动画。
struct GrabRegionHit {
    let region: GrabRegion

    /// `NSImage` 在 `PetView` 中经过 `.scaleProportionallyUpOrDown` 后的真实绘制区域。
    let drawnImageRect: NSRect

    /// 相对整张图的坐标：左下角为 (0, 0)，右上角为 (1, 1)。
    let normalizedImagePoint: NSPoint

    /// 相对角色实际非透明主体的坐标，坐标方向同上。
    let normalizedCharacterPoint: NSPoint

    /// 命中像素的 alpha，范围 0...1。
    let alpha: CGFloat
}

/// 使用实际 PNG alpha 判断拖拽抓取部位。所有 API 都是同步的。
///
/// 输入点和 `imageViewFrame` 必须使用同一个 `PetView` 坐标系。
/// `PetView` 当前没有翻转坐标，因此 y 轴向上。
final class GrabRegionDetector {
    static let shared = GrabRegionDetector()

    /// 小于该值的抗锯齿边缘会被当作透明，避免点到角色外的柔边。
    private static let alphaHitThreshold: UInt8 = 20

    private let maskCache = NSCache<NSImage, AlphaMask>()

    init() {
        // 512x512 素材约占 256 KiB alpha；控制在轻量桌宠可接受的范围内。
        maskCache.totalCostLimit = 12 * 1_024 * 1_024
        maskCache.countLimit = 24
    }

    /// 最简便的调用方式；点在图片留白或透明处时返回 `nil`。
    func detect(
        at pointInPetView: NSPoint,
        imageViewFrame: NSRect,
        image: NSImage
    ) -> GrabRegion? {
        hitTest(
            at: pointInPetView,
            imageViewFrame: imageViewFrame,
            image: image
        )?.region
    }

    /// 返回部位、alpha 以及归一化坐标，供需要细化动画的调用方使用。
    func hitTest(
        at pointInPetView: NSPoint,
        imageViewFrame: NSRect,
        image: NSImage
    ) -> GrabRegionHit? {
        guard
            imageViewFrame.width > 0,
            imageViewFrame.height > 0,
            let mask = alphaMask(for: image)
        else {
            return nil
        }

        let drawRect = Self.drawnImageRect(
            imageViewFrame: imageViewFrame,
            image: image,
            pixelSizeFallback: NSSize(width: mask.width, height: mask.height)
        )
        guard
            drawRect.width > 0,
            drawRect.height > 0,
            pointInPetView.x >= drawRect.minX,
            pointInPetView.x <= drawRect.maxX,
            pointInPetView.y >= drawRect.minY,
            pointInPetView.y <= drawRect.maxY
        else {
            return nil
        }

        let normalizedX = Self.clampUnit(
            (pointInPetView.x - drawRect.minX) / drawRect.width
        )
        let normalizedY = Self.clampUnit(
            (pointInPetView.y - drawRect.minY) / drawRect.height
        )

        let pixelX = min(mask.width - 1, Int(floor(normalizedX * CGFloat(mask.width))))
        // CGImage 解码后的扫描行从顶部开始，而 PetView 的 y=0 在底部。
        let pixelYFromTop = min(
            mask.height - 1,
            Int(floor((1 - normalizedY) * CGFloat(mask.height)))
        )
        let pixelIndex = pixelYFromTop * mask.width + pixelX
        let alphaByte = mask.alpha[pixelIndex]

        guard
            alphaByte >= Self.alphaHitThreshold,
            mask.characterPixels[pixelIndex] != 0
        else {
            return nil
        }

        let characterBounds = mask.characterBounds
        let characterWidth = max(1, characterBounds.maxX - characterBounds.minX)
        let characterHeight = max(1, characterBounds.maxY - characterBounds.minY)

        let characterX = Self.clampUnit(
            CGFloat(pixelX - characterBounds.minX) / CGFloat(characterWidth)
        )
        // characterBounds 同样是自顶向下的像素坐标，转成自底向上。
        let characterY = Self.clampUnit(
            CGFloat(characterBounds.maxY - pixelYFromTop) / CGFloat(characterHeight)
        )
        let characterPoint = NSPoint(x: characterX, y: characterY)

        return GrabRegionHit(
            region: Self.classify(normalizedCharacterPoint: characterPoint),
            drawnImageRect: drawRect,
            normalizedImagePoint: NSPoint(x: normalizedX, y: normalizedY),
            normalizedCharacterPoint: characterPoint,
            alpha: CGFloat(alphaByte) / 255
        )
    }

    /// 计算 `NSImageView.imageScaling = .scaleProportionallyUpOrDown` 且居中时的真实绘制区域。
    static func drawnImageRect(
        imageViewFrame: NSRect,
        image: NSImage
    ) -> NSRect {
        drawnImageRect(
            imageViewFrame: imageViewFrame,
            image: image,
            pixelSizeFallback: nil
        )
    }

    private static func drawnImageRect(
        imageViewFrame: NSRect,
        image: NSImage,
        pixelSizeFallback: NSSize?
    ) -> NSRect {
        let logicalSize: NSSize
        if image.size.width > 0, image.size.height > 0 {
            // NSImage.size 是 AppKit 实际排版使用的 point 大小，对 @2x/@3x 表示正确。
            logicalSize = image.size
        } else if let pixelSizeFallback {
            logicalSize = pixelSizeFallback
        } else {
            return .zero
        }

        guard
            logicalSize.width > 0,
            logicalSize.height > 0,
            imageViewFrame.width > 0,
            imageViewFrame.height > 0
        else {
            return .zero
        }

        let scale = min(
            imageViewFrame.width / logicalSize.width,
            imageViewFrame.height / logicalSize.height
        )
        let drawnSize = NSSize(
            width: logicalSize.width * scale,
            height: logicalSize.height * scale
        )

        return NSRect(
            x: imageViewFrame.midX - drawnSize.width / 2,
            y: imageViewFrame.midY - drawnSize.height / 2,
            width: drawnSize.width,
            height: drawnSize.height
        )
    }

    private static func classify(normalizedCharacterPoint point: NSPoint) -> GrabRegion {
        // 顶部优先判为头发/头部；底部优先判为腿脚。
        if point.y >= 0.72 {
            return .hairHead
        }
        if point.y <= 0.30 {
            return .leg
        }

        // 中部两侧是手臂；肩部附近略微放宽，适配指向和叉腰姿势。
        let sideInset: CGFloat = point.y >= 0.58 ? 0.34 : 0.29
        if point.x <= sideInset || point.x >= 1 - sideInset {
            return .arm
        }

        return .collarTorso
    }

    private func alphaMask(for image: NSImage) -> AlphaMask? {
        if let cached = maskCache.object(forKey: image) {
            return cached
        }

        guard
            let cgImage = Self.bestCGImage(for: image),
            let mask = AlphaMask(cgImage: cgImage, threshold: Self.alphaHitThreshold)
        else {
            return nil
        }

        maskCache.setObject(mask, forKey: image, cost: mask.alpha.count + mask.characterPixels.count)
        return mask
    }

    private static func bestCGImage(for image: NSImage) -> CGImage? {
        // 多表示 NSImage 优先选最高像素密度，避免 Retina 下用到低清 alpha mask。
        let bitmapRepresentations = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let best = bitmapRepresentations.max(by: {
            $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh
        }), let cgImage = best.cgImage {
            return cgImage
        }

        var proposedRect = NSRect(origin: .zero, size: image.size)
        if proposedRect.width <= 0 || proposedRect.height <= 0 {
            proposedRect.size = NSSize(width: 1, height: 1)
        }
        return image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
    }

    private static func clampUnit(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}

private final class AlphaMask: NSObject {
    struct PixelBounds {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    let width: Int
    let height: Int
    let alpha: [UInt8]
    let characterPixels: [UInt8]
    let characterBounds: PixelBounds

    init?(cgImage: CGImage, threshold: UInt8) {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        let didDraw = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard didDraw else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        for pixelIndex in alpha.indices {
            alpha[pixelIndex] = rgba[pixelIndex * 4 + 3]
        }

        guard let component = Self.findCharacterComponent(
            alpha: alpha,
            width: width,
            height: height,
            threshold: threshold
        ) else {
            return nil
        }

        self.width = width
        self.height = height
        self.alpha = alpha
        self.characterPixels = component.pixels
        self.characterBounds = component.bounds
        super.init()
    }

    /// 将飞出的徽章、速度线等独立配件与角色主体分开。
    /// 打分同时考虑面积、竖直跨度和靠近画面中心的程度。
    private static func findCharacterComponent(
        alpha: [UInt8],
        width: Int,
        height: Int,
        threshold: UInt8
    ) -> (pixels: [UInt8], bounds: PixelBounds)? {
        var visited = [UInt8](repeating: 0, count: alpha.count)
        var bestIndices: [Int] = []
        var bestBounds: PixelBounds?
        var bestScore = -Double.infinity
        var queue: [Int] = []
        queue.reserveCapacity(min(alpha.count, 65_536))

        for startIndex in alpha.indices {
            guard alpha[startIndex] >= threshold, visited[startIndex] == 0 else { continue }

            queue.removeAll(keepingCapacity: true)
            queue.append(startIndex)
            visited[startIndex] = 1
            var cursor = 0
            var minX = startIndex % width
            var maxX = minX
            var minY = startIndex / width
            var maxY = minY

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)

                let lowerY = max(0, y - 1)
                let upperY = min(height - 1, y + 1)
                let lowerX = max(0, x - 1)
                let upperX = min(width - 1, x + 1)

                for neighborY in lowerY...upperY {
                    for neighborX in lowerX...upperX {
                        if neighborX == x, neighborY == y { continue }
                        let neighborIndex = neighborY * width + neighborX
                        guard
                            visited[neighborIndex] == 0,
                            alpha[neighborIndex] >= threshold
                        else {
                            continue
                        }
                        visited[neighborIndex] = 1
                        queue.append(neighborIndex)
                    }
                }
            }

            let componentHeight = maxY - minY + 1
            let centerX = (Double(minX) + Double(maxX)) / 2 / Double(width)
            let centerWeight = max(0.35, 1 - abs(centerX - 0.5) * 1.4)
            let heightWeight = 0.5 + 1.8 * Double(componentHeight) / Double(height)
            let score = Double(queue.count) * centerWeight * heightWeight

            if score > bestScore {
                bestScore = score
                bestIndices = queue
                bestBounds = PixelBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            }
        }

        guard let bestBounds, !bestIndices.isEmpty else { return nil }
        var pixels = [UInt8](repeating: 0, count: alpha.count)
        for index in bestIndices {
            pixels[index] = 1
        }
        return (pixels, bestBounds)
    }
}
