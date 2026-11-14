import CUAProtocol
@testable import CUARuntime
import Foundation
import XCTest

private final class SemanticNode: AXObject, @unchecked Sendable {
    let identity: String
    var pid: UInt32 = 42
    var role: String
    var title: String?
    var identifier: String?
    var bounds: Rect
    var children: [SemanticNode] = []
    weak var parent: SemanticNode?
    weak var owner: SemanticNode?
    var value: String? = "private value"
    var enabled = true
    var enabledKnown = true
    var readable = true
    var complete = true
    var childrenComplete = true
    var valueSettable = false
    var selectedTextSettable = false
    var actions: [String] = []
    init(_ identity: String, role: String, title: String?, bounds: Rect) {
        self.identity = identity; self.role = role; self.title = title; self.bounds = bounds
    }
}

private final class SemanticBackend: AXReading, @unchecked Sendable {
    let app = SemanticNode("app", role: "AXApplication", title: nil, bounds: Rect(x: 0, y: 0, width: 1, height: 1))
    var appWindows: [SemanticNode] = []
    var windowsComplete = true
    var valueReads: [String] = []
    var applicationCalls = 0
    func application(pid: UInt32, context: OperationContext) throws -> any AXObject {
        try context.check(); applicationCalls += 1; return app
    }
    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren {
        try context.check(); return AXChildren(elements: appWindows, complete: windowsComplete)
    }
    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren {
        try context.check(); let node = element as! SemanticNode
        return AXChildren(elements: Array(node.children.prefix(limit)), complete: node.childrenComplete && node.children.count <= limit)
    }
    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check(); return (element as! SemanticNode).parent
    }
    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check(); return (element as! SemanticNode).owner
    }
    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32 {
        try context.check(); return (element as! SemanticNode).pid
    }
    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot? {
        try context.check(); let node = element as! SemanticNode
        guard node.readable else { throw NativeFailure(.nativeFailed, "injected unreadable node") }
        if includeValue { valueReads.append(node.identity) }
        return AXNodeSnapshot(role: node.role, title: node.title, label: node.title, identifier: node.identifier,
            bounds: node.bounds, enabled: node.enabled, enabledKnown: node.enabledKnown,
            value: includeValue ? node.value : nil, valueSettable: node.valueSettable,
            selectedTextSettable: node.selectedTextSettable, actions: node.actions, complete: node.complete)
    }
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool {
        (lhs as! SemanticNode).identity == (rhs as! SemanticNode).identity
    }
}

private final class SemanticCatalog: WindowCatalog, @unchecked Sendable {
    var records: [Target]
    init(_ records: [Target]) { self.records = records }
    func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult {
        try context.check(); return TargetsResult(targets: records, truncated: false)
    }
    func window(_ key: TargetKey, context: OperationContext) throws -> Target {
        try context.check()
        guard let target = records.first(where: { $0.key == key }) else { throw NativeFailure(.targetNotFound, "missing target") }
        return target
    }
    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] {
        try context.check(); return records.filter { $0.key.pid == pid }
    }
}

private struct SemanticFixture {
    let backend = SemanticBackend()
    let target = Target(key: TargetKey(pid: 42, windowId: 7), bundleId: "test.fixture", title: "Primary",
                        bounds: Rect(x: -10, y: 20, width: 440, height: 230))
    let catalog: SemanticCatalog
    let window: SemanticNode
    let first: SemanticNode
    let second: SemanticNode
    init() {
        catalog = SemanticCatalog([target])
        window = SemanticNode("window", role: "AXWindow", title: target.title, bounds: target.bounds)
        first = SemanticNode("first", role: "AXTextField", title: "Value", bounds: Rect(x: 30, y: 50, width: 200, height: 25))
        second = SemanticNode("second", role: "AXTextField", title: "Value", bounds: Rect(x: 30, y: 90, width: 200, height: 25))
        first.identifier = "first"; second.identifier = "second"
        first.valueSettable = true; second.valueSettable = true
        first.owner = window; second.owner = window; first.parent = window; second.parent = window
        window.children = [first, second]
        backend.appWindows = [window]
    }
    func observe(values: Bool = false, id: String = "obs-epoch-1") throws -> NativeObservation {
        try SemanticAXObserver(backend: backend, catalog: catalog).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: values), observationId: id,
            context: OperationContext(budgetMs: 5000))
    }
}

