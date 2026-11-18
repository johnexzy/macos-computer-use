import ApplicationServices
import CUAProtocol
import CoreGraphics
@testable import CUARuntime
import Foundation
import XCTest

private final class SemanticNode: AXObject, @unchecked Sendable {
    let identity: String
    var pid: UInt32 = 42
    var role: String
    var title: String?
    var identifier: String?
    var subrole: String?
    var bounds: Rect
    var children: [SemanticNode] = []
    weak var parent: SemanticNode?
    weak var owner: SemanticNode?
    var value: String? = "private value"
    var enabled = true
    var enabledKnown = true
    var readable = true
    var readUnavailable = false
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
        if node.readUnavailable { throw AXReadUnavailable() }
        guard node.readable else { throw NativeFailure(.nativeFailed, "injected unreadable node") }
        if includeValue { valueReads.append(node.identity) }
        return AXNodeSnapshot(role: node.role, title: node.title, label: node.title, identifier: node.identifier,
            bounds: node.bounds, enabled: node.enabled, enabledKnown: node.enabledKnown,
            value: includeValue ? node.value : nil, valueSettable: node.valueSettable,
            selectedTextSettable: node.selectedTextSettable, actions: node.actions, complete: node.complete,
            subrole: node.subrole)
    }
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool {
        (lhs as! SemanticNode).identity == (rhs as! SemanticNode).identity
    }
}

