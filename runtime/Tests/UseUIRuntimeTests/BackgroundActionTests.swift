import UseUIProtocol
@testable import UseUIRuntime
import Darwin
import Foundation
import XCTest

private let actionTarget = Target(key: TargetKey(pid: 42, windowId: 7), bundleId: "test.fixture", title: "Fixture",
                                  bounds: Rect(x: 0, y: 0, width: 600, height: 400))
private final class ActionNode: AXObject, @unchecked Sendable {
    var role: String
    init(_ role: String) { self.role = role }
}
private final class PrefixLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[StepReceipt]] = []
    func append(_ prefix: [StepReceipt], context: OperationContext) throws {
        try context.check(); lock.lock(); values.append(prefix); lock.unlock()
    }
    var prefixes: [[StepReceipt]] { lock.lock(); defer { lock.unlock() }; return values }
}
private final class ActionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func now() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func expire() { lock.lock(); value += UInt64(Limits.observationTTLMS) * 1_000_000; lock.unlock() }
}
private final class ActionBackend: AXReading, AXMutating, AXScrolling, WindowCatalog, @unchecked Sendable {
    enum Behavior { case apply, ignore, delayed, throwAfterWrite, readbackFailure, activate, activateBeforeDispatch, refuse, block }
    let app = ActionNode("AXApplication")
    let windowNode = ActionNode("AXWindow")
    let field = ActionNode("AXTextField")
    let button = ActionNode("AXButton")
    let scrollArea = ActionNode("AXScrollArea")
    let verticalBar = ActionNode("AXScrollBar")
    let horizontalBar = ActionNode("AXScrollBar")
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var behavior: Behavior = .apply
    var enabled = true
    var enabledKnown = true
    var enabledUnsupported = false
    var settable = true
    var selectedSettable = true
    var selectedRange: AXTextRange? = AXTextRange(location: 0, length: 0)
    var pressAdvertised = true
    var changePreimage = false
    var flipForegroundAfterFirst = false
    var flipForegroundAtRead: Int?
    var flippedForegroundPID: UInt32 = 42
    var failButtonReadback = false
    var invalidateGuardBeforeHandoff = false
    var valueAfterReads: Int?
    var unavailableValueReadNumbers: Set<Int> = []
    var unavailableAfterDispatchReads = 0
    var alwaysValueUnavailable = false
    var fieldPresent = true
    var scrollAreaPresent = false
    var verticalPosition = 0.5
    var horizontalPosition: Double?
    var beforeHandoff: (@Sendable () -> Void)?
    private var foregroundReads = 0
    private var preimageReads = 0
    private var valueReads = 0
    private var storedValue = "old"
    private var pendingValue: String?
    private var pendingReads = 0
    private var mutations = 0
    private var front: UInt32? = 100
    var value: String { get { lock.lock(); defer { lock.unlock() }; return storedValue }
        set { lock.lock(); storedValue = newValue; lock.unlock() } }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return mutations }
    func setForeground(_ pid: UInt32?) { lock.lock(); front = pid; lock.unlock() }
    func foreground() -> UInt32? {
        lock.lock(); defer { lock.unlock() }
        foregroundReads += 1
        return (flipForegroundAfterFirst && foregroundReads > 1)
            || (flipForegroundAtRead.map { foregroundReads >= $0 } ?? false) ? flippedForegroundPID : front
    }
    func application(pid: UInt32, context: OperationContext) throws -> any AXObject { try context.check(); return app }
    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren { try context.check(); return AXChildren(elements: [windowNode]) }
    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren {
        try context.check()
        if same(element, scrollArea) {
            return AXChildren(elements: horizontalPosition == nil ? [verticalBar] : [verticalBar, horizontalBar])
        }
        guard same(element, windowNode) else { return AXChildren(elements: []) }
        var children = fieldPresent ? [field, button] : [button]
        if scrollAreaPresent { children.append(scrollArea) }
        return AXChildren(elements: children)
    }
    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check()
        if same(element, verticalBar) || same(element, horizontalBar) { return scrollArea }
        return same(element, app) ? nil : same(element, windowNode) ? app : windowNode
    }
    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? { try context.check(); return windowNode }
    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32 { try context.check(); return 42 }
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool { lhs === rhs }
    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot? {
        try context.check()
        lock.lock(); defer { lock.unlock() }
        if includeValue && same(element, field) {
            valueReads += 1
            if alwaysValueUnavailable || unavailableValueReadNumbers.contains(valueReads) { throw AXReadUnavailable() }
            if mutations > 0 && unavailableAfterDispatchReads > 0 {
                unavailableAfterDispatchReads -= 1
                throw AXReadUnavailable()
            }
        }
        if includeValue && mutations == 0 {
            preimageReads += 1
            if changePreimage && preimageReads == 2 { storedValue = "different"; selectedRange = AXTextRange(location: 1, length: 0) }
            if let valueAfterReads, preimageReads >= valueAfterReads { storedValue = "ready" }
        }
        if includeValue && mutations > 0 && behavior == .readbackFailure { throw NativeFailure(.nativeFailed, "readback unavailable") }
        if mutations > 0 && failButtonReadback && same(element, button) { throw NativeFailure(.nativeFailed, "second check unavailable") }
        if includeValue, let pending = pendingValue {
            pendingReads -= 1
            if pendingReads == 0 { storedValue = pending; pendingValue = nil }
        }
        let role = (element as! ActionNode).role
        let isField = same(element, field)
        return AXNodeSnapshot(role: role, title: role == "AXWindow" ? actionTarget.title : nil,
            label: role == "AXTextField" ? "Field" : role == "AXButton" ? "Save" : nil,
            bounds: role == "AXWindow" ? actionTarget.bounds : Rect(x: 10, y: 20, width: 200, height: 30),
            enabled: enabled, enabledKnown: enabledKnown,
            value: includeValue && isField ? storedValue : nil,
            valueSettable: isField && settable,
            selectedTextSettable: isField && selectedSettable,
            selectedRange: isField ? selectedRange : nil,
            actions: role == "AXButton" && pressAdvertised ? ["AXPress"] : [], enabledUnsupported: enabledUnsupported)
    }
    func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult { try context.check(); return TargetsResult(targets: [actionTarget], truncated: false) }
    func window(_ key: TargetKey, context: OperationContext) throws -> Target { try context.check(); return actionTarget }
    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] { try context.check(); return [actionTarget] }
    private func mutate(_ expected: String?, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try context.check()
        if behavior == .refuse { throw NativeFailure(.unsupported, "setter no longer advertised") }
        if behavior == .activateBeforeDispatch { lock.lock(); front = 42; lock.unlock() }
        if invalidateGuardBeforeHandoff { value = "changed" }
        beforeHandoff?()
        try willDispatch()
        entered.signal()
        if behavior == .block { _ = release.wait(timeout: .now() + 2) }
        lock.lock()
        mutations += 1
        if let expected, behavior != .ignore {
            if behavior == .delayed { pendingValue = expected; pendingReads = 3 }
            else { storedValue = expected }
        }
        if behavior == .activate { front = 42 }
        lock.unlock()
        if behavior == .throwAfterWrite { throw NativeFailure(.nativeFailed, "setter returned an error after effect") }
    }
    func setValue(_ value: String, on object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try mutate(value, context: context, willDispatch: willDispatch)
    }
    func press(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try mutate(nil, context: context, willDispatch: willDispatch)
    }
    func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        let before = value
        let range = selectedRange.flatMap { Range(NSRange(location: $0.location, length: $0.length), in: before) }
        try mutate(range.map { before.replacingCharacters(in: $0, with: text) }, context: context, willDispatch: willDispatch)
    }
    func scrollbar(in area: any AXObject, axis: Axis, context: OperationContext) throws -> AXScrollbar? {
        try context.check()
        guard scrollAreaPresent, same(area, scrollArea) else { return nil }
        if axis == .vertical { return AXScrollbar(object: verticalBar, position: verticalPosition) }
        return horizontalPosition.map { AXScrollbar(object: horizontalBar, position: $0) }
    }
    func setScrollPosition(_ position: Double, on scrollbar: any AXObject, context: OperationContext,
                           willDispatch: @Sendable () throws -> Void) throws {
        try mutate(nil, context: context, willDispatch: willDispatch)
        if behavior == .ignore { return }
        if same(scrollbar, verticalBar) { verticalPosition = position }
        if same(scrollbar, horizontalBar) { horizontalPosition = position }
    }
}

