import ApplicationServices
import CUAProtocol
@testable import CUARuntime
import Foundation
import XCTest

final class AXAttributeResultTests: XCTestCase {
    func testOptionalDescriptionFailureDisclosesMissingMetadata() throws {
        let result = try decodeAXDescription(.failure, value: nil, context: OperationContext(budgetMs: 100))
        XCTAssertNil(result.value)
        XCTAssertFalse(result.complete)
        let supported = try decodeAXDescription(.success, value: "Text" as CFString, context: OperationContext(budgetMs: 100))
        XCTAssertEqual(supported.value, "Text")
        XCTAssertTrue(supported.complete)
    }
    func testOptionalDescriptionDoesNotSwallowIdentityPermissionOrMessagingErrors() {
        for (result, expected) in [(AXError.invalidUIElement, ErrorCode.staleElement), (.apiDisabled, .permissionDenied), (.cannotComplete, .nativeFailed)] {
            XCTAssertThrowsError(try decodeAXDescription(result, value: nil, context: OperationContext(budgetMs: 100))) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, expected)
            }
        }
    }
    func testSuccessfulDescriptionWithUnreadableTypeIsPartialRatherThanKnownAbsent() throws {
        for value in [nil, kCFBooleanFalse] as [CFTypeRef?] {
            let result = try decodeAXDescription(.success, value: value, context: OperationContext(budgetMs: 100))
            XCTAssertNil(result.value); XCTAssertFalse(result.complete)
        }
        let absent = try decodeAXDescription(.attributeUnsupported, value: nil, context: OperationContext(budgetMs: 100))
        XCTAssertNil(absent.value); XCTAssertTrue(absent.complete)
    }
    func testUnknownEnabledExceptionUsesOnlyExactTextRoles() {
        XCTAssertTrue(isWritableAXTextRole("AXTextField"))
        XCTAssertTrue(isWritableAXTextRole("AXTextArea"))
        XCTAssertFalse(isWritableAXTextRole("AXSlider"))
        XCTAssertFalse(isWritableAXTextRole("AXTextFieldCustom"))
        XCTAssertFalse(isWritableAXTextRole("AXButton"))
    }
    func testOptionalDescriptionFailurePreservesKnownDeadlineAndCancellation() {
        let expired = OperationContext(receivedAt: 0, budgetMs: 1, now: { 1_000_000 })
        let cancelled = OperationContext(budgetMs: 100); cancelled.cancel()
        for (context, expected) in [(expired, ErrorCode.deadlineExceeded), (cancelled, .cancelled)] {
            XCTAssertThrowsError(try decodeAXDescription(.failure, value: nil, context: context)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, expected)
            }
        }
    }
    func testEnabledUnsupportedIsDistinctFromFalseAndOtherMissingValues() throws {
        let context = OperationContext(budgetMs: 100)
        let unsupported = try decodeAXEnabled(.attributeUnsupported, value: nil, context: context)
        XCTAssertNil(unsupported.value); XCTAssertTrue(unsupported.unsupported)
        let missing = try decodeAXEnabled(.noValue, value: nil, context: context)
        XCTAssertNil(missing.value); XCTAssertFalse(missing.unsupported)
        let disabled = try decodeAXEnabled(.success, value: kCFBooleanFalse, context: context)
        XCTAssertEqual(disabled.value, false); XCTAssertFalse(disabled.unsupported)
        XCTAssertThrowsError(try decodeAXEnabled(.failure, value: nil, context: context)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .nativeFailed)
        }
    }
}
