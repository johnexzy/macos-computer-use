import CUAProtocol
import Foundation

public protocol AXObject: RetainedNativeHandle {}

public struct AXTextRange: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public struct AXChildren: Sendable {
    public let elements: [any AXObject]
    public let complete: Bool
    public init(elements: [any AXObject], complete: Bool = true) { self.elements = elements; self.complete = complete }
}

public struct AXElementIdentity: Equatable, Sendable {
    public let role: String
    public let identifier: String?
    public let subrole: String?
    public init(role: String, identifier: String?, subrole: String? = nil) {
        self.role = role; self.identifier = identifier; self.subrole = subrole
    }
}

public struct AXNodeSnapshot: Sendable {
    public let role: String
    public let title: String?
    public let label: String?
    public let identifier: String?
    public let subrole: String?
    public let bounds: Rect
    public let enabled: Bool
    public let enabledKnown: Bool
    public let enabledUnsupported: Bool
    public let value: String?
    public let valueSettable: Bool
    public let selectedTextSettable: Bool
    public let selectedRange: AXTextRange?
    public let actions: [String]
    public let complete: Bool
    public var identity: AXElementIdentity { AXElementIdentity(role: role, identifier: identifier, subrole: subrole) }
    public init(role: String, title: String? = nil, label: String? = nil, identifier: String? = nil,
                bounds: Rect, enabled: Bool = true, enabledKnown: Bool = true, value: String? = nil,
                valueSettable: Bool = false, selectedTextSettable: Bool = false, selectedRange: AXTextRange? = nil,
                actions: [String] = [], complete: Bool = true, subrole: String? = nil, enabledUnsupported: Bool = false) {
        self.role = role; self.title = title; self.label = label; self.identifier = identifier
        self.subrole = subrole
        self.bounds = bounds; self.enabled = enabled; self.enabledKnown = enabledKnown; self.value = value
        self.enabledUnsupported = enabledUnsupported
        self.valueSettable = valueSettable; self.selectedTextSettable = selectedTextSettable
        self.selectedRange = selectedRange; self.actions = actions; self.complete = complete
    }

    func availableActions(backend: any AXReading) -> [ElementAction] {
        guard backend is any AXMutating else { return [] }
        var available: [ElementAction] = []
        if valueSettable { available.append(.setValue) }
        if actions.contains("AXPress") { available.append(.press) }
        if selectedTextSettable { available.append(.typeText) }
        if role == "AXScrollArea", backend is any AXScrolling { available.append(.scroll) }
        return available
    }
}

/// This seam represents native reads; actions use retained objects, never selectors.
public protocol AXReading: Sendable {
    func application(pid: UInt32, context: OperationContext) throws -> any AXObject
    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren
    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren
    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)?
    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)?
    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32
    func identity(of element: any AXObject, context: OperationContext) throws -> AXElementIdentity?
    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot?
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool
}

public extension AXReading {
    func identity(of element: any AXObject, context: OperationContext) throws -> AXElementIdentity? {
        try snapshot(of: element, includeValue: false, context: context)?.identity
    }
}

public protocol WindowCatalog: Sendable {
    func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult
    func window(_ key: TargetKey, context: OperationContext) throws -> Target
    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target]
}

public struct NativeObservation: Sendable {
    public let observation: Observation
    public let handle: (any RetainedNativeHandle)?
    public init(observation: Observation, handle: (any RetainedNativeHandle)?) {
        self.observation = observation; self.handle = handle
    }
}

public struct ResolvedAXElement: Sendable {
    public let object: any AXObject
    public let snapshot: AXNodeSnapshot
    public init(object: any AXObject, snapshot: AXNodeSnapshot) { self.object = object; self.snapshot = snapshot }
}

public struct AXTreeSnapshot: Sendable {
    public let nodes: [ResolvedAXElement]
    public let complete: Bool
    public let visitedNodes: UInt32
    public init(nodes: [ResolvedAXElement], complete: Bool, visitedNodes: UInt32 = 0) {
        self.nodes = nodes; self.complete = complete; self.visitedNodes = visitedNodes
    }
}

private let maxTreeNodes = 1024
private let maxTreeDepth = 32

struct RetainedAXElement: Sendable {
    let object: any AXObject
    let identity: AXElementIdentity
    init(object: any AXObject, snapshot: AXNodeSnapshot) {
        self.object = object; identity = snapshot.identity
    }
}

/// Owns exact retained objects for one observation. The session registry enforces epoch/TTL.
public final class SemanticObservationHandle: RetainedNativeHandle, @unchecked Sendable {
    public let backend: any AXReading
    public let target: Target
    public let retainedWindow: any AXObject
    public let observationId: String
    public let includeValues: Bool
    private let application: any AXObject
    private let catalog: any WindowCatalog
    private let references: [String: RetainedAXElement]
    var eventTracker: TargetWindowEvents?

