import CUAProtocol
@testable import CUARuntime
import Foundation
import XCTest

private let integrationTarget = Target(key: TargetKey(pid: 42, windowId: 7), bundleId: "test.action-integration",
    title: "Action integration", bounds: Rect(x: 0, y: 0, width: 640, height: 480))

private final class IntegrationAXNode: AXObject, @unchecked Sendable {
    let role: String
    init(_ role: String) { self.role = role }
}

/// Models an AX call that cannot return until the test releases it. No OS UI is accessed.
private final class BlockingActionSystem: NativeSystem, AXReading, AXMutating, WindowCatalog, @unchecked Sendable {
    enum BlockAt { case none, handoff, readback, feedback }
    let blocked = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let point: BlockAt
    private let lock = NSLock()
    private let app = IntegrationAXNode("AXApplication")
    private let windowNode = IntegrationAXNode("AXWindow")
    private let field = IntegrationAXNode("AXTextField")
    private var value = "old"
    private var setterReturned = false
    private var writes = 0
    private var observations = 0
    private var exactReadbackFinished = false
    private let didMutate: @Sendable (Int) -> Void

    init(blockAt point: BlockAt, didMutate: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.point = point; self.didMutate = didMutate
    }
    var mutationCount: Int { lock.lock(); defer { lock.unlock() }; return writes }
    var observationCount: Int { lock.lock(); defer { lock.unlock() }; return observations }

    func permissions(context: OperationContext) throws -> Permissions {
        try context.check()
        return Permissions(accessibility: true, screenRecording: false, inputPosting: false)
    }
    func supportedActions(permissions: Permissions) -> [ActionKind] { [.setValue] }
    func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult {
        try context.check(); return TargetsResult(targets: [integrationTarget], truncated: false)
    }
    func window(_ key: TargetKey, context: OperationContext) throws -> Target { try context.check(); return integrationTarget }
    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] { try context.check(); return [integrationTarget] }
    func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)? {
        try context.check(); return app
    }
    func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation {
        lock.lock(); observations += 1; lock.unlock()
        return try SemanticAXObserver(backend: self, catalog: self).observe(params: params, observationId: observationId, context: context)
    }
    func application(pid: UInt32, context: OperationContext) throws -> any AXObject { try context.check(); return app }
    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren {
        try context.check(); return AXChildren(elements: [windowNode])
    }
    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren {
        try context.check(); return AXChildren(elements: same(element, windowNode) ? [field] : [])
    }
    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check(); return same(element, app) ? nil : same(element, windowNode) ? app : windowNode
    }
    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? { try context.check(); return windowNode }
    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32 { try context.check(); return 42 }
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool { lhs === rhs }
    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot? {
        try context.check()
        lock.lock()
        let didReturn = setterReturned
        let current = value
        let feedbackRead = point == .feedback && didReturn && !includeValue && same(element, field) && exactReadbackFinished
        if didReturn && includeValue && same(element, field) { exactReadbackFinished = true }
        lock.unlock()
        if (point == .readback && includeValue && same(element, field) && didReturn) || feedbackRead {
            blocked.signal()
            _ = release.wait(timeout: .now() + 3)
            try context.check()
        }
        let role = (element as! IntegrationAXNode).role
        return AXNodeSnapshot(role: role, title: role == "AXWindow" ? integrationTarget.title : nil,
            label: role == "AXTextField" ? "Field" : nil,
            bounds: role == "AXWindow" ? integrationTarget.bounds : Rect(x: 10, y: 20, width: 200, height: 30),
            value: includeValue && same(element, field) ? current : nil, valueSettable: same(element, field))
    }
    func setValue(_ value: String, on object: any AXObject, context: OperationContext,
                  willDispatch: @Sendable () throws -> Void) throws {
        try context.check()
        try willDispatch()
        if point == .handoff {
            blocked.signal()
            _ = release.wait(timeout: .now() + 3)
        }
        lock.lock()
        self.value = value; writes += 1; setterReturned = true
        let count = writes
        lock.unlock()
        didMutate(count)
    }
    func press(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "fixture supports only setValue")
    }
    func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext,
                             willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "fixture supports only setValue")
    }
}

private final class IntegrationResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Response] = []
    private let changed = DispatchSemaphore(value: 0)
    func append(_ response: Response) { lock.lock(); values.append(response); lock.unlock(); changed.signal() }
    func matching(_ id: String) -> [Response] { lock.lock(); defer { lock.unlock() }; return values.filter { $0.id == id } }
    func wait(_ id: String) throws -> Response {
        let deadline = DispatchTime.now() + 2
        while true {
            if let response = matching(id).first { return response }
            guard changed.wait(timeout: deadline) == .success else { throw ContractError("integration response timeout") }
        }
    }
}

