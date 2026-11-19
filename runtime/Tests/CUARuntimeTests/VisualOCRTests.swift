import CoreGraphics
import CoreText
import CUAProtocol
@testable import CUARuntime
import Foundation
import XCTest

private enum OCRTestFailure: Error { case recognition }
private final class OCRTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func expire() { lock.lock(); value = 1_000_000; lock.unlock() }
}

final class VisualOCRTests: XCTestCase {
    private func image(text: String? = nil, width: Int = 1200, height: Int = 160) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let text {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 64, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ]
            context.textPosition = CGPoint(x: 20, y: 50)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        }
        return try XCTUnwrap(context.makeImage())
    }

    func testPixelEdgesFlipOriginWithoutRoundingOrDisplayScale() {
        XCTAssertEqual(VisualOCR.imageBounds(CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.2), width: 800, height: 1600),
            Rect(x: 200, y: 1120, width: 400, height: 320))
        XCTAssertEqual(VisualOCR.imageBounds(CGRect(x: 0, y: 0, width: 1, height: 1), width: 321, height: 99),
            Rect(x: 0, y: 0, width: 321, height: 99))
        XCTAssertNil(VisualOCR.imageBounds(CGRect(x: -0.1, y: 0, width: 0.5, height: 1), width: 100, height: 100))
        XCTAssertNil(VisualOCR.imageBounds(CGRect(x: 0, y: 0, width: 0, height: 1), width: 100, height: 100))
    }

    func testQueryRangesKeepOriginalUnicodeTextAndEveryOccurrence() {
        let text = "🙂 Café cafe ＣＡＦＥ"
        let ranges = VisualOCR.queryRanges("cafe", in: text)
        XCTAssertEqual(ranges.map { String(text[$0]) }, ["Café", "cafe", "ＣＡＦＥ"])
        XCTAssertEqual(NSRange(ranges[0], in: text).location, 3)
        XCTAssertTrue(VisualOCR.queryRanges("", in: text).isEmpty)
    }

    func testEmptySuccessDiffersFromFailedAndUnavailableRecognition() throws {
        let bitmap = try image()
        let empty = try VisualOCR(read: { _, _, _ in OCRTextScan(regions: []) }).recognize(image: bitmap, context: OperationContext(budgetMs: 1000))
        XCTAssertEqual(empty.status, .complete); XCTAssertTrue(empty.matches.isEmpty); XCTAssertNotNil(empty.collected)
        let failed = try VisualOCR(read: { _, _, _ in throw OCRTestFailure.recognition }).recognize(image: bitmap, context: OperationContext(budgetMs: 1000))
        XCTAssertEqual(failed.status, .failed); XCTAssertTrue(failed.matches.isEmpty); XCTAssertNotNil(failed.collected)
        let missing = try VisualOCR(read: { _, _, _ in OCRTextScan(regions: [OCRTextRegion(text: "Text", normalizedBounds: nil)]) })
            .recognize(image: bitmap, context: OperationContext(budgetMs: 1000))
        XCTAssertEqual(missing.status, .unavailable); XCTAssertTrue(missing.matches.isEmpty)
    }

    func testMissingGeometryKeepsOtherMatchesAndDisclosesPartialCoverage() throws {
        let result = try VisualOCR(read: { _, _, _ in OCRTextScan(regions: [
            OCRTextRegion(text: "Readable", normalizedBounds: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
            OCRTextRegion(text: "No geometry", normalizedBounds: nil)
        ]) }).recognize(image: image(), context: OperationContext(budgetMs: 1000))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.matches.map(\.text), ["Readable"])
    }

    func testResultCountTextAndEncodedBytesAreBoundedWithoutTruncatingText() throws {
        let bitmap = try image()
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let many = try VisualOCR(read: { _, _, _ in OCRTextScan(regions: (0...Limits.maxOcrMatches).map { OCRTextRegion(text: "\($0)", normalizedBounds: rect) }) })
            .recognize(image: bitmap, context: OperationContext(budgetMs: 1000))
        XCTAssertEqual(many.status, .partial); XCTAssertEqual(many.matches.count, Limits.maxOcrMatches)
        let oversized = try VisualOCR(read: { _, _, _ in OCRTextScan(regions: [OCRTextRegion(text: String(repeating: "x", count: Limits.maxOcrTextBytes + 1), normalizedBounds: rect)]) })
            .recognize(image: bitmap, context: OperationContext(budgetMs: 1000))
        XCTAssertEqual(oversized.status, .partial); XCTAssertTrue(oversized.matches.isEmpty)
        let escaped = try VisualOCR(read: { _, _, _ in OCRTextScan(regions: (0..<100).map { _ in OCRTextRegion(
            text: "\"" + String(repeating: "\u{1}", count: 1023), normalizedBounds: rect) }) })
            .recognize(image: bitmap, context: OperationContext(budgetMs: 1000))
        XCTAssertEqual(escaped.status, .partial); XCTAssertLessThan(escaped.matches.count, 100)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(escaped).count, Limits.maxOcrBytes)
    }

    func testOriginalDeadlineAndCancellationAreNotReclassifiedAsOCRFailure() throws {
        let bitmap = try image(); let clock = OCRTestClock()
        let context = OperationContext(receivedAt: 0, budgetMs: 1, now: clock.now)
        let delayed = VisualOCR(read: { _, _, _ in clock.expire(); return OCRTextScan(regions: []) })
        XCTAssertThrowsError(try delayed.recognize(image: bitmap, context: context)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .deadlineExceeded)
        }
        let cancelled = OperationContext(budgetMs: 1000); cancelled.cancel()
        let never = VisualOCR(read: { _, _, _ in XCTFail("Cancelled operation entered recognition"); return OCRTextScan(regions: []) })
        XCTAssertThrowsError(try never.recognize(image: bitmap, context: cancelled)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .cancelled)
        }
    }

    func testLocalProportionalTextUsesVisionSubstringGeometry() throws {
        let bitmap = try image(text: "WWWWWW invoice WWWWWW")
        let all = try VisualOCR().recognize(image: bitmap, context: OperationContext(budgetMs: 10000))
        let query = try VisualOCR().recognize(image: bitmap, query: "invoice", context: OperationContext(budgetMs: 10000))
        XCTAssertEqual(all.status, .complete); XCTAssertEqual(query.status, .complete)
        let line = try XCTUnwrap(all.matches.first { $0.text.lowercased().contains("invoice") })
        let word = try XCTUnwrap(query.matches.first { $0.text.lowercased() == "invoice" })
        // Proportional glyphs make character-count fractions materially wider than Vision's range box.
        XCTAssertLessThan(word.imageBounds.width, line.imageBounds.width * 0.26)
        XCTAssertGreaterThan(word.imageBounds.x, line.imageBounds.x)
        XCTAssertLessThan(word.imageBounds.x + word.imageBounds.width, line.imageBounds.x + line.imageBounds.width)
    }
}
