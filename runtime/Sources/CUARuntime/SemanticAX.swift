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
    public let url: String?
    public var identity: AXElementIdentity { AXElementIdentity(role: role, identifier: identifier, subrole: subrole) }
    public init(role: String, title: String? = nil, label: String? = nil, identifier: String? = nil,
                bounds: Rect, enabled: Bool = true, enabledKnown: Bool = true, value: String? = nil,
                valueSettable: Bool = false, selectedTextSettable: Bool = false, selectedRange: AXTextRange? = nil,
                actions: [String] = [], complete: Bool = true, subrole: String? = nil, enabledUnsupported: Bool = false,
                url: String? = nil) {
        self.role = role; self.title = title; self.label = label; self.identifier = identifier
        self.subrole = subrole
        self.bounds = bounds; self.enabled = enabled; self.enabledKnown = enabledKnown; self.value = value
        self.enabledUnsupported = enabledUnsupported
        self.valueSettable = valueSettable; self.selectedTextSettable = selectedTextSettable
        self.selectedRange = selectedRange; self.actions = actions; self.complete = complete
        self.url = url
    }

    func availableActions(backend: any AXReading) -> [ElementAction] {
        guard backend is any AXMutating else { return [] }
        var available: [ElementAction] = []
        if valueSettable { available.append(.setValue) }
        if actions.contains("AXPress") { available.append(.press) }
        if selectedTextSettable { available.append(.typeText) }
        if role == "AXScrollArea", backend is any AXScrolling { available.append(.scroll) }
        if actions.contains("AXScrollToVisible") { available.append(.scrollToVisible) }
        if actions.contains("AXConfirm") { available.append(.confirm) }
        if actions.contains("AXShowMenu") { available.append(.showMenu) }
        if actions.contains("AXCancel") { available.append(.cancel) }
        return available
    }
}

/// This seam represents native reads; actions use retained objects, never selectors.
public protocol AXReading: Sendable {
    func application(pid: UInt32, context: OperationContext) throws -> any AXObject
    func focusedElement(of application: any AXObject, context: OperationContext) throws -> (any AXObject)?
    func menuBar(of application: any AXObject, context: OperationContext) throws -> (any AXObject)?
    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren
    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren
    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)?
    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)?
    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32
    func bounds(of element: any AXObject, context: OperationContext) throws -> Rect?
    func identity(of element: any AXObject, context: OperationContext) throws -> AXElementIdentity?
    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot?
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool
    func prepareBrowserAccessibility(application: any AXObject, bundleId: String?, context: OperationContext) throws -> Bool
}

public extension AXReading {
    func focusedElement(of application: any AXObject, context: OperationContext) throws -> (any AXObject)? { nil }
    func menuBar(of application: any AXObject, context: OperationContext) throws -> (any AXObject)? { nil }
    func bounds(of element: any AXObject, context: OperationContext) throws -> Rect? { nil }
    func prepareBrowserAccessibility(application: any AXObject, bundleId: String?, context: OperationContext) throws -> Bool { false }

    func identity(of element: any AXObject, context: OperationContext) throws -> AXElementIdentity? {
        try snapshot(of: element, includeValue: false, context: context)?.identity
    }
}

public protocol WindowCatalog: Sendable {
    func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult
    func window(_ key: TargetKey, context: OperationContext) throws -> Target
    func windowSnapshot(_ key: TargetKey, context: OperationContext) throws -> WindowSnapshot
    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target]
}

public struct WindowSnapshot: Sendable {
    public let target: Target
    let generation: ProcessGeneration?
}

public extension WindowCatalog {
    func windowSnapshot(_ key: TargetKey, context: OperationContext) throws -> WindowSnapshot {
        WindowSnapshot(target: try window(key, context: context), generation: nil)
    }
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
private let maxSelectiveTreeDepth = 48
private let activeSiblingBatch = 32

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
    public let application: any AXObject
    private let catalog: any WindowCatalog
    private let generation: ProcessGeneration?
    private let references: [String: RetainedAXElement]
    var eventTracker: TargetWindowEvents?

    public func didPublishObservation() { eventTracker?.publish() }

    init(backend: any AXReading, catalog: any WindowCatalog, application: any AXObject,
         target: Target, window: any AXObject, observationId: String, includeValues: Bool,
         references: [String: RetainedAXElement], generation: ProcessGeneration? = nil) {
        self.backend = backend; self.catalog = catalog; self.application = application
        self.target = target; retainedWindow = window; self.observationId = observationId
        self.includeValues = includeValues; self.references = references
        self.generation = generation
    }

