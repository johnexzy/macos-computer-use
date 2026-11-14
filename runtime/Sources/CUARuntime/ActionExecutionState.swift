import CUAProtocol
import Foundation

public struct ActionWitness: Sendable {
    public let observationId: String
    public let collected: CollectionInterval
    public let target: TargetKey
    public let elementRef: String
    public let condition: Condition
    public let matched: Bool
}

/// One atomic delivery ledger. A logical interruption seals a receipt without releasing physical mutation ownership.
public final class ActionExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private let act: ActRequest
    private var delivery: Delivery = .notDispatched
    private var verification: Verification = .unverified
    private var evidence: [CheckEvidence] = []
    private var checks: [ActionWitness] = []
    private var route: DeliveryRoute?
    private var reason: ReceiptReason = .nativeFailed
    private var stop: StopReason = .failed
    private var sealed = false

    public init(act: ActRequest) { self.act = act }

    public func interrupt(_ interruption: Interruption) -> ActResult {
        lock.lock(); defer { lock.unlock() }
        if !sealed {
            reason = interruption == .cancelled ? .cancelled : .deadlineExceeded
            stop = interruption == .cancelled ? .cancelled : .deadlineExceeded
            sealed = true
        }
        return resultLocked()
    }

    public func snapshot() -> ActResult {
        lock.lock(); defer { lock.unlock() }
        return resultLocked()
    }

    public var witnesses: [ActionWitness] {
        lock.lock(); defer { lock.unlock() }; return checks
    }

    func beginDispatch(context: OperationContext, route: DeliveryRoute) throws {
        lock.lock(); defer { lock.unlock() }
        guard !sealed else {
            throw NativeFailure(reason == .deadlineExceeded ? .deadlineExceeded : .cancelled, "action already settled")
        }
        try context.check()
        delivery = .unknown
        verification = .unverified
        evidence = []; checks = []
        self.route = route
    }

    func returnedSuccessfully() {
        lock.lock(); defer { lock.unlock() }
        if !sealed { delivery = .dispatched }
    }

    func checked(_ checks: [ActionWitness], verification: Verification) {
        lock.lock(); defer { lock.unlock() }
        if !sealed {
            self.checks = checks
            evidence = checks.map { CheckEvidence(observationId: $0.observationId, condition: $0.condition, matched: $0.matched) }
            self.verification = verification
        }
    }

    func finish(reason: ReceiptReason? = nil, stop: StopReason = .completed) {
        lock.lock(); defer { lock.unlock() }
        if !sealed {
            self.reason = reason ?? .nativeFailed
            self.stop = stop
            sealed = true
        }
    }

    func complete(context: OperationContext, alreadySatisfied: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard !sealed else { return }
        if let interruption = context.interruption {
            reason = interruption == .cancelled ? .cancelled : .deadlineExceeded
            stop = interruption == .cancelled ? .cancelled : .deadlineExceeded
        } else {
            reason = alreadySatisfied ? .alreadySatisfied : .nativeFailed
            stop = .completed
        }
        sealed = true
    }

    var hasEnteredDispatch: Bool {
        lock.lock(); defer { lock.unlock() }
        return delivery != .notDispatched
    }

    private func resultLocked() -> ActResult {
        let step = act.steps[0] // Frame validation precedes construction of a pending action.
        let receiptReason: ReceiptReason? = stop == .completed && reason != .alreadySatisfied ? nil : reason
        return ActResult(observationId: act.observationId,
            steps: [StepReceipt(actionId: step.actionId, delivery: delivery, verification: verification,
                                reason: receiptReason, evidence: evidence, route: route)],
            remainingSteps: UInt16(act.steps.count - 1), stopReason: stop)
    }
}
