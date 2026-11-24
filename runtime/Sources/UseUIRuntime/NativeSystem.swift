import AppKit
import ApplicationServices
import UseUIProtocol
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol AppOpening: Sendable {
    func open(_ request: OpenRequest, catalog: any WindowCatalog, context: OperationContext) throws -> OpenResult
}

public protocol ClipboardManaging: Sendable {
    func perform(_ request: ClipboardRequest, context: OperationContext) throws -> ClipboardResult
}

public protocol NativeSystem: Sendable {
    func permissions(context: OperationContext) throws -> Permissions
    func supportedActions(permissions: Permissions) -> [ActionKind]
    func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult
    func window(_ key: TargetKey, context: OperationContext) throws -> Target
    func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)?
    func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation
    func open(_ request: OpenRequest, context: OperationContext) throws -> OpenResult
    func clipboard(_ request: ClipboardRequest, context: OperationContext) throws -> ClipboardResult
    func configureObservationWorker(_ queue: DispatchQueue)
    func shutdownObservations()
}

public extension NativeSystem {
    func supportedActions(permissions: Permissions) -> [ActionKind] { [] }
    func open(_ request: OpenRequest, context: OperationContext) throws -> OpenResult {
        throw NativeFailure(.unsupported, "open is unavailable for this backend")
    }
    func clipboard(_ request: ClipboardRequest, context: OperationContext) throws -> ClipboardResult {
        throw NativeFailure(.unsupported, "clipboard is unavailable for this backend")
    }
    func configureObservationWorker(_ queue: DispatchQueue) {}
    func shutdownObservations() {}
    func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation {
        guard params.eventHistory == nil else { throw NativeFailure(.unsupported, "event retention is unavailable for this backend") }
        guard !params.includeScreenshot && !params.includeOcr else { throw NativeFailure(.unsupported, "visual observation is unavailable for this backend") }
        let start = nativeMilliseconds()
        let before = try window(params.target, context: context)
        let handle = try retainApplication(pid: params.target.pid, timeoutSeconds: context.nativeTimeoutSeconds(), context: context)
        let after = try window(params.target, context: context)
        guard before.bounds == after.bounds, before.bundleId == after.bundleId else {
            throw NativeFailure(.staleObservation, "window changed during lifecycle collection")
        }
        try context.check()
        return NativeObservation(observation: unavailableObservation(id: observationId, target: after, started: start, selectors: params.axSelectors), handle: handle)
    }
}

public struct MacOSSystem: NativeSystem {
    private let backend: any AXReading
    private let catalog: any WindowCatalog
    private let visual: any VisualCapturing
    private let opener: any AppOpening
    private let clipboardManager: any ClipboardManaging
    private let isAXTrusted: @Sendable () -> Bool
    private let eventRegistry = TargetEventRegistry()

    public init(backend: any AXReading = MacOSAXBackend(), catalog: any WindowCatalog = MacOSWindowCatalog()) {
        self.init(backend: backend, catalog: catalog, visual: ScreenWindowCapture(), opener: MacOSAppOpener(),
                  clipboardManager: MacOSClipboardManager(), isAXTrusted: { AXIsProcessTrusted() })
    }

