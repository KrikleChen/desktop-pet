import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Assets/accessory-scatter-source.png")
let alphaURL = root.appendingPathComponent("Assets/accessory-scatter-alpha.png")

guard
    let sourceImage = NSImage(contentsOf: sourceURL),
    let sourceData = sourceImage.tiffRepresentation,
    let sourceBitmap = NSBitmapImageRep(data: sourceData),
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: sourceBitmap.pixelsWide,
        pixelsHigh: sourceBitmap.pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
else {
    fatalError("无法读取散落道具精灵表：\(sourceURL.path)")
}

for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
        guard let color = sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            continue
        }

        let red = color.redComponent
        let green = color.greenComponent
        let blue = color.blueComponent
        let magentaStrength = min(red, blue) - green
        let keyedAlpha: CGFloat
        if magentaStrength >= 0.55 && red >= 0.72 && blue >= 0.72 {
            keyedAlpha = 0
        } else if magentaStrength > 0.25 && red >= 0.58 && blue >= 0.58 {
            keyedAlpha = color.alphaComponent * (0.55 - magentaStrength) / 0.30
        } else {
            keyedAlpha = color.alphaComponent
        }

        let spill = max(0, magentaStrength) * min(1, 1 - keyedAlpha)
        bitmap.setColor(
            NSColor(
                deviceRed: max(0, red - spill),
                green: green,
                blue: max(0, blue - spill),
                alpha: max(0, min(1, keyedAlpha))
            ),
            atX: x,
            y: y
        )
    }
}

guard let alphaData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法生成透明散落道具精灵表")
}
try alphaData.write(to: alphaURL)

let columns = 3
let rows = 2
let cellWidth = bitmap.pixelsWide / columns
let cellHeight = bitmap.pixelsHigh / rows
let names = [
    "scatter-attorney-badge-cg",
    "scatter-case-file-cg",
    "scatter-magatama-cg",
    "scatter-evidence-cg",
    "scatter-pen-cg",
    "scatter-notes-cg",
]

for index in names.indices {
    let column = index % columns
    let rowFromTop = index / columns
    let originX = column * cellWidth
    let originY = (rows - 1 - rowFromTop) * cellHeight

    var minimumX = originX + cellWidth
    var maximumX = originX
    var minimumY = originY + cellHeight
    var maximumY = originY

    for y in originY..<(originY + cellHeight) {
        for x in originX..<(originX + cellWidth) {
            guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.04 else {
                continue
            }
            minimumX = min(minimumX, x)
            maximumX = max(maximumX, x)
            minimumY = min(minimumY, y)
            maximumY = max(maximumY, y)
        }
    }

    guard minimumX <= maximumX, minimumY <= maximumY else {
        fatalError("散落道具 \(names[index]) 没有有效像素")
    }

    let padding = 12
    minimumX = max(originX, minimumX - padding)
    maximumX = min(originX + cellWidth - 1, maximumX + padding)
    minimumY = max(originY, minimumY - padding)
    maximumY = min(originY + cellHeight - 1, maximumY + padding)

    let cropRect = NSRect(
        x: minimumX,
        y: minimumY,
        width: maximumX - minimumX + 1,
        height: maximumY - minimumY + 1
    )
    guard let cropped = bitmap.cgImage?.cropping(to: cropRect) else {
        fatalError("无法裁剪散落道具：\(names[index])")
    }

    let output = NSBitmapImageRep(cgImage: cropped)
    guard let outputData = output.representation(using: .png, properties: [:]) else {
        fatalError("无法编码散落道具：\(names[index])")
    }
    try outputData.write(
        to: root.appendingPathComponent("Assets/\(names[index]).png")
    )
}

print("已生成 6 个透明散落道具素材。")
