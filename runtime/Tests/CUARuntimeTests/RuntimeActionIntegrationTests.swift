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
    enum BlockAt { case handoff, readback }
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

    init(blockAt point: BlockAt) { self.point = point }
    var mutationCount: Int { lock.lock(); defer { lock.unlock() }; return writes }

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
        try SemanticAXObserver(backend: self, catalog: self).observe(params: params, observationId: observationId, context: context)
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
        lock.unlock()
        if point == .readback && includeValue && same(element, field) && didReturn {
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
        lock.unlock()
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

final class RuntimeActionIntegrationTests: XCTestCase {
    func testDeadlineAfterNativeHandoffPreservesUnknownDelivery() throws {
        try verifyDeadline(blockAt: .handoff, expectedDelivery: .unknown)
    }

    func testDeadlineDuringReadbackPreservesSuccessfulDispatch() throws {
        try verifyDeadline(blockAt: .readback, expectedDelivery: .dispatched)
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