private final class IntegrationEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var wire: [Frame] = []
    func record(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    func wrote(_ frame: Frame) {
        lock.lock(); wire.append(frame)
        if case .progress(let progress) = frame { values.append("progress-\(progress.steps.count)") }
        lock.unlock()
    }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var frames: [Frame] { lock.lock(); defer { lock.unlock() }; return wire }
}

final class RuntimeActionIntegrationTests: XCTestCase {
    func testDeadlineAfterNativeHandoffPreservesUnknownDelivery() throws {
        try verifyDeadline(blockAt: .handoff, expectedDelivery: .unknown)
    }

    func testDeadlineDuringReadbackPreservesSuccessfulDispatch() throws {
        try verifyDeadline(blockAt: .readback, expectedDelivery: .dispatched)
    }

    func testActualProgressWritePrecedesEverySubsequentMutation() throws {
        let events = IntegrationEvents()
        let system = BlockingActionSystem(blockAt: .none, didMutate: { events.record("mutation-\($0)") })
        let values = IntegrationResponses()
        let output = OutputPump(write: { events.wrote(try Frame.decodeLine($0)) }, onFailure: { XCTFail("output failed") })
        let directory = try privateDirectory()
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: directory), foreground: { 100 })
        let session = RuntimeSession(system: system, epoch: "integration-epoch", actions: engine,
            emit: { response in
                do { try output.send(response) } catch { XCTFail("output admission failed") }
                values.append(response)
            },
            emitProgress: output.sendProgress)
        defer { session.shutdown() }
        let (observation, field) = try observe(session, values: values)
        let action = sequence(observation, field: field, count: 3)
        try send(action, to: session)
        let response = try values.wait("sequence")
        try response.validateFor(action, expectedEpoch: session.epoch)
        let drained = DispatchSemaphore(value: 0)
        output.finish { drained.signal() }
        XCTAssertEqual(drained.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(events.events, ["mutation-1", "progress-1", "mutation-2", "progress-2", "mutation-3"])
        for frame in events.frames {
            if case .progress(let progress) = frame { try progress.validateFor(action, expectedEpoch: session.epoch) }
        }
        XCTAssertEqual(system.mutationCount, 3)
    }

    func testStalledProgressWriteDoesNotBlockDeadlineControlOrPermitNextMutation() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let events = IntegrationEvents()
        let system = BlockingActionSystem(blockAt: .none)
        let values = IntegrationResponses()
        let output = OutputPump(write: { data in
            let frame = try Frame.decodeLine(data)
            if case .progress = frame { entered.signal(); _ = release.wait(timeout: .now() + 3) }
            events.wrote(frame)
        }, onFailure: { XCTFail("output failed") })
        let directory = try privateDirectory()
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: directory), foreground: { 100 })
        let session = RuntimeSession(system: system, epoch: "integration-epoch", actions: engine,
            emit: { response in
                do { try output.send(response) } catch { XCTFail("output admission failed") }
                values.append(response)
            },
            emitProgress: output.sendProgress)
        defer { release.signal(); session.shutdown() }
        let (observation, field) = try observe(session, values: values)
        let action = sequence(observation, field: field, count: 3, budget: 150)
        try send(action, to: session)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(system.mutationCount, 1)
        XCTAssertThrowsError(try MutationCoordinator(directory: directory).withOwnership(context: OperationContext(budgetMs: 20)) {})
        let response = try values.wait("sequence")
        try response.validateFor(action, expectedEpoch: session.epoch)
        guard case .act(let result) = response.body else { return XCTFail("missing deadline receipt") }
        XCTAssertEqual(result.steps.map(\.delivery), [.dispatched, .notDispatched])
        XCTAssertEqual(result.stopReason, .deadlineExceeded)
        XCTAssertEqual(result.remainingSteps, 1)
        XCTAssertEqual(system.mutationCount, 1)
        let barrier = request("barrier", .capabilities(Empty()))
        try send(barrier, to: session)
        _ = try values.wait("barrier") // The native worker also stops waiting without needing stdout to drain.
        release.signal()
        let drained = DispatchSemaphore(value: 0)
        output.finish { drained.signal() }
        XCTAssertEqual(drained.wait(timeout: .now() + 1), .success)
        let sequenceFrames = events.frames.filter {
            switch $0 { case .progress(let p): return p.id == "sequence"; case .response(let r): return r.id == "sequence"; default: return false }
        }
        guard sequenceFrames.count == 2 else { return XCTFail("expected one prefix and one final frame") }
        guard case .progress = sequenceFrames[0], case .response = sequenceFrames[1] else {
            return XCTFail("admitted prefix must precede the timer final on stdout")
        }
        XCTAssertEqual(system.mutationCount, 1)
        XCTAssertEqual(values.matching("sequence").count, 1)
    }

    func testWindowAbsenceReturnsItsWitnessWithoutFabricatingAnObservation() throws {
        let system = BlockingActionSystem(blockAt: .none)
        let values = IntegrationResponses()
        let engine = BackgroundActions(predicates: PredicateEvaluator(windowPresent: { _, context in try context.check(); return false }))
        let session = RuntimeSession(system: system, epoch: "integration-epoch", actions: engine, emit: values.append)
        defer { session.shutdown() }
        let (observation, _) = try observe(session, values: values)
        let condition = Condition.windowAbsent(Empty())
        let wait = request("gone", .waitFor(WaitRequest(observationId: observation.observationId,
            target: integrationTarget.key, condition: condition)))
        try send(wait, to: session)
        let response = try values.wait("gone")
        try response.validateFor(wait, expectedEpoch: session.epoch)
        guard case .waitFor(let result) = response.body else { return XCTFail("missing wait result") }
        XCTAssertEqual(result.outcome, .satisfied)
        XCTAssertTrue(result.alreadySatisfied)
        XCTAssertNil(result.observation)
        XCTAssertEqual(result.evidence?.condition, condition)
        XCTAssertEqual(result.evidence?.matched, true)
        XCTAssertNotNil(result.evidence?.collected)
        XCTAssertEqual(system.observationCount, 1)
        XCTAssertEqual(system.mutationCount, 0)
        XCTAssertEqual(session.observations.count, 1)
    }

    func testActionFeedbackUsesOnlyRequestedBaseReferencesWithoutPublishingObservation() throws {
        let system = BlockingActionSystem(blockAt: .none)
        let values = IntegrationResponses()
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: try privateDirectory()), foreground: { 100 })
        let session = RuntimeSession(system: system, epoch: "integration-epoch", actions: engine, emit: values.append)
        defer { session.shutdown() }
        let (observation, field) = try observe(session, values: values)
        for includeValues in [false, true] {
            let action = request("feedback-\(includeValues)", .act(ActRequest(grantId: "grant", observationId: observation.observationId,
                target: integrationTarget.key, steps: [ActionStep(actionId: "set", operation: .setValue(
                    SetValueOperation(elementRef: field.reference, value: "new-\(includeValues)")), precondition: nil, expect: nil)],
                feedback: FeedbackRequest(elementRefs: [field.reference], includeValues: includeValues))))
            try send(action, to: session)
            let response = try values.wait(action.id)
            try response.validateFor(action, expectedEpoch: session.epoch)
            guard case .act(let result) = response.body, let feedback = result.feedback else { return XCTFail("missing requested feedback") }
            XCTAssertEqual(result.stopReason, .completed)
            XCTAssertEqual(feedback.baseObservationId, observation.observationId)
            XCTAssertEqual(feedback.controls.map(\.elementRef), [field.reference])
            XCTAssertFalse(feedback.invalidated)
            if includeValues {
                XCTAssertEqual(feedback.controls[0].state, .changed)
                XCTAssertEqual(feedback.controls[0].element?.value, "new-true")
            } else {
                XCTAssertEqual(feedback.controls[0].state, .unchanged)
                XCTAssertNil(feedback.controls[0].element)
            }
        }
        XCTAssertEqual(system.observationCount, 1)
        XCTAssertEqual(session.observations.count, 1)
    }

    func testOptionalFeedbackDeadlinePreservesCompletedActionAndIgnoresLateReadback() throws {
        let system = BlockingActionSystem(blockAt: .feedback)
        let values = IntegrationResponses()
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: try privateDirectory()), foreground: { 100 })
        let session = RuntimeSession(system: system, epoch: "integration-epoch", actions: engine, emit: values.append)
        defer { system.release.signal(); session.shutdown() }
        let (observation, field) = try observe(session, values: values)
        let action = request("feedback-deadline", .act(ActRequest(grantId: "grant", observationId: observation.observationId,
            target: integrationTarget.key, steps: [ActionStep(actionId: "set", operation: .setValue(
                SetValueOperation(elementRef: field.reference, value: "new")), precondition: nil, expect: nil)],
            feedback: FeedbackRequest(elementRefs: [field.reference], includeValues: false))), budget: 150)
        try send(action, to: session)
        XCTAssertEqual(system.blocked.wait(timeout: .now() + 1), .success)
        let response = try values.wait(action.id)
        try response.validateFor(action, expectedEpoch: session.epoch)
        guard case .act(let result) = response.body else { return XCTFail("missing action receipt") }
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertNil(result.feedback)
        system.release.signal()
        let barrier = request("barrier", .capabilities(Empty()))
        try send(barrier, to: session)
        _ = try values.wait("barrier")
        XCTAssertEqual(system.mutationCount, 1)
        XCTAssertEqual(values.matching(action.id).count, 1)
    }

    private func privateDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-session-sequence-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func observe(_ session: RuntimeSession, values: IntegrationResponses) throws -> (Observation, Element) {
        let hello = request("hello", .hello(HelloRequest(clientName: "integration-tests", supportedVersions: [1],
            authority: Authority(grantId: "grant", mode: .backgroundRequired))), epoch: nil)
        try send(hello, to: session)
        _ = try values.wait("hello")
        let observe = request("observe", .observe(ObserveRequest(target: integrationTarget.key, includeScreenshot: false, includeValues: false)))
        try send(observe, to: session)
        let response = try values.wait("observe")
        try response.validateFor(observe, expectedEpoch: session.epoch)
        guard case .observe(let observation) = response.body,
              let field = observation.elements.first(where: { $0.role == "AXTextField" }) else {
            throw ContractError("semantic field missing")
        }
        return (observation, field)
    }

    private func sequence(_ observation: Observation, field: Element, count: Int, budget: UInt32 = 1000) -> Request {
        request("sequence", .act(ActRequest(grantId: "grant", observationId: observation.observationId,
            target: integrationTarget.key, steps: (0..<count).map {
                ActionStep(actionId: "set-\($0)", operation: .setValue(SetValueOperation(elementRef: field.reference,
                    value: "value-\($0)")), precondition: nil, expect: nil)
            })), budget: budget)
    }

    private func verifyDeadline(blockAt: BlockingActionSystem.BlockAt, expectedDelivery: Delivery) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-session-action-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let system = BlockingActionSystem(blockAt: blockAt)
        let values = IntegrationResponses()
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: directory), foreground: { 100 })
        let session = RuntimeSession(system: system, epoch: "integration-epoch", actions: engine, emit: values.append)
        defer { system.release.signal(); session.shutdown() }

        let hello = request("hello", .hello(HelloRequest(clientName: "integration-tests", supportedVersions: [1],
            authority: Authority(grantId: "grant", mode: .backgroundRequired))), epoch: nil)
        try send(hello, to: session)
        try values.wait("hello").validateFor(hello, expectedEpoch: session.epoch)

        let observe = request("observe", .observe(ObserveRequest(target: integrationTarget.key, includeScreenshot: false, includeValues: false)))
        try send(observe, to: session)
        let observed = try values.wait("observe")
        try observed.validateFor(observe, expectedEpoch: session.epoch)
        guard case .observe(let observation) = observed.body,
              let field = observation.elements.first(where: { $0.role == "AXTextField" }) else {
            return XCTFail("semantic field was not published")
        }
        let action = request("action", .act(ActRequest(grantId: "grant", observationId: observation.observationId,
            target: integrationTarget.key, steps: [ActionStep(actionId: "set", operation: .setValue(
                SetValueOperation(elementRef: field.reference, value: "new")), precondition: nil, expect: nil)])), budget: 200)
        try send(action, to: session)
        XCTAssertEqual(system.blocked.wait(timeout: .now() + 1), .success, "worker must cross the tested handoff before the deadline")

        // The blocked physical operation cannot supply this response; the independent control timer must snapshot the ledger.
        let response = try values.wait("action")
        try Frame.response(response).validate()
        try response.validateFor(action, expectedEpoch: session.epoch)
        guard case .act(let receipt) = response.body else { return XCTFail("expected an action receipt") }
        XCTAssertEqual(receipt.stopReason, .deadlineExceeded)
        XCTAssertEqual(receipt.steps[0].reason, .deadlineExceeded)
        XCTAssertEqual(receipt.steps[0].delivery, expectedDelivery)
        XCTAssertEqual(receipt.steps[0].verification, .unverified)
        XCTAssertEqual(receipt.steps[0].route, .axSetValue)

        system.release.signal()
        let barrier = request("barrier", .capabilities(Empty()))
        try send(barrier, to: session)
        try values.wait("barrier").validateFor(barrier, expectedEpoch: session.epoch)
        XCTAssertEqual(system.mutationCount, 1)
        XCTAssertEqual(values.matching("action").count, 1, "late native completion must not emit a replacement receipt")
        guard case .act(let retained) = try values.wait("action").body else { return XCTFail("action response changed") }
        XCTAssertEqual(retained.steps[0].delivery, expectedDelivery)
    }

    private func request(_ id: String, _ body: RequestBody, budget: UInt32 = 1000, epoch: String? = "integration-epoch") -> Request {
        Request(version: 1, id: id, epoch: epoch, budgetMs: budget, body: body)
    }
    private func send(_ request: Request, to session: RuntimeSession) throws {
        session.receive(request, frameBytes: try Frame.request(request).encodeLine().count)
    }
}
