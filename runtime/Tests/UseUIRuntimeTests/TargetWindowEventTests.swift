import UseUIProtocol
@testable import UseUIRuntime
import Foundation
import XCTest

private final class EventObject: AXObject, @unchecked Sendable {
    let id: String
    init(_ id: String) { self.id = id }
}

/// State changes are test-oracle writes. Native collection still uses the production observer and registry.
private final class EventFixture: AXReading, WindowCatalog, VisualCapturing, @unchecked Sendable {
    let pid: UInt32
    init(pid: UInt32 = 42) { self.pid = pid }
    let app = EventObject("app"), windowObject = EventObject("window"), toast = EventObject("toast"), noise = EventObject("noise")
    private let lock = NSLock()
    private var visible = false, unavailable = false
    private var text = "Saved", noiseText = "0"
    private var moved = false
    private var reads = 0
    var target: Target { Target(key: TargetKey(pid: pid, windowId: 7), bundleId: "test.events", title: "Events",
        bounds: Rect(x: 0, y: 0, width: moved ? 401 : 400, height: 240)) }
    let selectors = [UseUIProtocol.Selector(role: "AXStaticText", label: nil, identifier: "toast")]
    func set(visible: Bool, text: String = "Saved", unavailable: Bool = false) {
        lock.lock(); self.visible = visible; self.text = text; self.unavailable = unavailable; lock.unlock()
    }
    func move() { lock.lock(); moved = true; lock.unlock() }
    func animate() { lock.lock(); noiseText += "1"; lock.unlock() }
    var snapshotReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func application(pid: UInt32, context: OperationContext) throws -> any AXObject { try context.check(); return app }
    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren { try context.check(); return AXChildren(elements: [windowObject]) }
    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren {
        try context.check(); lock.lock(); defer { lock.unlock() }
        return AXChildren(elements: (element as! EventObject).id == "window" ? (visible ? [toast, noise] : [noise]) : [])
    }
    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? { try context.check(); return windowObject }
    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? { try context.check(); return windowObject }
    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32 { try context.check(); return pid }
    func identity(of element: any AXObject, context: OperationContext) throws -> AXElementIdentity? {
        try context.check(); lock.lock(); defer { lock.unlock() }
        let id = (element as! EventObject).id
        if unavailable && id == "toast" { throw AXReadUnavailable() }
        return AXElementIdentity(role: id == "window" ? "AXWindow" : "AXStaticText", identifier: id)
    }
    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot? {
        try context.check(); lock.lock(); defer { lock.unlock() }; reads += 1
        let id = (element as! EventObject).id
        if unavailable && id == "toast" { throw AXReadUnavailable() }
        if id == "window" { return AXNodeSnapshot(role: "AXWindow", title: target.title, identifier: id, bounds: target.bounds) }
        return AXNodeSnapshot(role: "AXStaticText", label: id == "toast" ? "Notice" : "Animation", identifier: id,
            bounds: Rect(x: 20, y: 30, width: 160, height: 20), value: includeValue ? (id == "toast" ? text : noiseText) : nil)
    }
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool { lhs === rhs }
    func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult { try context.check(); lock.lock(); defer { lock.unlock() }; return TargetsResult(targets: [target], truncated: false) }
    func window(_ key: TargetKey, context: OperationContext) throws -> Target { try context.check(); lock.lock(); defer { lock.unlock() }; return target }
    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] { try context.check(); lock.lock(); defer { lock.unlock() }; return [target] }
    func capture(target: Target, crop: Rect?, maxDimension: Int, context: OperationContext) throws -> CapturedVisual { throw NativeFailure(.unsupported, "test has no visual channel") }
    func observe(id: String = "event-observation", values: Bool = true) throws -> NativeObservation {
        try SemanticAXObserver(backend: self, catalog: self).observe(params: ObserveRequest(target: target.key, includeScreenshot: false,
            includeValues: values, axSelectors: selectors), observationId: id, context: OperationContext(budgetMs: 1000))
    }
}

private final class EventClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt64 = 0
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func advance() { lock.lock(); value += 60_000_000_000; lock.unlock() }
}