    init(backend: any AXReading, catalog: any WindowCatalog, visual: any VisualCapturing,
         opener: any AppOpening = MacOSAppOpener(),
         clipboardManager: any ClipboardManaging = MacOSClipboardManager(),
         isAXTrusted: @escaping @Sendable () -> Bool) {
        self.backend = backend
        self.catalog = catalog
        self.visual = visual
        self.opener = opener
        self.clipboardManager = clipboardManager
        self.isAXTrusted = isAXTrusted
    }
    public func permissions(context: OperationContext) throws -> Permissions {
        try context.check()
        let value = Permissions(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(),
                                inputPosting: CGPreflightPostEventAccess())
        try context.check()
        return value
    }
    public func supportedActions(permissions: Permissions) -> [ActionKind] {
        guard permissions.accessibility else { return [] }
        var supported: [ActionKind] = backend is any AXMutating
            ? [.setValue, .press, .typeText, .scrollToVisible, .confirm, .showMenu, .cancel, .invokeMenu, .setWindowFrame, .windowAction]
            : []
        if backend is any AXScrolling { supported.append(.scroll) }
        return supported
    }
    public func open(_ request: OpenRequest, context: OperationContext) throws -> OpenResult {
        try opener.open(request, catalog: catalog, context: context)
    }
    public func clipboard(_ request: ClipboardRequest, context: OperationContext) throws -> ClipboardResult {
        try clipboardManager.perform(request, context: context)
    }
    public func shutdownObservations() { eventRegistry.shutdown() }
    public func configureObservationWorker(_ queue: DispatchQueue) { eventRegistry.configure(worker: queue) }
    public func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult { try catalog.targets(request, context: context) }
    public func window(_ key: TargetKey, context: OperationContext) throws -> Target { try catalog.window(key, context: context) }
    public func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)? {
        guard AXIsProcessTrusted() else { return nil }
        return try backend.application(pid: pid, context: context)
    }
    public func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation {
        let wantsVisual = params.includeScreenshot || params.includeOcr
        let started = nativeMilliseconds()
        let window = try catalog.windowSnapshot(params.target, context: context)
        let semantic: NativeObservation
        if isAXTrusted() {
            let ax = ObserveRequest(target: params.target, includeScreenshot: false, includeValues: params.includeValues,
                                    axSelectors: params.axSelectors, scope: params.scope, interactiveOnly: params.interactiveOnly,
                                    query: params.query)
            do {
                semantic = try SemanticAXObserver(backend: backend, catalog: catalog).observe(
                    params: ax, observationId: observationId, target: window.target,
                    generation: window.generation, context: context)
            } catch let failure where (wantsVisual || window.target.bundleId == nil) && axUnavailable(failure) {
                let attempted = CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, nativeMilliseconds()))
                semantic = observeWindowOnly(window.target, id: observationId, started: started,
                                             accessibilityCollected: attempted, selectors: params.axSelectors)
            }
        } else {
            semantic = observeWindowOnly(window.target, id: observationId, started: started, selectors: params.axSelectors)
        }
        let observed = try retainingEvents(params: params, native: semantic, context: context)
        guard wantsVisual else { return observed }
        let (evidence, screenshot) = try collectVisual(params: params, semantic: observed.observation,
                                                      window: window, context: context)
        let ax = observed.observation
        let observation = Observation(observationId: ax.observationId, target: ax.target,
            collected: CollectionInterval(
                startedUnixMs: min(ax.collected.startedUnixMs, evidence.collected.startedUnixMs,
                                  evidence.ocr?.collected?.startedUnixMs ?? evidence.collected.startedUnixMs),
                finishedUnixMs: max(ax.collected.finishedUnixMs, evidence.collected.finishedUnixMs,
                                   evidence.ocr?.collected?.finishedUnixMs ?? evidence.collected.finishedUnixMs)
            ),
            windowBounds: ax.windowBounds, accessibility: ax.accessibility, accessibilityCollected: ax.accessibilityCollected,
            elements: ax.elements, screenshot: screenshot, visual: evidence, axSelection: ax.axSelection, events: ax.events)
        try context.check()
        let visualHandle: VisualObservationHandle?
        if observed.handle == nil, observation.accessibility == .unavailable, evidence.captureStatus == .captured,
           evidence.frame?.captureWindowBounds == window.target.bounds, window.generation != nil {
            visualHandle = VisualObservationHandle(window: window, catalog: catalog, observationId: observationId)
        } else {
            visualHandle = nil
        }
        return NativeObservation(observation: observation, handle: observed.handle ?? visualHandle)
    }

    private func retainingEvents(params: ObserveRequest, native: NativeObservation, context: OperationContext) throws -> NativeObservation {
        guard let request = params.eventHistory else { return native }
        guard let selectors = params.axSelectors else { throw NativeFailure(.invalidRequest, "event retention requires AX selectors") }
        let history: EventHistory
        if let handle = native.handle as? SemanticObservationHandle {
            let tracker = try eventRegistry.track(handle: handle, observation: native.observation, selectors: selectors, context: context)
            handle.eventTracker = tracker
            history = try tracker.history(after: request.cursor, includeValues: params.includeValues, context: context)
        } else {
            let now = nativeMilliseconds()
            history = EventHistory(cursor: EventCursor(generation: UUID().uuidString, sequence: 0), oldestSequence: nil,
                startedUnixMs: now, collected: CollectionInterval(startedUnixMs: now, finishedUnixMs: now),
                stale: request.cursor != nil, overrun: false, mode: .unavailable, coalescedWakes: 0, events: [])
        }
        let old = native.observation
        let observation = Observation(observationId: old.observationId, target: old.target,
            collected: CollectionInterval(startedUnixMs: old.collected.startedUnixMs,
                finishedUnixMs: max(old.collected.finishedUnixMs, history.collected.finishedUnixMs)),
            windowBounds: old.windowBounds, accessibility: old.accessibility, accessibilityCollected: old.accessibilityCollected,
            elements: old.elements, screenshot: old.screenshot, visual: old.visual, axSelection: old.axSelection, events: history)
        try context.check()
        return NativeObservation(observation: observation, handle: native.handle)
    }

    private func observeWindowOnly(_ target: Target, id: String, started: UInt64,
                                   accessibilityCollected: CollectionInterval? = nil, selectors: [UseUIProtocol.Selector]? = nil) -> NativeObservation {
        NativeObservation(observation: unavailableObservation(
            id: id, target: target, started: started, accessibilityCollected: accessibilityCollected, selectors: selectors), handle: nil)
    }

    private func collectVisual(params: ObserveRequest, semantic: Observation, window: WindowSnapshot,
                               context: OperationContext) throws -> (VisualEvidence, Screenshot?) {
        let started = nativeMilliseconds()
        func missing(_ status: CaptureStatus, collected: CollectionInterval? = nil) throws -> (VisualEvidence, Screenshot?) {
            try context.check()
            let interval = collected ?? CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, nativeMilliseconds()))
            let ocr = params.includeOcr ? OcrEvidence(status: .unavailable, collected: nil, matches: []) : nil
            return (VisualEvidence(captureStatus: status, collected: interval, geometryMatchesAX: nil, frame: nil, ocr: ocr), nil)
        }

        let captured: CapturedVisual
        do {
            let before = try catalog.windowSnapshot(params.target, context: context)
            guard window.generation == before.generation, window.target.bundleId == before.target.bundleId else {
                return try missing(.unavailable)
            }
            captured = try visual.capture(target: before.target, crop: params.cropWindow,
                                          maxDimension: Int(params.maxImageDimensionPx ?? 1600), context: context)
            let after = try catalog.windowSnapshot(params.target, context: context)
            guard before.generation == after.generation, before.target.bundleId == after.target.bundleId else {
                return try missing(.unavailable)
            }
            guard before.target.bounds == captured.frame.captureWindowBounds,
                  after.target.bounds == captured.frame.captureWindowBounds else { return try missing(.geometryChanged) }
        } catch let failure as VisualCaptureFailure {
            return try missing(failure.status, collected: failure.collected)
        } catch let failure as NativeFailure where failure.code == .targetNotFound {
            return try missing(.unavailable)
        }
        let frame = captured.frame
        let screenshot: Screenshot?
        if params.includeScreenshot {
            guard let data = jpegData(captured.image) else { return try missing(.failed) }
            screenshot = Screenshot(mimeType: .jpeg, widthPx: frame.widthPx, heightPx: frame.heightPx,
                dataBase64: data.base64EncodedString(), imageToScreen: frame.imageToScreen, collected: captured.collected)
        } else {
            screenshot = nil
        }
        let ocr = params.includeOcr ? try VisualOCR().recognize(image: captured.image, query: params.ocrQuery, context: context) : nil
        let matchesAX = semantic.accessibility == .unavailable ? nil : semantic.windowBounds == frame.captureWindowBounds
        return (VisualEvidence(captureStatus: .captured, collected: captured.collected,
                               geometryMatchesAX: matchesAX, frame: frame, ocr: ocr), screenshot)
    }
}

