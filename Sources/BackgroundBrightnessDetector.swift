import AppKit
import ImageIO

/// 根据桌宠落点处的桌面内容，保守地估算背景明暗。
///
/// 同步 `detect(window:)` 不截屏，只做保守壁纸 fallback；异步 `detect(behind:)` 会在
/// 用户已授权时通过 ScreenCaptureKit 截取一次小区域真实像素。两条路径都不会主动申请
/// 录屏权限，只有显式调用 `requestPermission()` 才可能出现系统授权流程。
final class BackgroundBrightnessDetector {
    enum Classification: String {
        case dark
        case normal
        case unknown
    }

    enum DiagnosticReason: String {
        case wallpaperSampled
        case realScreenSampled
        case coveredByWindow
        case notOnMainThread
        case screenUnavailable
        case wallpaperUnavailable
        case dynamicWallpaperUnsupported
        case wallpaperDecodeFailed
        case mappingFailed
        case samplingFailed
        case screenCaptureSamplingFailed
    }

    enum SampleCoordinateSpace: String {
        /// 左下角为原点的壁纸位图像素坐标。
        case wallpaperPixels
        /// AppKit 全局桌面坐标，单位为 point，左下角为原点。
        case desktopPoints
        /// ScreenCaptureKit 返回的小区域截图像素，左下角为原点。
        case screenCapturePixels
    }

    struct Sample {
        let point: NSPoint
        let coordinateSpace: SampleCoordinateSpace
        let relativeLuminance: CGFloat
    }

    struct CoveringWindow {
        let windowNumber: CGWindowID
        let ownerPID: Int?
        let ownerName: String?
        let layer: Int

        /// Core Graphics 全局窗口坐标，原点位于主屏幕左上角，Y 轴向下。
        let boundsInQuartzCoordinates: CGRect
    }

    struct Result {
        let classification: Classification

        /// 采样区域相对亮度的中位数，范围为 0（黑）到 1（白）。
        /// 无法可靠判断时为 `nil`。
        let brightness: CGFloat?

        var isDark: Bool {
            classification == .dark
        }

        static let unknown = Result(classification: .unknown, brightness: nil)
    }

    /// `print(detector.diagnose(...))` 即可输出适合命令行验收的诊断摘要。
    struct Diagnostic: CustomStringConvertible {
        let desktopPoint: NSPoint
        let screenFrame: NSRect?
        let screenBackingScaleFactor: CGFloat?
        let wallpaperURL: URL?
        let mappedWallpaperPoint: NSPoint?
        let samples: [Sample]
        let brightness: CGFloat?
        let upperQuartileBrightness: CGFloat?
        let classification: Classification
        let reason: DiagnosticReason
        let coveringWindow: CoveringWindow?
        let screenCapture: ScreenBackgroundSampler.Diagnostic?

        var result: Result {
            Result(classification: classification, brightness: brightness)
        }

        var description: String {
            let desktop = Self.pointDescription(desktopPoint)
            let mapped = mappedWallpaperPoint.map(Self.pointDescription) ?? "nil"
            let brightnessText = brightness.map { String(format: "%.4f", Double($0)) } ?? "nil"
            let upperQuartileText = upperQuartileBrightness
                .map { String(format: "%.4f", Double($0)) } ?? "nil"
            let scaleText = screenBackingScaleFactor
                .map { String(format: "%.2f", Double($0)) } ?? "nil"
            let wallpaper = wallpaperURL?.path ?? "nil"
            let covering = coveringWindow.map {
                "\($0.ownerName ?? "unknown")#\($0.windowNumber) layer=\($0.layer) "
                    + "bounds=\(NSStringFromRect($0.boundsInQuartzCoordinates))"
            } ?? "nil"
            let capture = screenCapture?.description ?? "notAttempted"

            return "classification=\(classification.rawValue) reason=\(reason.rawValue) "
                + "desktopPoint=\(desktop) wallpaperPoint=\(mapped) "
                + "brightnessMedian=\(brightnessText) brightnessP75=\(upperQuartileText) "
                + "samples=\(samples.count) backingScale=\(scaleText) "
                + "wallpaper=\(wallpaper) coveringWindow=\(covering) "
                + "screenCapture={\(capture)}"
        }

        private static func pointDescription(_ point: NSPoint) -> String {
            String(format: "(%.2f, %.2f)", Double(point.x), Double(point.y))
        }
    }

