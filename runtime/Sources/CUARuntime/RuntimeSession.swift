import CUAProtocol
import Foundation

public struct RuntimeLimits: Sendable {
    public var maxWorkItems = 16
    public var maxWorkBytes = Limits.maxFrameBytes
    public var maxRequestIDs = 4096
    public init() {}
}

private final class PendingRequest: @unchecked Sendable {
    let request: Request
    let context: OperationContext
    let timer: DispatchSourceTimer
    init(_ request: Request, context: OperationContext, timer: DispatchSourceTimer) {
        self.request = request; self.context = context; self.timer = timer
    }
}

private struct NativeResult: Sendable {
    let body: ResponseBody
    let handle: (any RetainedNativeHandle)?
    init(_ body: ResponseBody, handle: (any RetainedNativeHandle)? = nil) { self.body = body; self.handle = handle }
}

/// Control admission/timers/cancel are independent of the serial native worker and AppKit runloop.
public final class RuntimeSession: @unchecked Sendable {
    public let epoch: String
    public let observations: ObservationRegistry
    private let control = DispatchQueue(label: "cua.runtime.control")
    private let worker = DispatchQueue(label: "cua.runtime.native", qos: .userInitiated)
    private let system: any NativeSystem
    private let limits: RuntimeLimits
    private let emit: @Sendable (Response) -> Void
    private let didShutdown: @Sendable () -> Void
    private var session: SessionContext?
    private var seen: Set<String> = []
    private var pending: [String: PendingRequest] = [:]
    private var workItems = 0
    private var workBytes = 0
    private var closed = false
    private let maintenance: DispatchSourceTimer

    public init(system: any NativeSystem = MacOSSystem(), epoch: String = UUID().uuidString,
                limits: RuntimeLimits = RuntimeLimits(),
                emit: @escaping @Sendable (Response) -> Void,
                didShutdown: @escaping @Sendable () -> Void = {}) {
        self.system = system; self.epoch = epoch; self.limits = limits
        self.emit = emit; self.didShutdown = didShutdown
        observations = ObservationRegistry(epoch: epoch)
        maintenance = DispatchSource.makeTimerSource(queue: control)
        maintenance.schedule(deadline: .now() + 1, repeating: 1)
        maintenance.setEventHandler { [weak self] in self?.observations.prune() }
        maintenance.resume()
    }
    deinit { maintenance.cancel() }

    public func receive(_ request: Request, receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds, frameBytes: Int) {
        // Backpressure reaches the pipe reader before it can retain another decoded request.
        control.sync { self.admit(request, receivedAt: receivedAt, frameBytes: frameBytes) }
    }

    /// EOF, malformed input, SIGTERM, and transport loss release session-owned objects.
    /// Existing native reads can finish later; their results cannot recreate the invalidated registry.
    public func shutdown() { control.async { self.close() } }

    private func close() {
        guard !closed else { return }
        closed = true
        maintenance.cancel()
        for entry in Array(pending.values) { interrupt(entry, reason: .cancelled) }
        observations.invalidate()
        session = nil
        seen.removeAll()
        didShutdown()
    }