final class SemanticObservationTests: XCTestCase {
    func testPrivateValuesAreNeverRequestedAndRepeatedLabelsHaveDistinctOpaqueReferences() throws {
        let fixture = SemanticFixture()
        let result = try fixture.observe()
        XCTAssertEqual(result.observation.accessibility, .complete)
        XCTAssertEqual(result.observation.elements.count, 2)
        XCTAssertEqual(Set(result.observation.elements.compactMap(\.label)), ["Value"])
        XCTAssertEqual(Set(result.observation.elements.map(\.reference)).count, 2)
        XCTAssertTrue(result.observation.elements.allSatisfy { $0.value == nil })
        XCTAssertEqual(result.observation.elements.compactMap(\.identifier), ["first", "second"])
        XCTAssertTrue(fixture.backend.valueReads.isEmpty)
        let other = try fixture.observe(id: "obs-epoch-2")
        XCTAssertTrue(Set(result.observation.elements.map(\.reference)).isDisjoint(with: other.observation.elements.map(\.reference)))
        XCTAssertNotNil(result.observation.accessibilityCollected)
        try Frame.response(Response(version: 1, id: "r", epoch: "epoch", body: .observe(result.observation))).validate()
    }
    func testRequestedEmptyValueDiffersFromUnavailableValue() throws {
        let fixture = SemanticFixture()
        fixture.first.value = ""; fixture.second.value = nil
        let result = try fixture.observe(values: true)
        XCTAssertEqual(result.observation.elements[0].value, "")
        XCTAssertNil(result.observation.elements[1].value)
        XCTAssertFalse(fixture.backend.valueReads.isEmpty)
    }
    func testReorderRetainsSameObjectButRecreateWithSameIdentifierIsStale() throws {
        let fixture = SemanticFixture()
        let result = try fixture.observe()
        let handle = result.handle as! SemanticObservationHandle
        let reference = result.observation.elements[0].reference
        fixture.window.children.reverse()
        XCTAssertTrue(fixture.backend.same(try handle.resolve(reference, context: OperationContext(budgetMs: 5000)).object, fixture.first))
        let replacement = SemanticNode("new-first", role: "AXTextField", title: "Value", bounds: fixture.first.bounds)
        replacement.identifier = fixture.first.identifier; replacement.owner = fixture.window; replacement.parent = fixture.window
        fixture.window.children = [replacement, fixture.second]
        XCTAssertThrowsError(try handle.resolve(reference, context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleElement)
        }
    }
    func testRetainedObjectWithChangedIdentifierOrRoleIsStaleBeforePrivateValueRead() throws {
        let fixture = SemanticFixture()
        let result = try fixture.observe()
        let handle = result.handle as! SemanticObservationHandle
        let reference = result.observation.elements[0].reference
        fixture.first.identifier = "reused-control"
        XCTAssertThrowsError(try handle.resolve(reference, includeValue: true, context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleElement)
        }
        fixture.first.identifier = "first"; fixture.first.role = "AXButton"
        XCTAssertThrowsError(try handle.resolve(reference, includeValue: true, context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleElement)
        }
        XCTAssertTrue(fixture.backend.valueReads.isEmpty)
    }
    func testLegitimateValueLabelAndControlPositionChangesKeepRetainedReferenceValid() throws {
        let fixture = SemanticFixture()
        let result = try fixture.observe()
        let handle = result.handle as! SemanticObservationHandle
        fixture.first.value = "new value"
        fixture.first.title = "Description updated by editing"
        fixture.first.bounds = Rect(x: 30, y: 120, width: 210, height: 25)
        let resolved = try handle.resolve(result.observation.elements[0].reference, includeValue: true,
                                          context: OperationContext(budgetMs: 5000))
        XCTAssertTrue(fixture.backend.same(resolved.object, fixture.first))
        XCTAssertEqual(resolved.snapshot.value, "new value")
        XCTAssertEqual(resolved.snapshot.bounds, fixture.first.bounds)
        XCTAssertEqual(resolved.snapshot.identifier, "first")
    }
    func testOversizeIdentifierOmittedFromExportStillParticipatesInRetainedIdentity() throws {
        let fixture = SemanticFixture()
        fixture.first.identifier = String(repeating: "i", count: 1025)
        let result = try fixture.observe()
        let handle = result.handle as! SemanticObservationHandle
        XCTAssertNil(result.observation.elements[0].identifier)
        XCTAssertNoThrow(try handle.resolve(result.observation.elements[0].reference, context: OperationContext(budgetMs: 5000)))
        fixture.first.identifier = String(repeating: "j", count: 1025)
        XCTAssertThrowsError(try handle.resolve(result.observation.elements[0].reference, context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleElement)
        }
    }
    func testWrongWindowLinkRefusesBeforeReadingPrivateValue() throws {
        let fixture = SemanticFixture()
        let result = try fixture.observe()
        let handle = result.handle as! SemanticObservationHandle
        let other = SemanticNode("other-window", role: "AXWindow", title: "Other", bounds: fixture.target.bounds)
        fixture.first.owner = other
        XCTAssertThrowsError(try handle.resolve(result.observation.elements[0].reference, includeValue: true,
                                               context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleElement)
        }
        XCTAssertTrue(fixture.backend.valueReads.isEmpty)
    }
    func testParentChainCanEstablishOwningWindowWithoutAXWindowAttribute() throws {
        let fixture = SemanticFixture()
        fixture.first.owner = nil
        let result = try fixture.observe()
        let handle = result.handle as! SemanticObservationHandle
        XCTAssertNoThrow(try handle.resolve(result.observation.elements[0].reference, context: OperationContext(budgetMs: 5000)))
    }
    func testEquivalentCGSiblingsAreRejectedEvenWhenAXOnlyExposesOne() throws {
        let fixture = SemanticFixture()
        fixture.catalog.records.append(Target(key: TargetKey(pid: 42, windowId: 8), bundleId: "test.fixture",
            title: fixture.target.title, bounds: fixture.target.bounds))
        XCTAssertThrowsError(try fixture.observe()) { XCTAssertEqual(($0 as? NativeFailure)?.code, .ambiguousTarget) }
    }
    func testMissingAXTitleCannotDisambiguateEqualBoundsCGSiblingsWithDifferentTitles() throws {
        let fixture = SemanticFixture()
        fixture.catalog.records.append(Target(key: TargetKey(pid: 42, windowId: 8), bundleId: "test.fixture",
            title: "Secondary", bounds: fixture.target.bounds))
        XCTAssertNoThrow(try fixture.observe())
        fixture.window.title = nil
        XCTAssertThrowsError(try fixture.observe()) { XCTAssertEqual(($0 as? NativeFailure)?.code, .ambiguousTarget) }
    }
    func testAXWindowTieAndNearGeometryAreNeverResolvedByScoring() throws {
        let fixture = SemanticFixture()
        fixture.backend.appWindows.append(SemanticNode("tied-window", role: "AXWindow", title: fixture.target.title, bounds: fixture.target.bounds))
        XCTAssertThrowsError(try fixture.observe()) { XCTAssertEqual(($0 as? NativeFailure)?.code, .ambiguousTarget) }
        fixture.backend.appWindows.removeLast()
        fixture.window.bounds = Rect(x: fixture.target.bounds.x + 1, y: 20, width: 440, height: 230)
        XCTAssertThrowsError(try fixture.observe()) { XCTAssertEqual(($0 as? NativeFailure)?.code, .targetNotFound) }
    }
    func testWindowRecreationAndGeometryChangesInvalidateRetainedHandle() throws {
        let fixture = SemanticFixture()
        let result = try fixture.observe()
        let handle = result.handle as! SemanticObservationHandle
        fixture.backend.appWindows = [SemanticNode("replacement", role: "AXWindow", title: fixture.target.title, bounds: fixture.target.bounds)]
        XCTAssertThrowsError(try handle.resolve(result.observation.elements[0].reference, context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleElement)
        }
        fixture.backend.appWindows = [fixture.window]
        fixture.catalog.records = [Target(key: fixture.target.key, bundleId: "test.fixture", title: fixture.target.title,
            bounds: Rect(x: -11, y: 20, width: 440, height: 230))]
        XCTAssertThrowsError(try handle.resolve(result.observation.elements[0].reference, context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleObservation)
        }
    }
    func testCrossObservationReferencesAreNotReconstructed() throws {
        let fixture = SemanticFixture()
        let first = try fixture.observe()
        let second = try fixture.observe(id: "other-observation")
        let handle = second.handle as! SemanticObservationHandle
        XCTAssertThrowsError(try handle.resolve(first.observation.elements[0].reference, context: OperationContext(budgetMs: 5000))) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, .staleElement)
        }
        let registry = ObservationRegistry(epoch: "epoch")
        try registry.insert(first.observation, handle: first.handle)
        XCTAssertThrowsError(try registry.lookup(first.observation.observationId, epoch: "old-epoch", target: fixture.target.key))
    }
    func testReturnedControlsAndTreeTraversalAreBoundedWithPartialCoverage() throws {
        let fixture = SemanticFixture()
        fixture.window.children = (0..<1100).map { index in
            let node = SemanticNode("field-\(index)", role: "AXTextField", title: "Value", bounds: fixture.first.bounds)
            node.owner = fixture.window; node.parent = fixture.window; return node
        }
        let result = try fixture.observe()
        XCTAssertEqual(result.observation.elements.count, 256)
        XCTAssertEqual(result.observation.accessibility, .partial)
        XCTAssertLessThanOrEqual(try (result.handle as! SemanticObservationHandle).scan(context: OperationContext(budgetMs: 5000)).nodes.count, 1024)
    }
    func testUnreadableSubtreeIsPartialAndMissingEnabledIsNotReportedAsDisabledFact() throws {
        let fixture = SemanticFixture()
        fixture.second.readable = false
        let partial = try fixture.observe()
        XCTAssertEqual(partial.observation.accessibility, .partial)
        XCTAssertEqual(partial.observation.elements.count, 1)
        fixture.second.readable = true; fixture.second.enabledKnown = false
        let unknown = try fixture.observe()
        XCTAssertEqual(unknown.observation.accessibility, .partial)
        XCTAssertEqual(unknown.observation.elements.count, 1)
    }
    func testCancellationAndUnsupportedScreenshotsDoNotStartAXCollection() throws {
        let fixture = SemanticFixture()
        let context = OperationContext(budgetMs: 5000); context.cancel()
        XCTAssertThrowsError(try SemanticAXObserver(backend: fixture.backend, catalog: fixture.catalog).observe(
            params: ObserveRequest(target: fixture.target.key, includeScreenshot: false, includeValues: false), observationId: "o", context: context))
        XCTAssertEqual(fixture.backend.applicationCalls, 0)
        XCTAssertThrowsError(try SemanticAXObserver(backend: fixture.backend, catalog: fixture.catalog).observe(
            params: ObserveRequest(target: fixture.target.key, includeScreenshot: true, includeValues: false), observationId: "o", context: OperationContext(budgetMs: 5000)))
        XCTAssertEqual(fixture.backend.applicationCalls, 0)
    }
    func testOversizeValuesAndLabelsAreOmittedRatherThanTruncatedOrMadeEmpty() throws {
        let fixture = SemanticFixture()
        fixture.first.value = String(repeating: "a", count: 65_537)
        fixture.first.title = String(repeating: "l", count: 1025)
        fixture.first.identifier = String(repeating: "i", count: 1025)
        let result = try fixture.observe(values: true)
        XCTAssertEqual(result.observation.accessibility, .partial)
        XCTAssertNil(result.observation.elements[0].value)
        XCTAssertNil(result.observation.elements[0].label)
        XCTAssertNil(result.observation.elements[0].identifier)
    }
    func testAggregateEncodedPayloadIsBoundedEvenWithEscapedControlCharacters() throws {
        let fixture = SemanticFixture()
        fixture.window.children = (0..<256).map { index in
            let node = SemanticNode("value-\(index)", role: "AXTextField", title: "Value", bounds: fixture.first.bounds)
            node.value = String(repeating: "\u{0000}", count: 65_536)
            node.owner = fixture.window; node.parent = fixture.window; return node
        }
        let result = try fixture.observe(values: true)
        XCTAssertEqual(result.observation.accessibility, .partial)
        XCTAssertLessThan(result.observation.elements.count, 256)
        XCTAssertLessThan(try Frame.response(Response(version: 1, id: "r", epoch: "epoch", body: .observe(result.observation))).encodeLine().count,
                          3 * 1024 * 1024)
    }
}