    public func didPublishObservation() { eventTracker?.publish() }

    init(backend: any AXReading, catalog: any WindowCatalog, application: any AXObject,
         target: Target, window: any AXObject, observationId: String, includeValues: Bool,
         references: [String: RetainedAXElement]) {
        self.backend = backend; self.catalog = catalog; self.application = application
        self.target = target; retainedWindow = window; self.observationId = observationId
        self.includeValues = includeValues; self.references = references
    }

    public func validateWindow(context: OperationContext) throws {
        try context.check()
        let current = try catalog.window(target.key, context: context)
        guard current.bounds == target.bounds, current.bundleId == target.bundleId,
              titlesCompatible(current.title, target.title) else {
            throw NativeFailure(.staleObservation, "observed window metadata changed")
        }
        let live = try associatedWindow(target: current, application: application, backend: backend, catalog: catalog, context: context)
        guard backend.same(live, retainedWindow) else { throw NativeFailure(.staleElement, "observed AX window was replaced") }
    }

    func validateOwner(of object: any AXObject, context: OperationContext) throws {
        try requireOwningWindow(object, window: retainedWindow, pid: target.key.pid, backend: backend, context: context)
    }

    public func resolve(_ reference: String, includeValue: Bool = false, context: OperationContext) throws -> ResolvedAXElement {
        guard let retained = references[reference] else { throw NativeFailure(.staleElement, "reference does not belong to this observation") }
        let object = retained.object
        try validateWindow(context: context)
        try validateOwner(of: object, context: context)
        guard try containsRetainedObject(object, window: retainedWindow, backend: backend, context: context) else {
            throw NativeFailure(.staleElement, "retained control is not in the current bounded window tree")
        }
        guard try backend.identity(of: object, context: context) == retained.identity else {
            throw NativeFailure(.staleElement, "retained control role, subrole or identifier changed")
        }
        guard let snapshot = try backend.snapshot(of: object, includeValue: includeValue, context: context) else {
            throw NativeFailure(.staleElement, "retained control cannot be read")
        }
        guard snapshot.identity == retained.identity else {
            throw NativeFailure(.staleElement, "retained control role, subrole or identifier changed")
        }
        try validateOwner(of: object, context: context)
        try validateWindow(context: context)
        return ResolvedAXElement(object: object, snapshot: snapshot)
    }

    public func scan(includeValues: Bool = false, context: OperationContext) throws -> AXTreeSnapshot {
        try validateWindow(context: context)
        let scan = try collectTree(window: retainedWindow, pid: target.key.pid, backend: backend,
                                   includeValues: includeValues, context: context)
        try validateWindow(context: context)
        return scan
    }

    public func scan(selectors: [CUAProtocol.Selector], includeValues: Bool, context: OperationContext) throws -> AXTreeSnapshot {
        try validateWindow(context: context)
        let scan = try collectTree(window: retainedWindow, pid: target.key.pid, backend: backend,
                                  includeValues: includeValues, selectors: selectors, context: context)
        try validateWindow(context: context)
        return scan
    }
    func eventReadSource() -> SemanticObservationHandle {
        SemanticObservationHandle(backend: backend, catalog: catalog, application: application, target: target,
            window: retainedWindow, observationId: observationId, includeValues: includeValues, references: references)
    }
    func notificationObjects() -> [any AXObject] { [retainedWindow] + references.values.prefix(Limits.maxEventControls).map(\.object) }
}

public struct SemanticAXObserver: Sendable {
    private let backend: any AXReading
    private let catalog: any WindowCatalog
    public init(backend: any AXReading, catalog: any WindowCatalog) { self.backend = backend; self.catalog = catalog }

