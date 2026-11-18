import Foundation
import XCTest
@testable import CUAProtocol

final class ContractTests: XCTestCase {
    private var fixtureRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
    }
    private func fixtures(_ bucket: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: fixtureRoot.appendingPathComponent(bucket),
                                                   includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }
    private func fixture(_ name: String) throws -> Frame {
        try Frame.decodeLine(Data(contentsOf: fixtureRoot.appendingPathComponent("valid/\(name).json")))
    }
    func testSharedValidFixturesDecodeAndRoundTrip() throws {
        let paths = try fixtures("valid")
        XCTAssertEqual(paths.count, 57)
        for path in paths {
            let frame = try Frame.decodeLine(Data(contentsOf: path))
            let encoded = try frame.encodeLine()
            XCTAssertEqual(encoded.last, 10)
            XCTAssertEqual(try Frame.decodeLine(encoded), frame, path.lastPathComponent)
        }
    }
    func testAbsentVisualOptionsKeepTheLegacyAXWireShape() throws {
        let request = try fixture("observe-request")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.encodeLine()) as? [String: Any])
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let body = try XCTUnwrap(message["body"] as? [String: Any])
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        for name in ["includeOcr", "ocrQuery", "cropWindow", "maxImageDimensionPx"] { XCTAssertNil(params[name], name) }
        let old = try fixture("observe-partial-response")
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: old.encodeLine()) as? [String: Any])
        let responseMessage = try XCTUnwrap(response["message"] as? [String: Any])
        let responseBody = try XCTUnwrap(responseMessage["body"] as? [String: Any])
        let data = try XCTUnwrap(responseBody["data"] as? [String: Any])
        XCTAssertNil(data["visual"])
    }
    func testOCROnlyProvenanceMapsWindowAndScreenWithoutBitmapBytes() throws {
        guard case .response(let response) = try fixture("observe-ocr-only-response"),
              case .observe(let observation) = response.body,
              let visual = observation.visual, let frame = visual.frame else { return XCTFail() }
        XCTAssertNil(observation.screenshot)
        let point = Point(x: 15, y: 12)
        XCTAssertEqual(try frame.imageToScreen.toScreen(point), Point(x: -670, y: 144))
        XCTAssertEqual(try frame.imageToWindow.toScreen(point), Point(x: 130, y: 44))
        XCTAssertThrowsError(try frame.imageToWindow.toScreen(Point(x: 150, y: 12)))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(visual.ocr?.collected).startedUnixMs, visual.collected.finishedUnixMs)
    }
    func testOCRBudgetAccountsForJSONEscapingNotOnlyTextBytes() throws {
        guard case .response(let response) = try fixture("observe-ocr-only-response"),
              case .observe(let observation) = response.body, let ocr = observation.visual?.ocr,
              let first = ocr.matches.first else { return XCTFail() }
        let match = OcrMatch(text: String(repeating: "\u{0000}", count: Limits.maxOcrTextBytes), imageBounds: first.imageBounds)
        let oversized = OcrEvidence(status: .complete, collected: ocr.collected, matches: Array(repeating: match, count: 43))
        XCTAssertLessThanOrEqual(oversized.matches.count, Limits.maxOcrMatches)
        XCTAssertThrowsError(try oversized.validate())
    }
    func testSharedInvalidFixturesAreRejected() throws {
        let paths = try fixtures("invalid")
        XCTAssertEqual(paths.count, 84)
        for path in paths {
            XCTAssertThrowsError(try Frame.decodeLine(Data(contentsOf: path)), path.lastPathComponent)
        }
    }
    func testFramesAreBoundedSingleLineMessages() {
        XCTAssertThrowsError(try Frame.decodeLine(Data(repeating: 32, count: Limits.maxFrameBytes + 1)))
        for text in ["{}\n{}\n", "{}\r\n", "diagnostic output\n"] {
            XCTAssertThrowsError(try Frame.decodeLine(Data(text.utf8)))
        }
    }
    func testFeedbackEncodedBudgetIncludesJSONEscaping() throws {
        guard case .response(let response) = try fixture("act-feedback-response"),
              case .act(let act) = response.body, let feedback = act.feedback,
              let original = feedback.controls[0].element else { return XCTFail() }
        let controls = (0..<8).map { index in
            let reference = "feedback-\(index)"
            return ControlFeedback(elementRef: reference, state: .changed,
                element: Element(reference: reference, role: original.role, label: original.label,
                    value: String(repeating: "\u{0000}", count: 65_536), bounds: original.bounds,
                    enabled: original.enabled, actions: original.actions, identifier: original.identifier))
        }
        let oversized = ObservationFeedback(baseObservationId: feedback.baseObservationId, collected: feedback.collected,
            controls: controls, invalidated: false, truncated: false)
        let result = ActResult(observationId: act.observationId, steps: act.steps, remainingSteps: act.remainingSteps,
            stopReason: act.stopReason, feedback: oversized)
        XCTAssertThrowsError(try Frame.response(Response(version: response.version, id: response.id,
            epoch: response.epoch, body: .act(result))).validate())
    }
    func testPartialTransformMapsResizedImageAndRejectsUnknownRegion() throws {
        guard case .response(let response) = try fixture("observe-partial-response"),
              case .observe(let observation) = response.body,
              let transform = observation.screenshot?.imageToScreen else { return XCTFail() }
        XCTAssertEqual(try transform.toScreen(Point(x: 20, y: 12)), Point(x: -790, y: 103))
        XCTAssertThrowsError(try transform.toScreen(Point(x: 0, y: 12)))
        XCTAssertThrowsError(try transform.toScreen(Point(x: 70, y: 12)))
        let overflowing = ImageTransform(scaleX: 1e308, scaleY: transform.scaleY, offsetX: transform.offsetX,
                                         offsetY: transform.offsetY, validImageBounds: transform.validImageBounds, coverage: transform.coverage)
        XCTAssertThrowsError(try overflowing.toScreen(Point(x: 20, y: 12)))
    }
    func testAuthorityAndEpochComeFromHost() throws {
        guard case .request(let request) = try fixture("act-request"), case .act(let act) = request.body else {
            return XCTFail()
        }
        let session = SessionContext(epoch: "helper-epoch-1", authority: Authority(grantId: "host-grant-1", mode: .backgroundRequired))
        try session.authorize(request)
        let stale = Request(version: request.version, id: request.id, epoch: "old-epoch", budgetMs: request.budgetMs, body: request.body)
        XCTAssertThrowsError(try session.authorize(stale))
        let forgedAct = ActRequest(grantId: "self-granted", observationId: act.observationId, target: act.target, steps: act.steps)
        let forged = Request(version: request.version, id: request.id, epoch: request.epoch, budgetMs: request.budgetMs, body: .act(forgedAct))
        XCTAssertThrowsError(try session.authorize(forged))
        guard case .request(let hello) = try fixture("hello-request") else { return XCTFail() }
        XCTAssertThrowsError(try session.authorize(hello))
    }
    func testExplicitForegroundSelectionRequiresAnOperatorGrant() throws {
        guard case .request(let request) = try fixture("act-request"), case .act(let act) = request.body,
              let epoch = request.epoch else { return XCTFail() }
        let step = ActionStep(actionId: "click", operation: .click(ClickOperation(point: Point(x: 24, y: 16), space: .imagePixels)),
                              precondition: nil, expect: nil)
        func actRequest(foreground: Bool) -> Request {
            Request(version: request.version, id: request.id, epoch: epoch, budgetMs: request.budgetMs,
                body: .act(ActRequest(grantId: act.grantId, observationId: act.observationId, target: act.target,
                    steps: [step], foreground: foreground)))
        }
        let background = SessionContext(epoch: epoch, authority: Authority(grantId: act.grantId, mode: .backgroundRequired))
        let authorized = SessionContext(epoch: epoch, authority: Authority(grantId: act.grantId, mode: .foregroundAllowed))
        XCTAssertThrowsError(try background.authorize(actRequest(foreground: true)))
        try authorized.authorize(actRequest(foreground: true))
        let receipt = StepReceipt(actionId: "click", delivery: .dispatched, verification: .unverified, reason: nil,
                                  evidence: [], route: .foregroundClick)
        let result = Response(version: request.version, id: request.id, epoch: epoch,
            body: .act(ActResult(observationId: act.observationId, steps: [receipt], remainingSteps: 0, stopReason: .completed)))
        try result.validateFor(actRequest(foreground: true), expectedEpoch: epoch)
        XCTAssertThrowsError(try result.validateFor(actRequest(foreground: false), expectedEpoch: epoch))
    }

    func testPartialMutationAndUncertainDispatchDoNotBecomeRejections() throws {
        func result(_ name: String) throws -> ActResult {
            guard case .response(let response) = try fixture(name), case .act(let result) = response.body else {
                throw ContractError("wrong fixture kind")
            }
            return result
        }
        let partial = try result("act-partial-mutation")
        XCTAssertEqual(partial.steps[0].delivery, .dispatched)
        XCTAssertEqual(partial.steps[1].delivery, .notDispatched)
        XCTAssertEqual(partial.remainingSteps, 1)
        for name in ["act-timeout-dispatch-unknown", "act-helper-death-dispatch-unknown"] {
            let uncertain = try result(name)
            XCTAssertEqual(uncertain.steps[0].delivery, .unknown)
            XCTAssertEqual(uncertain.steps[0].verification, .unverified)
        }
        let existing = try result("act-already-satisfied")
        XCTAssertEqual(existing.steps[0].delivery, .notDispatched)
        XCTAssertEqual(existing.steps[0].verification, .confirmed)
        XCTAssertEqual(existing.steps[0].reason, .alreadySatisfied)
    }
    func testRepliesMatchPendingRequestEpochAndActionPrefix() throws {
        guard case .request(let request) = try fixture("act-request"),
              case .response(let response) = try fixture("act-verified-response"),
              case .act(let result) = response.body else { return XCTFail() }
        try response.validateFor(request, expectedEpoch: "helper-epoch-1")
        let wrongRequest = Response(version: response.version, id: "another-request", epoch: response.epoch, body: response.body)
        XCTAssertThrowsError(try wrongRequest.validateFor(request, expectedEpoch: "helper-epoch-1"))
        XCTAssertThrowsError(try response.validateFor(request, expectedEpoch: "restarted-helper"))
        let stale = Request(version: request.version, id: request.id, epoch: "old-epoch", budgetMs: request.budgetMs, body: request.body)
        XCTAssertThrowsError(try response.validateFor(stale, expectedEpoch: "helper-epoch-1"))
        let step = result.steps[0]
        let wrongStep = StepReceipt(actionId: "another-action", delivery: step.delivery, verification: step.verification,
                                    reason: step.reason, evidence: step.evidence)
        let wrongResult = ActResult(observationId: result.observationId, steps: [wrongStep], remainingSteps: 0, stopReason: .completed)
        let wrongPrefix = Response(version: response.version, id: response.id, epoch: response.epoch, body: .act(wrongResult))
        XCTAssertThrowsError(try wrongPrefix.validateFor(request, expectedEpoch: "helper-epoch-1"))
        for name in ["act-partial-mutation", "targets-response"] {
            guard case .response(let wrong) = try fixture(name) else { return XCTFail() }
            XCTAssertThrowsError(try wrong.validateFor(request, expectedEpoch: "helper-epoch-1"))
        }
    }
    func testObservationPrivacyFlagsAreCheckedAtResponseBoundary() throws {
        guard case .request(let request) = try fixture("observe-request"), case .observe(let observe) = request.body,
              case .response(let response) = try fixture("observe-partial-response"), case .observe(let observation) = response.body else {
            return XCTFail()
        }
        try response.validateFor(request, expectedEpoch: "helper-epoch-1")
        let element = observation.elements[0]
        let privateElement = Element(reference: element.reference, role: element.role, label: element.label, value: "private",
                                     bounds: element.bounds, enabled: element.enabled, actions: element.actions)
        let privateObservation = Observation(observationId: observation.observationId, target: observation.target,
                                             collected: observation.collected, windowBounds: observation.windowBounds,
                                             accessibility: observation.accessibility, accessibilityCollected: observation.accessibilityCollected,
                                             elements: [privateElement], screenshot: observation.screenshot)
        let privateResponse = Response(version: response.version, id: response.id, epoch: response.epoch, body: .observe(privateObservation))
        XCTAssertThrowsError(try privateResponse.validateFor(request, expectedEpoch: "helper-epoch-1"))
        let allowed = ObserveRequest(target: observe.target, includeScreenshot: true, includeValues: true)
        let allowedRequest = Request(version: request.version, id: request.id, epoch: request.epoch, budgetMs: request.budgetMs, body: .observe(allowed))
        try privateResponse.validateFor(allowedRequest, expectedEpoch: "helper-epoch-1")
        let noImage = ObserveRequest(target: observe.target, includeScreenshot: false, includeValues: true)
        let noImageRequest = Request(version: request.version, id: request.id, epoch: request.epoch, budgetMs: request.budgetMs, body: .observe(noImage))
        XCTAssertThrowsError(try privateResponse.validateFor(noImageRequest, expectedEpoch: "helper-epoch-1"))
    }
    func testProgressPreservesPrefixAndUnknownDeliveryRemainsIndependent() throws {
        guard case .request(let request) = try fixture("act-sequence-request"),
              case .progress(let progress) = try fixture("act-progress-prefix") else { return XCTFail() }
        try progress.validateFor(request, expectedEpoch: "helper-epoch-1")
        XCTAssertThrowsError(try progress.validateFor(request, expectedEpoch: "new-helper"))
        let step = progress.steps[0]
        let wrongStep = StepReceipt(actionId: "action-2", delivery: step.delivery, verification: step.verification,
                                    reason: step.reason, evidence: step.evidence)
        let wrong = CUAProtocol.Progress(version: progress.version, id: progress.id, epoch: progress.epoch,
                                         observationId: progress.observationId, steps: [wrongStep])
        XCTAssertThrowsError(try wrong.validateFor(request, expectedEpoch: "helper-epoch-1"))
        guard case .response(let partial) = try fixture("act-partial-mutation") else { return XCTFail() }
        try partial.validateFor(request, expectedEpoch: "helper-epoch-1")
        guard case .response(let response) = try fixture("act-unknown-state-confirmed"),
              case .act(let uncertain) = response.body else { return XCTFail() }
        XCTAssertEqual(uncertain.steps[0].delivery, .unknown)
        XCTAssertEqual(uncertain.steps[0].verification, .confirmed)
        XCTAssertNotEqual(uncertain.stopReason, .completed)
    }
    func testSharedExpectationCorrelationCases() throws {
        struct Case: Decodable { let name: String; let valid: Bool; let request: Frame; let reply: Frame }
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: fixtureRoot.appendingPathComponent("correlation.json")))
        XCTAssertEqual(cases.count, 66)
        for item in cases {
            try item.request.validate()
            try item.reply.validate()
            guard case .request(let request) = item.request else { return XCTFail() }
            func check() throws {
                switch item.reply {
                case .response(let response): try response.validateFor(request, expectedEpoch: "helper-epoch-1")
                case .progress(let progress): try progress.validateFor(request, expectedEpoch: "helper-epoch-1")
                default: throw ContractError("wrong correlation fixture kind")
                }
            }
            if item.valid { XCTAssertNoThrow(try check(), item.name) }
            else { XCTAssertThrowsError(try check(), item.name) }
        }
    }
    func testChannelTimesAndOverallClickCapability() throws {
        guard case .response(let response) = try fixture("observe-partial-response"), case .observe(let observation) = response.body,
              let ax = observation.accessibilityCollected, let screenshot = observation.screenshot else { return XCTFail() }
        XCTAssertLessThan(ax.finishedUnixMs, screenshot.collected.startedUnixMs)
        XCTAssertLessThanOrEqual(observation.collected.startedUnixMs, ax.startedUnixMs)
        XCTAssertLessThanOrEqual(screenshot.collected.finishedUnixMs, observation.collected.finishedUnixMs)
        guard case .response(let unavailableResponse) = try fixture("observe-unavailable-channel"),
              case .observe(let unavailable) = unavailableResponse.body else { return XCTFail() }
        XCTAssertNil(unavailable.accessibilityCollected)
        guard case .response(let capsResponse) = try fixture("capabilities-response"),
              case .capabilities(let caps) = capsResponse.body else { return XCTFail() }
        XCTAssertTrue(caps.actions.contains(.click))
        XCTAssertThrowsError(try JSONDecoder().decode(ElementAction.self, from: Data("\"click\"".utf8)))
    }
}
