import UseUIProtocol
import Foundation

public struct ActionWitness: Sendable {
    public let observationId: String
    public let collected: CollectionInterval
    public let target: TargetKey
    public let elementRef: String?
    public let condition: Condition
    public let matched: Bool
}

/// Immutable settled prefix plus one active step. Logical interruption never releases physical mutation ownership.
public final class ActionExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private let act: ActRequest
    private var prefix: [StepReceipt] = []
    private var prefixChecks: [ActionWitness] = []
    private var delivery: Delivery = .notDispatched
    private var verification: Verification = .unverified
    private var evidence: [CheckEvidence] = []
    private var checks: [ActionWitness] = []
    private var route: DeliveryRoute?
    private var reason: ReceiptReason = .nativeFailed
    private var stop: StopReason = .failed
    private var sealed = false
    private var interrupted = false
    private var feedback: ObservationFeedback?
    private var finalReason: ReceiptReason?
    private var foreground: ForegroundEvidence?

    public init(act: ActRequest) { self.act = act }

    public func interrupt(_ interruption: Interruption) -> ActResult {
        lock.lock(); defer { lock.unlock() }
        interrupted = true
        if !sealed {
            reason = interruption == .cancelled ? .cancelled : .deadlineExceeded
            stop = interruption == .cancelled ? .cancelled : .deadlineExceeded
            sealed = true
            if act.foreground {
                let observed = foreground
                foreground = ForegroundEvidence(initialPid: observed?.initialPid, lastPid: observed?.lastPid,
                    activationRequested: observed?.activationRequested ?? false, inputActivity: observed?.inputActivity ?? false,
                    externalActivation: observed?.externalActivation ?? false,
                    interruption: interruption == .cancelled ? .cancelled : .deadlineExceeded,
                    restoration: observed?.restoration ?? .notNeeded)
            }
        }
        return resultLocked()
    }

    public func snapshot() -> ActResult {
        lock.lock(); defer { lock.unlock() }; return resultLocked()
    }

    public var witnesses: [ActionWitness] {
        lock.lock(); defer { lock.unlock() }; return prefixChecks + checks
    }

    var isSealed: Bool { lock.lock(); defer { lock.unlock() }; return sealed }

    func checkActive(context: OperationContext) throws {
        lock.lock(); defer { lock.unlock() }; try requireActive(context)
    }

    func beginDispatch(context: OperationContext, route: DeliveryRoute) throws {
        lock.lock(); defer { lock.unlock() }
        try requireActive(context)
        delivery = .unknown; verification = .unverified
        evidence = []; checks = []; self.route = route
    }

    func returnedSuccessfully() {
        lock.lock(); defer { lock.unlock() }
        if !sealed { delivery = .dispatched }
    }

    func checked(_ checks: [ActionWitness], verification: Verification) {
        lock.lock(); defer { lock.unlock() }
        if !sealed {
            self.checks = checks
            evidence = checks.map { CheckEvidence(observationId: $0.observationId, condition: $0.condition,
                                                 matched: $0.matched, collected: $0.collected) }
            self.verification = verification
        }
    }

    func finish(reason: ReceiptReason? = nil, stop: StopReason = .completed) {
        lock.lock(); defer { lock.unlock() }
        if !sealed { self.reason = reason ?? .nativeFailed; self.stop = stop; sealed = true }
    }

    /// Commit before output admission. A timer during its write barrier sees the next step as not dispatched.
    func settle(context: OperationContext, reason: ReceiptReason?) throws -> [StepReceipt]? {
        lock.lock(); defer { lock.unlock() }
        try requireActive(context)
        // The final receipt has not been published. Keep it active until request-level checks finish.
        if prefix.count + 1 == act.steps.count { finalReason = reason; return nil }
        prefix.append(receiptLocked(reason: reason)); prefixChecks.append(contentsOf: checks)
        delivery = .notDispatched; verification = .unverified; evidence = []; checks = []
        route = nil; self.reason = .nativeFailed; stop = .failed
        return prefix
    }

    func finalize(context: OperationContext) throws {
        lock.lock(); defer { lock.unlock() }
        try requireActive(context)
        prefix.append(receiptLocked(reason: finalReason)); prefixChecks.append(contentsOf: checks)
        stop = .completed; sealed = true; checks = []
    }

    // Kept for a single-step caller that completes directly after its check.
    func complete(context: OperationContext, alreadySatisfied: Bool) {
        do {
            if try settle(context: context, reason: alreadySatisfied ? .alreadySatisfied : nil) == nil {
                try finalize(context: context)
            }
        }
        catch {
            if let interruption = context.interruption { _ = interrupt(interruption) }
        }
    }

    func attachFeedback(_ value: ObservationFeedback) {
        lock.lock(); defer { lock.unlock() }
        if !interrupted { feedback = value }
    }

    func recordForeground(_ value: ForegroundEvidence) {
        lock.lock(); defer { lock.unlock() }
        if !interrupted { foreground = value }
    }

    var hasEnteredDispatch: Bool {
        lock.lock(); defer { lock.unlock() }; return delivery != .notDispatched
    }

    private func requireActive(_ context: OperationContext) throws {
        guard !sealed else {
            throw NativeFailure(reason == .deadlineExceeded ? .deadlineExceeded : .cancelled, "action already settled")
        }
        try context.check()
    }

    private func receiptLocked(reason: ReceiptReason?) -> StepReceipt {
        StepReceipt(actionId: act.steps[prefix.count].actionId, delivery: delivery, verification: verification,
                    reason: reason, evidence: evidence, route: route)
    }

    private func resultLocked() -> ActResult {
        var steps = prefix
        if prefix.count < act.steps.count {
            let currentReason: ReceiptReason? = stop == .completed && reason != .alreadySatisfied ? nil : reason
            steps.append(receiptLocked(reason: currentReason))
        }
        return ActResult(observationId: act.observationId, steps: steps,
            remainingSteps: UInt16(act.steps.count - steps.count), stopReason: stop, feedback: feedback, foreground: foreground)
    }
}