    public func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation {
        guard !params.includeScreenshot && !params.includeOcr else { throw NativeFailure(.unsupported, "semantic observer only accepts AX requests") }
        let started = milliseconds()
        let target = try catalog.window(params.target, context: context)
        let axStarted = milliseconds()
        let application = try backend.application(pid: target.key.pid, context: context)
        let window = try associatedWindow(target: target, application: application, backend: backend, catalog: catalog, context: context)
        let scan = try collectTree(window: window, pid: target.key.pid, backend: backend,
                                   includeValues: params.includeValues, selectors: params.axSelectors, context: context)
        var references: [String: RetainedAXElement] = [:]
        var elements: [Element] = []
        var complete = scan.complete
        var encodedBytes = 0
        let encoder = JSONEncoder()
        for node in scan.nodes where params.axSelectors != nil || (node.snapshot.role != "AXWindow" && node.snapshot.role != "AXGroup") {
            if elements.count == Limits.maxElements { complete = false; break }
            let reference = "element-\(UUID().uuidString)"
            let s = node.snapshot
            if !s.enabledKnown { complete = false }
            guard !s.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.role.utf8.count <= 128 else {
                complete = false; continue
            }
            let label = bounded(s.label, bytes: 1024)
            let identifier = bounded(s.identifier, bytes: 1024)
            let subrole = bounded(s.subrole, bytes: 1024)
            let value = params.includeValues ? bounded(s.value, bytes: 65_536) : nil
            if label != s.label || identifier != s.identifier || subrole != s.subrole || (params.includeValues && value != s.value) { complete = false }
            let actions = s.availableActions(backend: backend)
            let element = Element(reference: reference, role: s.role, label: label, value: value,
                                  bounds: s.bounds, enabled: s.enabledKnown ? s.enabled : nil, actions: actions,
                                  identifier: identifier, subrole: subrole)
            let size = try encoder.encode(element).count
            if encodedBytes + size > 2 * 1024 * 1024 { complete = false; break }
            encodedBytes += size
            references[reference] = RetainedAXElement(object: node.object, snapshot: s)
            elements.append(element)
        }
        let handle = SemanticObservationHandle(backend: backend, catalog: catalog, application: application,
            target: target, window: window, observationId: observationId,
            includeValues: params.includeValues, references: references)
        try handle.validateWindow(context: context)
        let axFinished = max(axStarted, milliseconds())
        let selection = params.axSelectors.map { selectors in
            AxSelectionEvidence(selectors: selectors, coverage: scan.complete && elements.count == scan.nodes.count ? .complete : .partial,
                ambiguous: selectors.contains { selector in scan.nodes.filter { matches($0.snapshot, selector: selector) }.count > 1 },
                visitedNodes: scan.visitedNodes)
        }
        let observation = Observation(observationId: observationId, target: target.key,
            collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(axFinished, milliseconds())),
            windowBounds: target.bounds, accessibility: params.axSelectors == nil && complete ? .complete : .partial,
            accessibilityCollected: CollectionInterval(startedUnixMs: axStarted, finishedUnixMs: axFinished),
            elements: elements, screenshot: nil, axSelection: selection)
        try context.check()
        return NativeObservation(observation: observation, handle: handle)
    }
}

private func titlesCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
    guard let lhs, !lhs.isEmpty, let rhs, !rhs.isEmpty else { return true }
    return lhs == rhs
}

private func associatedWindow(target: Target, application: any AXObject, backend: any AXReading,
                              catalog: any WindowCatalog, context: OperationContext) throws -> any AXObject {
    let siblings = try catalog.processWindows(pid: target.key.pid, context: context)
    guard !siblings.contains(where: { $0.key != target.key && $0.bounds == target.bounds && titlesCompatible($0.title, target.title) }) else {
        throw NativeFailure(.ambiguousTarget, "CG window metadata cannot uniquely identify an AX window")
    }
    let windows = try backend.windows(of: application, context: context)
    guard windows.complete else { throw NativeFailure(.ambiguousTarget, "AX window candidates are incomplete") }
    var matches: [ResolvedAXElement] = []
    for window in windows.elements {
        try context.check()
        guard try backend.ownerPID(of: window, context: context) == target.key.pid,
              let snapshot = try backend.snapshot(of: window, includeValue: false, context: context),
              snapshot.bounds == target.bounds, titlesCompatible(snapshot.title, target.title) else { continue }
        matches.append(ResolvedAXElement(object: window, snapshot: snapshot))
    }
    guard matches.count == 1 else {
        throw NativeFailure(matches.isEmpty ? .targetNotFound : .ambiguousTarget,
                            matches.isEmpty ? "no exact AX window metadata association" : "multiple AX windows have matching metadata")
    }
    let selected = matches[0]
    guard !siblings.contains(where: {
        $0.key != target.key && $0.bounds == selected.snapshot.bounds && titlesCompatible($0.title, selected.snapshot.title)
    }) else {
        throw NativeFailure(.ambiguousTarget, "selected AX window metadata also matches another CG window")
    }
    return selected.object
}

private func requireOwningWindow(_ object: any AXObject, window: any AXObject, pid: UInt32,
                                 backend: any AXReading, context: OperationContext) throws {
    guard try backend.ownerPID(of: object, context: context) == pid else { throw NativeFailure(.staleElement, "AX object belongs to another process") }
    if backend.same(object, window) { return }
    if let owner = try backend.window(of: object, context: context) {
        guard backend.same(owner, window) else { throw NativeFailure(.staleElement, "AX object belongs to another window") }
        return
    }
    var ancestors: [any AXObject] = [object]
    var current = object
    for _ in 0..<maxTreeDepth {
        guard let parent = try backend.parent(of: current, context: context),
              !ancestors.contains(where: { backend.same($0, parent) }) else { break }
        if backend.same(parent, window) { return }
        ancestors.append(parent); current = parent
    }
    throw NativeFailure(.staleElement, "AX owning-window identity is unavailable")
}

