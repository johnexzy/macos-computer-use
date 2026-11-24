import CoreGraphics
import UseUIProtocol
import Foundation
import ScreenCaptureKit

struct CapturedVisual: Sendable {
    let image: CGImage
    let frame: VisualFrame
    let collected: CollectionInterval
}

struct VisualCaptureFailure: Error, Sendable {
    let status: CaptureStatus
    let collected: CollectionInterval
    let message: String
}

protocol VisualCapturing: Sendable {
    func capture(target: Target, crop: Rect?, maxDimension: Int, context: OperationContext) throws -> CapturedVisual
}

/// Captures only an exact desktop-independent window. No display fallback or permission request exists.
struct ScreenWindowCapture: VisualCapturing {
    // Screenshot requests cannot be cancelled. Keep their physical admission until the callback returns.
    private static let pendingAPI = DispatchSemaphore(value: 1)

    func capture(target: Target, crop: Rect? = nil, maxDimension: Int = 1600,
                 context: OperationContext) throws -> CapturedVisual {
        let started = visualMilliseconds()
        @Sendable func fail(_ status: CaptureStatus, _ message: String) -> VisualCaptureFailure {
            VisualCaptureFailure(status: status, collected: visualInterval(started), message: message)
        }
        try context.check()
        guard #available(macOS 14.0, *) else { throw fail(.unsupported, "Window screenshots require macOS 14 or newer") }
        guard (1...2048).contains(maxDimension) else { throw fail(.failed, "Invalid screenshot dimension bound") }
        guard !Thread.isMainThread else { throw fail(.unavailable, "Window capture requires the native worker queue") }
        let permitted = CGPreflightScreenCaptureAccess()
        try context.check()
        guard permitted else { throw fail(.permissionDenied, "Screen Recording access is unavailable") }
        // The observation owner brackets this operation with its catalog checks.
        let before = target

        let shareable: SCShareableContent = try request(context: context, failure: fail(.unavailable, "Window capture is busy")) { done in
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
                if error == nil, let content { done(.success(content)) }
                else { done(.failure(fail(CGPreflightScreenCaptureAccess() ? .failed : .permissionDenied,
                                         "Shareable window content is unavailable"))) }
            }
        }
        try context.check()
        let matches = shareable.windows.filter { $0.windowID == target.key.windowId && $0.owningApplication?.processID == pid_t(target.key.pid) }
        guard matches.count == 1, let window = matches.first, let app = window.owningApplication else {
            throw fail(.unavailable, "Exact window is unavailable for capture")
        }
        if let bundleId = target.bundleId, !app.bundleIdentifier.isEmpty, app.bundleIdentifier != bundleId {
            throw fail(.geometryChanged, "Capture application identity changed")
        }
        guard visualRect(window.frame) == before.bounds else { throw fail(.geometryChanged, "Window geometry changed before capture") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard filter.contentRect.width == before.bounds.width, filter.contentRect.height == before.bounds.height else {
            throw fail(.geometryChanged, "Capture content does not match the window frame")
        }
        let nativeWidth = Double(filter.contentRect.width) * Double(filter.pointPixelScale)
        let nativeHeight = Double(filter.contentRect.height) * Double(filter.pointPixelScale)
        guard let dimensions = CaptureGeometry.nativeDimensions(width: nativeWidth, height: nativeHeight) else {
            throw fail(.unavailable, "Window backing dimensions exceed capture bounds or are not exact")
        }
        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
        let image: CGImage = try request(context: context, failure: fail(.unavailable, "Window capture is busy")) { done in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if error == nil, let image { done(.success(image)) }
                else { done(.failure(fail(CGPreflightScreenCaptureAccess() ? .failed : .permissionDenied,
                                         "Window screenshot capture failed"))) }
            }
        }
        try context.check()
        guard image.width == dimensions.width, image.height == dimensions.height else {
            throw fail(.failed, "Captured bitmap does not match the configured window raster")
        }
        guard let layout = CaptureGeometry.layout(window: before.bounds, width: image.width, height: image.height,
                                                   crop: crop, maxDimension: maxDimension) else {
            throw fail(.failed, "Screenshot crop is outside the window or too small")
        }
        guard let rendered = layout.render(image) else { throw fail(.failed, "Window image crop or resize failed") }
        try context.check()
        return CapturedVisual(image: rendered, frame: layout.frame, collected: visualInterval(started))
    }

    private func request<Value>(context: OperationContext, failure: VisualCaptureFailure,
                                start: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void) throws -> Value {
        try context.check()
        guard Self.pendingAPI.wait(timeout: .now()) == .success else { throw failure }
        let callback = VisualCallback<Value>()
        start { result in
            Self.pendingAPI.signal()
            callback.complete(result)
        }
        return try callback.wait(context: context)
    }
}