    private func respond(_ request: Request, _ body: ResponseBody) {
        emit(Response(version: Limits.version, id: request.id, epoch: epoch, body: body))
    }
    private func reject(_ request: Request, code: ErrorCode, _ message: String) {
        respond(request, .error(Failure(code: code, message: message)))
    }
    private func admit(_ request: Request, receivedAt: UInt64, frameBytes: Int) {
        guard !closed else { return }
        guard request.id.utf8.count <= 256 else { reject(request, code: .invalidRequest, "request ID exceeds 256 bytes"); return }
        // A duplicate cannot create a second response for an already-correlated ID.
        guard !seen.contains(request.id) else { close(); return }
        guard seen.count < limits.maxRequestIDs else {
            reject(request, code: .resourceLimit, "session request-ID bound reached; reconnect")
            close(); return
        }
        seen.insert(request.id)
        let context = OperationContext(receivedAt: receivedAt, budgetMs: request.budgetMs)
        do { try Frame.request(request).validate() }
        catch { reject(request, code: .invalidRequest, String(describing: error)); return }
        if case .hello(let hello) = request.body {
            guard session == nil else { reject(request, code: .authorityDenied, "session already initialized"); return }
            guard context.interruption == nil else { respond(request, interruptedBody(request, .deadlineExceeded)); return }
            session = SessionContext(epoch: epoch, authority: hello.authority)
            respond(request, .hello(HelloResult(helperVersion: "0.1.0", selectedVersion: Limits.version)))
            return
        }
        guard let session else { reject(request, code: .authorityDenied, "host hello is required"); return }
        guard request.epoch == epoch else { reject(request, code: .staleEpoch, "stale helper epoch"); return }
        do { try session.authorize(request) }
        catch { reject(request, code: .authorityDenied, String(describing: error)); return }
        guard context.interruption == nil else { respond(request, interruptedBody(request, .deadlineExceeded)); return }
        if case .cancel(let cancel) = request.body {
            if let target = pending[cancel.requestId] {
                respond(request, .cancel(CancelResult(requestId: cancel.requestId, status: .requested)))
                interrupt(target, reason: .cancelled)
            } else {
                respond(request, .cancel(CancelResult(requestId: cancel.requestId,
                    status: seen.contains(cancel.requestId) ? .alreadyFinished : .notFound)))
            }
            return
        }
        guard workItems < limits.maxWorkItems, frameBytes <= limits.maxWorkBytes - workBytes else {
            reject(request, code: .resourceLimit, "bounded native request queue is full"); return
        }
        workItems += 1; workBytes += frameBytes
        let timer = DispatchSource.makeTimerSource(queue: control)
        let entry = PendingRequest(request, context: context, timer: timer)
        pending[request.id] = entry
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: context.deadlineNanoseconds))
        timer.setEventHandler { [weak self] in self?.interrupt(entry, reason: .deadlineExceeded) }
        timer.resume()
        worker.async { [self] in
            let result: NativeResult
            do {
                let body = try execute(request, mode: session.authority.mode, context: context)
                try context.check()
                result = body
            } catch let error as NativeFailure {
                result = NativeResult(.error(Failure(code: error.code, message: error.message)))
            } catch {
                result = NativeResult(.error(Failure(code: .nativeFailed, message: "native operation failed")))
            }
            control.async {
                self.workItems -= 1; self.workBytes -= frameBytes
                guard self.pending.removeValue(forKey: request.id) != nil else { return }
                timer.cancel()
                if let reason = context.interruption {
                    self.respond(request, self.interruptedBody(request, reason)); return
                }
                do {
                    if case .observe(let observation) = result.body {
                        try self.observations.insert(observation, handle: result.handle)
                    }
                    self.respond(request, result.body)
                } catch {
                    self.reject(request, code: .staleObservation, "session closed before observation publication")
                }
            }
        }
    }

    private func interrupt(_ entry: PendingRequest, reason: Interruption) {
        guard pending.removeValue(forKey: entry.request.id) != nil else { return }
        entry.context.cancel()
        entry.timer.cancel()
        respond(entry.request, interruptedBody(entry.request, reason))
    }

    private func interruptedBody(_ request: Request, _ reason: Interruption) -> ResponseBody {
        if case .act(let act) = request.body {
            let receiptReason: ReceiptReason = reason == .cancelled ? .cancelled : .deadlineExceeded
            let stop: StopReason = reason == .cancelled ? .cancelled : .deadlineExceeded
            return rejectedAct(act, reason: receiptReason, stop: stop)
        }
        if case .waitFor = request.body {
            return .waitFor(WaitResult(outcome: reason == .cancelled ? .cancelled : .timedOut,
                                      alreadySatisfied: false, observation: nil))
        }
        return .error(Failure(code: reason == .cancelled ? .cancelled : .deadlineExceeded, message: "\(reason)"))
    }

    private func rejectedAct(_ act: ActRequest, reason: ReceiptReason, stop: StopReason) -> ResponseBody {
        .act(ActResult(observationId: act.observationId,
            steps: [StepReceipt(actionId: act.steps[0].actionId, delivery: .notDispatched,
                                verification: .unverified, reason: reason, evidence: [])],
            remainingSteps: UInt16(act.steps.count - 1), stopReason: stop))
    }

    private func execute(_ request: Request, mode: ExecutionMode, context: OperationContext) throws -> NativeResult {
        try context.check()
        switch request.body {
        case .capabilities:
            return NativeResult(.capabilities(Capabilities(permissions: try system.permissions(context: context), mode: mode, actions: [])))
        case .targets(let params):
            return NativeResult(.targets(try system.targets(bundleId: params.bundleId, context: context)))
        case .observe(let params):
            guard !params.includeScreenshot else { throw NativeFailure(.unsupported, "screenshot collection is not implemented") }
            let start = unixMilliseconds()
            let target = try system.window(params.target, context: context)
            let handle = try system.retainApplication(pid: params.target.pid,
                timeoutSeconds: context.nativeTimeoutSeconds(), context: context)
            let revalidated = try system.window(params.target, context: context)
            guard target.bounds == revalidated.bounds, target.bundleId == revalidated.bundleId else {
                throw NativeFailure(.nativeFailed, "window changed during lifecycle collection")
            }
            try context.check()
            let observation = Observation(observationId: "obs-\(epoch)-\(UUID().uuidString)", target: params.target,
                collected: CollectionInterval(startedUnixMs: start, finishedUnixMs: max(start, unixMilliseconds())),
                windowBounds: revalidated.bounds, accessibility: .unavailable, accessibilityCollected: nil,
                elements: [], screenshot: nil)
            return NativeResult(.observe(observation), handle: handle)
        case .act(let act):
            return NativeResult(rejectedAct(act, reason: .unsupported, stop: .unsupported))
        case .waitFor:
            throw NativeFailure(.unsupported, "semantic waiting is not implemented")
        case .hello, .cancel:
            throw NativeFailure(.invalidRequest, "control request reached native worker")
        }
    }
}

private func unixMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