    public func validateWindow(context: OperationContext, allowTitleChange: Bool = false) throws {
        try context.check()
        let snapshot = try catalog.windowSnapshot(target.key, context: context)
        let current = snapshot.target
        guard (generation == nil || snapshot.generation == generation),
              current.bounds == target.bounds, current.bundleId == target.bundleId,
              (allowTitleChange || titlesCompatible(current.title, target.title)) else {
            throw NativeFailure(.staleObservation, "observed window metadata changed")
        }
        let live: any AXObject
        do {
            live = try associatedWindow(target: current, application: application, backend: backend, catalog: catalog, context: context)
        } catch let failure as NativeFailure where allowTitleChange && failure.code == .targetNotFound {
            // During browser navigation, AXTitle can update milliseconds before CGWindowName.
            // The CG window itself is still present (catalog.windowSnapshot succeeded above),
            // so surface a transient read gap for wait polling instead of failing closed early.
            throw AXReadUnavailable()
        }
        guard backend.same(live, retainedWindow) else { throw NativeFailure(.staleElement, "observed AX window was replaced") }
    }

    func validateOwner(of object: any AXObject, context: OperationContext) throws {
        try requireOwningWindow(object, window: retainedWindow, pid: target.key.pid, backend: backend, context: context)
    }

    public func resolve(_ reference: String, includeValue: Bool = false, allowTitleChange: Bool = false,
                        context: OperationContext) throws -> ResolvedAXElement {
        guard let retained = references[reference] else { throw NativeFailure(.staleElement, "reference does not belong to this observation") }
        let object = retained.object
        try validateWindow(context: context, allowTitleChange: allowTitleChange)
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
        try validateWindow(context: context, allowTitleChange: allowTitleChange)
        return ResolvedAXElement(object: object, snapshot: snapshot)
    }

    public func scan(includeValues: Bool = false, context: OperationContext) throws -> AXTreeSnapshot {
        try validateWindow(context: context)
        let scan = try collectTree(window: retainedWindow, pid: target.key.pid, backend: backend,
                                   includeValues: includeValues, context: context)
        try validateWindow(context: context)
        return scan
    }

    public func scan(selectors: [CUAProtocol.Selector], includeValues: Bool, allowTitleChange: Bool = false,
                     context: OperationContext) throws -> AXTreeSnapshot {
        try validateWindow(context: context, allowTitleChange: allowTitleChange)
        let scan = try collectTree(window: retainedWindow, pid: target.key.pid, backend: backend,
                                  includeValues: includeValues, selectors: selectors, context: context)
        try validateWindow(context: context, allowTitleChange: allowTitleChange)
        return scan
    }
    func eventReadSource() -> SemanticObservationHandle {
        SemanticObservationHandle(backend: backend, catalog: catalog, application: application, target: target,
            window: retainedWindow, observationId: observationId, includeValues: includeValues,
            references: references, generation: generation)
    }
    func notificationObjects() -> [any AXObject] { [retainedWindow] + references.values.prefix(Limits.maxEventControls).map(\.object) }
}

public struct SemanticAXObserver: Sendable {
    private let backend: any AXReading
    private let catalog: any WindowCatalog
    public init(backend: any AXReading, catalog: any WindowCatalog) { self.backend = backend; self.catalog = catalog }

    public func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation {
        let snapshot = try catalog.windowSnapshot(params.target, context: context)
        return try observe(params: params, observationId: observationId, target: snapshot.target,
                           generation: snapshot.generation, context: context)
    }