    /// 可选的真实屏幕采样实现。调用方只有在已经自行确认权限时才应注入该闭包；
    /// 本检测器本身不会申请权限。默认 `nil`，有窗口覆盖时直接返回 `.unknown`。
    typealias ScreenSampleProvider = (_ desktopPoint: NSPoint, _ radius: CGFloat) -> [Sample]?

    static let shared = BackgroundBrightnessDetector()

    /// 中位数低于该值，且 75 分位也低于 `darkUpperQuartileThreshold`，才判定为暗。
    let darkThreshold: CGFloat
    let darkUpperQuartileThreshold: CGFloat

    /// 以桌面坐标点为中心的采样半径，单位为屏幕 point。
    let sampleRadius: CGFloat

    private let screenSampleProvider: ScreenSampleProvider?
    private let maximumBitmapDimension = 2_048
    private let maximumCacheEntryCount = 4
    private let cacheLock = NSLock()
    private var cache: [URL: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0

    init(
        darkThreshold: CGFloat = 0.075,
        darkUpperQuartileThreshold: CGFloat = 0.12,
        sampleRadius: CGFloat = 56,
        screenSampleProvider: ScreenSampleProvider? = nil
    ) {
        self.darkThreshold = max(0, min(1, darkThreshold))
        self.darkUpperQuartileThreshold = max(0, min(1, darkUpperQuartileThreshold))
        self.sampleRadius = max(1, sampleRadius)
        self.screenSampleProvider = screenSampleProvider
    }

    /// 以窗口中心作为落点进行同步检测，适合在 `PetView.mouseUp(with:)` 中调用。
    func detect(window: NSWindow) -> Result {
        diagnose(window: window).result
    }

    /// 对 AppKit 全局桌面坐标中的指定点进行同步检测。
    func detect(atDesktopPoint point: NSPoint) -> Result {
        diagnose(atDesktopPoint: point).result
    }

    /// 只预检录屏权限，不触发系统授权弹框。
    func preflightPermission() -> Bool {
        ScreenBackgroundSampler.shared.preflightPermission()
    }

    /// 显式请求录屏权限。只能从用户主动点击的菜单项或按钮调用。
    @MainActor
    @discardableResult
    func requestPermission() -> Bool {
        ScreenBackgroundSampler.shared.requestPermission()
    }

    /// 授权后异步采样桌宠窗口下方的真实像素；未授权或旧系统保守回退。
    @MainActor
    func detect(behind window: NSWindow) async -> Result {
        await diagnose(behind: window).result
    }

    /// 返回真实像素采样及 fallback 的完整诊断。一次调用只进行一张小区域截图。
    @MainActor
    func diagnose(behind window: NSWindow) async -> Diagnostic {
        let frame = window.frame
        let point = NSPoint(x: frame.midX, y: frame.midY)
        let response = await ScreenBackgroundSampler.shared.capture(
            behind: window,
            radius: sampleRadius
        )

        guard let image = response.image else {
            return attaching(screenCapture: response.diagnostic, to: diagnose(window: window))
        }
        guard let bitmap = normalizedBitmap(from: image) else {
            return unknownDiagnostic(
                at: point,
                screen: screen(containingOrNearestTo: point),
                reason: .screenCaptureSamplingFailed,
                screenCapture: response.diagnostic
            )
        }

        let center = NSPoint(
            x: CGFloat(bitmap.width - 1) / 2,
            y: CGFloat(bitmap.height - 1) / 2
        )
        let samples = bitmapSamples(
            bitmap: bitmap,
            center: center,
            radiusInPixels: CGFloat(min(bitmap.width, bitmap.height)) * 0.44,
            coordinateSpace: .screenCapturePixels
        )
        guard let summary = summarize(samples: samples) else {
            return unknownDiagnostic(
                at: point,
                screen: screen(containingOrNearestTo: point),
                reason: .screenCaptureSamplingFailed,
                screenCapture: response.diagnostic
            )
        }

        let windowNumber = window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil
        return Diagnostic(
            desktopPoint: point,
            screenFrame: screen(containingOrNearestTo: point)?.frame,
            screenBackingScaleFactor: screen(containingOrNearestTo: point)?.backingScaleFactor,
            wallpaperURL: nil,
            mappedWallpaperPoint: nil,
            samples: summary.samples,
            brightness: summary.median,
            upperQuartileBrightness: summary.upperQuartile,
            classification: summary.classification,
            reason: .realScreenSampled,
            coveringWindow: ordinaryWindowCovering(
                desktopPoint: point,
                excludingWindowNumber: windowNumber
            ),
            screenCapture: response.diagnostic
        )
    }

    /// 返回窗口中心的完整诊断信息，并从窗口遮挡判断中排除桌宠自身窗口。
    func diagnose(window: NSWindow) -> Diagnostic {
        let frame = window.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let windowNumber = window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil
        return diagnose(atDesktopPoint: center, excludingWindowNumber: windowNumber)
    }

    /// 返回完整诊断信息，可由测试或命令行小工具直接调用并打印。
    func diagnose(
        atDesktopPoint point: NSPoint,
        excludingWindowNumber: CGWindowID? = nil
    ) -> Diagnostic {
        guard Thread.isMainThread else {
            return unknownDiagnostic(at: point, reason: .notOnMainThread)
        }
        guard let screen = screen(containingOrNearestTo: point) else {
            return unknownDiagnostic(at: point, reason: .screenUnavailable)
        }

        let screenFrame = screen.frame
        let backingScale = max(1, screen.backingScaleFactor)
        let coveringWindow = ordinaryWindowCovering(
            desktopPoint: point,
            excludingWindowNumber: excludingWindowNumber
        )

        if let coveringWindow {
            if let suppliedSamples = screenSampleProvider?(point, sampleRadius),
               let summary = summarize(samples: suppliedSamples) {
                return Diagnostic(
                    desktopPoint: point,
                    screenFrame: screenFrame,
                    screenBackingScaleFactor: backingScale,
                    wallpaperURL: nil,
                    mappedWallpaperPoint: nil,
                    samples: summary.samples,
                    brightness: summary.median,
                    upperQuartileBrightness: summary.upperQuartile,
                    classification: summary.classification,
                    reason: .realScreenSampled,
                    coveringWindow: coveringWindow,
                    screenCapture: nil
                )
            }

            // 窗口元数据只能证明“不是裸露壁纸”，不能得知窗口像素颜色。
            // 因此绝不回退到壁纸暗判，避免浅色应用窗口被暗壁纸误报。
            return unknownDiagnostic(
                at: point,
                screen: screen,
                reason: .coveredByWindow,
                coveringWindow: coveringWindow
            )
        }

        guard let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: screen),
              wallpaperURL.isFileURL else {
            return unknownDiagnostic(at: point, screen: screen, reason: .wallpaperUnavailable)
        }

        let bitmap: CachedBitmap
        switch wallpaper(for: wallpaperURL) {
        case .bitmap(let decoded):
            bitmap = decoded
        case .dynamic:
            return unknownDiagnostic(
                at: point,
                screen: screen,
                wallpaperURL: wallpaperURL,
                reason: .dynamicWallpaperUnsupported
            )
        case .unavailable:
            return unknownDiagnostic(
                at: point,
                screen: screen,
                wallpaperURL: wallpaperURL,
                reason: .wallpaperDecodeFailed
            )
        }

        guard let mapping = aspectFillMapping(
            desktopPoint: point,
            screenFrame: screenFrame,
            backingScaleFactor: backingScale,
            bitmapWidth: bitmap.width,
            bitmapHeight: bitmap.height
        ) else {
            return unknownDiagnostic(
                at: point,
                screen: screen,
                wallpaperURL: wallpaperURL,
                reason: .mappingFailed
            )
        }

        let samples = bitmapSamples(
            bitmap: bitmap,
            center: mapping.imagePoint,
            radiusInPixels: sampleRadius * mapping.wallpaperPixelsPerScreenPoint,
            coordinateSpace: .wallpaperPixels
        )
        guard let summary = summarize(samples: samples) else {
            return unknownDiagnostic(
                at: point,
                screen: screen,
                wallpaperURL: wallpaperURL,
                mappedWallpaperPoint: mapping.imagePoint,
                reason: .samplingFailed
            )
        }

        return Diagnostic(
            desktopPoint: point,
            screenFrame: screenFrame,
            screenBackingScaleFactor: backingScale,
            wallpaperURL: wallpaperURL,
            mappedWallpaperPoint: mapping.imagePoint,
            samples: summary.samples,
            brightness: summary.median,
            upperQuartileBrightness: summary.upperQuartile,
            classification: summary.classification,
            reason: .wallpaperSampled,
            coveringWindow: nil,
            screenCapture: nil
        )
    }

