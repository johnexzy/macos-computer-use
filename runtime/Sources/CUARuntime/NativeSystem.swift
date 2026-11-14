import AppKit
import ApplicationServices
import CUAProtocol
import CoreGraphics
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

public struct MacOSWindowCatalog: WindowCatalog {
    private let readWindows: @Sendable () throws -> [[String: Any]]
    private let readProcessBundles: @Sendable () -> [UInt32: String]

    public init() {
        self.init(windowRecords: {
            guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                throw NativeFailure(.nativeFailed, "window enumeration unavailable")
            }
            return records
        }, processBundles: {
            var bundles: [UInt32: String] = [:]
            for application in NSWorkspace.shared.runningApplications {
                let pid = application.processIdentifier
                guard pid > 0, let bundle = application.bundleIdentifier, !bundle.isEmpty else { continue }
                bundles[UInt32(pid)] = bundle
            }
            return bundles
        })
    }

    init(windowRecords: @escaping @Sendable () throws -> [[String: Any]],
         processBundles: @escaping @Sendable () -> [UInt32: String]) {
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
        let bundles = readProcessBundles()
        try context.check()
        let records = try readWindows()
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