private final class SemanticCatalog: WindowCatalog, @unchecked Sendable {
    var records: [Target]
    var didReadWindow: (() -> Void)?
    init(_ records: [Target]) { self.records = records }
    func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult {
        try context.check(); return TargetsResult(targets: records, truncated: false)
    }
    func window(_ key: TargetKey, context: OperationContext) throws -> Target {
        try context.check()
        guard let target = records.first(where: { $0.key == key }) else { throw NativeFailure(.targetNotFound, "missing target") }
        didReadWindow?()
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

private struct TestVisualCapture: VisualCapturing {
    let run: @Sendable (Target, Rect?, Int, OperationContext) throws -> CapturedVisual

    func capture(target: Target, crop: Rect?, maxDimension: Int, context: OperationContext) throws -> CapturedVisual {
        try run(target, crop, maxDimension, context)
    }
}

private func blankFrame(_ target: Target) throws -> CapturedVisual {
    let width: UInt32 = 160, height: UInt32 = 80
    let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    let image = try XCTUnwrap(bitmap.makeImage())
    let bounds = target.bounds
    let domain = Rect(x: 0, y: 0, width: Double(width), height: Double(height))
    let screen = ImageTransform(scaleX: bounds.width / Double(width), scaleY: bounds.height / Double(height),
        offsetX: bounds.x, offsetY: bounds.y, validImageBounds: domain, coverage: .complete)
    let window = ImageTransform(scaleX: screen.scaleX, scaleY: screen.scaleY,
        offsetX: 0, offsetY: 0, validImageBounds: domain, coverage: .complete)
    let now = UInt64(Date().timeIntervalSince1970 * 1000)
    let frame = VisualFrame(widthPx: width, heightPx: height, captureWindowBounds: bounds,
        captureScreenBounds: bounds, imageToScreen: screen, imageToWindow: window)
    return CapturedVisual(image: image, frame: frame, collected: CollectionInterval(startedUnixMs: now, finishedUnixMs: now))
}

final class SemanticObservationTests: XCTestCase {
    func testUnrequestedVisualChannelDoesNotEnterCaptureBackend() throws {
        let fixture = SemanticFixture()
        let capture = TestVisualCapture { _, _, _, _ in
            XCTFail("AX-only observation entered visual capture")
            throw NativeFailure(.nativeFailed, "unexpected visual capture")
        }
        let system = MacOSSystem(backend: fixture.backend, catalog: fixture.catalog, visual: capture, isAXTrusted: { true })
        let result = try system.observe(params: ObserveRequest(target: fixture.target.key, includeScreenshot: false, includeValues: false),
            observationId: "ax-only", context: OperationContext(budgetMs: 5000))
        XCTAssertEqual(result.observation.accessibility, .complete)
        XCTAssertNil(result.observation.visual)
    }

    func testVisualReceiptKeepsUnavailableAXDistinctFromCapturedFrame() throws {
        let fixture = SemanticFixture()
        let capture = TestVisualCapture { target, _, _, _ in try blankFrame(target) }
        let system = MacOSSystem(backend: fixture.backend, catalog: fixture.catalog, visual: capture, isAXTrusted: { false })
        let result = try system.observe(params: ObserveRequest(target: fixture.target.key, includeScreenshot: true, includeValues: false),
            observationId: "image-only", context: OperationContext(budgetMs: 5000))
        XCTAssertEqual(result.observation.accessibility, .unavailable)
        XCTAssertNil(result.observation.visual?.geometryMatchesAX)
        XCTAssertEqual(result.observation.visual?.captureStatus, .captured)
        XCTAssertNotNil(result.observation.screenshot)
        XCTAssertNil(result.handle)
        try Frame.response(Response(version: 1, id: "r", epoch: "epoch", body: .observe(result.observation))).validate()
    }

    func testFailedAXAssociationReportsAttemptAndReturnsVisualEvidence() throws {
        let fixture = SemanticFixture()
        fixture.backend.appWindows = []
        let capture = TestVisualCapture { target, _, _, _ in try blankFrame(target) }
        let system = MacOSSystem(backend: fixture.backend, catalog: fixture.catalog, visual: capture, isAXTrusted: { true })
        let result = try system.observe(params: ObserveRequest(target: fixture.target.key, includeScreenshot: true, includeValues: false),
            observationId: "ax-unavailable", context: OperationContext(budgetMs: 5000))
        XCTAssertEqual(result.observation.accessibility, .unavailable)
        XCTAssertNotNil(result.observation.accessibilityCollected)
        XCTAssertNil(result.observation.visual?.geometryMatchesAX)
        XCTAssertNotNil(result.observation.screenshot)
        XCTAssertNil(result.handle)
        try Frame.response(Response(version: 1, id: "r", epoch: "epoch", body: .observe(result.observation))).validate()
    }

    func testStableCaptureAfterWindowMoveDisclosesAXGeometryDisagreement() throws {
        let fixture = SemanticFixture()
        let moved = Target(key: fixture.target.key, bundleId: fixture.target.bundleId, title: fixture.target.title,
            bounds: Rect(x: -410, y: 180, width: 340, height: 540))
        var reads = 0
        fixture.catalog.didReadWindow = { [weak catalog = fixture.catalog] in
            reads += 1
            if reads == 2 { catalog?.records = [moved] }
        }
        let capture = TestVisualCapture { target, _, _, _ in try blankFrame(target) }
        let system = MacOSSystem(backend: fixture.backend, catalog: fixture.catalog, visual: capture, isAXTrusted: { true })
        let result = try system.observe(params: ObserveRequest(target: fixture.target.key, includeScreenshot: true, includeValues: false),
            observationId: "visual-drift", context: OperationContext(budgetMs: 5000))
        XCTAssertEqual(result.observation.windowBounds, fixture.target.bounds)
        XCTAssertEqual(result.observation.visual?.frame?.captureWindowBounds, moved.bounds)
        XCTAssertEqual(result.observation.visual?.geometryMatchesAX, false)
        let handle = try XCTUnwrap(result.handle as? SemanticObservationHandle)
        XCTAssertThrowsError(try handle.validateWindow(context: OperationContext(budgetMs: 5000)))
        try Frame.response(Response(version: 1, id: "r", epoch: "epoch", body: .observe(result.observation))).validate()
    }

    func testWindowMoveDuringCaptureDiscardsPixelsAndOCR() throws {
        let fixture = SemanticFixture()
        let catalog = fixture.catalog
        let moved = Target(key: fixture.target.key, bundleId: fixture.target.bundleId, title: fixture.target.title,
            bounds: Rect(x: 500, y: 50, width: 440, height: 230))
        let capture = TestVisualCapture { target, _, _, _ in
            let activeFrame = try blankFrame(target)
            catalog.records = [moved]
            return activeFrame
        }
        let system = MacOSSystem(backend: fixture.backend, catalog: catalog, visual: capture, isAXTrusted: { true })
        let result = try system.observe(params: ObserveRequest(target: fixture.target.key, includeScreenshot: true, includeValues: false, includeOcr: true),
            observationId: "capture-drift", context: OperationContext(budgetMs: 5000))
        XCTAssertEqual(result.observation.accessibility, .complete)
        XCTAssertEqual(result.observation.visual?.captureStatus, .geometryChanged)
        XCTAssertEqual(result.observation.visual?.ocr?.status, .unavailable)
        XCTAssertNil(result.observation.visual?.frame)
        XCTAssertNil(result.observation.screenshot)
    }

    func testUnavailableReadKeepsReadableSiblingsWithoutProvingAbsence() throws {
        let fixture = SemanticFixture()
        fixture.second.readUnavailable = true
        let native = try fixture.observe()
        XCTAssertEqual(native.observation.accessibility, .partial)
        XCTAssertEqual(native.observation.elements.compactMap(\.identifier), ["first"])
        let handle = try XCTUnwrap(native.handle as? SemanticObservationHandle)
        XCTAssertFalse(try handle.scan(context: OperationContext(budgetMs: 5000)).complete)
        let missing = Condition.elementAbsent(ElementCondition(selector: Selector(role: "AXTextField", label: nil, identifier: "missing")))
        XCTAssertNil(try PredicateEvaluator().evaluate(missing, handle: handle,
            context: OperationContext(budgetMs: 5000)).matched)
    }

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
    func testUnlabelledCloseButtonSubroleIsExportedAndCannotBeReusedAsMinimize() throws {
        let fixture = SemanticFixture()
        fixture.first.role = "AXButton"; fixture.first.title = nil; fixture.first.identifier = nil
        fixture.first.subrole = "AXCloseButton"
        let result = try fixture.observe()
        let element = result.observation.elements[0]
        XCTAssertNil(element.label)
        XCTAssertEqual(element.subrole, "AXCloseButton")
        fixture.first.subrole = "AXMinimizeButton"
        let handle = result.handle as! SemanticObservationHandle
        XCTAssertThrowsError(try handle.resolve(element.reference, includeValue: true, context: OperationContext(budgetMs: 100))) {
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
        XCTAssertEqual(unknown.observation.elements.count, 2)
        XCTAssertNil(unknown.observation.elements[1].enabled)
        let encoded = try JSONEncoder().encode(unknown.observation.elements[1])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"enabled\":null"))
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
        fixture.first.subrole = String(repeating: "s", count: 1025)
        let result = try fixture.observe(values: true)
        XCTAssertEqual(result.observation.accessibility, .partial)
        XCTAssertNil(result.observation.elements[0].value)
        XCTAssertNil(result.observation.elements[0].label)
        XCTAssertNil(result.observation.elements[0].identifier)
        XCTAssertNil(result.observation.elements[0].subrole)
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

final class PredicateAndFeedbackTests: XCTestCase {
    private func context() -> OperationContext { OperationContext(budgetMs: 5000) }
    private func retained(_ native: NativeObservation) -> RetainedObservation {
        RetainedObservation(observation: native.observation, handle: native.handle,
                            createdAt: DispatchTime.now().uptimeNanoseconds)
    }
    func testPartialScanEstablishesPositivePresenceButCannotProveMissingElementAbsent() throws {
        let fixture = SemanticFixture()
        let handle = try fixture.observe().handle as! SemanticObservationHandle
        fixture.window.childrenComplete = false
        let present = ElementCondition(selector: Selector(role: "AXTextField", label: "Value", identifier: "first"))
        let missing = ElementCondition(selector: Selector(role: "AXTextField", label: nil, identifier: "missing"))
        let evaluator = PredicateEvaluator()
        XCTAssertEqual(try evaluator.evaluate(.elementExists(present), handle: handle, context: context()).matched, true)
        XCTAssertEqual(try evaluator.evaluate(.elementAbsent(present), handle: handle, context: context()).matched, false)
        XCTAssertNil(try evaluator.evaluate(.elementAbsent(missing), handle: handle, context: context()).matched)
        fixture.window.childrenComplete = true
        let absent = try evaluator.evaluate(.elementAbsent(missing), handle: handle, context: context())
        XCTAssertEqual(absent.matched, true)
        XCTAssertNotNil(absent.evidence?.collected)
        XCTAssertNil(absent.elementRef)
        XCTAssertTrue(fixture.backend.valueReads.isEmpty)
    }
    func testUnavailableValueAndEnabledStateAreUnknownRatherThanNegativeEvidence() throws {
        let fixture = SemanticFixture()
        let observation = try fixture.observe()
        let handle = observation.handle as! SemanticObservationHandle
        let reference = observation.observation.elements[0].reference
        fixture.first.value = nil; fixture.first.enabledKnown = false
        let evaluator = PredicateEvaluator()
        XCTAssertNil(try evaluator.evaluate(.valueEquals(ValueCondition(elementRef: reference, value: "")), handle: handle, context: context()).evidence)
        XCTAssertNil(try evaluator.evaluate(.enabled(EnabledCondition(elementRef: reference, enabled: false)), handle: handle, context: context()).evidence)
        fixture.first.value = ""
        XCTAssertEqual(try evaluator.evaluate(.valueEquals(ValueCondition(elementRef: reference, value: "")), handle: handle, context: context()).matched, true)
    }
    func testUnsupportedEnabledStateDoesNotHideCompleteRoleAbsence() throws {
        let fixture = SemanticFixture()
        let unsupported = try decodeAXEnabled(.attributeUnsupported, value: nil, context: context())
        for node in [fixture.window, fixture.second] {
            node.enabledKnown = unsupported.value != nil
            node.enabled = unsupported.value ?? false
            node.complete = unsupported.completeForTraversal
        }
        let native = try fixture.observe()
        let handle = native.handle as! SemanticObservationHandle
        let reference = native.observation.elements[1].reference
        XCTAssertEqual(native.observation.accessibility, .partial)
        XCTAssertNil(native.observation.elements[1].enabled)
        XCTAssertTrue(try handle.scan(context: context()).complete)
        let absent = Condition.elementAbsent(ElementCondition(selector: Selector(role: "AXCheckBox", label: nil, identifier: nil)))
        let evaluator = PredicateEvaluator()
        XCTAssertEqual(try evaluator.evaluate(absent, handle: handle, context: context()).matched, true)
        XCTAssertNil(try evaluator.evaluate(.enabled(EnabledCondition(elementRef: reference, enabled: true)), handle: handle, context: context()).matched)
        fixture.window.complete = try decodeAXEnabled(.noValue, value: nil, context: context()).completeForTraversal
        XCTAssertNil(try evaluator.evaluate(absent, handle: handle, context: context()).matched)
    }
    func testWindowAbsenceUsesIndependentExactPresenceWithoutRequiringLiveAXWindow() throws {
        let fixture = SemanticFixture()
        let handle = try fixture.observe().handle as! SemanticObservationHandle
        fixture.catalog.records = []
        let absent = PredicateEvaluator(windowPresent: { key, context in try context.check(); XCTAssertEqual(key, fixture.target.key); return false })
        let result = try absent.evaluate(.windowAbsent(Empty()), handle: handle, context: context())
        XCTAssertEqual(result.matched, true)
        XCTAssertEqual(result.target, fixture.target.key)
        XCTAssertNotNil(result.evidence?.collected)
        XCTAssertNil(result.elementRef)
        let offscreen = PredicateEvaluator(windowPresent: { _, context in try context.check(); return true })
        XCTAssertEqual(try offscreen.evaluate(.windowAbsent(Empty()), handle: handle, context: context()).matched, false)
    }
    func testFeedbackComparesRequestedPublicProjectionWithoutCreatingReferences() throws {
        let fixture = SemanticFixture()
        let native = try fixture.observe()
        let reference = native.observation.elements[0].reference
        let collector = FeedbackCollector()
        fixture.first.value = "new private value"
        let privateResult = collector.collect(FeedbackRequest(elementRefs: [reference], includeValues: false), entry: retained(native), context: context())
        XCTAssertEqual(privateResult.controls[0].state, .unchanged)
        XCTAssertNil(privateResult.controls[0].element)
        XCTAssertTrue(fixture.backend.valueReads.isEmpty)
        let disclosed = collector.collect(FeedbackRequest(elementRefs: [reference], includeValues: true), entry: retained(native), context: context())
        XCTAssertEqual(disclosed.controls[0].state, .changed)
        XCTAssertEqual(disclosed.controls[0].element?.reference, reference)
        XCTAssertEqual(disclosed.controls[0].element?.value, "new private value")
        XCTAssertEqual(disclosed.baseObservationId, native.observation.observationId)
        XCTAssertFalse(disclosed.invalidated)
    }
    func testFeedbackPreservesUnknownEnabledAndSubroleProjection() throws {
        let fixture = SemanticFixture()
        fixture.first.enabledKnown = false; fixture.first.subrole = "AXSearchTextField"
        let native = try fixture.observe()
        let reference = native.observation.elements[0].reference
        let unchanged = FeedbackCollector().collect(FeedbackRequest(elementRefs: [reference], includeValues: false), entry: retained(native), context: context())
        XCTAssertEqual(unchanged.controls[0].state, .unchanged)
        XCTAssertTrue(unchanged.truncated)
        let disclosed = FeedbackCollector().collect(FeedbackRequest(elementRefs: [reference], includeValues: true), entry: retained(native), context: context())
        XCTAssertEqual(disclosed.controls[0].state, .changed)
        XCTAssertNil(disclosed.controls[0].element?.enabled)
        XCTAssertEqual(disclosed.controls[0].element?.subrole, "AXSearchTextField")
    }
    func testExplicitValueDisclosureChangesProjectionEvenWithoutAMutation() throws {
        let fixture = SemanticFixture()
        let native = try fixture.observe()
        let reference = native.observation.elements[0].reference
        let unchangedValue = fixture.first.value
        let result = FeedbackCollector().collect(FeedbackRequest(elementRefs: [reference], includeValues: true), entry: retained(native), context: context())
        XCTAssertEqual(fixture.first.value, unchangedValue)
        XCTAssertEqual(result.controls[0].state, .changed)
        XCTAssertEqual(result.controls[0].element?.value, unchangedValue)
        XCTAssertEqual(result.controls[0].element?.reference, reference)
    }
    func testIndividualControlInvalidationDoesNotInvalidateUnrelatedReferences() throws {
        let fixture = SemanticFixture()
        let native = try fixture.observe()
        let references = native.observation.elements.map(\.reference)
        fixture.first.identifier = "reused"
        let result = FeedbackCollector().collect(FeedbackRequest(elementRefs: references, includeValues: false), entry: retained(native), context: context())
        XCTAssertEqual(result.controls.map(\.state), [.invalidated, .unchanged])
        XCTAssertFalse(result.invalidated)
        XCTAssertTrue(result.controls.allSatisfy { $0.element == nil })
    }
    func testWholeWindowInvalidationAndNativeUnavailabilityRemainDistinct() throws {
        let fixture = SemanticFixture()
        let native = try fixture.observe()
        let request = FeedbackRequest(elementRefs: native.observation.elements.map(\.reference), includeValues: false)
        fixture.first.readable = false
        let unavailable = FeedbackCollector().collect(request, entry: retained(native), context: context())
        XCTAssertEqual(unavailable.controls.map(\.state), [.unavailable, .unchanged])
        XCTAssertFalse(unavailable.invalidated)
        fixture.catalog.records = []
        let invalidated = FeedbackCollector().collect(request, entry: retained(native), context: context())
        XCTAssertTrue(invalidated.invalidated)
        XCTAssertTrue(invalidated.controls.allSatisfy { $0.state == .invalidated && $0.element == nil })
    }
    func testFeedbackDeadlineIsBestEffortAndDoesNotRequestValues() throws {
        let fixture = SemanticFixture()
        let native = try fixture.observe()
        let context = context(); context.cancel()
        let result = FeedbackCollector().collect(FeedbackRequest(elementRefs: native.observation.elements.map(\.reference), includeValues: true), entry: retained(native), context: context)
        XCTAssertTrue(result.controls.allSatisfy { $0.state == .unavailable && $0.element == nil })
        XCTAssertFalse(result.invalidated)
        XCTAssertTrue(fixture.backend.valueReads.isEmpty)
    }
    func testExpiredFeedbackBindingDoesNotRefreshOrReadRetainedReferences() throws {
        let fixture = SemanticFixture()
        let native = try fixture.observe()
        let expired = RetainedObservation(observation: native.observation, handle: native.handle, createdAt: 0)
        let result = FeedbackCollector().collect(FeedbackRequest(elementRefs: native.observation.elements.map(\.reference), includeValues: true), entry: expired, context: context())
        XCTAssertTrue(result.invalidated)
        XCTAssertTrue(result.controls.allSatisfy { $0.state == .invalidated && $0.element == nil })
        XCTAssertTrue(fixture.backend.valueReads.isEmpty)
    }
    func testFeedbackEncodedPayloadIsBoundedWithExplicitUnavailableRemainder() throws {
        let fixture = SemanticFixture()
        fixture.window.children = (0..<8).map { index in
            let node = SemanticNode("feedback-\(index)", role: "AXTextField", title: "Value", bounds: fixture.first.bounds)
            node.value = String(repeating: "\u{0000}", count: 65_536)
            node.owner = fixture.window; node.parent = fixture.window; return node
        }
        let native = try fixture.observe()
        let result = FeedbackCollector().collect(FeedbackRequest(elementRefs: native.observation.elements.map(\.reference), includeValues: true), entry: retained(native), context: context())
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.controls.count, 8)
        XCTAssertTrue(result.controls.contains { $0.state == .changed })
        XCTAssertTrue(result.controls.contains { $0.state == .unavailable })
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, Limits.maxFeedbackBytes)
    }
}
