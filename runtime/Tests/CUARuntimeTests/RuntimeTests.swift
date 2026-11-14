import CUAProtocol
@testable import CUARuntime
import Foundation
import XCTest

private let testTarget = Target(key: TargetKey(pid: 42, windowId: 7), bundleId: "test.fixture", title: "Fixture",
                                bounds: Rect(x: -10, y: 20, width: 640, height: 480))

private final class Counter: @unchecked Sendable {
    let lock = NSLock()
    var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    func get() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}
private final class Handle: RetainedNativeHandle, @unchecked Sendable {
    let released: Counter
    init(_ released: Counter) { self.released = released }
    deinit { released.increment() }
}
private final class FakeSystem: NativeSystem, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let retainEntered = DispatchSemaphore(value: 0)
    let retainRelease = DispatchSemaphore(value: 0)
    let calls = Counter()
    let released = Counter()
    let hold: Bool
    let holdRetain: Bool
    init(hold: Bool = false, holdRetain: Bool = false) { self.hold = hold; self.holdRetain = holdRetain }
    func permissions(context: OperationContext) throws -> Permissions {
        calls.increment(); entered.signal()
        defer { finished.signal() }
        if hold { _ = release.wait(timeout: .now() + 5) }
        try context.check()
        return Permissions(accessibility: true, screenRecording: false, inputPosting: false)
    }
    func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult {
        calls.increment(); try context.check()
        return TargetsResult(targets: [testTarget], truncated: false)
    }
    func window(_ key: TargetKey, context: OperationContext) throws -> Target { try context.check(); return testTarget }
    func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)? {
        try context.check()
        XCTAssertGreaterThan(timeoutSeconds, 0)
        XCTAssertLessThanOrEqual(timeoutSeconds, 0.25)
        let handle = Handle(released)
        if holdRetain {
            retainEntered.signal()
            _ = retainRelease.wait(timeout: .now() + 5)
        }
        return handle
    }
}
private final class Collector: @unchecked Sendable {
    let lock = NSLock()
    var responses: [Response] = []
    let changed = DispatchSemaphore(value: 0)
    func append(_ value: Response) { lock.lock(); responses.append(value); lock.unlock(); changed.signal() }
    func all() -> [Response] { lock.lock(); defer { lock.unlock() }; return responses }
    func response(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> Response {
        let deadline = DispatchTime.now() + 2
        while true {
            if let value = all().first(where: { $0.id == id }) { return value }
            guard changed.wait(timeout: deadline) == .success else {
                XCTFail("response timeout for \(id)", file: file, line: line)
                throw ContractError("test timed out")
            }
        }
    }
}
private final class TestClock: @unchecked Sendable {
    let lock = NSLock()
    var value: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ ns: UInt64) { lock.lock(); value += ns; lock.unlock() }
}

final class RuntimeTests: XCTestCase {
    func request(_ id: String, _ body: RequestBody, budget: UInt32 = 1000, epoch: String? = "epoch") -> Request {
        Request(version: 1, id: id, epoch: epoch, budgetMs: budget, body: body)
    }
    func send(_ request: Request, to session: RuntimeSession, receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
        session.receive(request, receivedAt: receivedAt, frameBytes: try Frame.request(request).encodeLine().count)
    }
    private func connected(_ system: FakeSystem = FakeSystem(), limits: RuntimeLimits = RuntimeLimits(),
                   shutdown: @escaping @Sendable () -> Void = {}) throws -> (RuntimeSession, Collector) {
        let values = Collector()
        let session = RuntimeSession(system: system, epoch: "epoch", limits: limits, emit: values.append, didShutdown: shutdown)
        let hello = request("hello", .hello(HelloRequest(clientName: "tests", supportedVersions: [1],
                              authority: Authority(grantId: "grant", mode: .backgroundRequired))), epoch: nil)
        try send(hello, to: session)
        let response = try values.response("hello")
        try response.validateFor(hello, expectedEpoch: "epoch")
        return (session, values)
    }
    func errorCode(_ value: Response) -> ErrorCode? {
        if case .error(let error) = value.body { return error.code }; return nil
    }

