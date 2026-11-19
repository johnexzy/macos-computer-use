import ApplicationServices
import CUAProtocol
@testable import CUARuntime
import Foundation
import XCTest

final class AXAttributeResultTests: XCTestCase {
    func testBoundedActionNamesKeepAdvertisedPressAndDoNotSynthesizeIt() {
        let otherActions = (0..<40).map { "AXOther\($0)" }
        let press = kAXPressAction as String
        XCTAssertEqual(boundedAXActionNames(otherActions), Array(otherActions.prefix(32)))
        XCTAssertEqual(boundedAXActionNames([press] + otherActions), [press] + Array(otherActions.prefix(31)))
        XCTAssertEqual(boundedAXActionNames(otherActions + [press]), [press] + Array(otherActions.prefix(31)))
        XCTAssertEqual(boundedAXActionNames([]), [])
    }

    func testOptionalDescriptionFailureDisclosesMissingMetadata() throws {
        let result = try decodeAXDescription(.failure, value: nil, context: OperationContext(budgetMs: 100))
        XCTAssertNil(result.value)
        XCTAssertFalse(result.complete)
        let supported = try decodeAXDescription(.success, value: "Text" as CFString, context: OperationContext(budgetMs: 100))
        XCTAssertEqual(supported.value, "Text")
        XCTAssertTrue(supported.complete)
    }
    func testOptionalDescriptionDoesNotSwallowIdentityPermissionOrMessagingErrors() {
        for (result, expected) in [(AXError.invalidUIElement, ErrorCode.staleElement), (.apiDisabled, .permissionDenied)] {
            XCTAssertThrowsError(try decodeAXDescription(result, value: nil, context: OperationContext(budgetMs: 100))) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, expected)
            }
        }
        XCTAssertThrowsError(try decodeAXDescription(.cannotComplete, value: nil, context: OperationContext(budgetMs: 100))) {
            XCTAssertTrue($0 is AXReadUnavailable)
        }
    }
    func testCannotCompleteIsUnknownOnlyBeforeAnInterruption() {
        XCTAssertThrowsError(try checkAXRead(.cannotComplete, context: OperationContext(budgetMs: 100))) {
            XCTAssertTrue($0 is AXReadUnavailable)
        }
        let expired = OperationContext(receivedAt: 0, budgetMs: 1, now: { 1_000_000 })
        let cancelled = OperationContext(budgetMs: 100); cancelled.cancel()
        for (context, expected) in [(expired, ErrorCode.deadlineExceeded), (cancelled, .cancelled)] {
            XCTAssertThrowsError(try checkAXRead(.cannotComplete, context: context)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, expected)
            }
        }
        XCTAssertThrowsError(try checkAXRead(.failure, context: OperationContext(budgetMs: 100))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .nativeFailed)
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
        XCTAssertTrue(unsupported.completeForTraversal)
        let missing = try decodeAXEnabled(.noValue, value: nil, context: context)
        XCTAssertNil(missing.value); XCTAssertFalse(missing.unsupported)
        XCTAssertFalse(missing.completeForTraversal)
        let disabled = try decodeAXEnabled(.success, value: kCFBooleanFalse, context: context)
        XCTAssertEqual(disabled.value, false); XCTAssertFalse(disabled.unsupported)
        XCTAssertTrue(disabled.completeForTraversal)
        for value in [nil, "unknown" as CFString, NSNumber(value: 0), NSNumber(value: 1)] as [CFTypeRef?] {
            let unreadable = try decodeAXEnabled(.success, value: value, context: context)
            XCTAssertNil(unreadable.value); XCTAssertFalse(unreadable.completeForTraversal)
        }
        XCTAssertThrowsError(try decodeAXEnabled(.failure, value: nil, context: context)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .nativeFailed)
        }
    }
}