    func observe(params: ObserveRequest, observationId: String, target: Target,
                 generation: ProcessGeneration?, context: OperationContext) throws -> NativeObservation {
        guard !params.includeScreenshot && !params.includeOcr else { throw NativeFailure(.unsupported, "semantic observer only accepts AX requests") }
        let started = milliseconds()
        let axStarted = milliseconds()
        let application = try backend.application(pid: target.key.pid, context: context)
        let activatedBrowserAX = try backend.prepareBrowserAccessibility(application: application, bundleId: target.bundleId, context: context)
        let window = try associatedWindow(target: target, application: application, backend: backend, catalog: catalog, context: context)
        let effectiveScope = params.scope ?? .window
        if effectiveScope == .menuBar {
            return try observeMenuBar(params: params, observationId: observationId, target: target, application: application,
                                      window: window, generation: generation, started: started, axStarted: axStarted, context: context)
        }
        if activatedBrowserAX {
            let webSelector = [CUAProtocol.Selector(role: "AXWebArea", label: nil, identifier: nil)]
            // Cold-started Chromium renderers can take ~1.5-2.0s to publish their first AXWebArea
            // after AXEnhancedUserInterface flips from 0 to 1; warm browsers match immediately.
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_500_000_000
            var webRoots: [any AXObject] = []
            while DispatchTime.now().uptimeNanoseconds < deadline {
                try context.check()
                let probe = try collectTree(window: window, pid: target.key.pid, backend: backend,
                                            includeValues: false, selectors: webSelector, application: application,
                                            visibleIn: target.bounds, context: context)
                if !probe.nodes.isEmpty {
                    webRoots = probe.nodes.map(\.object)
                    break
                }
                let delay = Double(try context.nativeTimeoutSeconds(maximum: 0.08))
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
            if !webRoots.isEmpty {
                // Wait briefly until Chromium's web accessibility tree populates interactive actions
                // (e.g. AXPress / settable AXValue) so the very first observe has full actions.
                let interactiveSelectors = [
                    CUAProtocol.Selector(role: "AXButton", label: nil, identifier: nil),
                    CUAProtocol.Selector(role: "AXLink", label: nil, identifier: nil),
                    CUAProtocol.Selector(role: "AXCheckBox", label: nil, identifier: nil),
                    CUAProtocol.Selector(role: "AXTextField", label: nil, identifier: nil),
                ]
                let settleStart = DispatchTime.now().uptimeNanoseconds
                let settleDeadline = settleStart + 500_000_000
                let emptyDeadline = settleStart + 100_000_000
                while DispatchTime.now().uptimeNanoseconds < settleDeadline {
                    try context.check()
                    let probe = try collectTree(roots: webRoots, window: window, pid: target.key.pid, backend: backend,
                                                includeValues: false, selectors: interactiveSelectors, application: application,
                                                visibleIn: target.bounds, context: context)
                    if probe.nodes.contains(where: { $0.snapshot.actions.contains("AXPress") || $0.snapshot.valueSettable || $0.snapshot.selectedTextSettable }) {
                        break
                    }
                    if probe.nodes.isEmpty && DispatchTime.now().uptimeNanoseconds >= emptyDeadline {
                        break
                    }
                    let delay = Double(try context.nativeTimeoutSeconds(maximum: 0.05))
                    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                }
            }
        }
        let scanRoots: [any AXObject]
        var scopedComplete = true
        if effectiveScope == .webArea {
            let webProbe = try collectTree(window: window, pid: target.key.pid, backend: backend,
                                           includeValues: false, selectors: [CUAProtocol.Selector(role: "AXWebArea", label: nil, identifier: nil)],
                                           application: application, visibleIn: target.bounds, context: context)
            scanRoots = webProbe.nodes.map(\.object)
            scopedComplete = webProbe.complete
        } else {
            scanRoots = [window]
        }
        let scan: AXTreeSnapshot
        if scanRoots.isEmpty {
            scan = AXTreeSnapshot(nodes: [], complete: scopedComplete, visitedNodes: 0)
        } else {
            let raw = try collectTree(roots: scanRoots, window: window, pid: target.key.pid, backend: backend,
                                      includeValues: params.includeValues, selectors: params.axSelectors, application: application,
                                      visibleIn: target.bounds, context: context)
            scan = AXTreeSnapshot(nodes: raw.nodes, complete: scopedComplete && raw.complete, visitedNodes: raw.visitedNodes)
        }
        if target.bundleId == nil, params.axSelectors == nil, effectiveScope == .window,
           !scan.nodes.contains(where: { $0.snapshot.role != "AXWindow" && $0.snapshot.role != "AXGroup" }) {
            throw AXReadUnavailable()
        }
        var references: [String: RetainedAXElement] = [:]
        var elements: [Element] = []
        var complete = scan.complete
        var encodedBytes = 0
        let encoder = JSONEncoder()
        var eligible = scan.nodes.filter { params.axSelectors != nil || ($0.snapshot.role != "AXWindow" && $0.snapshot.role != "AXGroup") }
        if params.interactiveOnly {
            eligible = eligible.filter { isInteractiveElement($0.snapshot) }
        }
        if let query = params.query {
            eligible = eligible.filter { matchesQuery($0.snapshot, query: query, includeValues: params.includeValues) }
        }
        let selectedNodes: [ResolvedAXElement]
        if params.axSelectors == nil && eligible.count > Limits.maxElements {
            complete = false
            selectedNodes = selectElementsForBudget(eligible, limit: Limits.maxElements, windowBounds: target.bounds)
        } else {
            selectedNodes = eligible
        }
        for node in selectedNodes {
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
            let url = boundedNonEmpty(s.url, bytes: Limits.maxUrlBytes)
            let value = params.includeValues ? bounded(s.value, bytes: 65_536) : nil
            if label != s.label || identifier != s.identifier || subrole != s.subrole || url != s.url || (params.includeValues && value != s.value) { complete = false }
            let actions = s.availableActions(backend: backend)
            let element = Element(reference: reference, role: s.role, label: label, value: value,
                                  bounds: s.bounds, enabled: s.enabledKnown ? s.enabled : nil, actions: actions,
                                  identifier: identifier, subrole: subrole, url: url)
            let size = try encoder.encode(element).count
            if encodedBytes + size > 2 * 1024 * 1024 { complete = false; break }
            encodedBytes += size
            references[reference] = RetainedAXElement(object: node.object, snapshot: s)
            elements.append(element)
        }
        let handle = SemanticObservationHandle(backend: backend, catalog: catalog, application: application,
            target: target, window: window, observationId: observationId,
            includeValues: params.includeValues, references: references, generation: generation)
        try handle.validateWindow(context: context)
        let axFinished = max(axStarted, milliseconds())
        let selection = params.axSelectors.map { selectors in
            AxSelectionEvidence(selectors: selectors, coverage: scan.complete && elements.count == eligible.count ? .complete : .partial,
                ambiguous: selectors.contains { selector in eligible.filter { matches($0.snapshot, selector: selector) }.count > 1 },
                visitedNodes: scan.visitedNodes)
        }
        let scoped = effectiveScope != .window || params.interactiveOnly || params.query != nil
        let observation = Observation(observationId: observationId, target: target.key,
            collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(axFinished, milliseconds())),
            windowBounds: target.bounds, accessibility: params.axSelectors == nil && !scoped && complete ? .complete : .partial,
            accessibilityCollected: CollectionInterval(startedUnixMs: axStarted, finishedUnixMs: axFinished),
            elements: elements, screenshot: nil, axSelection: selection)
        try context.check()
        return NativeObservation(observation: observation, handle: handle)
    }

