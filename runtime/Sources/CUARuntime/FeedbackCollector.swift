import CUAProtocol
import Foundation

/// Best-effort projection readback. It never changes the action ledger or creates references.
public struct FeedbackCollector: Sendable {
    public init() {}

    public func collect(_ request: FeedbackRequest, entry: RetainedObservation,
                        context: OperationContext) -> ObservationFeedback {
        let started = feedbackMilliseconds()
        var controls = request.elementRefs.map { ControlFeedback(elementRef: $0, state: .unavailable) }
        var truncated = false
        func expired() -> Bool {
            let now = DispatchTime.now().uptimeNanoseconds
            return now >= entry.createdAt && now - entry.createdAt >= UInt64(Limits.observationTTLMS) * 1_000_000
        }
        func result(invalidated: Bool = false) -> ObservationFeedback {
            let invalidated = invalidated || expired()
            return ObservationFeedback(baseObservationId: entry.observation.observationId,
                collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, feedbackMilliseconds())),
                controls: invalidated ? request.elementRefs.map { ControlFeedback(elementRef: $0, state: .invalidated) } : controls,
                invalidated: invalidated, truncated: truncated)
        }
        if expired() { return result(invalidated: true) }
        guard let handle = entry.handle as? SemanticObservationHandle else { return result() }
        guard handle.observationId == entry.observation.observationId, handle.target.key == entry.observation.target else {
            return result(invalidated: true)
        }
        do { try handle.validateWindow(context: context) }
        catch { return result(invalidated: bindingInvalidated(error)) }

        let base = Dictionary(uniqueKeysWithValues: entry.observation.elements.map { ($0.reference, $0) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var bytes = (try? encoder.encode(result()).count) ?? Limits.maxFeedbackBytes
        for (index, reference) in request.elementRefs.enumerated() {
            if expired() { return result(invalidated: true) }
            if context.interruption != nil { truncated = true; break }
            let feedback: ControlFeedback
            if let original = base[reference] {
                do {
                    let snapshot = try handle.resolve(reference, includeValue: request.includeValues, context: context).snapshot
                    guard snapshot.enabledKnown, !snapshot.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          snapshot.role.utf8.count <= 128 else { continue }
                    let label = exportString(snapshot.label, limit: 1024)
                    let identifier = exportString(snapshot.identifier, limit: 1024)
                    let value = request.includeValues ? exportString(snapshot.value, limit: 65_536) : nil
                    if !snapshot.complete || label != snapshot.label || identifier != snapshot.identifier
                        || (request.includeValues && value != snapshot.value) { truncated = true }
                    var actions: [ElementAction] = []
                    if handle.backend is any AXMutating {
                        if snapshot.valueSettable { actions.append(.setValue) }
                        if snapshot.actions.contains("AXPress") { actions.append(.press) }
                        if snapshot.selectedTextSettable { actions.append(.typeText) }
                    }
                    let current = Element(reference: reference, role: snapshot.role, label: label, value: value,
                        bounds: snapshot.bounds, enabled: snapshot.enabled, actions: actions, identifier: identifier)
                    let previous = Element(reference: original.reference, role: original.role, label: original.label,
                        value: request.includeValues ? original.value : nil, bounds: original.bounds,
                        enabled: original.enabled, actions: original.actions, identifier: original.identifier)
                    feedback = current == previous
                        ? ControlFeedback(elementRef: reference, state: .unchanged)
                        : ControlFeedback(elementRef: reference, state: .changed, element: current)
                } catch {
                    feedback = ControlFeedback(elementRef: reference,
                        state: bindingInvalidated(error) ? .invalidated : .unavailable)
                }
            } else {
                feedback = ControlFeedback(elementRef: reference, state: .invalidated)
            }
            let previousSize = (try? encoder.encode(controls[index]).count) ?? 0
            let nextSize = (try? encoder.encode(feedback).count) ?? Limits.maxFeedbackBytes
            if bytes - previousSize + nextSize + 64 > Limits.maxFeedbackBytes { truncated = true; break }
            bytes += nextSize - previousSize
            controls[index] = feedback
        }
        do { try handle.validateWindow(context: context) }
        catch { if bindingInvalidated(error) { return result(invalidated: true) } }
        return result()
    }
}

private func bindingInvalidated(_ error: any Error) -> Bool {
    guard let error = error as? NativeFailure else { return false }
    return error.code == .staleObservation || error.code == .staleElement
        || error.code == .targetNotFound || error.code == .ambiguousTarget
}
private func exportString(_ string: String?, limit: Int) -> String? { string.flatMap { $0.utf8.count <= limit ? $0 : nil } }
private func feedbackMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