final class BackgroundActionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cua-mutation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func entry(_ backend: ActionBackend, includeValues: Bool = false) -> RetainedObservation {
        let observation = Observation(observationId: "origin", target: actionTarget.key,
            collected: CollectionInterval(startedUnixMs: 1, finishedUnixMs: 2), windowBounds: actionTarget.bounds,
            accessibility: .complete, accessibilityCollected: CollectionInterval(startedUnixMs: 1, finishedUnixMs: 2),
            elements: [], screenshot: nil)
        let handle = SemanticObservationHandle(backend: backend, catalog: backend, application: backend.app,
            target: actionTarget, window: backend.windowNode, observationId: "origin", includeValues: includeValues,
            references: [
                "field": RetainedAXElement(object: backend.field,
                    snapshot: AXNodeSnapshot(role: backend.field.role, bounds: actionTarget.bounds)),
                "button": RetainedAXElement(object: backend.button,
                    snapshot: AXNodeSnapshot(role: "AXButton", bounds: actionTarget.bounds)),
                "scroll": RetainedAXElement(object: backend.scrollArea,
                    snapshot: AXNodeSnapshot(role: "AXScrollArea", bounds: actionTarget.bounds))
            ])
        return RetainedObservation(observation: observation, handle: handle, createdAt: DispatchTime.now().uptimeNanoseconds)
    }
    private func request(_ operation: UseUIProtocol.Operation = .setValue(SetValueOperation(elementRef: "field", value: "new")),
                         precondition: Condition? = nil, expect: Condition? = nil) -> ActRequest {
        ActRequest(grantId: "grant", observationId: "origin", target: actionTarget.key,
            steps: [ActionStep(actionId: "action", operation: operation, precondition: precondition, expect: expect)])
    }
    private func perform(_ backend: ActionBackend, _ act: ActRequest, includeValues: Bool = false, budget: UInt32 = 300,
                         progress: BackgroundActions.ProgressSink? = nil) throws -> (ActResult, ActionExecutionState) {
        let state = ActionExecutionState(act: act)
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: try directory()), foreground: backend.foreground)
        let result = engine.act(act, entry: entry(backend, includeValues: includeValues),
                                context: OperationContext(budgetMs: budget), state: state, progress: progress)
        let wireRequest = Request(version: 1, id: "request", epoch: "epoch", budgetMs: budget, body: .act(act))
        let response = Response(version: 1, id: "request", epoch: "epoch", body: .act(result))
        try Frame.response(response).validate()
        try response.validateFor(wireRequest, expectedEpoch: "epoch")
        return (result, state)
    }
    private func sequence(_ operations: [UseUIProtocol.Operation]) -> ActRequest {
        ActRequest(grantId: "grant", observationId: "origin", target: actionTarget.key,
            steps: operations.enumerated().map {
                ActionStep(actionId: "step-\($0.offset)", operation: $0.element, precondition: nil, expect: nil)
            })
    }
    func testSetValueInfersExactPostconditionAndUsesFreshWitness() throws {
        let backend = ActionBackend(); let act = request()
        let (result, state) = try perform(backend, act)
        XCTAssertEqual(backend.value, "new"); XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.steps[0].route, .axSetValue)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.steps[0].evidence[0].condition, .valueEquals(ValueCondition(elementRef: "field", value: "new")))
        XCTAssertNotEqual(result.steps[0].evidence[0].observationId, "origin")
        XCTAssertEqual(state.witnesses.count, 1)
    }
    func testSixteenStepsUseOneSequenceAndCumulativeSettledPrefixes() throws {
        let backend = ActionBackend(); let log = PrefixLog()
        let act = sequence((0..<16).map { .setValue(SetValueOperation(elementRef: "field", value: "value-\($0)")) })
        let (result, _) = try perform(backend, act, budget: 1000, progress: log.append)
        XCTAssertEqual(backend.calls, 16)
        XCTAssertEqual(backend.value, "value-15")
        XCTAssertEqual(result.steps.count, 16)
        XCTAssertEqual(result.remainingSteps, 0)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(log.prefixes.map(\.count), Array(1..<16))
        for prefix in log.prefixes { XCTAssertEqual(prefix, Array(result.steps.prefix(prefix.count))) }
    }
    func testMixedSequenceWaitIsReadOnlyAndAnExistingConditionDoesNotPress() throws {
        let backend = ActionBackend(); let log = PrefixLog()
        let act = sequence([
            .setValue(SetValueOperation(elementRef: "field", value: "new")),
            .waitFor(WaitOperation(condition: .valueEquals(ValueCondition(elementRef: "field", value: "new")))),
            .press(ElementOperation(elementRef: "button"))
        ])
        let (result, _) = try perform(backend, act, progress: log.append)
        XCTAssertEqual(backend.calls, 2)
        XCTAssertEqual(result.steps[1].delivery, .notDispatched)
        XCTAssertEqual(result.steps[1].reason, .alreadySatisfied)
        XCTAssertNil(result.steps[1].route)
        XCTAssertEqual(result.steps[2].delivery, .dispatched)
        XCTAssertEqual(result.stopReason, .completed)
    }
    func testPureWaitSequenceDistinguishesLaterConditionAndNeedsNoForeground() throws {
        let backend = ActionBackend(); backend.valueAfterReads = 2
        let act = sequence([
            .waitFor(WaitOperation(condition: .enabled(EnabledCondition(elementRef: "button", enabled: true)))),
            .waitFor(WaitOperation(condition: .valueEquals(ValueCondition(elementRef: "field", value: "ready")))),
            .waitFor(WaitOperation(condition: .elementExists(ElementCondition(selector: Selector(role: "AXButton", label: "Save", identifier: nil))))),
            .waitFor(WaitOperation(condition: .elementAbsent(ElementCondition(selector: Selector(role: "AXCheckBox", label: nil, identifier: nil)))))
        ])
        let state = ActionExecutionState(act: act)
        let engine = BackgroundActions(foreground: { nil })
        let result = engine.act(act, entry: entry(backend), context: OperationContext(budgetMs: 300), state: state)
        let req = Request(version: 1, id: "waits", epoch: "epoch", budgetMs: 300, body: .act(act))
        try Response(version: 1, id: "waits", epoch: "epoch", body: .act(result)).validateFor(req, expectedEpoch: "epoch")
        XCTAssertEqual(result.steps.map(\.reason), [.alreadySatisfied, .conditionSatisfied, .alreadySatisfied, .alreadySatisfied])
        XCTAssertTrue(result.steps.allSatisfy { $0.delivery == .notDispatched && $0.route == nil })
        XCTAssertEqual(backend.calls, 0)
    }
    func testSequenceCancellationAtPrefixBoundaryLeavesNextStepUnsent() throws {
        let backend = ActionBackend()
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                            .press(ElementOperation(elementRef: "button")),
                            .setValue(SetValueOperation(elementRef: "field", value: "last"))])
        let (result, _) = try perform(backend, act, progress: { _, context in context.cancel() })
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps.count, 2)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[1].delivery, .notDispatched)
        XCTAssertEqual(result.stopReason, .cancelled)
        XCTAssertEqual(result.remainingSteps, 1)
    }
    func testSequenceRevalidatesEachRetainedTargetAndStopsWithoutReselecting() throws {
        let backend = ActionBackend()
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                            .setValue(SetValueOperation(elementRef: "field", value: "last")),
                            .press(ElementOperation(elementRef: "button"))])
        let (result, _) = try perform(backend, act, progress: { _, _ in backend.fieldPresent = false })
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[1].delivery, .notDispatched)
        XCTAssertEqual(result.stopReason, .targetStale)
        XCTAssertEqual(result.remainingSteps, 1)
    }
    func testWaitDeadlineAfterSettledMutationNeverClaimsInputForWait() throws {
        let backend = ActionBackend(); let log = PrefixLog()
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                            .waitFor(WaitOperation(condition: .valueEquals(ValueCondition(elementRef: "field", value: "never")))),
                            .press(ElementOperation(elementRef: "button"))])
        let (result, _) = try perform(backend, act, budget: 40, progress: log.append)
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[1].delivery, .notDispatched)
        XCTAssertEqual(result.steps[1].verification, .mismatch)
        XCTAssertEqual(result.stopReason, .deadlineExceeded)
        XCTAssertEqual(result.remainingSteps, 1)
    }
    func testFailedProgressWriteStopsBeforeNextMutation() throws {
        let backend = ActionBackend()
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                            .press(ElementOperation(elementRef: "button"))])
        let (result, _) = try perform(backend, act, progress: { _, _ in throw NativeFailure(.nativeFailed, "test output failed") })
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[1].delivery, .notDispatched)
        XCTAssertEqual(result.stopReason, .failed)
    }
    func testSequenceDoesNotRefreshOriginTTLAtProgressOrDispatch() throws {
        for expireAtHandoff in [false, true] {
            let backend = ActionBackend()
            let origin = entry(backend)
            let clock = ActionClock(origin.createdAt)
            if expireAtHandoff { backend.beforeHandoff = clock.expire }
            let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                                .press(ElementOperation(elementRef: "button"))])
            let state = ActionExecutionState(act: act)
            let engine = BackgroundActions(coordinator: MutationCoordinator(directory: try directory()), now: clock.now, foreground: { 100 })
            let result = engine.act(act, entry: origin, context: OperationContext(budgetMs: 300), state: state,
                progress: { _, _ in clock.expire() })
            let req = Request(version: 1, id: "ttl", epoch: "epoch", budgetMs: 300, body: .act(act))
            try Response(version: 1, id: "ttl", epoch: "epoch", body: .act(result)).validateFor(req, expectedEpoch: "epoch")
            XCTAssertEqual(result.stopReason, .targetStale)
            XCTAssertEqual(backend.calls, expireAtHandoff ? 0 : 1)
            XCTAssertEqual(result.steps.last?.delivery, .notDispatched)
            XCTAssertEqual(result.steps.first?.delivery, expireAtHandoff ? .notDispatched : .dispatched)
        }
    }
    func testFinalForegroundFailurePreservesKnownLastEffectAndWrittenPrefix() throws {
        let backend = ActionBackend(); let log = PrefixLog()
        // Baseline + four per-step samples each: the tenth is the final request sample.
        backend.flipForegroundAtRead = 10
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                            .setValue(SetValueOperation(elementRef: "field", value: "last"))])
        let (result, _) = try perform(backend, act, progress: log.append)
        XCTAssertEqual(backend.calls, 2)
        XCTAssertEqual(result.stopReason, .failed)
        XCTAssertEqual(result.steps.map(\.delivery), [.dispatched, .dispatched])
        XCTAssertEqual(result.steps.map(\.verification), [.confirmed, .confirmed])
        XCTAssertEqual(result.steps[1].reason, .nativeFailed)
        XCTAssertEqual(result.remainingSteps, 0)
        XCTAssertEqual(log.prefixes, [[result.steps[0]]])
    }
    func testUnrelatedForegroundSwitchBeforeHandoffAllowsTargetedAXInput() throws {
        let backend = ActionBackend()
        backend.beforeHandoff = { backend.setForeground(200) }
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.stopReason, .completed)
    }
    func testInitiallyForegroundTargetDoesNotRequireExclusiveDesktopUse() throws {
        let backend = ActionBackend(); backend.setForeground(42)
        backend.beforeHandoff = { backend.setForeground(200) }
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.stopReason, .completed)
    }
    func testGenuineReadbackFailureRemainsFailedAfterUnrelatedForegroundSwitch() throws {
        let backend = ActionBackend(); backend.behavior = .readbackFailure
        backend.beforeHandoff = { backend.setForeground(200) }
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .unverified)
        XCTAssertEqual(result.steps[0].reason, .nativeFailed)
        XCTAssertEqual(result.stopReason, .failed)
    }
    func testUnrelatedFinalForegroundSwitchPreservesCompletedSequenceAndPrefix() throws {
        let backend = ActionBackend(); let log = PrefixLog()
        backend.flipForegroundAtRead = 10; backend.flippedForegroundPID = 200
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                            .setValue(SetValueOperation(elementRef: "field", value: "last"))])
        let (result, _) = try perform(backend, act, progress: log.append)
        XCTAssertEqual(backend.calls, 2)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.steps.map(\.delivery), [.dispatched, .dispatched])
        XCTAssertEqual(result.steps.map(\.verification), [.confirmed, .confirmed])
        XCTAssertEqual(log.prefixes, [[result.steps[0]]])
    }
    func testUnrelatedForegroundSwitchDoesNotReplaceMixedWaitDeadline() throws {
        let backend = ActionBackend(); let log = PrefixLog()
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                            .waitFor(WaitOperation(condition: .valueEquals(ValueCondition(elementRef: "field", value: "never")))),
                            .press(ElementOperation(elementRef: "button"))])
        let (result, _) = try perform(backend, act, budget: 40, progress: { prefix, context in
            try log.append(prefix, context: context); backend.setForeground(200)
        })
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.stopReason, .deadlineExceeded)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.steps[1].delivery, .notDispatched)
        XCTAssertEqual(result.steps[1].verification, .mismatch)
        XCTAssertEqual(result.remainingSteps, 1)
        XCTAssertEqual(log.prefixes, [[result.steps[0]]])
    }
    func testKnownInterruptionWinsOverCleanupTargetActivationWithoutChangingPrefix() throws {
        for cancelled in [false, true] {
            let backend = ActionBackend(); let log = PrefixLog(); let clock = ActionClock(0)
            let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
                                .waitFor(WaitOperation(condition: .valueEquals(ValueCondition(elementRef: "field", value: "never")))),
                                .press(ElementOperation(elementRef: "button"))])
            let state = ActionExecutionState(act: act)
            let context = OperationContext(receivedAt: 0, budgetMs: 300, now: clock.now)
            let engine = BackgroundActions(coordinator: MutationCoordinator(directory: try directory()), foreground: backend.foreground)
            let result = engine.act(act, entry: entry(backend), context: context, state: state,
                progress: { prefix, context in
                    try log.append(prefix, context: context)
                    backend.setForeground(42)
                    if cancelled { context.cancel() } else { clock.expire() }
                })
            XCTAssertEqual(result.stopReason, cancelled ? .cancelled : .deadlineExceeded)
            XCTAssertEqual(result.steps[0].delivery, .dispatched)
            XCTAssertEqual(result.steps[0].verification, .confirmed)
            XCTAssertEqual(result.steps[1].delivery, .notDispatched)
            XCTAssertEqual(result.steps[1].reason, cancelled ? .cancelled : .deadlineExceeded)
            XCTAssertEqual(result.remainingSteps, 1)
            XCTAssertEqual(backend.calls, 1)
            XCTAssertEqual(log.prefixes, [[result.steps[0]]])
        }
    }
    func testUnknownForegroundDuringHandoffRefusesInput() throws {
        let backend = ActionBackend()
        backend.beforeHandoff = { backend.setForeground(nil) }
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 0)
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertEqual(result.stopReason, .unsupported)
    }
    func testExistingExactValueIsNotNewDelivery() throws {
        let backend = ActionBackend(); backend.value = "new"
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 0)
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.steps[0].reason, .alreadySatisfied)
        XCTAssertNil(result.steps[0].route)
    }
    func testUnsupportedEnabledTextControlCanUseConfirmedWritableAttributes() throws {
        for role in ["AXTextField", "AXTextArea"] {
            for operation in [UseUIProtocol.Operation.setValue(SetValueOperation(elementRef: "field", value: "new")),
                              .typeText(TypeTextOperation(elementRef: "field", text: "X"))] {
                let backend = ActionBackend(); backend.field.role = role
                backend.enabledKnown = false; backend.enabledUnsupported = true
                let (result, _) = try perform(backend, request(operation), includeValues: true)
                XCTAssertEqual(backend.calls, 1)
                XCTAssertEqual(result.steps[0].delivery, .dispatched)
                XCTAssertEqual(result.steps[0].verification, .confirmed)
                XCTAssertEqual(result.stopReason, .completed)
            }
        }
    }
    func testUnsupportedEnabledDoesNotAuthorizePressDisabledOrNonwritableTargets() throws {
        for option in 0..<4 {
            let backend = ActionBackend(); backend.enabledUnsupported = true
            backend.enabledKnown = option == 1
            if option == 1 { backend.enabled = false }
            if option == 2 { backend.settable = false }
            if option == 3 { backend.selectedSettable = false }
            let operation: UseUIProtocol.Operation = option == 0 ? .press(ElementOperation(elementRef: "button"))
                : option == 3 ? .typeText(TypeTextOperation(elementRef: "field", text: "X"))
                : .setValue(SetValueOperation(elementRef: "field", value: "new"))
            let (result, _) = try perform(backend, request(operation))
            XCTAssertEqual(backend.calls, 0)
            XCTAssertEqual(result.steps[0].delivery, .notDispatched)
            XCTAssertEqual(result.stopReason, .unsupported)
        }
    }
    func testUnsupportedEnabledExceptionIsLimitedToExactTextRoles() throws {
        for operation in [UseUIProtocol.Operation.setValue(SetValueOperation(elementRef: "field", value: "new")),
                          .typeText(TypeTextOperation(elementRef: "field", text: "X"))] {
            let backend = ActionBackend(); backend.field.role = "AXSlider"
            backend.enabledKnown = false; backend.enabledUnsupported = true
            let (result, _) = try perform(backend, request(operation))
            XCTAssertTrue(backend.settable); XCTAssertTrue(backend.selectedSettable)
            XCTAssertEqual(backend.calls, 0)
            XCTAssertEqual(result.stopReason, .unsupported)
        }
        let enabledWidget = ActionBackend(); enabledWidget.field.role = "AXSlider"
        let (result, _) = try perform(enabledWidget, request())
        XCTAssertEqual(enabledWidget.calls, 1)
        XCTAssertEqual(result.stopReason, .completed)
    }
    func testIgnoredSetterDoesNotPassAnUnrelatedEnabledExpectation() throws {
        let backend = ActionBackend(); backend.behavior = .ignore
        let (result, _) = try perform(backend, request(expect: .enabled(EnabledCondition(elementRef: "field", enabled: true))), budget: 40)
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .mismatch)
        XCTAssertEqual(result.stopReason, .deadlineExceeded)
        XCTAssertTrue(result.steps[0].evidence.contains { !$0.matched })
    }
    func testDelayedValueReadbackUsesTheSameRetainedTarget() throws {
        let backend = ActionBackend(); backend.behavior = .delayed
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.stopReason, .completed)
    }
    func testReadbackCannotCompleteResamplesWithoutRepeatingTheWriter() throws {
        let backend = ActionBackend(); backend.unavailableAfterDispatchReads = 1
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.steps[0].evidence.count, 1)
        XCTAssertEqual(result.steps[0].evidence.first?.matched, true)
    }
    func testUnavailableReadCannotHideAnActualSetterError() throws {
        let backend = ActionBackend(); backend.behavior = .throwAfterWrite
        backend.unavailableAfterDispatchReads = 1
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.stopReason, .failed)
        XCTAssertEqual(result.steps[0].delivery, .unknown)
        XCTAssertEqual(result.steps[0].verification, .unverified)
        XCTAssertTrue(result.steps[0].evidence.isEmpty)
    }
    func testUnavailablePredispatchReadsNeverRetryOrWrite() throws {
        for read in 1...3 {
            let backend = ActionBackend(); backend.unavailableValueReadNumbers = [read]
            let guardCondition = Condition.valueEquals(ValueCondition(elementRef: "field", value: "old"))
            let (result, _) = try perform(backend, request(precondition: guardCondition))
            XCTAssertEqual(backend.calls, 0)
            XCTAssertEqual(result.stopReason, .failed)
            XCTAssertEqual(result.steps[0].delivery, .notDispatched)
            XCTAssertEqual(result.steps[0].reason, .nativeFailed)
        }
    }
    func testNativeErrorAfterAnEffectPreservesUnknownDeliveryAndConfirmedState() throws {
        let backend = ActionBackend(); backend.behavior = .throwAfterWrite
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.value, "new")
        XCTAssertEqual(result.steps[0].delivery, .unknown)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.stopReason, .failed)
    }
    func testReadbackFailureAndForegroundChangeDoNotEraseDispatch() throws {
        for behavior in [ActionBackend.Behavior.readbackFailure, .activate] {
            let backend = ActionBackend(); backend.behavior = behavior
            let (result, _) = try perform(backend, request())
            XCTAssertEqual(result.steps[0].delivery, .dispatched)
            XCTAssertEqual(result.stopReason, .failed)
            if behavior == .activate { XCTAssertEqual(result.steps[0].verification, .confirmed) }
            else { XCTAssertEqual(result.steps[0].verification, .unverified) }
        }
    }
    func testCompletedCheckSurvivesLaterReadbackFailure() throws {
        let backend = ActionBackend(); backend.failButtonReadback = true
        let expected = Condition.enabled(EnabledCondition(elementRef: "button", enabled: true))
        let (result, _) = try perform(backend, request(expect: expected))
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .unverified)
        XCTAssertEqual(result.steps[0].evidence.count, 1)
        XCTAssertEqual(result.steps[0].evidence[0].condition, .valueEquals(ValueCondition(elementRef: "field", value: "new")))
        XCTAssertTrue(result.steps[0].evidence[0].matched)
        XCTAssertEqual(result.stopReason, .failed)
    }
    func testForegroundChangeDuringFinalNativePreflightPreventsHandoff() throws {
        let backend = ActionBackend(); backend.behavior = .activateBeforeDispatch
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(backend.calls, 0)
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertNil(result.steps[0].route)
        XCTAssertEqual(result.stopReason, .failed)
    }
    func testPreconditionChangedDuringNativePreflightPreventsHandoff() throws {
        let backend = ActionBackend(); backend.invalidateGuardBeforeHandoff = true
        let guardCondition = Condition.valueEquals(ValueCondition(elementRef: "field", value: "old"))
        let (result, _) = try perform(backend, request(precondition: guardCondition))
        XCTAssertEqual(backend.calls, 0)
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertEqual(result.steps[0].verification, .unverified)
        XCTAssertNil(result.steps[0].route)
        XCTAssertEqual(result.stopReason, .preconditionFailed)
        XCTAssertEqual(result.steps[0].evidence.count, 1)
        XCTAssertEqual(result.steps[0].evidence[0].condition, guardCondition)
        XCTAssertFalse(result.steps[0].evidence[0].matched)
    }
    func testPressUsesOnlyAdvertisedAXPressAndChecksForeground() throws {
        let backend = ActionBackend()
        let (result, _) = try perform(backend, request(.press(ElementOperation(elementRef: "button"))))
        XCTAssertEqual(result.steps[0].route, .axPress)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .unverified)
        backend.pressAdvertised = false
        let (unsupported, _) = try perform(backend, request(.press(ElementOperation(elementRef: "button"))))
        XCTAssertEqual(unsupported.steps[0].delivery, .notDispatched)
        XCTAssertEqual(unsupported.steps[0].reason, .unsupported)
        XCTAssertNil(unsupported.steps[0].route)
        XCTAssertEqual(backend.calls, 1)

        backend.pressAdvertised = true
        backend.behavior = .refuse
        let (withdrawn, _) = try perform(backend, request(.press(ElementOperation(elementRef: "button"))))
        XCTAssertEqual(withdrawn.steps[0].delivery, .notDispatched)
        XCTAssertEqual(withdrawn.steps[0].reason, .unsupported)
        XCTAssertEqual(backend.calls, 1)
    }
    func testScrollDispatchesOnceOnRequestedAxisAndConfirmsDirectionalMovement() throws {
        let backend = ActionBackend(); backend.scrollAreaPresent = true; backend.horizontalPosition = 0.5
        let act = request(.scroll(ScrollOperation(elementRef: "scroll", axis: .horizontal, amount: -250)))
        let (result, _) = try perform(backend, act)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].route, .axScroll)
        XCTAssertEqual(backend.horizontalPosition, 0.25)
        XCTAssertEqual(backend.verticalPosition, 0.5)
        XCTAssertEqual(backend.calls, 1)
    }
    func testIgnoredScrollWriteDoesNotCompleteOrRedispatch() throws {
        let backend = ActionBackend(); backend.scrollAreaPresent = true; backend.behavior = .ignore
        let act = request(.scroll(ScrollOperation(elementRef: "scroll", axis: .vertical, amount: 250)))
        let (result, _) = try perform(backend, act, budget: 80)
        XCTAssertEqual(result.stopReason, .deadlineExceeded)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(backend.verticalPosition, 0.5)
        XCTAssertEqual(backend.calls, 1)
    }
    func testScrollRefusesStaleAreaUnsupportedAxisAndBoundaryBeforeDispatch() throws {
        let backend = ActionBackend()
        let vertical = request(.scroll(ScrollOperation(elementRef: "scroll", axis: .vertical, amount: 250)))
        let horizontal = request(.scroll(ScrollOperation(elementRef: "scroll", axis: .horizontal, amount: 250)))
        let (stale, _) = try perform(backend, vertical)
        XCTAssertEqual(stale.stopReason, .targetStale)
        backend.scrollAreaPresent = true
        let (unsupported, _) = try perform(backend, horizontal)
        XCTAssertEqual(unsupported.stopReason, .unsupported)
        backend.verticalPosition = 1
        let (atEdge, _) = try perform(backend, vertical)
        XCTAssertEqual(atEdge.stopReason, .verificationFailed)
        for result in [stale, unsupported, atEdge] {
            XCTAssertEqual(result.steps[0].delivery, .notDispatched)
            XCTAssertNil(result.steps[0].route)
        }
        XCTAssertEqual(backend.calls, 0)
    }
    func testCapabilityEnabledGuardAndMultistepRefuseBeforeDispatch() throws {
        for option in 0..<4 {
            let backend = ActionBackend()
            if option == 0 { backend.enabled = false }
            if option == 1 { backend.enabledKnown = false }
            if option == 2 { backend.settable = false }
            if option == 3 { backend.behavior = .refuse }
            let (result, _) = try perform(backend, request())
            XCTAssertEqual(result.steps[0].delivery, .notDispatched)
            XCTAssertEqual(result.stopReason, .unsupported)
            XCTAssertEqual(backend.calls, 0)
        }
        let backend = ActionBackend()
        let (guarded, _) = try perform(backend, request(precondition: .enabled(EnabledCondition(elementRef: "field", enabled: false))))
        XCTAssertEqual(guarded.stopReason, .preconditionFailed)
        XCTAssertEqual(guarded.steps[0].verification, .unverified)
        let one = request(); let two = ActRequest(grantId: one.grantId, observationId: one.observationId, target: one.target,
            steps: one.steps + [ActionStep(actionId: "second", operation: one.steps[0].operation, precondition: nil, expect: nil)])
        let (result, _) = try perform(backend, two)
        XCTAssertEqual(result.remainingSteps, 1)
        XCTAssertEqual(result.stopReason, .unsupported)
        XCTAssertEqual(backend.calls, 0)
    }
    func testSelectedTextReplacementUsesUTF16RangeAndNeverContainsMatching() throws {
        let backend = ActionBackend(); backend.value = "A😀B"; backend.selectedRange = AXTextRange(location: 1, length: 2)
        let act = request(.typeText(TypeTextOperation(elementRef: "field", text: "🧑🏾‍💻")))
        let (result, _) = try perform(backend, act, includeValues: true)
        XCTAssertEqual(backend.value, "A🧑🏾‍💻B")
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.steps[0].route, .axSelectedText)
        backend.value = "hello there"; backend.selectedRange = AXTextRange(location: 11, length: 0); backend.behavior = .ignore
        let (ignored, _) = try perform(backend, request(.typeText(TypeTextOperation(elementRef: "field", text: "hello"))), includeValues: true, budget: 40)
        XCTAssertEqual(ignored.steps[0].verification, .mismatch)
        XCTAssertEqual(ignored.stopReason, .deadlineExceeded)
    }
    func testPrivateTextEditDoesNotLeakPreexistingValueIntoEvidence() throws {
        let backend = ActionBackend(); backend.value = "private-prefix:"; backend.selectedRange = AXTextRange(location: 15, length: 0)
        let (result, _) = try perform(backend, request(.typeText(TypeTextOperation(elementRef: "field", text: "hello"))))
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertEqual(result.steps[0].verification, .unverified)
        let encoded = try JSONEncoder().encode(result)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-prefix"))
    }
    func testTextNoopStillDispatchesAndChangedPreimageRefusesInput() throws {
        let backend = ActionBackend(); backend.value = "same"; backend.selectedRange = AXTextRange(location: 0, length: 4)
        let operation = UseUIProtocol.Operation.typeText(TypeTextOperation(elementRef: "field", text: "same"))
        let (result, _) = try perform(backend, request(operation), includeValues: true)
        XCTAssertEqual(result.steps[0].delivery, .dispatched)
        XCTAssertNil(result.steps[0].reason)
        let changed = ActionBackend(); changed.changePreimage = true
        let (refused, _) = try perform(changed, request(.typeText(TypeTextOperation(elementRef: "field", text: "X"))), includeValues: true)
        XCTAssertEqual(refused.steps[0].delivery, .notDispatched)
        XCTAssertEqual(refused.stopReason, .targetStale)
        XCTAssertEqual(changed.calls, 0)
    }
    func testUnknownForegroundBaselineDoesNotAuthorizeBackgroundInput() throws {
        let backend = ActionBackend(); let act = request(); let state = ActionExecutionState(act: act)
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: try directory()), foreground: { nil })
        let result = engine.act(act, entry: entry(backend), context: OperationContext(budgetMs: 100), state: state)
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertEqual(result.stopReason, .unsupported)
        XCTAssertEqual(backend.calls, 0)
    }
    func testAlreadyObservedValueEvidenceSurvivesForegroundChangeAndInterruption() throws {
        let backend = ActionBackend(); backend.value = "new"; backend.flipForegroundAfterFirst = true
        let (result, _) = try perform(backend, request())
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.stopReason, .failed)
        XCTAssertEqual(backend.calls, 0)
        let act = request(); let state = ActionExecutionState(act: act)
        state.checked([ActionWitness(observationId: "check-before", collected: CollectionInterval(startedUnixMs: 1, finishedUnixMs: 2),
            target: actionTarget.key, elementRef: "field", condition: .valueEquals(ValueCondition(elementRef: "field", value: "new")), matched: true)], verification: .confirmed)
        let interrupted = state.interrupt(.deadlineExceeded)
        XCTAssertEqual(interrupted.steps[0].delivery, .notDispatched)
        XCTAssertEqual(interrupted.steps[0].verification, .confirmed)
        let wire = Request(version: 1, id: "r", epoch: "e", budgetMs: 100, body: .act(act))
        let response = Response(version: 1, id: "r", epoch: "e", body: .act(interrupted))
        try Frame.response(response).validate()
        try response.validateFor(wire, expectedEpoch: "e")
    }
    func testSealedCancellationPreventsNewDispatchAndRetainsPhysicalOwnership() throws {
        let backend = ActionBackend(); let act = request(); let state = ActionExecutionState(act: act)
        _ = state.interrupt(.cancelled)
        let directory = try directory()
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: directory), foreground: backend.foreground)
        let result = engine.act(act, entry: entry(backend), context: OperationContext(budgetMs: 200), state: state)
        XCTAssertEqual(result.steps[0].delivery, .notDispatched)
        XCTAssertEqual(backend.calls, 0)
        backend.behavior = .block
        let activeState = ActionExecutionState(act: act); let context = OperationContext(budgetMs: 1000)
        let retained = entry(backend); let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { _ = engine.act(act, entry: retained, context: context, state: activeState); done.leave() }
        XCTAssertEqual(backend.entered.wait(timeout: .now() + 1), .success)
        let interrupted = activeState.interrupt(.cancelled); context.cancel()
        XCTAssertEqual(interrupted.steps[0].delivery, .unknown)
        XCTAssertThrowsError(try MutationCoordinator(directory: directory).withOwnership(context: OperationContext(budgetMs: 20)) { XCTFail("physical lock released early") })
        backend.release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(activeState.snapshot().steps[0].delivery, .unknown)
    }
    func testExactValueWaitDistinguishesExistingStateAndTimesOut() throws {
        let backend = ActionBackend(); let retained = entry(backend)
        let engine = BackgroundActions(coordinator: MutationCoordinator(directory: try directory()), foreground: backend.foreground)
        let wait = WaitRequest(observationId: "origin", target: actionTarget.key, condition: .valueEquals(ValueCondition(elementRef: "field", value: "old")))
        let existing = try engine.wait(wait, entry: retained, context: OperationContext(budgetMs: 100))
        XCTAssertEqual(existing.outcome, .satisfied); XCTAssertTrue(existing.alreadySatisfied)
        let missing = WaitRequest(observationId: "origin", target: actionTarget.key, condition: .valueEquals(ValueCondition(elementRef: "field", value: "missing")))
        XCTAssertThrowsError(try engine.wait(missing, entry: retained, context: OperationContext(budgetMs: 20))) { error in
            XCTAssertEqual((error as? NativeFailure)?.code, .deadlineExceeded)
        }
    }
    func testPureWaitCannotCompleteThenPositiveIsLaterSatisfactionWithoutFalseEvidence() throws {
        let backend = ActionBackend(); backend.value = "ready"; backend.unavailableValueReadNumbers = [1]
        let wait = WaitOperation(condition: .valueEquals(ValueCondition(elementRef: "field", value: "ready")))
        let (result, state) = try perform(backend, request(.waitFor(wait)))
        XCTAssertEqual(backend.calls, 0)
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.steps[0].reason, .conditionSatisfied)
        XCTAssertEqual(result.steps[0].verification, .confirmed)
        XCTAssertEqual(result.steps[0].evidence.count, 1)
        XCTAssertTrue(state.witnesses.allSatisfy(\.matched))
    }
    func testAllUnavailableWaitKeepsSettledPrefixAndNoInventedWitness() throws {
        let backend = ActionBackend(); let log = PrefixLog()
        let act = sequence([.setValue(SetValueOperation(elementRef: "field", value: "new")),
            .waitFor(WaitOperation(condition: .valueEquals(ValueCondition(elementRef: "field", value: "never")))),
            .press(ElementOperation(elementRef: "button"))])
        let (result, _) = try perform(backend, act, budget: 40, progress: { prefix, context in
            try log.append(prefix, context: context)
            backend.alwaysValueUnavailable = true
        })
        XCTAssertEqual(backend.calls, 1)
        XCTAssertEqual(result.stopReason, .deadlineExceeded)
        XCTAssertEqual(result.remainingSteps, 1)
        XCTAssertEqual(log.prefixes, [Array(result.steps.prefix(1))])
        XCTAssertEqual(result.steps[1].delivery, .notDispatched)
        XCTAssertEqual(result.steps[1].verification, .unverified)
        XCTAssertTrue(result.steps[1].evidence.isEmpty)
    }
    func testStandaloneWaitResamplesCannotCompleteAndNeverCallsItAlreadySatisfied() throws {
        let backend = ActionBackend(); backend.unavailableValueReadNumbers = [1]
        let wait = WaitRequest(observationId: "origin", target: actionTarget.key,
            condition: .valueEquals(ValueCondition(elementRef: "field", value: "old")))
        let result = try BackgroundActions().wait(wait, entry: entry(backend), context: OperationContext(budgetMs: 100))
        XCTAssertEqual(result.outcome, .satisfied)
        XCTAssertFalse(result.alreadySatisfied)
        XCTAssertEqual(result.evidence?.matched, true)
        XCTAssertEqual(backend.calls, 0)
    }
    func testStandaloneWaitAllUnavailableExhaustsOriginalBudget() {
        let backend = ActionBackend(); backend.alwaysValueUnavailable = true
        let wait = WaitRequest(observationId: "origin", target: actionTarget.key,
            condition: .valueEquals(ValueCondition(elementRef: "field", value: "old")))
        XCTAssertThrowsError(try BackgroundActions().wait(wait, entry: entry(backend), context: OperationContext(budgetMs: 20))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .deadlineExceeded)
        }
        XCTAssertEqual(backend.calls, 0)
    }
    func testIndependentProcessLockExclusionAndCrashRelease() throws {
        let directory = try directory(); let lockPath = directory.appendingPathComponent("mutation.lock").path
        let child = Process(); let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", "-u", "-c", "import os,fcntl,sys,time\nf=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600)\nfcntl.flock(f,fcntl.LOCK_EX)\nprint('locked',flush=True)\ntime.sleep(5)", lockPath]
        child.standardOutput = pipe
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        XCTAssertEqual(String(data: try XCTUnwrap(pipe.fileHandleForReading.read(upToCount: 7)), encoding: .utf8), "locked\n")
        XCTAssertThrowsError(try MutationCoordinator(directory: directory).withOwnership(context: OperationContext(budgetMs: 20)) { XCTFail("cross-process exclusion failed") })
        kill(child.processIdentifier, SIGKILL); child.waitUntilExit()
        XCTAssertNoThrow(try MutationCoordinator(directory: directory).withOwnership(context: OperationContext(budgetMs: 100)) {})
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))
    }
}
