import AppKit
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

/// 使用 ScreenCaptureKit 对桌宠窗口下方做一次性、小区域截图。
///
/// 本类型不会主动申请录屏权限。只有调用方显式调用 `requestPermission()` 才会出现
/// 系统授权流程；`capture(behind:radius:)` 在未授权时直接返回 `.permissionDenied`。
final class ScreenBackgroundSampler {
    enum Status: String {
        case captured
        case unsupportedSystem
        case permissionDenied
        case displayUnavailable
        case petWindowUnavailable
        case shareableContentFailed
        case invalidCaptureRegion
        case captureFailed
    }

    struct Diagnostic: CustomStringConvertible {
        let status: Status
        let permissionGranted: Bool
        let displayID: CGDirectDisplayID?
        let sourceRectInDisplayPoints: CGRect?
        let outputPixelSize: CGSize?
        let pointPixelScale: CGFloat?
        let excludedWindowIDs: [CGWindowID]
        let errorDescription: String?

        var description: String {
            let display = displayID.map(String.init) ?? "nil"
            let sourceRect = sourceRectInDisplayPoints.map(NSStringFromRect) ?? "nil"
            let output = outputPixelSize.map {
                String(format: "%.0fx%.0f", Double($0.width), Double($0.height))
            } ?? "nil"
            let scale = pointPixelScale.map {
                String(format: "%.2f", Double($0))
            } ?? "nil"
            let excluded = excludedWindowIDs.map(String.init).joined(separator: ",")
            return "status=\(status.rawValue) permission=\(permissionGranted) "
                + "display=\(display) sourceRect=\(sourceRect) output=\(output) "
                + "pointPixelScale=\(scale) excludedWindows=[\(excluded)] "
                + "error=\(errorDescription ?? "nil")"
        }
    }

    struct Response {
        let image: CGImage?
        let diagnostic: Diagnostic
    }

    static let shared = ScreenBackgroundSampler()

    // SCStreamConfiguration.backgroundColor 是 assign/unowned，必须由采样器长期持有。
    private let captureBackgroundColor = CGColor(gray: 1, alpha: 1)

