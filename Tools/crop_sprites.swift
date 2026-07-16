import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("Assets/spritesheet-alpha.png")

guard
    let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fatalError("无法读取精灵表：\(sourceURL.path)")
}

let sprites: [(name: String, column: Int, row: Int)] = [
    ("idle", 0, 0),
    ("think", 1, 0),
    ("objection", 2, 0),
    ("slam", 0, 1),
    ("sweat", 1, 1),
    ("evidence", 2, 1),
]

let cellWidth = image.width / 3
let cellHeight = image.height / 2

for sprite in sprites {
    let rect = CGRect(
        x: sprite.column * cellWidth,
        y: sprite.row * cellHeight,
        width: cellWidth,
        height: cellHeight
    )

    guard let cropped = image.cropping(to: rect) else {
        fatalError("无法裁剪动作：\(sprite.name)")
    }

    let outputURL = root.appendingPathComponent("Assets/\(sprite.name)-cg.png")
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法创建输出文件：\(outputURL.path)")
    }

    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("无法保存动作：\(sprite.name)")
    }

    print("已生成 \(outputURL.lastPathComponent)")
}

let interactionSourceURL = root.appendingPathComponent("Assets/interaction-spritesheet-alpha.png")
guard
    let interactionSource = CGImageSourceCreateWithURL(interactionSourceURL as CFURL, nil),
    let interactionImage = CGImageSourceCreateImageAtIndex(interactionSource, 0, nil)
else {
    fatalError("无法读取互动精灵表：\(interactionSourceURL.path)")
}

let interactionSprites: [(name: String, column: Int, row: Int)] = [
    ("held-struggle", 0, 0),
    ("held-resigned", 1, 0),
    ("afraid-dark", 2, 0),
    ("flashlight", 0, 1),
    ("sleepy", 1, 1),
    ("dropped", 2, 1),
]

let interactionCellWidth = interactionImage.width / 3
let interactionCellHeight = interactionImage.height / 2

for sprite in interactionSprites {
    let rect = CGRect(
        x: sprite.column * interactionCellWidth,
        y: sprite.row * interactionCellHeight,
        width: interactionCellWidth,
        height: interactionCellHeight
    )

    guard let cropped = interactionImage.cropping(to: rect) else {
        fatalError("无法裁剪互动动作：\(sprite.name)")
    }

    let outputURL = root.appendingPathComponent("Assets/\(sprite.name)-cg.png")
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法创建输出文件：\(outputURL.path)")
    }

    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("无法保存互动动作：\(sprite.name)")
    }

    print("已生成 \(outputURL.lastPathComponent)")
}

let easterEggSourceURL = root.appendingPathComponent("Assets/character-easter-eggs-alpha.png")
guard
    let easterEggSource = CGImageSourceCreateWithURL(easterEggSourceURL as CFURL, nil),
    let easterEggImage = CGImageSourceCreateImageAtIndex(easterEggSource, 0, nil)
else {
    fatalError("无法读取角色彩蛋精灵表：\(easterEggSourceURL.path)")
}

let easterEggSprites: [(name: String, column: Int, row: Int)] = [
    ("badge-toss", 0, 0),
    ("magatama", 1, 0),
    ("stepladder", 2, 0),
    ("thinker", 0, 1),
    ("heard-name", 1, 1),
    ("decisive-evidence", 2, 1),
]

let easterEggCellWidth = easterEggImage.width / 3
let easterEggCellHeight = easterEggImage.height / 2

for sprite in easterEggSprites {
    let rect = CGRect(
        x: sprite.column * easterEggCellWidth,
        y: sprite.row * easterEggCellHeight,
        width: easterEggCellWidth,
        height: easterEggCellHeight
    )

    guard let cropped = easterEggImage.cropping(to: rect) else {
        fatalError("无法裁剪角色彩蛋动作：\(sprite.name)")
    }

    let outputURL = root.appendingPathComponent("Assets/\(sprite.name)-cg.png")
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法创建输出文件：\(outputURL.path)")
    }

    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("无法保存角色彩蛋动作：\(sprite.name)")
    }

    print("已生成 \(outputURL.lastPathComponent)")
}

let grabRegionSourceURL = root.appendingPathComponent("Assets/grab-regions-alpha.png")
guard
    let grabRegionSource = CGImageSourceCreateWithURL(grabRegionSourceURL as CFURL, nil),
    let grabRegionImage = CGImageSourceCreateImageAtIndex(grabRegionSource, 0, nil)
else {
    fatalError("无法读取部位拖拽精灵表：\(grabRegionSourceURL.path)")
}

let grabRegionSprites: [(name: String, column: Int, row: Int)] = [
    ("hair-struggle", 0, 0),
    ("arm-struggle", 1, 0),
    ("leg-struggle", 2, 0),
    ("hair-resigned", 0, 1),
    ("arm-resigned", 1, 1),
    ("leg-resigned", 2, 1),
]

let grabRegionCellWidth = grabRegionImage.width / 3
let grabRegionCellHeight = grabRegionImage.height / 2

for sprite in grabRegionSprites {
    let rect = CGRect(
        x: sprite.column * grabRegionCellWidth,
        y: sprite.row * grabRegionCellHeight,
        width: grabRegionCellWidth,
        height: grabRegionCellHeight
    )

    guard let cropped = grabRegionImage.cropping(to: rect) else {
        fatalError("无法裁剪部位拖拽动作：\(sprite.name)")
    }

    let outputURL = root.appendingPathComponent("Assets/\(sprite.name)-cg.png")
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法创建输出文件：\(outputURL.path)")
    }

    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("无法保存部位拖拽动作：\(sprite.name)")
    }

    print("已生成 \(outputURL.lastPathComponent)")
}

let throwSourceURL = root.appendingPathComponent("Assets/throw-sprites-alpha.png")
guard
    let throwSource = CGImageSourceCreateWithURL(throwSourceURL as CFURL, nil),
    let throwImage = CGImageSourceCreateImageAtIndex(throwSource, 0, nil)
else {
    fatalError("无法读取甩飞精灵表：\(throwSourceURL.path)")
}

let throwSprites: [(name: String, column: Int, row: Int)] = [
    ("thrown", 0, 0),
    ("spinning", 1, 0),
    ("impact", 2, 0),
    ("dizzy", 0, 1),
    ("dusting", 1, 1),
    ("irritated", 2, 1),
]

let throwCellWidth = throwImage.width / 3
let throwCellHeight = throwImage.height / 2

for sprite in throwSprites {
    let rect = CGRect(
        x: sprite.column * throwCellWidth,
        y: sprite.row * throwCellHeight,
        width: throwCellWidth,
        height: throwCellHeight
    )

    guard let cropped = throwImage.cropping(to: rect) else {
        fatalError("无法裁剪甩飞动作：\(sprite.name)")
    }

    let outputURL = root.appendingPathComponent("Assets/\(sprite.name)-cg.png")
    guard let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("无法创建输出文件：\(outputURL.path)")
    }

    CGImageDestinationAddImage(destination, cropped, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("无法保存甩飞动作：\(sprite.name)")
    }

    print("已生成 \(outputURL.lastPathComponent)")
}