    func testFramingAcrossReadsAndEOF() throws {
        let req = request("cap", .capabilities(Empty()))
        let line = try Frame.request(req).encodeLine()
        var framer = LineFramer()
        XCTAssertTrue(try framer.append(line.prefix(10)).isEmpty)
        let lines = try framer.append(line.dropFirst(10))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(try Frame.decodeLine(lines[0]), .request(req))
        XCTAssertNoThrow(try framer.finish())
        _ = try framer.append(Data("{".utf8))
        XCTAssertThrowsError(try framer.finish())
    }
    func testMalformedAndOversizeFraming() throws {
        XCTAssertThrowsError(try Frame.decodeLine(Data("{}\r\n".utf8)))
        XCTAssertThrowsError(try Frame.decodeLine(Data("not-json\n".utf8)))
        var framer = LineFramer()
        XCTAssertThrowsError(try framer.append(Data(repeating: 65, count: Limits.maxFrameBytes)))
    }
    func testHandshakeAuthorityAndEpochAreNotModelSelectable() throws {
        let (session, values) = try connected()
        defer { session.shutdown() }
        let old = request("old", .capabilities(Empty()), epoch: "old-epoch")
        try send(old, to: session)
        XCTAssertEqual(errorCode(try values.response("old")), .staleEpoch)
        let forged = request("forged", .act(ActRequest(grantId: "forged", observationId: "o", target: testTarget.key,
            steps: [ActionStep(actionId: "a", operation: .press(ElementOperation(elementRef: "r")), precondition: nil, expect: nil)])))
        try send(forged, to: session)
        XCTAssertEqual(errorCode(try values.response("forged")), .authorityDenied)
        let cap = request("cap", .capabilities(Empty()))
        try send(cap, to: session)
        guard case .capabilities(let result) = try values.response("cap").body else { return XCTFail("wrong response") }
        XCTAssertEqual(result.actions, [])
        XCTAssertEqual(result.mode, .backgroundRequired)
    }
    func testDuplicateRequestClosesWithoutReplayingOrSecondFinalResponse() throws {
        let ended = DispatchSemaphore(value: 0)
        let system = FakeSystem()
        let (session, values) = try connected(system, shutdown: { ended.signal() })
        let req = request("cap", .capabilities(Empty()))
        try send(req, to: session)
        _ = try values.response("cap")
        try send(req, to: session)
        XCTAssertEqual(ended.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(system.calls.get(), 1)
        XCTAssertEqual(values.all().filter { $0.id == "cap" }.count, 1)
    }
    func testCancelDoesNotWaitForNativeWorker() throws {
        let system = FakeSystem(hold: true)
        let (session, values) = try connected(system)
        defer { system.release.signal(); session.shutdown() }
        let req = request("blocked", .capabilities(Empty()))
        try send(req, to: session)
        XCTAssertEqual(system.entered.wait(timeout: .now() + 1), .success)
        let start = DispatchTime.now().uptimeNanoseconds
        let cancel = request("cancel", .cancel(CancelRequest(requestId: "blocked")))
        try send(cancel, to: session)
        guard case .cancel(let ack) = try values.response("cancel").body else { return XCTFail("missing ack") }
        XCTAssertEqual(ack.status, .requested)
        XCTAssertEqual(errorCode(try values.response("blocked")), .cancelled)
        XCTAssertLessThan(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, 250)
        system.release.signal()
        XCTAssertEqual(system.finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(values.all().filter { $0.id == "blocked" }.count, 1)
    }
    func testWholeBudgetIncludesQueueAndLateNativeResultsDoNotReplaceTimeout() throws {
        let system = FakeSystem(hold: true)
        let (session, values) = try connected(system)
        defer { system.release.signal(); session.shutdown() }
        try send(request("blocked", .capabilities(Empty())), to: session)
        XCTAssertEqual(system.entered.wait(timeout: .now() + 1), .success)
        let queued = request("queued", .targets(TargetsRequest(bundleId: nil)), budget: 30)
        try send(queued, to: session)
        XCTAssertEqual(errorCode(try values.response("queued")), .deadlineExceeded)
        XCTAssertEqual(system.calls.get(), 1)
        system.release.signal()
        _ = try values.response("blocked")
        try send(request("barrier", .act(ActRequest(grantId: "grant", observationId: "o", target: testTarget.key,
            steps: [ActionStep(actionId: "a", operation: .press(ElementOperation(elementRef: "r")), precondition: nil, expect: nil)]))), to: session)
        _ = try values.response("barrier")
        XCTAssertEqual(system.calls.get(), 1)
        XCTAssertEqual(values.all().filter { $0.id == "queued" }.count, 1)
    }
    func testCancelledPhysicalWorkStillCountsAgainstQueueBound() throws {
        let system = FakeSystem(hold: true)
        var limits = RuntimeLimits(); limits.maxWorkItems = 2
        let (session, values) = try connected(system, limits: limits)
        defer { system.release.signal(); session.shutdown() }
        try send(request("blocked", .capabilities(Empty())), to: session)
        XCTAssertEqual(system.entered.wait(timeout: .now() + 1), .success)
        try send(request("queued", .targets(TargetsRequest(bundleId: nil))), to: session)
        try send(request("cancel", .cancel(CancelRequest(requestId: "queued"))), to: session)
        _ = try values.response("cancel")
        try send(request("overflow", .capabilities(Empty())), to: session)
        XCTAssertEqual(errorCode(try values.response("overflow")), .resourceLimit)
    }
    func testExpiredOnReceiptNeverCallsNative() throws {
        let system = FakeSystem()
        let (session, values) = try connected(system)
        defer { session.shutdown() }
        try send(request("expired", .capabilities(Empty()), budget: 1), to: session,
                 receivedAt: DispatchTime.now().uptimeNanoseconds - 2_000_000)
        XCTAssertEqual(errorCode(try values.response("expired")), .deadlineExceeded)
        XCTAssertEqual(system.calls.get(), 0)
    }
    func testActUnsupportedReceiptAccountsForUnsentSuffix() throws {
        let (session, values) = try connected()
        defer { session.shutdown() }
        let req = request("act", .act(ActRequest(grantId: "grant", observationId: "o", target: testTarget.key,
            steps: ["first", "second"].map { ActionStep(actionId: $0, operation: .setValue(SetValueOperation(elementRef: "r", value: "v")), precondition: nil, expect: nil) })))
        try send(req, to: session)
        let response = try values.response("act")
        try response.validateFor(req, expectedEpoch: "epoch")
        guard case .act(let result) = response.body else { return XCTFail("wrong response") }
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertEqual(result.stopReason, .unsupported)
        XCTAssertEqual(result.remainingSteps, 1)
    }
    func testLifecycleObservationRetainsHandleAndShutdownReleasesIt() throws {
        let system = FakeSystem()
        let ended = DispatchSemaphore(value: 0)
        let (session, values) = try connected(system, shutdown: { ended.signal() })
        let req = request("observe", .observe(ObserveRequest(target: testTarget.key, includeScreenshot: false, includeValues: false)))
        try send(req, to: session)
        let response = try values.response("observe")
        try response.validateFor(req, expectedEpoch: "epoch")
        guard case .observe(let observation) = response.body else { return XCTFail("wrong response") }
        XCTAssertEqual(observation.accessibility, .unavailable)
        XCTAssertTrue(observation.elements.isEmpty)
        XCTAssertNil(observation.screenshot)
        XCTAssertEqual(session.observations.count, 1)
        XCTAssertThrowsError(try session.observations.lookup(observation.observationId, epoch: "other", target: testTarget.key))
        session.shutdown()
        XCTAssertEqual(ended.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(session.observations.count, 0)
        XCTAssertEqual(system.released.get(), 1)
    }
    func testShutdownAcknowledgesPendingAndDoesNotWaitForBlockedRead() throws {
        let system = FakeSystem(hold: true)
        let ended = DispatchSemaphore(value: 0)
        let (session, values) = try connected(system, shutdown: { ended.signal() })
        defer { system.release.signal() }
        try send(request("blocked", .capabilities(Empty())), to: session)
        XCTAssertEqual(system.entered.wait(timeout: .now() + 1), .success)
        session.shutdown()
        XCTAssertEqual(ended.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(errorCode(try values.response("blocked")), .cancelled)
    }
    func testRegistryBoundExpiryAndCleanupReleaseHandles() throws {
        let time = TestClock()
        let released = Counter()
        let registry = ObservationRegistry(epoch: "epoch", now: time.now)
        for index in 0...32 {
            let observation = Observation(observationId: "o-\(index)", target: testTarget.key,
                collected: CollectionInterval(startedUnixMs: 0, finishedUnixMs: 0), windowBounds: testTarget.bounds,
                accessibility: .unavailable, accessibilityCollected: nil, elements: [], screenshot: nil)
            try registry.insert(observation, handle: Handle(released))
        }
        XCTAssertEqual(registry.count, 32)
        XCTAssertEqual(released.get(), 1)
        XCTAssertThrowsError(try registry.lookup("o-0", epoch: "epoch", target: testTarget.key))
        time.advance(UInt64(Limits.observationTTLMS) * 1_000_000)
        registry.prune()
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(released.get(), 33)
        registry.invalidate()
        let observation = Observation(observationId: "late", target: testTarget.key,
            collected: CollectionInterval(startedUnixMs: 0, finishedUnixMs: 0), windowBounds: testTarget.bounds,
            accessibility: .unavailable, accessibilityCollected: nil, elements: [], screenshot: nil)
        XCTAssertThrowsError(try registry.insert(observation, handle: Handle(released)))
    }

    func testCancelledLateObservationReleasesUnpublishedHandle() throws {
        let system = FakeSystem(holdRetain: true)
        let (session, values) = try connected(system)
        defer { system.retainRelease.signal(); session.shutdown() }
        try send(request("observe", .observe(ObserveRequest(target: testTarget.key, includeScreenshot: false, includeValues: false))), to: session)
        XCTAssertEqual(system.retainEntered.wait(timeout: .now() + 1), .success)
        try send(request("cancel", .cancel(CancelRequest(requestId: "observe"))), to: session)
        _ = try values.response("cancel")
        XCTAssertEqual(errorCode(try values.response("observe")), .cancelled)
        system.retainRelease.signal()
        try send(request("barrier", .capabilities(Empty())), to: session)
        _ = try values.response("barrier")
        XCTAssertEqual(session.observations.count, 0)
        XCTAssertEqual(system.released.get(), 1)
        XCTAssertEqual(values.all().filter { $0.id == "observe" }.count, 1)
    }

    func testOutputBackpressureIsBoundedAndFinishDrainsAcceptedFrames() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let written = Counter()
        let pump = OutputPump(write: { _ in
            entered.signal(); _ = release.wait(timeout: .now() + 2); written.increment()
        }, onFailure: {})
        let response = Response(version: 1, id: "r", epoch: "epoch", body: .capabilities(
            Capabilities(permissions: Permissions(accessibility: false, screenRecording: false, inputPosting: false),
                         mode: .backgroundRequired, actions: [])))
        try pump.send(response)
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        for _ in 1..<32 { try pump.send(response) }
        XCTAssertThrowsError(try pump.send(response))
        pump.finish { finished.signal() }
        for _ in 0..<32 { release.signal() }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(written.get(), 32)
        XCTAssertThrowsError(try pump.send(response))
    }

    func testRequestHistoryIsBoundedWithoutForgettingDuplicateIDs() throws {
        let ended = DispatchSemaphore(value: 0)
        var limits = RuntimeLimits(); limits.maxRequestIDs = 2
        let (session, values) = try connected(limits: limits, shutdown: { ended.signal() })
        try send(request("cap", .capabilities(Empty())), to: session)
        _ = try values.response("cap")
        try send(request("overflow", .capabilities(Empty())), to: session)
        XCTAssertEqual(errorCode(try values.response("overflow")), .resourceLimit)
        XCTAssertEqual(ended.wait(timeout: .now() + 1), .success)
    }
}