    /// 壁纸文件被外部替换但元数据未变化时，可主动清空缓存。
    func invalidateCache() {
        cacheLock.lock()
        cache.removeAll(keepingCapacity: true)
        cacheLock.unlock()
    }

    private func unknownDiagnostic(
        at point: NSPoint,
        screen: NSScreen? = nil,
        wallpaperURL: URL? = nil,
        mappedWallpaperPoint: NSPoint? = nil,
        reason: DiagnosticReason,
        coveringWindow: CoveringWindow? = nil,
        screenCapture: ScreenBackgroundSampler.Diagnostic? = nil
    ) -> Diagnostic {
        Diagnostic(
            desktopPoint: point,
            screenFrame: screen?.frame,
            screenBackingScaleFactor: screen?.backingScaleFactor,
            wallpaperURL: wallpaperURL,
            mappedWallpaperPoint: mappedWallpaperPoint,
            samples: [],
            brightness: nil,
            upperQuartileBrightness: nil,
            classification: .unknown,
            reason: reason,
            coveringWindow: coveringWindow,
            screenCapture: screenCapture
        )
    }

    private func attaching(
        screenCapture: ScreenBackgroundSampler.Diagnostic,
        to diagnostic: Diagnostic
    ) -> Diagnostic {
        Diagnostic(
            desktopPoint: diagnostic.desktopPoint,
            screenFrame: diagnostic.screenFrame,
            screenBackingScaleFactor: diagnostic.screenBackingScaleFactor,
            wallpaperURL: diagnostic.wallpaperURL,
            mappedWallpaperPoint: diagnostic.mappedWallpaperPoint,
            samples: diagnostic.samples,
            brightness: diagnostic.brightness,
            upperQuartileBrightness: diagnostic.upperQuartileBrightness,
            classification: diagnostic.classification,
            reason: diagnostic.reason,
            coveringWindow: diagnostic.coveringWindow,
            screenCapture: screenCapture
        )
    }