private func collectTree(window: any AXObject, pid: UInt32, backend: any AXReading,
                         includeValues: Bool, selectors: [CUAProtocol.Selector]? = nil, context: OperationContext) throws -> AXTreeSnapshot {
    var pending: [(any AXObject, Int)] = [(window, 0)]
    var seen: [any AXObject] = []
    var nodes: [ResolvedAXElement] = []
    var complete = true
    while let (object, depth) = pending.popLast() {
        try context.check()
        if seen.contains(where: { backend.same($0, object) }) { complete = false; continue }
        guard seen.count < maxTreeNodes else { complete = false; break }
        seen.append(object)
        do {
            try requireOwningWindow(object, window: window, pid: pid, backend: backend, context: context)
            if let selectors {
                guard let identity = try backend.identity(of: object, context: context) else {
                    complete = false
                    let children = try backend.children(of: object, limit: max(0, maxTreeNodes - seen.count - pending.count), context: context)
                    if !children.complete || (depth >= maxTreeDepth && !children.elements.isEmpty) { complete = false }
                    if depth < maxTreeDepth { for child in children.elements.reversed() { pending.append((child, depth + 1)) } }
                    continue
                }
                let candidates = selectors.filter { $0.role == identity.role && ($0.identifier == nil || $0.identifier == identity.identifier) }
                if !candidates.isEmpty {
                    if var snapshot = try backend.snapshot(of: object, includeValue: false, context: context) {
                        if snapshot.identity != identity { complete = false }
                        else {
                            if snapshot.label == nil && !snapshot.complete && candidates.contains(where: { $0.label != nil }) { complete = false }
                            if candidates.contains(where: { matches(snapshot, selector: $0) }) {
                                if includeValues {
                                    guard let withValue = try backend.snapshot(of: object, includeValue: true, context: context) else {
                                        complete = false; continue
                                    }
                                    snapshot = withValue
                                }
                                if snapshot.identity == identity && candidates.contains(where: { matches(snapshot, selector: $0) }) {
                                    nodes.append(ResolvedAXElement(object: object, snapshot: snapshot))
                                } else { complete = false }
                            }
                        }
                    } else { complete = false }
                }
            } else if let snapshot = try backend.snapshot(of: object, includeValue: includeValues, context: context) {
                nodes.append(ResolvedAXElement(object: object, snapshot: snapshot))
                if !snapshot.complete { complete = false }
            } else { complete = false }
            let children = try backend.children(of: object, limit: max(0, maxTreeNodes - seen.count - pending.count), context: context)
            if !children.complete { complete = false }
            if depth >= maxTreeDepth {
                if !children.elements.isEmpty { complete = false }
            } else {
                for child in children.elements.reversed() { pending.append((child, depth + 1)) }
            }
        } catch is AXReadUnavailable {
            // Keep readable siblings without claiming that the unreadable subtree is absent.
            complete = false
        } catch let error as NativeFailure where error.code == .staleElement || error.code == .nativeFailed {
            complete = false
        }
    }
    return AXTreeSnapshot(nodes: nodes, complete: complete, visitedNodes: UInt32(seen.count))
}

func matches(_ snapshot: AXNodeSnapshot, selector: CUAProtocol.Selector) -> Bool {
    snapshot.role == selector.role && (selector.identifier == nil || selector.identifier == snapshot.identifier)
        && (selector.label == nil || selector.label == snapshot.label)
}

/// Membership needs current identities/children, not a second full attribute read of every sibling.
private func containsRetainedObject(_ sought: any AXObject, window: any AXObject, backend: any AXReading,
                                    context: OperationContext) throws -> Bool {
    var pending: [(any AXObject, Int)] = [(window, 0)]
    var seen: [any AXObject] = []
    while let (object, depth) = pending.popLast() {
        try context.check()
        if seen.contains(where: { backend.same($0, object) }) { continue }
        guard seen.count < maxTreeNodes else { return false }
        seen.append(object)
        if backend.same(object, sought) { return true }
        if depth >= maxTreeDepth { continue }
        let children = try backend.children(of: object, limit: max(0, maxTreeNodes - seen.count - pending.count), context: context)
        for child in children.elements.reversed() { pending.append((child, depth + 1)) }
    }
    return false
}

private func milliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
private func bounded(_ string: String?, bytes: Int) -> String? {
    string.flatMap { $0.utf8.count <= bytes ? $0 : nil }
}
