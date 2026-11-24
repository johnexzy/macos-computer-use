import CoreGraphics
import UseUIProtocol
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
    private let visual: any VisualCapturing
    private let ocr: @Sendable (CGImage, String?, OperationContext) throws -> OcrEvidence

    public init() {
        self.init(windowPresent: Self.nativeWindowPresent, visual: ScreenWindowCapture(),
                  ocr: { try VisualOCR().recognize(image: $0, query: $1, context: $2) })
    }
    public init(windowPresent: @escaping @Sendable (TargetKey, OperationContext) throws -> Bool) {
        self.init(windowPresent: windowPresent, visual: ScreenWindowCapture(),
                  ocr: { try VisualOCR().recognize(image: $0, query: $1, context: $2) })
    }
    init(windowPresent: @escaping @Sendable (TargetKey, OperationContext) throws -> Bool = PredicateEvaluator.nativeWindowPresent,
         visual: any VisualCapturing,
         ocr: @escaping @Sendable (CGImage, String?, OperationContext) throws -> OcrEvidence = { try VisualOCR().recognize(image: $0, query: $1, context: $2) }) {
        self.windowPresent = windowPresent
        self.visual = visual
        self.ocr = ocr
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
        case .valueContains(let value):
            reference = value.elementRef
            let snapshot = try handle.resolve(value.elementRef, includeValue: true, context: context).snapshot
            matched = snapshot.value.map { $0.contains(value.contains) }
        case .enabled(let value):
            reference = value.elementRef
            let snapshot = try handle.resolve(value.elementRef, context: context).snapshot
            matched = snapshot.enabledKnown ? snapshot.enabled == value.enabled : nil
        case .urlContains(let value):
            reference = value.elementRef
            if let ref = value.elementRef {
                let snapshot = try handle.resolve(ref, allowTitleChange: true, context: context).snapshot
                matched = snapshot.url.map { $0.contains(value.contains) }
            } else {
                let scan = try handle.scan(selectors: [UseUIProtocol.Selector(role: "AXWebArea", label: nil, identifier: nil)],
                                           includeValues: false, allowTitleChange: true, context: context)
                if scan.nodes.contains(where: { $0.snapshot.url?.contains(value.contains) == true }) {
                    matched = true
                } else if scan.complete && scan.nodes.allSatisfy({ $0.snapshot.complete }) {
                    matched = false
                } else {
                    matched = nil
                }
            }
        case .ocrContains(let value):
            reference = nil
            try handle.validateWindow(context: context, allowTitleChange: true)
            matched = try evaluateOcr(value, target: handle.target, context: context)
        case .elementExists(let value), .elementAbsent(let value):
            reference = nil
            let scan = try handle.scan(context: context)
            let found = scan.nodes.contains { matches($0.snapshot, selector: value.selector) }
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

    func evaluate(_ condition: Condition, visualHandle: VisualObservationHandle,
                  context: OperationContext) throws -> PredicateEvaluation {
        try context.check()
        let started = nowMilliseconds()
        let matched: Bool?
        switch condition {
        case .windowAbsent:
            matched = try !windowPresent(visualHandle.target.key, context)
        case .ocrContains(let value):
            try visualHandle.validateWindow(context: context)
            matched = try evaluateOcr(value, target: visualHandle.target, context: context)
        default:
            throw NativeFailure(.unsupported, "AX conditions require a semantic observation")
        }
        try context.check()
        let interval = CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, nowMilliseconds()))
        let evidence = matched.map {
            CheckEvidence(observationId: "check-\(UUID().uuidString)", condition: condition, matched: $0, collected: interval)
        }
        return PredicateEvaluation(evidence: evidence, collected: interval, target: visualHandle.target.key, elementRef: nil)
    }

    private func evaluateOcr(_ value: OcrCondition, target: Target, context: OperationContext) throws -> Bool? {
        let captured: CapturedVisual
        do {
            captured = try visual.capture(target: target, crop: value.cropWindow, maxDimension: 1600, context: context)
        } catch let failure as VisualCaptureFailure {
            switch failure.status {
            case .permissionDenied:
                throw NativeFailure(.permissionDenied, "Screen Recording permission is required for ocrContains")
            case .unsupported:
                throw NativeFailure(.unsupported, "visual capture is unsupported on this system")
            default:
                return nil
            }
        }
        let evidence = try ocr(captured.image, value.contains, context)
        switch evidence.status {
        case .complete:
            return !evidence.matches.isEmpty
        case .partial:
            return evidence.matches.isEmpty ? nil : true
        case .failed, .unavailable:
            return nil
        }
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
