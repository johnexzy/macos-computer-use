import UseUIProtocol
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
    let execution: ActionExecutionState?
    init(_ request: Request, context: OperationContext, timer: DispatchSourceTimer) {
        self.request = request; self.context = context; self.timer = timer
        if case .act(let act) = request.body { execution = ActionExecutionState(act: act) }
        else { execution = nil }
    }
}

private struct NativeResult: Sendable {
    let body: ResponseBody
    let handle: (any RetainedNativeHandle)?
    let activity: DesktopActivity?
    init(_ body: ResponseBody, handle: (any RetainedNativeHandle)? = nil, activity: DesktopActivity? = nil) {
        self.body = body; self.handle = handle; self.activity = activity
    }
}

/// Control admission/timers/cancel are independent of the serial native worker and AppKit runloop.
public final class RuntimeSession: @unchecked Sendable {
    public let epoch: String
    public let observations: ObservationRegistry
    private let control = DispatchQueue(label: "cua.runtime.control")
    private let worker = DispatchQueue(label: "cua.runtime.native", qos: .userInitiated)
    private let system: any NativeSystem
    private let actions: BackgroundActions
    private let activityOverlay: DesktopActivityOverlay?
    private let livePreview: RuntimeLivePreview?
    private let menuBar: MenuBarIsland?
    private let telemetryListener: TelemetryListener?
    private let limits: RuntimeLimits
    private let emit: @Sendable (Response) -> Void
    private let emitProgress: (@Sendable (UseUIProtocol.Progress) throws -> OutputTicket)?
    private let didShutdown: @Sendable () -> Void
    private var session: SessionContext?
    private var seen: Set<String> = []
    private var pending: [String: PendingRequest] = [:]
    private var workItems = 0
    private var workBytes = 0
    private var closed = false
    private var nextObsSeq: UInt64 = 0
    private let maintenance: DispatchSourceTimer

    public init(system: any NativeSystem = MacOSSystem(), epoch: String = UUID().uuidString,
                limits: RuntimeLimits = RuntimeLimits(),
                actions: BackgroundActions = BackgroundActions(),
                visualFeedback: Bool = false,
                livePreview: Bool = false,
                menuBar: Bool = false,
                telemetrySocketPath: String? = nil,
                emit: @escaping @Sendable (Response) -> Void,
                emitProgress: (@Sendable (UseUIProtocol.Progress) throws -> OutputTicket)? = nil,
                didShutdown: @escaping @Sendable () -> Void = {}) {
        self.system = system; self.epoch = epoch; self.limits = limits
        self.actions = actions
        let preview = (livePreview || menuBar) ? RuntimeLivePreview() : nil
        self.livePreview = livePreview ? preview : nil

        let overlay = visualFeedback ? DesktopActivityOverlay(onActivity: { [weak preview] activity in
            preview?.present(activity)
        }) : nil
        let island: MenuBarIsland? = menuBar ? MenuBarIsland(
            overlayEnabled: visualFeedback,
            onToggleOverlay: { enabled in overlay?.isEnabled = enabled },
            onSelectMotion: { style in overlay?.motionStyle = style },
            onToggleLiveView: { preview?.toggle() },
            onHideOverlay: { overlay?.hide() }
        ) : nil
        if let overlay, let island {
            DispatchQueue.main.async { [weak preview] in
                overlay.onActivity = { [weak preview] activity in
                    preview?.present(activity)
                    island.recordNative(activity)
                }
            }
        }
        self.activityOverlay = overlay
        self.menuBar = island

        if let telemetrySocketPath, !telemetrySocketPath.isEmpty, let island {
            let listener = TelemetryListener(socketPath: telemetrySocketPath) { event in
                island.submitHostTelemetry(event)
            }
            listener.start()
            self.telemetryListener = listener
        } else {
            self.telemetryListener = nil
        }

        self.emit = emit; self.emitProgress = emitProgress; self.didShutdown = didShutdown
        observations = ObservationRegistry(epoch: epoch)
        system.configureObservationWorker(worker)
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
        system.shutdownObservations()
        observations.invalidate()
        activityOverlay?.dismiss()
        livePreview?.dismiss()
        telemetryListener?.stop()
        menuBar?.shutdown()
        session = nil
        seen.removeAll()
        didShutdown()
    }

