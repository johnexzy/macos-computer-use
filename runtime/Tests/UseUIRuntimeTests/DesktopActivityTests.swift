import UseUIProtocol
@testable import UseUIRuntime
import XCTest

final class DesktopActivityTests: XCTestCase {
    func testWritingCueFollowsDeliveryAndVerification() throws {
        let target = TargetKey(pid: 42, windowId: 7)
        let bounds = Rect(x: 100, y: 200, width: 400, height: 300)
        let field = Element(reference: "field", role: "AXTextArea", label: nil, value: nil,
            bounds: Rect(x: 120, y: 250, width: 300, height: 100), enabled: true, actions: [.setValue])
        let observation = Observation(observationId: "obs", target: target,
            collected: CollectionInterval(startedUnixMs: 1, finishedUnixMs: 2), windowBounds: bounds,
            accessibility: .complete, accessibilityCollected: nil, elements: [field], screenshot: nil)
        let request = ActRequest(grantId: "grant", observationId: "obs", target: target, steps: [
            ActionStep(actionId: "edit", operation: .setValue(.init(elementRef: "field", value: "draft")),
                       precondition: nil, expect: nil)
        ])

        func activity(_ delivery: Delivery, _ verification: Verification, reason: ReceiptReason? = nil) -> DesktopActivity? {
            let receipt = StepReceipt(actionId: "edit", delivery: delivery, verification: verification, reason: reason, evidence: [])
            let result = ActResult(observationId: "obs", steps: [receipt], remainingSteps: 0, stopReason: .completed)
            return DesktopActivity.action(request, result: result, observation: observation)
        }

        let skipped = try XCTUnwrap(activity(.notDispatched, .unverified, reason: .targetStale))
        XCTAssertEqual(skipped.phase.badgeLabel, "Skipped")
        XCTAssertNil(skipped.point)
        XCTAssertNil(activity(.notDispatched, .confirmed, reason: .alreadySatisfied))
        let written = try XCTUnwrap(activity(.dispatched, .confirmed))
        XCTAssertEqual(written.phase, .written)
        XCTAssertEqual(written.target, target)
        XCTAssertEqual(written.point, CGPoint(x: 132, y: 264))
        XCTAssertEqual(activity(.dispatched, .unverified)?.phase, .writingSent)
        for outcome in [activity(.unknown, .unverified), activity(.dispatched, .mismatch),
                        activity(.dispatched, .unverified, reason: .deadlineExceeded)] {
            XCTAssertEqual(outcome?.phase, .check)
            XCTAssertNil(outcome?.point)
        }

        let batch = ActRequest(grantId: "grant", observationId: "obs", target: target, steps: request.steps + [
            ActionStep(actionId: "second", operation: .press(.init(elementRef: "field")), precondition: nil, expect: nil)
        ])
        let partial = ActResult(observationId: "obs", steps: [
            StepReceipt(actionId: "edit", delivery: .dispatched, verification: .confirmed, reason: nil, evidence: []),
            StepReceipt(actionId: "second", delivery: .notDispatched, verification: .unverified, reason: .targetStale, evidence: [])
        ], remainingSteps: 0, stopReason: .targetStale)
        XCTAssertEqual(DesktopActivity.action(batch, result: partial, observation: observation)?.phase, .skipped)
        XCTAssertEqual(DesktopActivity.recoveryPhase(batch, result: partial), .skipped)
    }
}