    private func screen(containingOrNearestTo point: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        if let containingScreen = screens.first(where: { $0.frame.contains(point) }) {
            return containingScreen
        }

        return screens.min { lhs, rhs in
            squaredDistance(from: point, to: lhs.frame) < squaredDistance(from: point, to: rhs.frame)
        }
    }

    private func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return dx * dx + dy * dy
    }

    private func ordinaryWindowCovering(
        desktopPoint: NSPoint,
        excludingWindowNumber: CGWindowID?
    ) -> CoveringWindow? {
        guard let quartzPoint = quartzPoint(fromAppKitDesktopPoint: desktopPoint) else {
            // 坐标无法可靠转换时，调用方最终仍会走壁纸采样。正常情况下主屏幕恒存在。
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }

        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        for info in rawWindows {
            guard numberValue(info[kCGWindowLayer as String])?.intValue == 0 else { continue }
            guard numberValue(info[kCGWindowIsOnscreen as String])?.boolValue != false else { continue }
            guard (numberValue(info[kCGWindowAlpha as String])?.doubleValue ?? 1) > 0.01 else {
                continue
            }

            let windowNumber = CGWindowID(
                numberValue(info[kCGWindowNumber as String])?.uint32Value ?? 0
            )
            guard windowNumber != 0, windowNumber != excludingWindowNumber else { continue }

            let ownerPID = numberValue(info[kCGWindowOwnerPID as String])?.intValue
            guard ownerPID != ownPID else { continue }
            guard let bounds = windowBounds(info[kCGWindowBounds as String]),
                  bounds.width > 1, bounds.height > 1,
                  bounds.contains(quartzPoint) else {
                continue
            }

            return CoveringWindow(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                ownerName: info[kCGWindowOwnerName as String] as? String,
                layer: 0,
                boundsInQuartzCoordinates: bounds
            )
        }

        return nil
    }

    private func quartzPoint(fromAppKitDesktopPoint point: NSPoint) -> CGPoint? {
        // NSScreen.screens[0] 是含菜单栏的主屏幕；Quartz 全局坐标以其左上角为原点。
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        return CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    private func numberValue(_ value: Any?) -> NSNumber? {
        value as? NSNumber
    }

    private func windowBounds(_ value: Any?) -> CGRect? {
        guard let dictionary = value as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dictionary)
    }

    private func aspectFillMapping(
        desktopPoint: NSPoint,
        screenFrame: NSRect,
        backingScaleFactor: CGFloat,
        bitmapWidth: Int,
        bitmapHeight: Int
    ) -> Mapping? {
        guard screenFrame.width > 0, screenFrame.height > 0,
              bitmapWidth > 0, bitmapHeight > 0,
              backingScaleFactor.isFinite, backingScaleFactor > 0 else {
            return nil
        }

        let imageWidth = CGFloat(bitmapWidth)
        let imageHeight = CGFloat(bitmapHeight)
        let screenPixelWidth = screenFrame.width * backingScaleFactor
        let screenPixelHeight = screenFrame.height * backingScaleFactor
        let displayScale = max(
            screenPixelWidth / imageWidth,
            screenPixelHeight / imageHeight
        )
        guard displayScale.isFinite, displayScale > 0 else { return nil }

        let renderedWidth = imageWidth * displayScale
        let renderedHeight = imageHeight * displayScale
        let localPixelX = (desktopPoint.x - screenFrame.minX) * backingScaleFactor
        let localPixelY = (desktopPoint.y - screenFrame.minY) * backingScaleFactor

        // aspect-fill：壁纸先居中放大到覆盖屏幕，再裁掉超出屏幕的两边。
        let imageX = (localPixelX + (renderedWidth - screenPixelWidth) / 2) / displayScale
        let imageY = (localPixelY + (renderedHeight - screenPixelHeight) / 2) / displayScale

        return Mapping(
            imagePoint: NSPoint(
                x: max(0, min(imageWidth - 1, imageX)),
                y: max(0, min(imageHeight - 1, imageY))
            ),
            wallpaperPixelsPerScreenPoint: backingScaleFactor / displayScale
        )
    }

    private func bitmapSamples(
        bitmap: CachedBitmap,
        center: NSPoint,
        radiusInPixels: CGFloat,
        coordinateSpace: SampleCoordinateSpace
    ) -> [Sample] {
        let radius = max(1, radiusInPixels)
        let gridRadius = 4

        return bitmap.pixels.withUnsafeBytes { rawBuffer -> [Sample] in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return []
            }

            var samples: [Sample] = []
            samples.reserveCapacity(49)

            for gridY in -gridRadius...gridRadius {
                for gridX in -gridRadius...gridRadius {
                    let normalizedX = CGFloat(gridX) / CGFloat(gridRadius)
                    let normalizedY = CGFloat(gridY) / CGFloat(gridRadius)
                    let distanceSquared = normalizedX * normalizedX + normalizedY * normalizedY
                    guard distanceSquared <= 1 else { continue }

                    let sampleX = Int((center.x + normalizedX * radius).rounded())
                    let sampleY = Int((center.y + normalizedY * radius).rounded())
                    let x = max(0, min(bitmap.width - 1, sampleX))
                    let yFromBottom = max(0, min(bitmap.height - 1, sampleY))

                    // CGContext 的位图内存第 0 行是视觉顶部；映射坐标则沿用 AppKit/Quartz
                    // 绘图空间的左下原点，因此读取字节时必须翻转 Y。
                    let memoryRow = bitmap.height - 1 - yFromBottom
                    let offset = memoryRow * bitmap.bytesPerRow + x * 4

                    let alpha = CGFloat(bytes[offset + 3]) / 255
                    guard alpha > 0.99 else { continue }
                    let red = CGFloat(bytes[offset]) / 255
                    let green = CGFloat(bytes[offset + 1]) / 255
                    let blue = CGFloat(bytes[offset + 2]) / 255

                    samples.append(Sample(
                        point: NSPoint(x: x, y: yFromBottom),
                        coordinateSpace: coordinateSpace,
                        relativeLuminance: relativeLuminance(red: red, green: green, blue: blue)
                    ))
                }
            }

            return samples
        }
    }

    private func summarize(samples: [Sample]) -> SampleSummary? {
        let validSamples = samples.filter {
            $0.relativeLuminance.isFinite
                && $0.relativeLuminance >= 0
                && $0.relativeLuminance <= 1
        }
        // 少量单点不足以可靠暗判；壁纸标准采样正常会得到 49 个点。
        guard validSamples.count >= 9 else { return nil }

        let sorted = validSamples.map(\.relativeLuminance).sorted()
        let median = percentile(sorted, fraction: 0.5)
        let upperQuartile = percentile(sorted, fraction: 0.75)

        // 只有采样区域的大多数像素都很暗时才触发怕黑；边界和中灰统一按 normal。
        let classification: Classification =
            median < darkThreshold && upperQuartile < darkUpperQuartileThreshold
            ? .dark
            : .normal

        return SampleSummary(
            samples: validSamples,
            median: median,
            upperQuartile: upperQuartile,
            classification: classification
        )
    }

    private func percentile(_ sortedValues: [CGFloat], fraction: CGFloat) -> CGFloat {
        guard sortedValues.count > 1 else { return sortedValues[0] }
        let position = max(0, min(1, fraction)) * CGFloat(sortedValues.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }
        let interpolation = position - CGFloat(lowerIndex)
        return sortedValues[lowerIndex]
            + (sortedValues[upperIndex] - sortedValues[lowerIndex]) * interpolation
    }

    private func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        0.2126 * linearizedSRGB(red)
            + 0.7152 * linearizedSRGB(green)
            + 0.0722 * linearizedSRGB(blue)
    }

    private func linearizedSRGB(_ component: CGFloat) -> CGFloat {
        if component <= 0.04045 {
            return component / 12.92
        }
        return CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }

    private func wallpaper(for url: URL) -> CachedWallpaper {
        let key = normalizedCacheKey(for: url)
        let fingerprint = fileFingerprint(for: key)

        cacheLock.lock()
        accessCounter &+= 1
        let currentAccess = accessCounter
        if var cached = cache[key], cached.fingerprint == fingerprint {
            cached.lastAccess = currentAccess
            cache[key] = cached
            cacheLock.unlock()
            return cached.wallpaper
        }
        cacheLock.unlock()

        let decoded = decodeWallpaper(at: key)
        guard case .unavailable = decoded else {
            cacheLock.lock()
            cache[key] = CacheEntry(
                wallpaper: decoded,
                fingerprint: fingerprint,
                lastAccess: currentAccess
            )
            evictLeastRecentlyUsedEntryIfNeeded(excluding: key)
            cacheLock.unlock()
            return decoded
        }
        return .unavailable
    }

    private func normalizedCacheKey(for url: URL) -> URL {
        guard url.isFileURL else { return url.absoluteURL }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func fileFingerprint(for url: URL) -> FileFingerprint {
        guard url.isFileURL else { return FileFingerprint(modificationDate: nil, fileSize: nil) }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileFingerprint(
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize
        )
    }

    private func decodeWallpaper(at url: URL) -> CachedWallpaper {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return .unavailable
        }
        // 多帧 HEIC/动态壁纸的第 0 帧不等于当前屏幕帧，不能拿它做暗判。
        guard CGImageSourceGetCount(source) == 1 else { return .dynamic }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumBitmapDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .unavailable
        }

        guard let bitmap = normalizedBitmap(from: image) else { return .unavailable }
        return .bitmap(bitmap)
    }

    private func normalizedBitmap(from image: CGImage) -> CachedBitmap? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let bytesPerRow = width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // 在 sRGB 白底上合成，既完成源色彩空间转换，也避免透明像素被当成黑色。
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }

        return CachedBitmap(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(bytes: data, count: bytesPerRow * height)
        )
    }

    private func evictLeastRecentlyUsedEntryIfNeeded(excluding protectedKey: URL) {
        guard cache.count > maximumCacheEntryCount else { return }
        let candidate = cache
            .filter { $0.key != protectedKey }
            .min { $0.value.lastAccess < $1.value.lastAccess }
        if let key = candidate?.key {
            cache.removeValue(forKey: key)
        }
    }
}

private extension BackgroundBrightnessDetector {
    struct Mapping {
        let imagePoint: NSPoint
        let wallpaperPixelsPerScreenPoint: CGFloat
    }

    struct SampleSummary {
        let samples: [Sample]
        let median: CGFloat
        let upperQuartile: CGFloat
        let classification: Classification
    }

    struct CachedBitmap {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixels: Data
    }

    enum CachedWallpaper {
        case bitmap(CachedBitmap)
        case dynamic
        case unavailable
    }

    struct FileFingerprint: Equatable {
        let modificationDate: Date?
        let fileSize: Int?
    }

    struct CacheEntry {
        let wallpaper: CachedWallpaper
        let fingerprint: FileFingerprint
        var lastAccess: UInt64
    }
}