    /// 只查询当前录屏授权状态，不触发系统弹框。
    func preflightPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 唯一会主动请求录屏权限的 API，应只由明确的用户操作调用。
    @MainActor
    @discardableResult
    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 捕获桌宠窗口中心下方的真实屏幕像素。仅在落地后调用一次即可。
    @MainActor
    func capture(behind window: NSWindow, radius: CGFloat) async -> Response {
        guard #available(macOS 14.0, *) else {
            return failure(status: .unsupportedSystem, permissionGranted: preflightPermission())
        }
        guard preflightPermission() else {
            return failure(status: .permissionDenied, permissionGranted: false)
        }
        return await captureOnMacOS14(behind: window, radius: radius)
    }

    @available(macOS 14.0, *)
    @MainActor
    private func captureOnMacOS14(behind window: NSWindow, radius: CGFloat) async -> Response {
        let windowFrame = window.frame
        let appKitPoint = NSPoint(x: windowFrame.midX, y: windowFrame.midY)
        guard let quartzPoint = quartzPoint(fromAppKitDesktopPoint: appKitPoint) else {
            return failure(status: .displayUnavailable, permissionGranted: true)
        }

        let content: SCShareableContent
        do {
            // 此调用在未授权时可能进入系统权限流程，因此前面必须先通过 preflight。
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            return failure(
                status: .shareableContentFailed,
                permissionGranted: true,
                error: error
            )
        }

        guard let display = display(containingOrNearestTo: quartzPoint, in: content.displays) else {
            return failure(status: .displayUnavailable, permissionGranted: true)
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let petWindowID = window.windowNumber > 0 ? CGWindowID(window.windowNumber) : nil
        let ownWindows = content.windows.filter {
            $0.owningApplication?.processID == ownPID || $0.windowID == petWindowID
        }
        let excludedWindowIDs = ownWindows.map(\.windowID)

        // 不能确认桌宠已被过滤时不截图，避免把角色自身像素当作底层背景。
        if let petWindowID, !excludedWindowIDs.contains(petWindowID) {
            return failure(
                status: .petWindowUnavailable,
                permissionGranted: true,
                displayID: display.displayID,
                excludedWindowIDs: excludedWindowIDs
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let localPoint = CGPoint(
            x: quartzPoint.x - display.frame.minX,
            y: quartzPoint.y - display.frame.minY
        )
        let displayLocalBounds = CGRect(
            x: 0,
            y: 0,
            width: display.frame.width,
            height: display.frame.height
        )
        let safeRadius = max(16, min(128, radius))
        let requestedRect = CGRect(
            x: localPoint.x - safeRadius,
            y: localPoint.y - safeRadius,
            width: safeRadius * 2,
            height: safeRadius * 2
        )
        let sourceRect = requestedRect.intersection(displayLocalBounds).integral
        guard !sourceRect.isNull, sourceRect.width >= 8, sourceRect.height >= 8 else {
            return failure(
                status: .invalidCaptureRegion,
                permissionGranted: true,
                displayID: display.displayID,
                sourceRect: sourceRect,
                excludedWindowIDs: excludedWindowIDs
            )
        }

        let pointPixelScale = max(1, CGFloat(filter.pointPixelScale))
        let outputWidth = max(8, Int(ceil(sourceRect.width * pointPixelScale)))
        let outputHeight = max(8, Int(ceil(sourceRect.height * pointPixelScale)))

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = outputWidth
        configuration.height = outputHeight
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsDisplay = true
        configuration.shouldBeOpaque = true
        configuration.backgroundColor = captureBackgroundColor

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            return Response(
                image: image,
                diagnostic: Diagnostic(
                    status: .captured,
                    permissionGranted: true,
                    displayID: display.displayID,
                    sourceRectInDisplayPoints: sourceRect,
                    outputPixelSize: CGSize(width: image.width, height: image.height),
                    pointPixelScale: pointPixelScale,
                    excludedWindowIDs: excludedWindowIDs,
                    errorDescription: nil
                )
            )
        } catch {
            return failure(
                status: .captureFailed,
                permissionGranted: true,
                displayID: display.displayID,
                sourceRect: sourceRect,
                outputPixelSize: CGSize(width: outputWidth, height: outputHeight),
                pointPixelScale: pointPixelScale,
                excludedWindowIDs: excludedWindowIDs,
                error: error
            )
        }
    }

    @MainActor
    private func quartzPoint(fromAppKitDesktopPoint point: NSPoint) -> CGPoint? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        return CGPoint(x: point.x, y: primaryScreen.frame.maxY - point.y)
    }

    @available(macOS 14.0, *)
    private func display(containingOrNearestTo point: CGPoint, in displays: [SCDisplay]) -> SCDisplay? {
        if let containing = displays.first(where: { $0.frame.contains(point) }) {
            return containing
        }
        return displays.min {
            squaredDistance(from: point, to: $0.frame) < squaredDistance(from: point, to: $1.frame)
        }
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x < rect.minX
            ? rect.minX - point.x
            : (point.x > rect.maxX ? point.x - rect.maxX : 0)
        let dy = point.y < rect.minY
            ? rect.minY - point.y
            : (point.y > rect.maxY ? point.y - rect.maxY : 0)
        return dx * dx + dy * dy
    }

    private func failure(
        status: Status,
        permissionGranted: Bool,
        displayID: CGDirectDisplayID? = nil,
        sourceRect: CGRect? = nil,
        outputPixelSize: CGSize? = nil,
        pointPixelScale: CGFloat? = nil,
        excludedWindowIDs: [CGWindowID] = [],
        error: Error? = nil
    ) -> Response {
        Response(
            image: nil,
            diagnostic: Diagnostic(
                status: status,
                permissionGranted: permissionGranted,
                displayID: displayID,
                sourceRectInDisplayPoints: sourceRect,
                outputPixelSize: outputPixelSize,
                pointPixelScale: pointPixelScale,
                excludedWindowIDs: excludedWindowIDs,
                errorDescription: error?.localizedDescription
            )
        )
    }
}