/// Integer raster edges define the realized crop; the requested fractional edges are never invented as pixels.
struct CaptureGeometry {
    let pixelCrop: CGRect
    let width: Int
    let height: Int
    let frame: VisualFrame

    func render(_ image: CGImage) -> CGImage? {
        guard let cropped = image.cropping(to: pixelCrop) else { return nil }
        if cropped.width == width && cropped.height == height { return cropped }
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.interpolationQuality = .high
        bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bitmap.makeImage()
    }

    static func nativeDimensions(width: Double, height: Double) -> (width: Int, height: Int)? {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 8192, height <= 8192, width * height <= 16_777_216,
              abs(width - width.rounded()) < 0.000001, abs(height - height.rounded()) < 0.000001 else { return nil }
        return (Int(width.rounded()), Int(height.rounded()))
    }

    static func layout(window: Rect, width: Int, height: Int, crop: Rect?, maxDimension: Int) -> CaptureGeometry? {
        guard [window.x, window.y, window.width, window.height].allSatisfy(\.isFinite), window.width > 0, window.height > 0,
              width > 0, height > 0, (1...2048).contains(maxDimension) else { return nil }
        let requested = crop ?? Rect(x: 0, y: 0, width: window.width, height: window.height)
        guard [requested.x, requested.y, requested.width, requested.height].allSatisfy(\.isFinite),
              requested.x >= 0, requested.y >= 0, requested.width > 0, requested.height > 0,
              requested.x + requested.width <= window.width, requested.y + requested.height <= window.height else { return nil }
        // Round inward so a crop never includes pixels beyond the requested logical region.
        let left = ceil(requested.x * Double(width) / window.width)
        let top = ceil(requested.y * Double(height) / window.height)
        let right = floor((requested.x + requested.width) * Double(width) / window.width)
        let bottom = floor((requested.y + requested.height) * Double(height) / window.height)
        guard right > left, bottom > top else { return nil }
        let pixelCrop = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        let ratio = min(1, Double(maxDimension) / max(pixelCrop.width, pixelCrop.height))
        let outputWidth = max(1, Int((pixelCrop.width * ratio).rounded()))
        let outputHeight = max(1, Int((pixelCrop.height * ratio).rounded()))
        let local = Rect(x: left * window.width / Double(width), y: top * window.height / Double(height),
                         width: (right - left) * window.width / Double(width), height: (bottom - top) * window.height / Double(height))
        let bounds = Rect(x: window.x + local.x, y: window.y + local.y, width: local.width, height: local.height)
        let domain = Rect(x: 0, y: 0, width: Double(outputWidth), height: Double(outputHeight))
        let screen = ImageTransform(scaleX: local.width / Double(outputWidth), scaleY: local.height / Double(outputHeight),
            offsetX: bounds.x, offsetY: bounds.y, validImageBounds: domain, coverage: .complete)
        let windowMap = ImageTransform(scaleX: screen.scaleX, scaleY: screen.scaleY, offsetX: local.x, offsetY: local.y,
            validImageBounds: domain, coverage: .complete)
        return CaptureGeometry(pixelCrop: pixelCrop, width: outputWidth, height: outputHeight,
            frame: VisualFrame(widthPx: UInt32(outputWidth), heightPx: UInt32(outputHeight), captureWindowBounds: window,
                captureScreenBounds: bounds, imageToScreen: screen, imageToWindow: windowMap))
    }
}

/// Completion may arrive after cancellation; abandoned results are dropped without publication.
final class VisualCallback<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<Value, any Error>?
    private var accepting = true

    func complete(_ result: Result<Value, any Error>) {
        lock.lock(); defer { lock.unlock() }
        guard accepting, self.result == nil else { return }
        self.result = result
        ready.signal()
    }

    func wait(context: OperationContext) throws -> Value {
        defer {
            lock.lock(); accepting = false; result = nil; lock.unlock()
        }
        while true {
            try context.check()
            lock.lock(); let delivered = result; lock.unlock()
            if let delivered { try context.check(); return try delivered.get() }
            _ = ready.wait(timeout: .now() + Double(try context.nativeTimeoutSeconds(maximum: 0.01)))
        }
    }
}

private func visualMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
private func visualInterval(_ started: UInt64) -> CollectionInterval {
    CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, visualMilliseconds()))
}
private func visualRect(_ value: CGRect) -> Rect {
    Rect(x: value.origin.x, y: value.origin.y, width: value.width, height: value.height)
}