private func axUnavailable(_ failure: any Error) -> Bool {
    if failure is AXReadUnavailable { return true }
    switch (failure as? NativeFailure)?.code {
    case .ambiguousTarget, .targetNotFound, .staleObservation, .staleElement, .nativeFailed, .permissionDenied: return true
    default: return false
    }
}

func jpegData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    guard CGImageDestinationFinalize(output), data.length <= Limits.maxImageBytes else { return nil }
    return data as Data
}

/// A public process-birth/image signature, not a full exec generation (same-image exec is indistinguishable).
struct ProcessGeneration: Equatable, Sendable {
    let startAbstime: UInt64
    let executableUUID: UUID

    static func live(_ info: rusage_info_v0, status: Int32) -> ProcessGeneration? {
        // Images without an LC_UUID are unavailable; birth alone does not identify an executable image.
        guard status == 0, info.ri_proc_start_abstime > 0, info.ri_proc_exit_abstime == 0,
              withUnsafeBytes(of: info.ri_uuid, { $0.contains { $0 != 0 } }) else { return nil }
        return ProcessGeneration(startAbstime: info.ri_proc_start_abstime, executableUUID: UUID(uuid: info.ri_uuid))
    }
}

/// Only immutable app metadata is retained. Every use rechecks the live kernel signature.
struct WindowProcessOwner: Sendable {
    let generation: ProcessGeneration
    let bundleId: String?
}