    private func respond(_ request: Request, _ body: ResponseBody, activity: DesktopActivity? = nil) {
        if !closed {
            if let activity {
                if let activityOverlay { activityOverlay.submit(activity) }
                else { livePreview?.submit(activity) }
            } else if case .act(let act) = request.body, case .act(let result) = body {
                if let recovery = DesktopActivity.recoveryPhase(act, result: result) {
                    activityOverlay?.showRecovery(recovery, target: act.target)
                    if activityOverlay == nil { livePreview?.recover(recovery, target: act.target) }
                } else {
                    activityOverlay?.discardApproach(for: act.target)
                }
            }
        }
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
            respond(request, .hello(HelloResult(helperVersion: "1.1.0", selectedVersion: Limits.version)))
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
                let body = try execute(request, mode: session.authority.mode, context: context, execution: entry.execution)
                if case .act = request.body {} else { try context.check() }
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
                    self.respond(request, self.interruptedBody(request, reason, execution: entry.execution)); return
                }
                do {
                    if case .observe(let observation) = result.body {
                        try self.observations.insert(observation, handle: result.handle)
                        self.livePreview?.follow(observation, target: (result.handle as? SemanticObservationHandle)?.target)
                    }
                    if case .waitFor(let wait) = result.body, let observation = wait.observation {
                        try self.observations.insert(observation, handle: result.handle)
                        self.livePreview?.follow(observation, target: (result.handle as? SemanticObservationHandle)?.target)
                    }
                    if case .act(let actRes) = result.body, let observation = actRes.observation {
                        try self.observations.insert(observation, handle: result.handle)
                        self.livePreview?.follow(observation, target: (result.handle as? SemanticObservationHandle)?.target)
                    }
                    if case .open(let openRes) = result.body, let observation = openRes.observation {
                        try self.observations.insert(observation, handle: result.handle)
                        self.livePreview?.follow(observation, target: (result.handle as? SemanticObservationHandle)?.target)
                    }
                    self.respond(request, result.body, activity: result.activity)
                } catch {
                    self.reject(request, code: .staleObservation, "session closed before observation publication")
                }
            }
        }
    }

    private func interrupt(_ entry: PendingRequest, reason: Interruption) {
        guard pending.removeValue(forKey: entry.request.id) != nil else { return }
        let body = interruptedBody(entry.request, reason, execution: entry.execution)
        entry.context.cancel()
        entry.timer.cancel()
        respond(entry.request, body)
    }

    private func interruptedBody(_ request: Request, _ reason: Interruption, execution: ActionExecutionState? = nil) -> ResponseBody {
        if case .act(let act) = request.body {
            if let execution { return .act(execution.interrupt(reason)) }
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

    private func execute(_ request: Request, mode: ExecutionMode, context: OperationContext, execution: ActionExecutionState?) throws -> NativeResult {
        try context.check()
        switch request.body {
        case .capabilities:
            let permissions = try system.permissions(context: context)
            var supported = system.supportedActions(permissions: permissions)
            if mode == .foregroundAllowed && permissions.inputPosting {
                if permissions.accessibility { supported.append(contentsOf: [.key, .hotkey, .typeKeys, .focusWindow]) }
                if #available(macOS 14.0, *), permissions.screenRecording {
                    supported.append(contentsOf: [.click, .doubleClick, .rightClick, .hover, .drag, .scrollWheel])
                }
            }
            return NativeResult(.capabilities(Capabilities(permissions: permissions, mode: mode, actions: supported)))
        case .targets(let params):
            return NativeResult(.targets(try system.targets(params, context: context)))
        case .open(let params):
            let opened = try system.open(params, context: context)
            if let after = params.observe, context.interruption == nil {
                let ordered = opened.targets.filter { $0.bounds.width >= 100 && $0.bounds.height >= 100 }
                    + opened.targets.filter { $0.bounds.width < 100 || $0.bounds.height < 100 }
                for candidate in ordered.prefix(4) {
                    if let native = try? system.observe(params: after.toObserveRequest(target: candidate.key),
                                                        observationId: nextObservationID(), context: context) {
                        let enriched = OpenResult(pid: opened.pid, bundleId: opened.bundleId,
                                                  activated: opened.activated, targets: opened.targets,
                                                  observation: native.observation)
                        return NativeResult(.open(enriched), handle: native.handle)
                    }
                }
            }
            return NativeResult(.open(opened))
        case .clipboard(let params):
            return NativeResult(.clipboard(try system.clipboard(params, context: context)))
        case .observe(let params):
            activityOverlay?.beginObservation(params.target)
            let native = try system.observe(params: params, observationId: nextObservationID(), context: context)
            return NativeResult(.observe(native.observation), handle: native.handle,
                activity: activityOverlay != nil || livePreview != nil ? .observing(native.observation) : nil)
        case .act(let act):
            if emitProgress == nil && act.steps.count > 1 && act.steps.contains(where: {
                if case .waitFor = $0.operation { return false }; return true
            }) { return NativeResult(rejectedAct(act, reason: .unsupported, stop: .unsupported)) }
            let retained: RetainedObservation
            do {
                retained = try observations.lookup(act.observationId, epoch: epoch, target: act.target)
            } catch let failure as NativeFailure where failure.code == .staleObservation {
                return NativeResult(rejectedAct(act, reason: .targetStale, stop: .targetStale))
            }
            guard let execution else { throw NativeFailure(.nativeFailed, "action state unavailable") }
            livePreview?.follow(retained.observation, target: (retained.handle as? SemanticObservationHandle)?.target,
                                onlyIfDifferent: true)
            let progress: BackgroundActions.ProgressSink?
            if let emitProgress {
                progress = { [self] prefix, context in
                    // Admission and timer finals share control ordering. Never wait for stdout while holding control.
                    let ticket = try control.sync {
                        guard !closed, pending[request.id]?.execution === execution, !execution.isSealed else {
                            throw NativeFailure(.cancelled, "request settled before progress admission")
                        }
                        try context.check()
                        return try emitProgress(UseUIProtocol.Progress(version: Limits.version, id: request.id, epoch: epoch,
                            observationId: act.observationId, steps: prefix))
                    }
                    try ticket.wait(context: context)
                }
            } else { progress = nil }
            let result = actions.act(act, entry: retained, context: context, state: execution,
                                     progress: progress, activityOverlay: activityOverlay)
            let activity = activityOverlay != nil || livePreview != nil
                ? DesktopActivity.action(act, result: result, observation: retained.observation) : nil
            if let after = act.observeAfter, result.stopReason == .completed, context.interruption == nil {
                if let native = try? system.observe(params: after.toObserveRequest(target: act.target),
                                                    observationId: nextObservationID(), context: context) {
                    let enriched = ActResult(observationId: result.observationId, steps: result.steps,
                                             remainingSteps: result.remainingSteps, stopReason: result.stopReason,
                                             feedback: result.feedback, foreground: result.foreground,
                                             observation: native.observation)
                    return NativeResult(.act(enriched), handle: native.handle, activity: activity)
                }
            }
            return NativeResult(.act(result), activity: activity)
        case .waitFor(let wait):
            let retained = try observations.lookup(wait.observationId, epoch: epoch, target: wait.target)
            let started = unixMilliseconds()
            let evaluated = try actions.wait(wait, entry: retained, context: context)
            guard evaluated.outcome == .satisfied else {
                return NativeResult(.waitFor(WaitResult(outcome: evaluated.outcome, alreadySatisfied: false, observation: nil)))
            }
            if case .windowAbsent = wait.condition {
                return NativeResult(.waitFor(WaitResult(outcome: .satisfied, alreadySatisfied: evaluated.alreadySatisfied,
                    observation: nil, evidence: evaluated.evidence)))
            }
            let observeParams: ObserveRequest
            if case .ocrContains(let ocr) = wait.condition, retained.handle is VisualObservationHandle {
                observeParams = ObserveRequest(target: wait.target, includeScreenshot: false,
                                               includeValues: wait.includeValues, includeOcr: true,
                                               ocrQuery: ocr.contains, cropWindow: ocr.cropWindow,
                                               scope: wait.scope)
            } else {
                observeParams = ObserveRequest(target: wait.target, includeScreenshot: false,
                                               includeValues: wait.includeValues, scope: wait.scope)
            }
            let native = try system.observe(params: observeParams, observationId: nextObservationID(), context: context)
            let original = native.observation
            let finished = max(started, original.collected.finishedUnixMs)
            let axInterval = original.accessibilityCollected.map {
                CollectionInterval(startedUnixMs: min(started, $0.startedUnixMs), finishedUnixMs: max(started, $0.finishedUnixMs))
            }
            let observation = Observation(observationId: original.observationId, target: original.target,
                collected: CollectionInterval(startedUnixMs: min(started, original.collected.startedUnixMs), finishedUnixMs: finished),
                windowBounds: original.windowBounds, accessibility: original.accessibility, accessibilityCollected: axInterval,
                elements: original.elements, screenshot: nil, visual: original.visual)
            return NativeResult(.waitFor(WaitResult(outcome: .satisfied, alreadySatisfied: evaluated.alreadySatisfied,
                observation: observation, evidence: evaluated.evidence)), handle: native.handle)
        case .hello, .cancel:
            throw NativeFailure(.invalidRequest, "control request reached native worker")
        }
    }

    private func nextObservationID() -> String {
        nextObsSeq += 1
        return "obs-\(nextObsSeq)"
    }
}

private func unixMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