final class TargetWindowEventTests: XCTestCase {
    func testQueuedReadsDoNotStartAfterStopOrAbsoluteExpiry() throws {
        for expire in [false, true] {
            let fixture = EventFixture(), worker = DispatchQueue(label: "test.native"), clock = EventClock()
            let tracker = try tracker(fixture, worker: worker, clock: clock)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            worker.async { entered.signal(); release.wait() }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            let before = fixture.snapshotReads
            tracker.wake(source: .poll, notification: nil, observed: UInt64(Date().timeIntervalSince1970 * 1000))
            if expire { clock.advance() } else { tracker.stop() }
            release.signal(); worker.sync {}
            XCTAssertEqual(fixture.snapshotReads, before); XCTAssertEqual(try history(tracker).sampleCount, 0)
            XCTAssertTrue(try history(tracker).stale); XCTAssertEqual(try history(tracker).mode, .unavailable)
        }
    }
    func testOnlyFourPublishedWindowsRemainActive() throws {
        let events = TargetEventRegistry(), registry = ObservationRegistry(epoch: "epoch")
        events.configure(worker: DispatchQueue(label: "test.native"))
        var trackers: [TargetWindowEvents] = []
        for index in 0..<5 {
            let fixture = EventFixture(pid: UInt32(42 + index)), native = try fixture.observe(id: "window-\(index)")
            let handle = try XCTUnwrap(native.handle as? SemanticObservationHandle)
            let tracker = try events.track(handle: handle, observation: native.observation, selectors: fixture.selectors, context: OperationContext(budgetMs: 1000))
            handle.eventTracker = tracker; trackers.append(tracker)
            try registry.insert(native.observation, handle: handle)
        }
        XCTAssertFalse(trackers[0].active); XCTAssertTrue(trackers.dropFirst().allSatisfy(\.active))
        events.shutdown(); XCTAssertTrue(trackers.allSatisfy { !$0.active })
    }
    private func tracker(_ fixture: EventFixture, worker: DispatchQueue, clock: EventClock = EventClock()) throws -> TargetWindowEvents {
        let native = try fixture.observe()
        return TargetWindowEvents(handle: try XCTUnwrap(native.handle as? SemanticObservationHandle), selectors: fixture.selectors,
            baseline: native.observation, worker: worker, now: clock.now)
    }
    private func sample(_ tracker: TargetWindowEvents, worker: DispatchQueue, source: EventSource = .poll) {
        tracker.wake(source: source, notification: source == .notification ? "AXLayoutChanged" : nil,
            observed: UInt64(Date().timeIntervalSince1970 * 1000)); worker.sync {}
    }
    private func history(_ tracker: TargetWindowEvents, cursor: EventCursor? = nil, values: Bool = true) throws -> EventHistory {
        try tracker.history(after: cursor, includeValues: values, context: OperationContext(budgetMs: 1000))
    }
    func testNotificationIsOnlyAWakeupAndUnrelatedAnimationIsNotAnEvent() throws {
        let fixture = EventFixture(), worker = DispatchQueue(label: "test.events")
        let tracker = try tracker(fixture, worker: worker)
        fixture.animate(); sample(tracker, worker: worker, source: .notification)
        XCTAssertTrue(try history(tracker).events.isEmpty)
        fixture.set(visible: true); sample(tracker, worker: worker, source: .notification)
        let appeared = try history(tracker)
        XCTAssertEqual(appeared.sampleCount, 2); XCTAssertEqual(appeared.events.count, 1)
        XCTAssertEqual(appeared.events[0].controls.first?.value, "Saved")
        XCTAssertEqual(appeared.events[0].source, .notification)
        fixture.set(visible: false); sample(tracker, worker: worker)
        let removed = try history(tracker, cursor: appeared.cursor)
        XCTAssertEqual(removed.events.count, 1); XCTAssertTrue(removed.events[0].controls.isEmpty)
        XCTAssertEqual(removed.events[0].coverage, .complete)
    }
    func testUnreadableLeafCannotBecomeCompleteAbsenceEvidence() throws {
        let fixture = EventFixture(), worker = DispatchQueue(label: "test.events")
        let tracker = try tracker(fixture, worker: worker)
        fixture.set(visible: true, unavailable: true); sample(tracker, worker: worker)
        let event = try XCTUnwrap(history(tracker).events.first)
        XCTAssertEqual(event.coverage, .partial); XCTAssertTrue(event.controls.isEmpty)
    }
    func testCursorOverrunPrivacyAndGenerationAreExplicit() throws {
        let fixture = EventFixture(), worker = DispatchQueue(label: "test.events")
        let tracker = try tracker(fixture, worker: worker)
        for index in 0..<70 { fixture.set(visible: true, text: "value-\(index)"); sample(tracker, worker: worker) }
        let retained = try history(tracker, values: false)
        XCTAssertEqual(retained.cursor.sequence, 70); XCTAssertEqual(retained.sampleCount, 70)
        XCTAssertLessThanOrEqual(retained.events.count, Limits.maxTargetEvents)
        XCTAssertTrue(retained.overrun); XCTAssertTrue(retained.events.allSatisfy { $0.controls.allSatisfy { $0.value == nil } })
        XCTAssertTrue(try history(tracker, cursor: retained.cursor).events.isEmpty)
        XCTAssertTrue(try history(tracker, cursor: EventCursor(generation: "old-generation", sequence: 0)).stale)
        XCTAssertThrowsError(try history(tracker, cursor: EventCursor(generation: retained.cursor.generation, sequence: 71)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        XCTAssertLessThanOrEqual(try encoder.encode(retained).count, Limits.maxTargetEventBytes)
    }
    func testEventsWaitBehindTheSameNativeWorkerAndCoalesce() throws {
        let fixture = EventFixture(), worker = DispatchQueue(label: "test.native")
        let tracker = try tracker(fixture, worker: worker)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        worker.async { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        fixture.set(visible: true); tracker.wake(source: .poll, notification: nil, observed: UInt64(Date().timeIntervalSince1970 * 1000))
        tracker.wake(source: .poll, notification: nil, observed: UInt64(Date().timeIntervalSince1970 * 1000))
        XCTAssertEqual(try history(tracker).sampleCount, 0)
        release.signal(); worker.sync {}
        XCTAssertEqual(try history(tracker).sampleCount, 1); XCTAssertEqual(try history(tracker).coalescedWakes, 1)
    }
    func testAbsoluteTTLAndWindowGeometryInvalidateHistory() throws {
        let fixture = EventFixture(), worker = DispatchQueue(label: "test.events"), clock = EventClock()
        let tracker = try tracker(fixture, worker: worker, clock: clock)
        clock.advance(); fixture.set(visible: true); sample(tracker, worker: worker)
        XCTAssertFalse(tracker.active); XCTAssertTrue(try history(tracker).stale); XCTAssertEqual(try history(tracker).sampleCount, 0)
        let moved = try self.tracker(fixture, worker: worker)
        fixture.move(); sample(moved, worker: worker)
        XCTAssertTrue(try history(moved).stale); XCTAssertFalse(moved.active)
    }
    func testUnpublishedReplacementReleasesTrackerWithoutStoppingPublishedHistory() throws {
        let fixture = EventFixture(), worker = DispatchQueue(label: "test.native")
        let system = MacOSSystem(backend: fixture, catalog: fixture, visual: fixture, isAXTrusted: { true })
        system.configureObservationWorker(worker)
        let params = ObserveRequest(target: fixture.target.key, includeScreenshot: false, includeValues: false,
            axSelectors: fixture.selectors, eventHistory: EventHistoryRequest())
        let registry = ObservationRegistry(epoch: "epoch")
        let native = try system.observe(params: params, observationId: "published", context: OperationContext(budgetMs: 1000))
        try registry.insert(native.observation, handle: native.handle)
        let original = try XCTUnwrap((native.handle as? SemanticObservationHandle)?.eventTracker)
        let replacement = ObserveRequest(target: fixture.target.key, includeScreenshot: false, includeValues: false,
            axSelectors: [UseUIProtocol.Selector(role: "AXStaticText", label: nil, identifier: "noise")], eventHistory: EventHistoryRequest())
        var unpublished: NativeObservation? = try system.observe(params: replacement, observationId: "cancelled", context: OperationContext(budgetMs: 1000))
        weak var released = (unpublished?.handle as? SemanticObservationHandle)?.eventTracker
        XCTAssertNotNil(released); unpublished = nil; worker.sync {}
        XCTAssertNil(released); XCTAssertTrue(original.active)
        system.shutdownObservations(); XCTAssertFalse(original.active)
    }
    func testFallbackPollingActuallyRereadsBeforeTheNextRequest() throws {
        let fixture = EventFixture(), worker = DispatchQueue(label: "test.native")
        let native = try fixture.observe()
        let tracker = TargetWindowEvents(handle: try XCTUnwrap(native.handle as? SemanticObservationHandle), selectors: fixture.selectors,
            baseline: native.observation, worker: worker)
        try tracker.start(context: OperationContext(budgetMs: 1000)); defer { tracker.stop() }
        fixture.set(visible: true)
        let deadline = Date(timeIntervalSinceNow: 1)
        while try history(tracker).events.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        let captured = try history(tracker)
        XCTAssertEqual(captured.mode, .polling); XCTAssertEqual(captured.events.first?.controls.first?.value, "Saved")
    }
}