/// A verified live owner can lack AppKit bundle metadata.
final class WindowProcessResolver: @unchecked Sendable {
    private struct Entry: Sendable { let generation: ProcessGeneration; let bundle: String; let createdAt: UInt64 }
    private let lock = NSLock()
    private var entries: [UInt32: Entry] = [:]
    private var order: [UInt32] = []
    private let generation: @Sendable (UInt32) -> ProcessGeneration?
    private let metadata: @Sendable ([UInt32]) -> [UInt32: String]
    private let now: @Sendable () -> UInt64
    private let capacity: Int
    private let lifetime: UInt64

    convenience init() { self.init(generation: Self.nativeGeneration, metadata: Self.nativeMetadata) }
    init(generation: @escaping @Sendable (UInt32) -> ProcessGeneration?,
         metadata: @escaping @Sendable ([UInt32]) -> [UInt32: String],
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         capacity: Int = 256, lifetime: UInt64 = 60_000_000_000) {
        self.generation = generation; self.metadata = metadata; self.now = now
        self.capacity = capacity; self.lifetime = lifetime
    }

    func resolve(_ pids: [UInt32]) -> [UInt32: WindowProcessOwner] {
        lock.lock(); pruneLocked(); let cached = entries; lock.unlock()
        var signatures: [UInt32: ProcessGeneration] = [:]
        var bundles: [UInt32: String] = [:]
        var missing: [UInt32] = []
        for pid in pids {
            guard let current = generation(pid) else { remove(pid); continue }
            signatures[pid] = current
            if let entry = cached[pid], entry.generation == current { bundles[pid] = entry.bundle }
            else { remove(pid); missing.append(pid) }
        }
        let discovered = missing.isEmpty ? [:] : metadata(missing)
        for pid in pids {
            guard let before = signatures[pid], let after = generation(pid), before == after else {
                signatures.removeValue(forKey: pid); bundles.removeValue(forKey: pid); remove(pid); continue
            }
            if bundles[pid] == nil, let bundle = discovered[pid], !bundle.isEmpty {
                bundles[pid] = bundle
                lock.lock(); pruneLocked()
                order.removeAll { $0 == pid }
                while order.count >= capacity { entries.removeValue(forKey: order.removeFirst()) }
                entries[pid] = Entry(generation: before, bundle: bundle, createdAt: now())
                order.append(pid); lock.unlock()
            }
        }
        let checkedAt = now()
        for (pid, entry) in cached where bundles[pid] != nil && entry.generation == signatures[pid] {
            if checkedAt >= entry.createdAt && checkedAt - entry.createdAt >= lifetime {
                signatures.removeValue(forKey: pid); bundles.removeValue(forKey: pid); remove(pid)
            }
        }
        return Dictionary(uniqueKeysWithValues: signatures.map { pid, generation in
            (pid, WindowProcessOwner(generation: generation, bundleId: bundles[pid]))
        })
    }

