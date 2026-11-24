import CoreGraphics
import UseUIProtocol
@testable import UseUIRuntime
import XCTest

final class DesktopActivityTests: XCTestCase {
    func testWritingCueFollowsDeliveryAndVerification() throws {
        let target = TargetKey(pid: 42, windowId: 7)
        let bounds = Rect(x: 100, y: 200, width: 400, height: 300)
        let field = Element(reference: "field", role: "AXTextArea", label: "Notes", value: nil,
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
        XCTAssertEqual(written.controlBounds, field.bounds)
        XCTAssertEqual(written.pillText, "Updated \"Notes\"")
        XCTAssertFalse(written.isForeground)
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

    func testApproachingCarriesNarrationAndForegroundPosture() {
        let target = Target(key: TargetKey(pid: 99, windowId: 12), bundleId: "com.apple.TextEdit",
                            title: "Draft", bounds: Rect(x: 0, y: 0, width: 800, height: 600))
        let buttonBounds = Rect(x: 320, y: 200, width: 120, height: 34)
        let bg = DesktopActivity.approaching(target, control: buttonBounds, writing: false, label: "Suggest Edit")
        XCTAssertEqual(bg.pillText, "Clicking \"Suggest Edit\"")
        XCTAssertEqual(bg.controlBounds, buttonBounds)
        XCTAssertFalse(bg.isForeground)

        let fg = DesktopActivity.approaching(target, screenPoint: Point(x: 400, y: 300), label: "Foreground action", isForeground: true)
        XCTAssertEqual(fg.pillText, "Foreground action")
        XCTAssertTrue(fg.isForeground)
    }

    func testCursorTrajectoryBezierAndFittsTiming() {
        let shortHop = CursorTrajectory.build(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 40, y: 25),
                                              style: .signatureArc, reduceMotion: false)
        let longSweep = CursorTrajectory.build(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 700, y: 420),
                                               style: .signatureArc, reduceMotion: false)
        XCTAssertGreaterThan(shortHop.duration, 0.10)
        XCTAssertGreaterThan(longSweep.duration, shortHop.duration)
        XCTAssertLessThanOrEqual(longSweep.duration, 0.24)

        // Endpoints match exact start and destination; midpoint curves off the straight chord.
        XCTAssertEqual(longSweep.point(at: 0).x, 10, accuracy: 0.01)
        XCTAssertEqual(longSweep.point(at: 1).x, 700, accuracy: 0.01)
        let mid = longSweep.point(at: 0.5)
        let straightMidY: CGFloat = (10 + 420) / 2
        XCTAssertNotEqual(mid.y, straightMidY, accuracy: 2.0)

        // Banking settles to exactly zero at start and arrival.
        XCTAssertEqual(longSweep.bankAngleRadians(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(longSweep.bankAngleRadians(at: 1), 0, accuracy: 0.0001)
        XCTAssertNotEqual(longSweep.bankAngleRadians(at: 0.5), 0, accuracy: 0.001)

        // Reduce Motion and Reduced preset disable animation cleanly.
        let reduced = CursorTrajectory.build(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 700, y: 420),
                                             style: .signatureArc, reduceMotion: true)
        XCTAssertEqual(reduced.duration, 0)
        XCTAssertEqual(reduced.maxBankRadians, 0)
    }
}
