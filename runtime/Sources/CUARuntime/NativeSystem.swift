import AppKit
import ApplicationServices
import CUAProtocol
import CoreGraphics
import Foundation

public protocol NativeSystem: Sendable {
    func permissions(context: OperationContext) throws -> Permissions
    func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult
    func window(_ key: TargetKey, context: OperationContext) throws -> Target
    func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)?
}

final class AXApplicationHandle: RetainedNativeHandle, @unchecked Sendable {
    let element: AXUIElement
    init(pid: pid_t, timeoutSeconds: Float) throws {
        element = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(element, timeoutSeconds) == .success else {
            throw NativeFailure(.nativeFailed, "could not install AX messaging timeout")
        }
    }
}

/// Read-only native functions. No activation, selectors, input, or permission requests.
public struct MacOSSystem: NativeSystem {
    public init() {}
    public func permissions(context: OperationContext) throws -> Permissions {
        try context.check()
        let value = Permissions(accessibility: AXIsProcessTrusted(), screenRecording: CGPreflightScreenCaptureAccess(),
                                inputPosting: CGPreflightPostEventAccess())
        try context.check()
        return value
    }
    public func targets(bundleId: String?, context: OperationContext) throws -> TargetsResult {
        let windows = try windowRecords(context: context)
        var result: [Target] = []
        var truncated = false
        for record in windows {
            try context.check()
            guard let target = target(record), bundleId == nil || target.bundleId == bundleId else { continue }
            if result.count == Limits.maxTargets { truncated = true; break }
            result.append(target)
        }
        try context.check()
        return TargetsResult(targets: result, truncated: truncated)
    }
    public func window(_ key: TargetKey, context: OperationContext) throws -> Target {
        let windows = try windowRecords(context: context)
        for record in windows {
            try context.check()
            guard (record[kCGWindowNumber as String] as? UInt32) == key.windowId,
                  (record[kCGWindowOwnerPID as String] as? UInt32) == key.pid,
                  let value = target(record) else { continue }
            return value
        }
        throw NativeFailure(.targetNotFound, "exact visible window/process pair not found")
    }
    public func retainApplication(pid: UInt32, timeoutSeconds: Float, context: OperationContext) throws -> (any RetainedNativeHandle)? {
        try context.check()
        guard AXIsProcessTrusted() else { return nil }
        let handle = try AXApplicationHandle(pid: pid_t(pid), timeoutSeconds: timeoutSeconds)
        try context.check()
        return handle
    }
    private func windowRecords(context: OperationContext) throws -> [[String: Any]] {
        try context.check()
        guard let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw NativeFailure(.nativeFailed, "window enumeration unavailable")
        }
        try context.check()
        return records
    }
    private func target(_ record: [String: Any]) -> Target? {
        guard (record[kCGWindowLayer as String] as? Int) == 0,
              let pid = record[kCGWindowOwnerPID as String] as? UInt32, pid > 0, pid <= UInt32(Int32.max),
              let windowId = record[kCGWindowNumber as String] as? UInt32, windowId > 0,
              let bundleId = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier, !bundleId.isEmpty,
              let bounds = record[kCGWindowBounds as String] as? [String: Double],
              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return Target(key: TargetKey(pid: pid, windowId: windowId), bundleId: bundleId,
                      title: record[kCGWindowName as String] as? String ?? "",
                      bounds: Rect(x: x, y: y, width: width, height: height))
    }
}