    private func remove(_ pid: UInt32) {
        lock.lock(); entries.removeValue(forKey: pid); order.removeAll { $0 == pid }; lock.unlock()
    }
    private func pruneLocked() {
        let current = now()
        order.removeAll { pid in
            guard let entry = entries[pid] else { return true }
            if current >= entry.createdAt && current - entry.createdAt >= lifetime {
                entries.removeValue(forKey: pid); return true
            }
            return false
        }
    }
    private static func nativeGeneration(_ pid: UInt32) -> ProcessGeneration? {
        guard pid > 0, pid <= UInt32(Int32.max) else { return nil }
        var info = rusage_info_v0()
        let status = withUnsafeMutableBytes(of: &info) { bytes in
            proc_pid_rusage(pid_t(pid), RUSAGE_INFO_V0, bytes.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        return ProcessGeneration.live(info, status: status)
    }
    private static func nativeMetadata(_ pids: [UInt32]) -> [UInt32: String] {
        let snapshot: @Sendable () -> [UInt32: String] = {
            var bundles: [UInt32: String] = [:]
            for pid in pids {
                guard pid > 0, pid <= UInt32(Int32.max),
                      let application = NSRunningApplication(processIdentifier: pid_t(pid)),
                      let bundle = application.bundleIdentifier, !bundle.isEmpty else { continue }
                bundles[pid] = bundle
            }
            return bundles
        }
        return Thread.isMainThread ? snapshot() : DispatchQueue.main.sync(execute: snapshot)
    }
}

public struct MacOSWindowCatalog: WindowCatalog {
    private let readWindows: @Sendable () throws -> [[String: Any]]
    private let readAllWindows: (@Sendable () throws -> [[String: Any]])?
    private let readProcessOwners: @Sendable ([UInt32]) -> [UInt32: WindowProcessOwner]
    private let readApps: @Sendable () -> [AppInfo]
    private let readDisplays: @Sendable () -> [DisplayInfo]

    public init() {
        let resolver = WindowProcessResolver()
        let copyRecords: @Sendable (CGWindowListOption) throws -> [[String: Any]] = { options in
            guard let records = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
                throw NativeFailure(.nativeFailed, "window enumeration unavailable")
            }
            // The runtime’s optional nonactivating panel is presentation, outside the target catalog.
            let runtimePID = UInt32(getpid())
            return records.filter { ($0[kCGWindowOwnerPID as String] as? UInt32) != runtimePID }
        }
        self.init(
            windowRecords: { try copyRecords([.optionOnScreenOnly, .excludeDesktopElements]) },
            processOwners: resolver.resolve,
            allWindowRecords: { try copyRecords([.optionAll, .excludeDesktopElements]) },
            apps: Self.nativeApps,
            displays: Self.nativeDisplays
        )
    }

    init(windowRecords: @escaping @Sendable () throws -> [[String: Any]],
         processOwners: @escaping @Sendable ([UInt32]) -> [UInt32: WindowProcessOwner],
         allWindowRecords: (@Sendable () throws -> [[String: Any]])? = nil,
         apps: @escaping @Sendable () -> [AppInfo] = MacOSWindowCatalog.nativeApps,
         displays: @escaping @Sendable () -> [DisplayInfo] = MacOSWindowCatalog.nativeDisplays) {
        readWindows = windowRecords
        readProcessOwners = processOwners
        readAllWindows = allWindowRecords
        readApps = apps
        readDisplays = displays
    }

    public func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult {
        let (windows, owners, onScreenIDs) = try snapshot(includeOffscreen: request.includeOffscreen, context: context)
        var result: [Target] = []
        var truncated = false
        for record in windows {
            try context.check()
            guard let pid = record[kCGWindowOwnerPID as String] as? UInt32,
                  let owner = owners[pid],
                  request.bundleId == nil || owner.bundleId == request.bundleId,
                  !request.unbundledOnly || owner.bundleId == nil,
                  let windowId = record[kCGWindowNumber as String] as? UInt32 else { continue }
            let onScreen: Bool? = request.includeOffscreen ? onScreenIDs.contains(windowId) : nil
            guard let target = target(record, bundleId: owner.bundleId, onScreen: onScreen),
                  contains(request.titleContains, in: target.title),
                  contains(request.ownerContains, in: record[kCGWindowOwnerName as String] as? String) else { continue }
            if result.count == Limits.maxTargets { truncated = true; break }
            result.append(target)
        }
        try context.check()
        let apps: [AppInfo]?
        if request.includeApps {
            let filtered = readApps().filter { app in
                (request.bundleId == nil || app.bundleId == request.bundleId)
                    && (!request.unbundledOnly || app.bundleId == nil)
                    && contains(request.ownerContains, in: app.name)
            }
            apps = Array(filtered.prefix(Limits.maxTargets))
        } else {
            apps = nil
        }
        try context.check()
        let displays: [DisplayInfo]? = request.includeDisplays ? Array(readDisplays().prefix(32)) : nil
        try context.check()
        return TargetsResult(targets: result, truncated: truncated, apps: apps, displays: displays)
    }
    private func contains(_ query: String?, in value: String?) -> Bool {
        guard let query else { return true }
        return value?.range(of: query, options: .caseInsensitive) != nil
    }
    public func window(_ key: TargetKey, context: OperationContext) throws -> Target {
        try windowSnapshot(key, context: context).target
    }
    public func windowSnapshot(_ key: TargetKey, context: OperationContext) throws -> WindowSnapshot {
        let (windows, owners, _) = try snapshot(includeOffscreen: false, context: context)
        for record in windows {
            try context.check()
            guard (record[kCGWindowNumber as String] as? UInt32) == key.windowId,
                  (record[kCGWindowOwnerPID as String] as? UInt32) == key.pid,
                  (record[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let owner = owners[key.pid] else {
                throw NativeFailure(.nativeFailed, "process metadata unavailable for exact window")
            }
            guard let value = target(record, bundleId: owner.bundleId) else {
                throw NativeFailure(.nativeFailed, "exact window metadata unavailable")
            }
            return WindowSnapshot(target: value, generation: owner.generation)
        }
        throw NativeFailure(.targetNotFound, "exact visible window/process pair not found")
    }
    public func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] {
        let (windows, owners, _) = try snapshot(includeOffscreen: false, context: context)
        guard let owner = owners[pid] else {
            throw NativeFailure(.nativeFailed, "process metadata unavailable for window association")
        }
        var result: [Target] = []
        for record in windows {
            try context.check()
            guard (record[kCGWindowOwnerPID as String] as? UInt32) == pid,
                  (record[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let value = target(record, bundleId: owner.bundleId) else {
                throw NativeFailure(.ambiguousTarget, "process window metadata is incomplete")
            }
            guard result.count < 1024 else { throw NativeFailure(.ambiguousTarget, "process window catalog exceeds association bound") }
            result.append(value)
        }
        return result
    }
    private func snapshot(includeOffscreen: Bool, context: OperationContext) throws -> ([[String: Any]], [UInt32: WindowProcessOwner], Set<UInt32>) {
        try context.check()
        let onScreenRecords = try readWindows()
        try context.check()
        let records: [[String: Any]]
        let onScreenIDs: Set<UInt32>
        if includeOffscreen, let readAllWindows {
            onScreenIDs = Set(onScreenRecords.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
            records = try readAllWindows()
            try context.check()
        } else {
            onScreenIDs = Set(onScreenRecords.compactMap { $0[kCGWindowNumber as String] as? UInt32 })
            records = onScreenRecords
        }
        let pids = Set(records.compactMap { record -> UInt32? in
            guard (record[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return record[kCGWindowOwnerPID as String] as? UInt32
        })
        let owners = readProcessOwners(pids.sorted())
        try context.check()
        return (records, owners, onScreenIDs)
    }
    private func target(_ record: [String: Any], bundleId: String?, onScreen: Bool? = nil) -> Target? {
        guard (record[kCGWindowLayer as String] as? Int) == 0,
              let pid = record[kCGWindowOwnerPID as String] as? UInt32, pid > 0, pid <= UInt32(Int32.max),
              let windowId = record[kCGWindowNumber as String] as? UInt32, windowId > 0,
              let bounds = record[kCGWindowBounds as String] as? [String: Double],
              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let ownerName = (record[kCGWindowOwnerName as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Target(key: TargetKey(pid: pid, windowId: windowId), bundleId: bundleId,
                      title: record[kCGWindowName as String] as? String ?? "",
                      bounds: Rect(x: x, y: y, width: width, height: height),
                      ownerName: bundleId == nil ? ownerName.flatMap { (1...1024).contains($0.utf8.count) ? $0 : nil } : nil,
                      onScreen: onScreen)
    }

    private static func nativeApps() -> [AppInfo] {
        let collectRunning: @Sendable () -> [AppInfo] = {
            var running: [AppInfo] = []
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                let rawName = app.localizedName ?? app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.utf8.count <= 1024 else { continue }
                let pid: UInt32? = app.processIdentifier > 0 ? UInt32(app.processIdentifier) : nil
                let rawBundle = app.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
                let bundleId = rawBundle.flatMap { !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil }
                running.append(AppInfo(pid: pid, bundleId: bundleId, name: name, running: true,
                                       active: app.isActive, hidden: app.isHidden))
            }
            return running
        }
        var apps = Thread.isMainThread ? collectRunning() : DispatchQueue.main.sync(execute: collectRunning)
        var seenBundles = Set(apps.compactMap(\.bundleId))
        var seenNames = Set(apps.map { $0.name.lowercased() })

        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        let roots = ["/Applications", homeApps, "/System/Applications", "/System/Applications/Utilities"]
        let fm = FileManager.default
        var installed: [AppInfo] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items where item.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(item)
                let url = URL(fileURLWithPath: path)
                let name = url.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.utf8.count <= 1024 else { continue }
                let rawBundle = Bundle(url: url)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
                let bundleId = rawBundle.flatMap { !$0.isEmpty && $0.utf8.count <= 128 ? $0 : nil }
                if let bundleId, seenBundles.contains(bundleId) { continue }
                if bundleId == nil && seenNames.contains(name.lowercased()) { continue }
                if let bundleId { seenBundles.insert(bundleId) }
                seenNames.insert(name.lowercased())
                installed.append(AppInfo(pid: nil, bundleId: bundleId, name: name, running: false, active: false, hidden: false))
            }
        }
        apps.sort { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        installed.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return apps + installed
    }

    private static func nativeDisplays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success, count > 0 else { return [] }
        let scaleSnapshot: @Sendable () -> [UInt32: Double] = {
            var map: [UInt32: Double] = [:]
            for screen in NSScreen.screens {
                if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                    let scale = Double(screen.backingScaleFactor)
                    if scale.isFinite && scale > 0 { map[num.uint32Value] = scale }
                }
            }
            return map
        }
        let scaleByID = Thread.isMainThread ? scaleSnapshot() : DispatchQueue.main.sync(execute: scaleSnapshot)
        var displays: [DisplayInfo] = []
        for id in ids.prefix(Int(count)) where id > 0 {
            let bounds = CGDisplayBounds(id)
            guard bounds.size.width > 0, bounds.size.height > 0,
                  [bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height].allSatisfy(\.isFinite) else { continue }
            var scale = scaleByID[id] ?? 1.0
            if scaleByID[id] == nil, let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
                let ratio = Double(mode.pixelWidth) / Double(mode.width)
                if ratio.isFinite && ratio > 0 { scale = ratio }
            }
            displays.append(DisplayInfo(
                displayId: id,
                bounds: Rect(x: Double(bounds.origin.x), y: Double(bounds.origin.y),
                             width: Double(bounds.size.width), height: Double(bounds.size.height)),
                scaleFactor: scale,
                isPrimary: CGDisplayIsMain(id) != 0
            ))
        }
        displays.sort { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            return lhs.displayId < rhs.displayId
        }
        return displays
    }
}

private final class OpenBox: @unchecked Sendable {
    private let lock = NSLock()
    var app: NSRunningApplication?
    var error: Error?
    func set(app: NSRunningApplication?, error: Error?) {
        lock.lock(); self.app = app; self.error = error; lock.unlock()
    }
    func read() -> (NSRunningApplication?, Error?) {
        lock.lock(); defer { lock.unlock() }; return (app, error)
    }
}

public struct MacOSAppOpener: AppOpening {
    public init() {}

    public func open(_ request: OpenRequest, catalog: any WindowCatalog, context: OperationContext) throws -> OpenResult {
        try context.check()
        let appURL: URL?
        if let bundleId = request.bundleId {
            guard let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                throw NativeFailure(.targetNotFound, "application bundle not found")
            }
            appURL = found
        } else if let appName = request.appName {
            guard let found = Self.resolveAppURL(named: appName) else {
                throw NativeFailure(.targetNotFound, "application not found")
            }
            appURL = found
        } else {
            appURL = nil
        }

        let targetURL: URL?
        if let rawUrl = request.url {
            guard let parsed = URL(string: rawUrl) else {
                throw NativeFailure(.invalidRequest, "invalid URL")
            }
            targetURL = parsed
        } else {
            targetURL = nil
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = request.activate
        config.createsNewApplicationInstance = request.newInstance

        let sem = DispatchSemaphore(value: 0)
        let box = OpenBox()
        let completion: @Sendable (NSRunningApplication?, Error?) -> Void = { app, error in
            box.set(app: app, error: error)
            sem.signal()
        }

        try context.check()
        if let appURL, let targetURL {
            NSWorkspace.shared.open([targetURL], withApplicationAt: appURL, configuration: config, completionHandler: completion)
        } else if let appURL {
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: completion)
        } else if let targetURL {
            NSWorkspace.shared.open(targetURL, configuration: config, completionHandler: completion)
        } else {
            throw NativeFailure(.invalidRequest, "open requires bundleId, appName, or url")
        }

        while sem.wait(timeout: .now() + .milliseconds(25)) != .success {
            try context.check()
        }
        try context.check()
        let (launched, error) = box.read()
        if error != nil {
            throw NativeFailure(.nativeFailed, "macOS failed to open target")
        }

        let pid: UInt32? = launched.flatMap { $0.processIdentifier > 0 ? UInt32($0.processIdentifier) : nil }
        let bundleId = launched?.bundleIdentifier ?? request.bundleId
        var windows: [Target] = []
        if let pid {
            let windowDeadline = min(context.deadlineNanoseconds, DispatchTime.now().uptimeNanoseconds + 800_000_000)
            while true {
                try context.check()
                if let list = try? catalog.processWindows(pid: pid, context: context), !list.isEmpty {
                    windows = Array(list.prefix(Limits.maxTargets))
                    break
                }
                if DispatchTime.now().uptimeNanoseconds >= windowDeadline { break }
                let delay = Double(try context.nativeTimeoutSeconds(maximum: 0.05))
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            }
        }
        return OpenResult(pid: pid, bundleId: bundleId, activated: request.activate, targets: windows)
    }

    private static func resolveAppURL(named name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidates = trimmed.hasSuffix(".app") ? [trimmed] : ["\(trimmed).app", trimmed]
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        let roots = ["/Applications", homeApps, "/System/Applications", "/System/Applications/Utilities"]
        let fm = FileManager.default
        for root in roots {
            for candidate in candidates {
                let path = (root as NSString).appendingPathComponent(candidate)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        let lower = trimmed.lowercased()
        let running = NSWorkspace.shared.runningApplications
        for app in running {
            if let localized = app.localizedName, localized.lowercased() == lower, let url = app.bundleURL {
                return url
            }
            if let url = app.bundleURL {
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                if stem == lower { return url }
            }
        }
        return nil
    }
}

public struct MacOSClipboardManager: ClipboardManaging {
    public init() {}

    public func perform(_ request: ClipboardRequest, context: OperationContext) throws -> ClipboardResult {
        try context.check()
        let work: @Sendable () -> Result<ClipboardResult, NativeFailure> = {
            let pb = NSPasteboard.general
            switch request.action {
            case .read:
                return .success(Self.summarize(pb, includeText: request.includeText))
            case .clear:
                pb.clearContents()
                return .success(Self.summarize(pb, includeText: false))
            case .write:
                if let text = request.text {
                    pb.clearContents()
                    guard pb.setString(text, forType: .string) else {
                        return .failure(NativeFailure(.nativeFailed, "failed to write text to clipboard"))
                    }
                    return .success(Self.summarize(pb, includeText: false))
                } else if let filePath = request.filePath {
                    guard FileManager.default.fileExists(atPath: filePath) else {
                        return .failure(NativeFailure(.targetNotFound, "clipboard file not found"))
                    }
                    let url = NSURL(fileURLWithPath: filePath)
                    pb.clearContents()
                    guard pb.writeObjects([url]) else {
                        return .failure(NativeFailure(.nativeFailed, "failed to write file to clipboard"))
                    }
                    return .success(Self.summarize(pb, includeText: false))
                } else if let imagePath = request.imagePath {
                    guard FileManager.default.fileExists(atPath: imagePath) else {
                        return .failure(NativeFailure(.targetNotFound, "clipboard image not found"))
                    }
                    guard let image = NSImage(contentsOfFile: imagePath) else {
                        return .failure(NativeFailure(.invalidRequest, "unable to decode image at imagePath"))
                    }
                    pb.clearContents()
                    guard pb.writeObjects([image]) else {
                        return .failure(NativeFailure(.nativeFailed, "failed to write image to clipboard"))
                    }
                    return .success(Self.summarize(pb, includeText: false))
                }
                return .failure(NativeFailure(.invalidRequest, "clipboard write requires text, filePath, or imagePath"))
            }
        }
        let outcome = Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
        try context.check()
        return try outcome.get()
    }

    private static func summarize(_ pb: NSPasteboard, includeText: Bool) -> ClipboardResult {
        let changeCount = UInt64(max(0, pb.changeCount))
        var seenTypes: Set<String> = []
        var types: [String] = []
        for raw in pb.types ?? [] {
            let value = raw.rawValue
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= 256,
                  seenTypes.insert(value).inserted else { continue }
            types.append(value)
            if types.count == Limits.maxClipboardTypes { break }
        }
        let rawText = pb.string(forType: .string)
        let textBytes = rawText.map { UInt32(min($0.utf8.count, Int(UInt32.max))) }
        let text: String?
        let truncated: Bool
        if includeText, let rawText {
            if rawText.utf8.count <= Limits.maxClipboardBytes {
                text = rawText
                truncated = false
            } else {
                text = truncateUTF8(rawText, maxBytes: Limits.maxClipboardBytes)
                truncated = true
            }
        } else {
            text = nil
            truncated = false
        }
        return ClipboardResult(changeCount: changeCount, types: types, text: text, textBytes: textBytes, truncated: truncated)
    }

    private static func truncateUTF8(_ value: String, maxBytes: Int) -> String {
        var bytes = 0
        var end = value.startIndex
        for idx in value.indices {
            let next = value.index(after: idx)
            let len = value[idx..<next].utf8.count
            if bytes + len > maxBytes { break }
            bytes += len
            end = next
        }
        return String(value[..<end])
    }
}

private func nativeMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
private func unavailableObservation(id: String, target: Target, started: UInt64,
                                    accessibilityCollected: CollectionInterval? = nil, selectors: [UseUIProtocol.Selector]? = nil) -> Observation {
    Observation(observationId: id, target: target.key,
        collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, nativeMilliseconds())),
        windowBounds: target.bounds, accessibility: .unavailable, accessibilityCollected: accessibilityCollected, elements: [], screenshot: nil,
        axSelection: selectors.map { AxSelectionEvidence(selectors: $0, coverage: .unavailable, ambiguous: false, visitedNodes: 0) })
}
