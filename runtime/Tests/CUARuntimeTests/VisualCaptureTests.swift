import CoreGraphics
import CUAProtocol
@testable import CUARuntime
import XCTest

final class VisualCaptureTests: XCTestCase {
    func testRetinaPortraitResizeMapsToNegativeDesktopWithoutMainDisplayScale() throws {
        let window = Rect(x: -900, y: -240, width: 600, height: 1200)
        let layout = try XCTUnwrap(CaptureGeometry.layout(window: window, width: 1200, height: 2400, crop: nil, maxDimension: 1600))
        XCTAssertEqual(layout.width, 800); XCTAssertEqual(layout.height, 1600)
        XCTAssertEqual(layout.frame.captureScreenBounds, window)
        XCTAssertEqual(layout.frame.imageToScreen.scaleX, 0.75)
        XCTAssertEqual(layout.frame.imageToScreen.scaleY, 0.75)
        XCTAssertEqual(layout.frame.imageToScreen.offsetX, -900)
        XCTAssertEqual(layout.frame.imageToWindow.offsetX, 0)
    }

    func testFractionalCropUsesActualInwardPixelEdges() throws {
        let window = Rect(x: 100, y: 200, width: 500, height: 300)
        let crop = Rect(x: 10.2, y: 20.2, width: 100.1, height: 50.1)
        let layout = try XCTUnwrap(CaptureGeometry.layout(window: window, width: 1000, height: 600, crop: crop, maxDimension: 1600))
        XCTAssertEqual(layout.pixelCrop, CGRect(x: 21, y: 41, width: 199, height: 99))
        XCTAssertEqual(layout.frame.captureScreenBounds, Rect(x: 110.5, y: 220.5, width: 99.5, height: 49.5))
        XCTAssertEqual(layout.frame.imageToWindow.offsetX, 10.5)
        XCTAssertEqual(layout.frame.imageToScreen.scaleX, 0.5)
    }

    func testInvalidOrEmptyCropNeverGetsAnInventedMapping() {
        let window = Rect(x: 0, y: 0, width: 100, height: 100)
        for crop in [Rect(x: -1, y: 0, width: 10, height: 10), Rect(x: 90, y: 0, width: 11, height: 10),
                     Rect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)] {
            XCTAssertNil(CaptureGeometry.layout(window: window, width: 100, height: 100, crop: crop, maxDimension: 1600))
        }
        XCTAssertNil(CaptureGeometry.nativeDimensions(width: 16384, height: 100))
        XCTAssertNil(CaptureGeometry.nativeDimensions(width: 3000.3, height: 100))
        XCTAssertNil(CaptureGeometry.nativeDimensions(width: 8192, height: 8192))
    }

    func testBitmapCropUsesTopLeftPixelRowsAndReturnsDeclaredDimensions() throws {
        // Red/green in the first raster row; blue/white in the second.
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let layout = try XCTUnwrap(CaptureGeometry.layout(window: Rect(x: -100, y: 80, width: 100, height: 100),
            width: 2, height: 2, crop: Rect(x: 0, y: 0, width: 50, height: 50), maxDimension: 1600))
        let cropped = try XCTUnwrap(layout.render(image))
        XCTAssertEqual(cropped.width, 1); XCTAssertEqual(cropped.height, 1)
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(bitmap.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [255, 0, 0, 255])
    }

    func testCallbackCannotTurnAnExpiredContextIntoSuccess() {
        let callback = VisualCallback<Int>(); callback.complete(.success(42))
        let context = OperationContext(receivedAt: 0, budgetMs: 1, now: { 1_000_000 })
        XCTAssertThrowsError(try callback.wait(context: context)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .deadlineExceeded)
        }
        callback.complete(.success(99))
    }

    func testCancelledCallbackAndDuplicateCompletionCannotChangeResult() throws {
        let delivered = VisualCallback<Int>(); delivered.complete(.success(7)); delivered.complete(.success(8))
        XCTAssertEqual(try delivered.wait(context: OperationContext(budgetMs: 100)), 7)
        let cancelled = VisualCallback<Int>(); let context = OperationContext(budgetMs: 100); context.cancel()
        XCTAssertThrowsError(try cancelled.wait(context: context)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .cancelled)
        }
        cancelled.complete(.success(9))
    }

    func testMissingCallbackExhaustsOriginalBudgetAndDropsLateCompletion() {
        let callback = VisualCallback<Int>()
        for attempt in 0..<2 {
            if attempt == 1 { callback.complete(.success(99)) }
            XCTAssertThrowsError(try callback.wait(context: OperationContext(budgetMs: 5))) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, .deadlineExceeded)
            }
        }
    }
}
