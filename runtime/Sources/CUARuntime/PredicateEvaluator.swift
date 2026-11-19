import CoreGraphics
import CUAProtocol
import Foundation

public struct PredicateEvaluation: Sendable {
    public let evidence: CheckEvidence?
    public let collected: CollectionInterval
    public let target: TargetKey
    public let elementRef: String?
    public var matched: Bool? { evidence?.matched }
    public init(evidence: CheckEvidence?, collected: CollectionInterval, target: TargetKey, elementRef: String?) {
        self.evidence = evidence; self.collected = collected; self.target = target; self.elementRef = elementRef
    }
}

public struct PredicateEvaluator: Sendable {
    private let windowPresent: @Sendable (TargetKey, OperationContext) throws -> Bool
    public init() { windowPresent = Self.nativeWindowPresent }
    public init(windowPresent: @escaping @Sendable (TargetKey, OperationContext) throws -> Bool) {
        self.windowPresent = windowPresent
    }

    public func evaluate(_ condition: Condition, handle: SemanticObservationHandle,
                         context: OperationContext) throws -> PredicateEvaluation {
        try context.check()
        let started = nowMilliseconds()
        let matched: Bool?
        let reference: String?
        switch condition {
        case .windowAbsent:
            reference = nil
            matched = try !windowPresent(handle.target.key, context)
        case .valueEquals(let value):
            reference = value.elementRef
            let snapshot = try handle.resolve(value.elementRef, includeValue: true, context: context).snapshot
            matched = snapshot.value.map { $0 == value.value }
        case .enabled(let value):
            reference = value.elementRef
            let snapshot = try handle.resolve(value.elementRef, context: context).snapshot
            matched = snapshot.enabledKnown ? snapshot.enabled == value.enabled : nil
        case .elementExists(let value), .elementAbsent(let value):
            reference = nil
            let scan = try handle.scan(context: context)
            let found = scan.nodes.contains { node in
                let snapshot = node.snapshot, selector = value.selector
                return snapshot.role == selector.role
                    && (selector.label == nil || selector.label == snapshot.label)
                    && (selector.identifier == nil || selector.identifier == snapshot.identifier)
            }
            let exists: Bool? = found ? true : (scan.complete ? false : nil)
            if case .elementAbsent = condition { matched = exists.map { !$0 } }
            else { matched = exists }
        }
        try context.check()
        let interval = CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, nowMilliseconds()))
        let evidence = matched.map {
            CheckEvidence(observationId: "check-\(UUID().uuidString)", condition: condition, matched: $0, collected: interval)
        }
        return PredicateEvaluation(evidence: evidence, collected: interval, target: handle.target.key, elementRef: reference)
    }

    private static func nativeWindowPresent(_ target: TargetKey, _ context: OperationContext) throws -> Bool {
        try context.check()
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw NativeFailure(.nativeFailed, "complete window catalog unavailable")
        }
        var complete = true
        for row in rows {
            try context.check()
            guard let pid = row[kCGWindowOwnerPID as String] as? UInt32,
                  let window = row[kCGWindowNumber as String] as? UInt32 else { complete = false; continue }
            if pid == target.pid && window == target.windowId { return true }
        }
        guard complete else { throw NativeFailure(.nativeFailed, "complete window catalog metadata unavailable") }
        try context.check()
        return false
    }
}

private func nowMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
