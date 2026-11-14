import AppKit
import ApplicationServices
import CUAProtocol
import CoreGraphics
import Darwin
import Foundation

public protocol NativeSystem: Sendable {
    func permissions(context: OperationContext) throws -> Permissions
    func supportedActions(permissions: Permissions) -> [ActionKind]
    func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult
    func window(_ key: TargetKey, context: OperationContext) throws -> Target
    func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)?
    func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation
}

public extension NativeSystem {
    func supportedActions(permissions: Permissions) -> [ActionKind] { [] }
    func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation {
        guard !params.includeScreenshot else { throw NativeFailure(.unsupported, "screenshot collection is not implemented") }
        let start = nativeMilliseconds()
        let before = try window(params.target, context: context)
        let handle = try retainApplication(pid: params.target.pid, timeoutSeconds: context.nativeTimeoutSeconds(), context: context)
        let after = try window(params.target, context: context)
        guard before.bounds == after.bounds, before.bundleId == after.bundleId else {
            throw NativeFailure(.staleObservation, "window changed during lifecycle collection")
        }
        try context.check()
        return NativeObservation(observation: unavailableObservation(id: observationId, target: after, started: start), handle: handle)
    }
}

public struct MacOSSystem: NativeSystem {
    private let backend: any AXReading
    private let catalog: any WindowCatalog
    public init(backend: any AXReading = MacOSAXBackend(), catalog: any WindowCatalog = MacOSWindowCatalog()) {
        self.backend = backend; self.catalog = catalog
    }
    public func permissions(context: OperationContext) throws -> Permissions {
        try context.check()
        let value = Permissions(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(),
                                inputPosting: CGPreflightPostEventAccess())
        try context.check()
        return value
    }
    public func supportedActions(permissions: Permissions) -> [ActionKind] {
        permissions.accessibility && backend is any AXMutating ? [.setValue, .press, .typeText] : []
    }
    public func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult { try catalog.targets(bundleId: bundleId, context: context) }
    public func window(_ key: TargetKey, context: OperationContext) throws -> Target { try catalog.window(key, context: context) }
    public func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)? {
        guard AXIsProcessTrusted() else { return nil }
        return try backend.application(pid: pid, context: context)
    }
    public func observe(params: ObserveRequest, observationId: String, context: OperationContext) throws -> NativeObservation {
        guard !params.includeScreenshot else { throw NativeFailure(.unsupported, "screenshot collection is not implemented") }
        let started = nativeMilliseconds()
        let target = try catalog.window(params.target, context: context)
        guard AXIsProcessTrusted() else {
            return NativeObservation(observation: unavailableObservation(id: observationId, target: target, started: started), handle: nil)
        }
        return try SemanticAXObserver(backend: backend, catalog: catalog).observe(params: params, observationId: observationId, context: context)
    }
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
final class ProcessBundleResolver: @unchecked Sendable {
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

    func resolve(_ pids: [UInt32]) -> [UInt32: String] {
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
                bundles.removeValue(forKey: pid); remove(pid); continue
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
                bundles.removeValue(forKey: pid); remove(pid)
            }
        }
        return bundles
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
    private let readProcessBundles: @Sendable ([UInt32]) -> [UInt32: String]

    public init() {
        let resolver = ProcessBundleResolver()
        self.init(windowRecords: {
            guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                throw NativeFailure(.nativeFailed, "window enumeration unavailable")
            }
            return records
        }, processBundles: resolver.resolve)
    }

    init(windowRecords: @escaping @Sendable () throws -> [[String: Any]],
         processBundles: @escaping @Sendable ([UInt32]) -> [UInt32: String]) {
        readWindows = windowRecords; readProcessBundles = processBundles
    }

    public func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult {
        let (windows, bundles) = try snapshot(context: context)
        var result: [Target] = []
        var truncated = false
        for record in windows {
            try context.check()
            guard let pid = record[kCGWindowOwnerPID as String] as? UInt32,
                  let bundle = bundles[pid], !bundle.isEmpty,
                  let target = target(record, bundleId: bundle), bundleId == nil || target.bundleId == bundleId else { continue }
            if result.count == Limits.maxTargets { truncated = true; break }
            result.append(target)
        }
        try context.check()
        return TargetsResult(targets: result, truncated: truncated)
    }
    public func window(_ key: TargetKey, context: OperationContext) throws -> Target {
        let (windows, bundles) = try snapshot(context: context)
        for record in windows {
            try context.check()
            guard (record[kCGWindowNumber as String] as? UInt32) == key.windowId,
                  (record[kCGWindowOwnerPID as String] as? UInt32) == key.pid,
                  (record[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let bundle = bundles[key.pid], !bundle.isEmpty else {
                throw NativeFailure(.nativeFailed, "process metadata unavailable for exact window")
            }
            guard let value = target(record, bundleId: bundle) else {
                throw NativeFailure(.nativeFailed, "exact window metadata unavailable")
            }
            return value
        }
        throw NativeFailure(.targetNotFound, "exact visible window/process pair not found")
    }
    public func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] {
        let (windows, bundles) = try snapshot(context: context)
        guard let bundle = bundles[pid], !bundle.isEmpty else {
            throw NativeFailure(.nativeFailed, "process metadata unavailable for window association")
        }
        var result: [Target] = []
        for record in windows {
            try context.check()
            guard (record[kCGWindowOwnerPID as String] as? UInt32) == pid,
                  (record[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let value = target(record, bundleId: bundle) else {
                throw NativeFailure(.ambiguousTarget, "process window metadata is incomplete")
            }
            guard result.count < 1024 else { throw NativeFailure(.ambiguousTarget, "process window catalog exceeds association bound") }
            result.append(value)
        }
        return result
    }
    private func snapshot(context: OperationContext) throws -> ([[String: Any]], [UInt32: String]) {
        try context.check()
        let records = try readWindows()
        try context.check()
        let pids = Set(records.compactMap { record -> UInt32? in
            guard (record[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return record[kCGWindowOwnerPID as String] as? UInt32
        })
        let bundles = readProcessBundles(pids.sorted())
        try context.check()
        return (records, bundles)
    }
    private func target(_ record: [String: Any], bundleId: String) -> Target? {
        guard (record[kCGWindowLayer as String] as? Int) == 0,
              let pid = record[kCGWindowOwnerPID as String] as? UInt32, pid > 0, pid <= UInt32(Int32.max),
              let windowId = record[kCGWindowNumber as String] as? UInt32, windowId > 0,
              let bounds = record[kCGWindowBounds as String] as? [String: Double],
              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return Target(key: TargetKey(pid: pid, windowId: windowId), bundleId: bundleId,
                      title: record[kCGWindowName as String] as? String ?? "",
                      bounds: Rect(x: x, y: y, width: width, height: height))
    }
}

private func nativeMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
private func unavailableObservation(id: String, target: Target, started: UInt64) -> Observation {
    Observation(observationId: id, target: target.key,
        collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, nativeMilliseconds())),
        windowBounds: target.bounds, accessibility: .unavailable, accessibilityCollected: nil, elements: [], screenshot: nil)
}