    private func observeMenuBar(params: ObserveRequest, observationId: String, target: Target, application: any AXObject,
                                window: any AXObject, generation: ProcessGeneration?, started: UInt64, axStarted: UInt64,
                                context: OperationContext) throws -> NativeObservation {
        guard let menuBar = try backend.menuBar(of: application, context: context) else {
            let handle = SemanticObservationHandle(backend: backend, catalog: catalog, application: application,
                target: target, window: window, observationId: observationId,
                includeValues: params.includeValues, references: [:], generation: generation)
            try handle.validateWindow(context: context)
            let axFinished = max(axStarted, milliseconds())
            let selection = params.axSelectors.map {
                AxSelectionEvidence(selectors: $0, coverage: .unavailable, ambiguous: false, visitedNodes: 0)
            }
            let observation = Observation(observationId: observationId, target: target.key,
                collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(axFinished, milliseconds())),
                windowBounds: target.bounds, accessibility: .partial,
                accessibilityCollected: CollectionInterval(startedUnixMs: axStarted, finishedUnixMs: axFinished),
                elements: [], screenshot: nil, axSelection: selection)
            return NativeObservation(observation: observation, handle: handle)
        }

        var collected: [(object: any AXObject, snapshot: AXNodeSnapshot, pathLabel: String)] = []
        var visited: UInt32 = 0
        var complete = true
        func walkMenu(_ container: any AXObject, prefix: [String], depth: Int) throws {
            guard depth <= 6 else { complete = false; return }
            let children = try backend.children(of: container, limit: max(0, maxTreeNodes - Int(visited)), context: context)
            if !children.complete { complete = false }
            for child in children.elements {
                try context.check()
                guard Int(visited) < maxTreeNodes else { complete = false; return }
                visited += 1
                do {
                    guard let snap = try backend.snapshot(of: child, includeValue: false, context: context) else {
                        complete = false; continue
                    }
                    if snap.role == "AXMenu" {
                        try walkMenu(child, prefix: prefix, depth: depth)
                        continue
                    }
                    let segment = snap.title ?? snap.label ?? ""
                    guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let path = prefix + [segment]
                    if snap.role == "AXMenuItem" && path.count >= 2 {
                        let pathLabel = path.joined(separator: " > ")
                        let projected = AXNodeSnapshot(role: snap.role, title: pathLabel, label: pathLabel,
                            identifier: snap.identifier, bounds: snap.bounds, enabled: snap.enabled,
                            enabledKnown: snap.enabledKnown, value: nil, actions: snap.actions,
                            complete: snap.complete, subrole: snap.subrole, enabledUnsupported: snap.enabledUnsupported)
                        if let selectors = params.axSelectors {
                            if selectors.contains(where: { matches(projected, selector: $0) }) {
                                collected.append((child, projected, pathLabel))
                            }
                        } else if let query = params.query {
                            if matchesQuery(projected, query: query, includeValues: false) {
                                collected.append((child, projected, pathLabel))
                            }
                        } else {
                            collected.append((child, projected, pathLabel))
                        }
                    }
                    if snap.role == "AXMenuBarItem" || snap.role == "AXMenuItem" {
                        try walkMenu(child, prefix: path, depth: depth + 1)
                    }
                } catch is AXReadUnavailable { complete = false }
                catch let error as NativeFailure where error.code == .staleElement || error.code == .nativeFailed { complete = false }
            }
        }
        try walkMenu(menuBar, prefix: [], depth: 0)

