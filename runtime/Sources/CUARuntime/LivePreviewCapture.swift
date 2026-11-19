import CoreGraphics
import CoreMedia
import CoreVideo
import CUAProtocol
import Foundation
import ScreenCaptureKit
import VideoToolbox

struct LivePreviewTarget: Equatable, Sendable {
    let processId: Int32
    let windowId: UInt32
    let bounds: Rect
    let sheetBounds: Rect?
}

@MainActor final class LivePreviewCapture {
    private var selectedTarget: LivePreviewTarget?
    private var captureTask: Task<Void, Never>?

    func follow(_ target: LivePreviewTarget, onFrame: @escaping @MainActor (CGImage, CGRect) -> Void,
                onUnavailable: @escaping @MainActor () -> Void) {
        guard selectedTarget != target else { return }
        selectedTarget = target
        let previous = captureTask
        previous?.cancel()
        captureTask = Task { [weak self] in
            // Finish stopping the old capture before creating another stream.
            await previous?.value
            guard !Task.isCancelled else { return }
            if #available(macOS 14.2, *), CGPreflightScreenCaptureAccess() {
                await Self.capture(target, onFrame: onFrame)
            }
            guard !Task.isCancelled else { return }
            self?.selectedTarget = nil
            onUnavailable()
        }
    }

    func stop() {
        selectedTarget = nil
        captureTask?.cancel()
    }

    @available(macOS 14.2, *)
    private static func capture(_ target: LivePreviewTarget, onFrame: @MainActor (CGImage, CGRect) -> Void) async {
        do {
            guard let content = await shareableContent() else { return }
            try Task.checkCancellation()
            guard let scope = PreviewCaptureScope(target: target, content: content) else { return }
            let (frames, continuation) = AsyncStream.makeStream(of: CGImage.self, bufferingPolicy: .bufferingNewest(1))
            let output = PreviewStreamOutput(continuation: continuation)
            let stream = SCStream(filter: scope.filter, configuration: scope.configuration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            for await image in frames {
                guard !Task.isCancelled else { break }
                onFrame(image, scope.viewport)
            }
            try await stream.stopCapture()
        } catch {
            // A stopped, cancelled, or unavailable preview never affects the native action.
        }
    }

    @available(macOS 14.2, *)
    private static func shareableContent() async -> SCShareableContent? {
        // ScreenCaptureKit may not answer an overlapping shareable-content request.
        let (results, reply) = AsyncStream.makeStream(of: PreviewShareableContent.self, bufferingPolicy: .bufferingNewest(1))
        requestShareableContent(reply)
        let timeout = Task {
            try? await Task.sleep(for: .seconds(2))
            reply.finish()
        }
        defer { timeout.cancel() }
        var iterator = results.makeAsyncIterator()
        return await iterator.next()?.value
    }

    private static func requestShareableContent(_ reply: AsyncStream<PreviewShareableContent>.Continuation) {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { content, _ in
            if let content { reply.yield(PreviewShareableContent(value: content)) }
            reply.finish()
        }
    }
}

/// ScreenCaptureKit returns this immutable snapshot on its callback queue.
private struct PreviewShareableContent: @unchecked Sendable {
    let value: SCShareableContent
}

@available(macOS 14.2, *)
private struct PreviewCaptureScope {
    let filter: SCContentFilter
    let configuration: SCStreamConfiguration
    let viewport: CGRect

    init?(target: LivePreviewTarget, content: SCShareableContent) {
        let windows = content.windows.filter { $0.owningApplication?.processID == target.processId }
        let matches = windows.filter { $0.windowID == target.windowId && $0.frame == target.bounds.previewRect }
        guard matches.count == 1, let parent = matches.first else { return nil }

        let configuration = SCStreamConfiguration()
        let viewport: CGRect
        if let sheetBounds = target.sheetBounds {
            // The caller verifies AX ownership. Include only its unique native surface and the exact parent.
            let sheets = windows.filter { $0.windowID != parent.windowID && $0.frame == sheetBounds.previewRect }
            guard sheets.count == 1, let sheet = sheets.first else { return nil }
            viewport = parent.frame.union(sheet.frame)
            guard let display = content.displays.first(where: { $0.frame.contains(viewport) }) else { return nil }
            filter = SCContentFilter(display: display, including: [parent, sheet])
            configuration.sourceRect = viewport.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        } else {
            viewport = parent.frame
            filter = SCContentFilter(desktopIndependentWindow: parent)
        }

        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let scale = min(1, 720 / max(viewport.width, viewport.height))
        configuration.width = max(1, Int((viewport.width * scale).rounded(.up)))
        configuration.height = max(1, Int((viewport.height * scale).rounded(.up)))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true
        configuration.includeChildWindows = false
        self.configuration = configuration
        self.viewport = viewport
    }
}

private final class PreviewStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "cua.preview.frames", qos: .utility)
    private let continuation: AsyncStream<CGImage>.Continuation

    init(continuation: AsyncStream<CGImage>.Continuation) { self.continuation = continuation }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        continuation.finish()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: rawStatus) else { return }
        if status == .blank || status == .suspended || status == .stopped {
            continuation.finish()
            return
        }
        guard status == .complete, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image: CGImage?
        if VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image) == noErr, let image {
            continuation.yield(image)
        }
    }
}

private extension Rect {
    var previewRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