        var elements: [Element] = []
        var encodedBytes = 0
        let encoder = JSONEncoder()
        for item in collected {
            if elements.count == Limits.maxElements { complete = false; break }
            let s = item.snapshot
            let label = bounded(item.pathLabel, bytes: 1024)
            let identifier = bounded(s.identifier, bytes: 1024)
            let subrole = bounded(s.subrole, bytes: 1024)
            if label != item.pathLabel || identifier != s.identifier || subrole != s.subrole {
                complete = false
                if label != item.pathLabel, params.axSelectors != nil { continue }
            }
            let element = Element(reference: "menu-\(UUID().uuidString)", role: s.role, label: label, value: nil,
                                  bounds: s.bounds, enabled: s.enabledKnown ? s.enabled : nil, actions: [],
                                  identifier: identifier, subrole: subrole, url: nil)
            let size = try encoder.encode(element).count
            if encodedBytes + size > 2 * 1024 * 1024 { complete = false; break }
            encodedBytes += size
            elements.append(element)
        }
        let handle = SemanticObservationHandle(backend: backend, catalog: catalog, application: application,
            target: target, window: window, observationId: observationId,
            includeValues: params.includeValues, references: [:], generation: generation)
        try handle.validateWindow(context: context)
        let axFinished = max(axStarted, milliseconds())
        let selection = params.axSelectors.map { selectors in
            AxSelectionEvidence(selectors: selectors, coverage: complete && elements.count == collected.count ? .complete : .partial,
                ambiguous: selectors.contains { selector in collected.filter { matches($0.snapshot, selector: selector) }.count > 1 },
                visitedNodes: visited)
        }
        let observation = Observation(observationId: observationId, target: target.key,
            collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(axFinished, milliseconds())),
            windowBounds: target.bounds, accessibility: .partial,
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

/// Fail-closed browser/AX window title compatibility.
/// Supports exact matches, Chromium-style `" - <Browser/Profile>"` suffixes on `AXTitle`,
/// and macOS WindowServer middle-ellipsis truncation (`"prefix…suffix"`) on `CGWindowName`.
func axTitleCompatible(axTitle: String?, cgTitle: String?) -> Bool {
    guard let axTitle, !axTitle.isEmpty, let cgTitle, !cgTitle.isEmpty else { return true }
    if axTitle == cgTitle { return true }
    if axTitle.hasPrefix(cgTitle + " - ") { return true }
    // WindowServer middle-truncates very long CGWindow titles with a single U+2026 ellipsis.
    if let ellipsis = cgTitle.firstIndex(of: "\u{2026}") {
        let afterEllipsis = cgTitle.index(after: ellipsis)
        let prefix = cgTitle[..<ellipsis]
        let suffix = cgTitle[afterEllipsis...]
        if !suffix.contains("\u{2026}"), prefix.count >= 4, suffix.count >= 4, axTitle.hasPrefix(prefix) {
            let searchStart = axTitle.index(axTitle.startIndex, offsetBy: prefix.count)
            var cursor = searchStart
            while let match = axTitle.range(of: suffix, range: cursor..<axTitle.endIndex) {
                let tail = axTitle[match.upperBound...]
                if tail.isEmpty || tail.hasPrefix(" - ") { return true }
                cursor = match.upperBound
            }
        }
    }
    return false
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
              snapshot.bounds == target.bounds, axTitleCompatible(axTitle: snapshot.title, cgTitle: target.title) else { continue }
        matches.append(ResolvedAXElement(object: window, snapshot: snapshot))
    }
    guard matches.count == 1 else {
        throw NativeFailure(matches.isEmpty ? .targetNotFound : .ambiguousTarget,
                            matches.isEmpty ? "no exact AX window metadata association" : "multiple AX windows have matching metadata")
    }
    let selected = matches[0]
    guard !siblings.contains(where: {
        $0.key != target.key && $0.bounds == selected.snapshot.bounds && axTitleCompatible(axTitle: selected.snapshot.title, cgTitle: $0.title)
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
    for _ in 0..<maxSelectiveTreeDepth {
        guard let parent = try backend.parent(of: current, context: context),
              !ancestors.contains(where: { backend.same($0, parent) }) else { break }
        if backend.same(parent, window) { return }
        ancestors.append(parent); current = parent
    }
    throw NativeFailure(.staleElement, "AX owning-window identity is unavailable")
}

private func collectTree(roots: [any AXObject]? = nil, window: any AXObject, pid: UInt32, backend: any AXReading,
                         includeValues: Bool, selectors: [CUAProtocol.Selector]? = nil, application: (any AXObject)? = nil,
                         visibleIn windowBounds: Rect? = nil, context: OperationContext) throws -> AXTreeSnapshot {
    let depthLimit = selectors == nil ? maxTreeDepth : maxSelectiveTreeDepth
    let focusPath: [any AXObject]
    if selectors != nil, let application {
        focusPath = try optionalTopologyRead {
            guard let focus = try backend.focusedElement(of: application, context: context) else { return [] }
            return try parentPath(from: focus, to: window, backend: backend, context: context)
        } ?? []
    } else {
        focusPath = []
    }
    typealias PendingNode = (object: any AXObject, depth: Int)
    let initialRoots = roots ?? [window]
    var pending: [PendingNode] = initialRoots.reversed().map { ($0, 0) }
    var deferred: [PendingNode] = []
    var seen: [any AXObject] = []
    var nodes: [ResolvedAXElement] = []
    var clippedNodes: [ResolvedAXElement] = []
    var complete = true

    func enqueueDeferred(_ children: ArraySlice<any AXObject>, depth: Int) {
        // Lower-priority work must not reserve the budget for undiscovered visible descendants.
        let capacity = maxTreeNodes - deferred.count
        if children.count > capacity { complete = false }
        for child in children.prefix(capacity).reversed() { deferred.append((child, depth)) }
    }
    func enqueueChildren(of object: any AXObject, depth: Int, clipped: Bool) throws {
        let children = try backend.children(of: object, limit: max(0, maxTreeNodes - seen.count - pending.count), context: context)
        if !children.complete { complete = false }
        guard depth < depthLimit else {
            if !children.elements.isEmpty { complete = false }
            return
        }
        // The focus is only a traversal hint. All refs still come from walking the exact window tree.
        var ordered = children.elements
        if let parent = focusPath.firstIndex(where: { backend.same($0, object) }), parent > 0,
           let branch = ordered.firstIndex(where: { backend.same($0, focusPath[parent - 1]) }), branch > 0 {
            let preferred = ordered.remove(at: branch)
            ordered.insert(preferred, at: 0)
        }
        let childDepth = depth + 1
        if clipped {
            enqueueDeferred(ordered[...], depth: childDepth)
        } else if windowBounds != nil, ordered.count > activeSiblingBatch {
            // Sample both edges of a wide sibling list before its interior. This keeps
            // long history lists from starving adjacent branches or controls at the end.
            let edge = activeSiblingBatch / 2
            enqueueDeferred(ordered[edge..<(ordered.count - edge)], depth: childDepth)
            for child in ordered.suffix(edge).reversed() { pending.append((child, childDepth)) }
            for child in ordered.prefix(edge).reversed() { pending.append((child, childDepth)) }
        } else {
            for child in ordered.reversed() { pending.append((child, childDepth)) }
        }
    }
    while let (object, depth) = pending.popLast() ?? deferred.popLast() {
        try context.check()
        if seen.contains(where: { backend.same($0, object) }) { complete = false; continue }
        guard seen.count < maxTreeNodes else { complete = false; break }
        seen.append(object)
        do {
            try requireOwningWindow(object, window: window, pid: pid, backend: backend, context: context)
            var clipped = false
            if selectors != nil, let windowBounds, depth > 0,
               let bounds = try optionalTopologyRead({ try backend.bounds(of: object, context: context) }) {
                clipped = isClipped(bounds, to: windowBounds)
            }
            func append(_ snapshot: AXNodeSnapshot) {
                let resolved = ResolvedAXElement(object: object, snapshot: snapshot)
                if clipped { clippedNodes.append(resolved) }
                else { nodes.append(resolved) }
            }
            if let selectors {
                guard let identity = try backend.identity(of: object, context: context) else {
                    complete = false
                    try enqueueChildren(of: object, depth: depth, clipped: clipped)
                    continue
                }
                let candidates = selectors.filter {
                    ($0.role == nil || $0.role == identity.role) && ($0.identifier == nil || $0.identifier == identity.identifier)
                }
                if !candidates.isEmpty {
                    if var snapshot = try backend.snapshot(of: object, includeValue: false, context: context) {
                        if snapshot.identity != identity { complete = false }
                        else {
                            if snapshot.label == nil && !snapshot.complete && candidates.contains(where: { $0.label != nil || $0.labelContains != nil }) { complete = false }
                            if candidates.contains(where: { matches(snapshot, selector: $0) }) {
                                if includeValues {
                                    guard let withValue = try backend.snapshot(of: object, includeValue: true, context: context) else {
                                        complete = false; continue
                                    }
                                    snapshot = withValue
                                }
                                if snapshot.identity == identity && candidates.contains(where: { matches(snapshot, selector: $0) }) {
                                    append(snapshot)
                                } else { complete = false }
                            }
                        }
                    } else { complete = false }
                }
            } else if let snapshot = try backend.snapshot(of: object, includeValue: includeValues, context: context) {
                if let windowBounds, depth > 0 { clipped = isClipped(snapshot.bounds, to: windowBounds) }
                append(snapshot)
                if !snapshot.complete { complete = false }
            } else { complete = false }
            try enqueueChildren(of: object, depth: depth, clipped: clipped)
        } catch is AXReadUnavailable {
            // Keep readable siblings without claiming that the unreadable subtree is absent.
            complete = false
        } catch let error as NativeFailure where error.code == .staleElement || error.code == .nativeFailed {
            complete = false
        }
    }
    return AXTreeSnapshot(nodes: nodes + clippedNodes, complete: complete, visitedNodes: UInt32(seen.count))
}

private let interactiveRoles: Set<String> = [
    "AXWebArea", "AXLink", "AXButton", "AXTextField", "AXTextArea", "AXSearchField",
    "AXComboBox", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
    "AXTabButton", "AXTabGroup", "AXSlider", "AXIncrementor", "AXScrollArea",
    "AXToolbar", "AXMenuItem", "AXDisclosureTriangle",
]

private let landmarkRoles: Set<String> = [
    "AXHeading", "AXList", "AXTable", "AXSheet", "AXDialog", "AXOutline",
]

private func isInteractiveElement(_ snapshot: AXNodeSnapshot) -> Bool {
    interactiveRoles.contains(snapshot.role)
        || snapshot.valueSettable
        || snapshot.selectedTextSettable
        || snapshot.actions.contains("AXPress")
        || snapshot.actions.contains("AXConfirm")
        || snapshot.actions.contains("AXShowMenu")
        || snapshot.actions.contains("AXCancel")
}

/// When an unfiltered observation exceeds `limit`, retain visible interactive controls
/// and web roots ahead of dense non-interactive text/cell runs while keeping document order.
func selectElementsForBudget(_ nodes: [ResolvedAXElement], limit: Int, windowBounds: Rect?) -> [ResolvedAXElement] {
    guard nodes.count > limit, limit > 0 else { return Array(nodes.prefix(max(0, limit))) }
    var tiers: [[Int]] = [[], [], [], [], []]
    for (index, node) in nodes.enumerated() {
        let clipped = windowBounds.map { isClipped(node.snapshot.bounds, to: $0) } ?? false
        let interactive = isInteractiveElement(node.snapshot)
        let tier: Int
        if !clipped && interactive { tier = 0 }
        else if !clipped && landmarkRoles.contains(node.snapshot.role) { tier = 1 }
        else if !clipped { tier = 2 }
        else if interactive { tier = 3 }
        else { tier = 4 }
        tiers[tier].append(index)
    }
    var chosen: [Int] = []
    chosen.reserveCapacity(limit)
    for bucket in tiers {
        let remaining = limit - chosen.count
        if remaining <= 0 { break }
        chosen.append(contentsOf: bucket.prefix(remaining))
    }
    chosen.sort()
    return chosen.map { nodes[$0] }
}

private func isClipped(_ element: Rect, to window: Rect) -> Bool {
    let width = min(element.x + element.width, window.x + window.width) - max(element.x, window.x)
    let height = min(element.y + element.height, window.y + window.height) - max(element.y, window.y)
    return width <= 1 || height <= 1
}

func matches(_ snapshot: AXNodeSnapshot, selector: CUAProtocol.Selector) -> Bool {
    (selector.role == nil || snapshot.role == selector.role)
        && (selector.identifier == nil || selector.identifier == snapshot.identifier)
        && (selector.label == nil || selector.label == snapshot.label)
        && (selector.labelContains == nil || (snapshot.label?.contains(selector.labelContains!) == true))
}

func matchesQuery(_ snapshot: AXNodeSnapshot, query: String, includeValues: Bool) -> Bool {
    let fields: [String?] = includeValues
        ? [snapshot.label, snapshot.title, snapshot.identifier, snapshot.subrole, snapshot.url, snapshot.value]
        : [snapshot.label, snapshot.title, snapshot.identifier, snapshot.subrole, snapshot.url]
    return fields.contains { $0?.range(of: query, options: .caseInsensitive) != nil }
}

/// Membership needs current identities/children, not a second full attribute read of every sibling.
private func containsRetainedObject(_ sought: any AXObject, window: any AXObject, backend: any AXReading,
                                    context: OperationContext) throws -> Bool {
    if let connected = try optionalTopologyRead({
        guard let path = try parentPath(from: sought, to: window, backend: backend, context: context) else { return false }
        var remaining = maxTreeNodes
        for (child, parent) in zip(path, path.dropFirst()) {
            let children = try backend.children(of: parent, limit: remaining, context: context)
            guard children.elements.contains(where: { backend.same($0, child) }) else { return false }
            remaining -= children.elements.count
        }
        return true
    }), connected { return true }

    var pending: [(any AXObject, Int)] = [(window, 0)]
    var seen: [any AXObject] = []
    while let (object, depth) = pending.popLast() {
        try context.check()
        if seen.contains(where: { backend.same($0, object) }) { continue }
        guard seen.count < maxTreeNodes else { return false }
        seen.append(object)
        if backend.same(object, sought) { return true }
        if depth >= maxSelectiveTreeDepth { continue }
        let children = try backend.children(of: object, limit: max(0, maxTreeNodes - seen.count - pending.count), context: context)
        for child in children.elements.reversed() { pending.append((child, depth + 1)) }
    }
    return false
}

private func parentPath(from object: any AXObject, to window: any AXObject, backend: any AXReading,
                        context: OperationContext) throws -> [any AXObject]? {
    var path = [object]
    var current = object
    for _ in 0..<maxSelectiveTreeDepth {
        if backend.same(current, window) { return path }
        guard let parent = try backend.parent(of: current, context: context),
              !path.contains(where: { backend.same($0, parent) }) else { return nil }
        path.append(parent)
        current = parent
    }
    return backend.same(current, window) ? path : nil
}

private func optionalTopologyRead<T>(_ read: () throws -> T?) throws -> T? {
    do { return try read() }
    catch is AXReadUnavailable { return nil }
    catch let error as NativeFailure where error.code == .staleElement || error.code == .nativeFailed { return nil }
}

private func milliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
private func bounded(_ string: String?, bytes: Int) -> String? {
    string.flatMap { $0.utf8.count <= bytes ? $0 : nil }
}
private func boundedNonEmpty(_ string: String?, bytes: Int) -> String? {
    string.flatMap { !$0.isEmpty && $0.utf8.count <= bytes ? $0 : nil }
}
