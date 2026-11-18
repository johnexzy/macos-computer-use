import AppKit
import ApplicationServices
import CUAProtocol
import Foundation

/// Setters must call willDispatch immediately before entering the actual mutation API.
public protocol AXMutating: Sendable {
    func setValue(_ value: String, on object: any AXObject, context: OperationContext,
                  willDispatch: @Sendable () throws -> Void) throws
    func press(_ object: any AXObject, context: OperationContext,
               willDispatch: @Sendable () throws -> Void) throws
    func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext,
                             willDispatch: @Sendable () throws -> Void) throws
}

public struct WaitEvaluation: Sendable {
    public let outcome: WaitOutcome
    public let alreadySatisfied: Bool
    public let evidence: CheckEvidence?
}

public struct BackgroundActions: Sendable {
    private let coordinator: MutationCoordinator
    private let foreground: @Sendable () -> UInt32?
    private let predicates: PredicateEvaluator
    private let now: @Sendable () -> UInt64
    private let foregroundPlatform: any ForegroundPlatform
    private let coordinateCapture: any VisualCapturing

    public init(coordinator: MutationCoordinator = MutationCoordinator(),
                predicates: PredicateEvaluator = PredicateEvaluator(),
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                foreground: @escaping @Sendable () -> UInt32? = {
                    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid > 0 else { return nil }
                    return UInt32(pid)
                }) {
        self.init(coordinator: coordinator, predicates: predicates, now: now, foreground: foreground,
                  foregroundPlatform: NativeForegroundPlatform(), coordinateCapture: ScreenWindowCapture())
    }

    init(coordinator: MutationCoordinator = MutationCoordinator(), predicates: PredicateEvaluator = PredicateEvaluator(),
         now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         foreground: @escaping @Sendable () -> UInt32? = { nil },
         foregroundPlatform: any ForegroundPlatform, coordinateCapture: any VisualCapturing) {
        self.coordinator = coordinator; self.foreground = foreground; self.predicates = predicates; self.now = now
        self.foregroundPlatform = foregroundPlatform; self.coordinateCapture = coordinateCapture
    }

    /// The sink must return only after a full progress frame is physically written.
    public typealias ProgressSink = @Sendable ([StepReceipt], OperationContext) throws -> Void

    public func act(_ request: ActRequest, entry: RetainedObservation, context: OperationContext,
                    state: ActionExecutionState, progress: ProgressSink? = nil) -> ActResult {
        let hasMutation = request.steps.contains { if case .waitFor = $0.operation { return false }; return true }
        if hasMutation && request.steps.count > 1 && progress == nil {
            state.finish(reason: .unsupported, stop: .unsupported); return state.snapshot()
        }
        let run = {
            let before = hasMutation && !request.foreground ? foreground() : nil
            if hasMutation && !request.foreground && before == nil { throw NativeFailure(.unsupported, "foreground baseline is unavailable") }
            defer {
                if !state.isSealed && before != nil {
                    // Cleanup must not seal a secondary foreground error ahead of a known interruption.
                    if let interruption = context.interruption { _ = state.interrupt(interruption) }
                    else {
                        do { try checkForeground(before, targetPID: request.target.pid) }
                        catch let failure as NativeFailure { finish(state, failure: failure) }
                        catch { state.finish(reason: .nativeFailed, stop: .failed) }
                    }
                }
            }
            let handle = try semanticHandle(entry, observationId: request.observationId, target: request.target)
            let foreground = request.foreground ? try ForegroundControl(platform: foregroundPlatform, capture: coordinateCapture,
                target: handle, context: context, state: state) : nil
            defer { foreground?.restore() }
            for step in request.steps {
                try state.checkActive(context: context)
                try checkLifetime(entry)
                try foreground?.checkContext()
                let reason: ReceiptReason?
                if case .waitFor(let wait) = step.operation {
                    reason = try waitStep(wait.condition, entry: entry, handle: handle, context: context,
                                          state: state, foreground: foreground)
                } else if let foreground {
                    let already = try executeForeground(step, entry: entry, handle: handle, context: context, state: state, control: foreground)
                    reason = already ? .alreadySatisfied : nil
                } else {
                    let already = try execute(step, entry: entry, handle: handle, context: context, state: state, before: before)
                    reason = already ? .alreadySatisfied : nil
                }
                try foreground?.checkContext()
                if before != nil { try checkForeground(before, targetPID: request.target.pid) }
                if let prefix = try state.settle(context: context, reason: reason), let progress {
                    try progress(prefix, context)
                }
            }
            if before != nil { try checkForeground(before, targetPID: request.target.pid) }
            foreground?.restore()
            try state.finalize(context: context)
        }
        do {
            if hasMutation { try coordinator.withOwnership(context: context, run) }
            else { try run() }
        } catch let error as NativeFailure { finish(state, failure: error) }
        catch let stopped as ForegroundStopped {
            switch stopped.reason {
            case .permissionUnavailable, .activationFailed: state.finish(reason: .unsupported, stop: .unsupported)
            case .frameChanged, .windowChanged: state.finish(reason: .targetStale, stop: .targetStale)
            default: state.finish(reason: .nativeFailed, stop: .failed)
            }
        }
        catch { state.finish(reason: .nativeFailed, stop: .failed) }
        if let requested = request.feedback {
            state.attachFeedback(FeedbackCollector().collect(requested, entry: entry, context: context))
        }
        return state.snapshot()
    }

    public func wait(_ request: WaitRequest, entry: RetainedObservation, context: OperationContext) throws -> WaitEvaluation {
        let handle = try semanticHandle(entry, observationId: request.observationId, target: request.target)
        var first = true
        while true {
            try context.check()
            try checkLifetime(entry)
            do {
                let evaluation = try predicates.evaluate(request.condition, handle: handle, context: context)
                if evaluation.matched == true {
                    return WaitEvaluation(outcome: .satisfied, alreadySatisfied: first, evidence: evaluation.evidence)
                }
            } catch is AXReadUnavailable { /* No state evidence; sample again within this budget. */ }
            first = false
            try pause(context)
        }
    }

    private func waitStep(_ condition: Condition, entry: RetainedObservation, handle: SemanticObservationHandle, context: OperationContext,
                          state: ActionExecutionState, foreground: ForegroundControl? = nil) throws -> ReceiptReason {
        var first = true
        while true {
            try state.checkActive(context: context)
            try checkLifetime(entry)
            try foreground?.checkContext()
            do {
                if let check = try evaluate(condition, handle: handle, context: context) {
                    state.checked([check], verification: check.matched ? .confirmed : .mismatch)
                    if check.matched { return first ? .alreadySatisfied : .conditionSatisfied }
                }
            } catch is AXReadUnavailable { /* Keep the last genuine witness, if any. */ }
            first = false
            try pause(context)
        }
    }

    private func executeForeground(_ step: ActionStep, entry: RetainedObservation, handle: SemanticObservationHandle,
                                   context: OperationContext, state: ActionExecutionState, control: ForegroundControl) throws -> Bool {
        let route: DeliveryRoute
        switch step.operation {
        case .click: route = .foregroundClick
        case .key: route = .foregroundKey
        default: throw NativeFailure(.unsupported, "foreground operation is not available")
        }
        func checkGuard() throws {
            guard let condition = step.precondition else { return }
            guard let check = try evaluate(condition, handle: handle, context: context) else {
                throw NativeFailure(.unsupported, "foreground precondition cannot be read")
            }
            if !check.matched {
                state.checked([check], verification: .unverified)
                state.finish(reason: .preconditionFailed, stop: .preconditionFailed)
                throw NativeFailure(.nativeFailed, "foreground precondition no longer holds")
            }
        }
        try checkGuard()
        if let expected = step.expect, let check = try evaluate(expected, handle: handle, context: context), check.matched {
            state.checked([check], verification: .confirmed)
            return true
        }

        try control.post(step.operation, observation: entry.observation, checkGuard: checkGuard) {
            try checkLifetime(entry)
            try state.beginDispatch(context: context, route: route)
        }
        state.returnedSuccessfully()
        guard let expected = step.expect else { return false }
        while true {
            try context.check()
            try checkLifetime(entry)
            do {
                let checks = try recordChecks([expected], handle: handle, context: context, state: state)
                if checks.first?.matched == true { return false }
            } catch is AXReadUnavailable { /* No usable observation at this sample. */ }
            try control.checkContext()
            try pause(context)
        }
    }

    private func execute(_ step: ActionStep, entry: RetainedObservation, handle: SemanticObservationHandle, context: OperationContext,
                         state: ActionExecutionState, before: UInt32?) throws -> Bool {
        try context.check()
        guard let writer = handle.backend as? any AXMutating else { throw NativeFailure(.unsupported, "semantic mutation backend unavailable") }
        let reference: String
        let route: DeliveryRoute
        switch step.operation {
        case .setValue(let value): reference = value.elementRef; route = .axSetValue
        case .press(let value): reference = value.elementRef; route = .axPress
        case .typeText(let value): reference = value.elementRef; route = .axSelectedText
        default: throw NativeFailure(.unsupported, "background operation is not implemented")
        }
        let resolved = try handle.resolve(reference, includeValue: true, context: context)
        try requireEnabledSnapshot(resolved.snapshot, allowUnsupported: route != .axPress)
        switch step.operation {
        case .setValue: guard resolved.snapshot.valueSettable else { throw NativeFailure(.unsupported, "AXValue is not settable") }
        case .press: guard resolved.snapshot.actions.contains("AXPress") else { throw NativeFailure(.unsupported, "AXPress is not advertised") }
        case .typeText: guard resolved.snapshot.selectedTextSettable else { throw NativeFailure(.unsupported, "AXSelectedText is not settable") }
        default: break
        }
        if let condition = step.precondition {
            guard let check = try evaluate(condition, handle: handle, context: context) else {
                throw NativeFailure(.unsupported, "precondition cannot be read")
            }
            if !check.matched {
                state.checked([check], verification: .unverified)
                state.finish(reason: .preconditionFailed, stop: .preconditionFailed)
                return false
            }
        }
        var required: [Condition] = []
        var privateTextExpectation: String?
        switch step.operation {
        case .setValue(let value): required.append(.valueEquals(ValueCondition(elementRef: reference, value: value.value)))
        case .typeText(let value):
            let expected = expectedEdit(value.text, snapshot: resolved.snapshot)
            let disclosed = expected.map { expected in
                handle.includeValues || step.expect == .valueEquals(ValueCondition(elementRef: reference, value: expected))
            } ?? false
            if let expected, disclosed { required.append(.valueEquals(ValueCondition(elementRef: reference, value: expected))) }
            else { privateTextExpectation = expected }
            if (expected == nil || !disclosed) && step.expect != nil {
                throw NativeFailure(.unsupported, "exact text-edit proof is unavailable without disclosing existing values")
            }
        default: break
        }
        if let expected = step.expect, !required.contains(expected) { required.append(expected) }
        let canSkip: Bool
        if case .setValue = step.operation { canSkip = true } else { canSkip = step.expect != nil }
        if canSkip && !required.isEmpty {
            let checks = try required.compactMap { try evaluate($0, handle: handle, context: context) }
            if checks.count == required.count && checks.allSatisfy(\.matched) {
                state.checked(checks, verification: .confirmed)
                return true
            }
        }
        try checkForeground(before, targetPID: handle.target.key.pid)
        try context.check()
        // Resolve again inside the shared mutation boundary; never reselect by a label.
        let typing: Bool
        if case .typeText = step.operation { typing = true } else { typing = false }
        let live = try handle.resolve(reference, includeValue: typing, context: context)
        guard handle.backend.same(live.object, resolved.object) else {
            throw NativeFailure(.staleElement, "target changed before dispatch")
        }
        try requireEnabledSnapshot(live.snapshot, allowUnsupported: route != .axPress)
        if typing && (live.snapshot.value != resolved.snapshot.value || live.snapshot.selectedRange != resolved.snapshot.selectedRange) {
            throw NativeFailure(.staleElement, "text value or selection changed before dispatch")
        }
        let handoff: @Sendable () throws -> Void = {
            try checkLifetime(entry)
            if let condition = step.precondition {
                guard let check = try evaluate(condition, handle: handle, context: context) else {
                    throw NativeFailure(.unsupported, "precondition cannot be read before dispatch")
                }
                if !check.matched {
                    state.checked([check], verification: .unverified)
                    state.finish(reason: .preconditionFailed, stop: .preconditionFailed)
                    throw NativeFailure(.nativeFailed, "precondition changed before dispatch")
                }
            }
            try checkForeground(before, targetPID: handle.target.key.pid)
            try checkLifetime(entry)
            try state.beginDispatch(context: context, route: route)
        }
        var mutationFailure: NativeFailure?
        do {
            switch step.operation {
            case .setValue(let value):
                try writer.setValue(value.value, on: resolved.object, context: context, willDispatch: handoff)
            case .press:
                try writer.press(resolved.object, context: context, willDispatch: handoff)
            case .typeText(let value):
                try writer.replaceSelectedText(value.text, on: resolved.object, context: context, willDispatch: handoff)
            default: break
            }
            state.returnedSuccessfully()
        } catch let error as NativeFailure { mutationFailure = error }
        catch { mutationFailure = NativeFailure(.nativeFailed, "native action returned an error") }
        if !state.hasEnteredDispatch, let mutationFailure { throw mutationFailure }
        if required.isEmpty && privateTextExpectation == nil {
            try checkForeground(before, targetPID: handle.target.key.pid)
            if let mutationFailure { throw mutationFailure }
            return false
        }
        while true {
            try context.check()
            try checkLifetime(entry)
            do {
                let checks = try recordChecks(required, handle: handle, context: context, state: state)
                let privateMatched: Bool
                if let expected = privateTextExpectation {
                    let current = try handle.resolve(reference, includeValue: true, context: context)
                    guard handle.backend.same(current.object, resolved.object) else { throw NativeFailure(.staleElement, "readback target changed") }
                    privateMatched = current.snapshot.value == expected
                } else { privateMatched = true }
                try checkForeground(before, targetPID: handle.target.key.pid)
                if let mutationFailure { throw mutationFailure }
                if checks.count == required.count && checks.allSatisfy(\.matched) && privateMatched { return false }
            } catch is AXReadUnavailable {
                // Only effect reads may repeat. An actual setter error must still stop this action.
                if let mutationFailure { throw mutationFailure }
                try checkForeground(before, targetPID: handle.target.key.pid)
            }
            try pause(context)
        }
    }

    private func recordChecks(_ required: [Condition], handle: SemanticObservationHandle,
                              context: OperationContext, state: ActionExecutionState) throws -> [ActionWitness] {
        var checks: [ActionWitness] = []
        for condition in required {
            if let check = try evaluate(condition, handle: handle, context: context) { checks.append(check) }
            let verification: Verification = checks.contains(where: { !$0.matched }) ? .mismatch
                : checks.count == required.count ? .confirmed : .unverified
            // Retain each completed read even if a later read fails or the timer settles the request.
            state.checked(checks, verification: verification)
        }
        return checks
    }

    private func checkLifetime(_ entry: RetainedObservation) throws {
        if now() >= entry.createdAt + UInt64(Limits.observationTTLMS) * 1_000_000 {
            throw NativeFailure(.staleObservation, "origin observation expired during execution")
        }
    }

    private func semanticHandle(_ entry: RetainedObservation, observationId: String, target: TargetKey) throws -> SemanticObservationHandle {
        guard entry.observation.observationId == observationId, entry.observation.target == target,
              let handle = entry.handle as? SemanticObservationHandle, handle.observationId == observationId,
              handle.target.key == target else { throw NativeFailure(.staleObservation, "semantic observation is unavailable or belongs to another target") }
        return handle
    }

    private func evaluate(_ condition: Condition, handle: SemanticObservationHandle, context: OperationContext) throws -> ActionWitness? {
        let result = try predicates.evaluate(condition, handle: handle, context: context)
        guard let evidence = result.evidence else { return nil }
        return ActionWitness(observationId: evidence.observationId, collected: result.collected,
            target: result.target, elementRef: result.elementRef, condition: evidence.condition, matched: evidence.matched)
    }

    private func expectedEdit(_ text: String, snapshot: AXNodeSnapshot) -> String? {
        guard let value = snapshot.value, let selected = snapshot.selectedRange,
              selected.location >= 0, selected.length >= 0, selected.location <= value.utf16.count,
              selected.length <= value.utf16.count - selected.location,
              let range = Range(NSRange(location: selected.location, length: selected.length), in: value) else { return nil }
        return value.replacingCharacters(in: range, with: text)
    }

    private func pause(_ context: OperationContext) throws {
        Thread.sleep(forTimeInterval: Double(try context.nativeTimeoutSeconds(maximum: 0.005)))
    }
    private func checkForeground(_ before: UInt32?, targetPID: UInt32) throws {
        guard let current = foreground() else { throw NativeFailure(.unsupported, "foreground state is unavailable") }
        // Exact AX input does not depend on which unrelated app the person is using.
        if before != targetPID && current == targetPID {
            throw NativeFailure(.nativeFailed, "controlled target became foreground during background operation")
        }
    }
    private func finish(_ state: ActionExecutionState, failure: NativeFailure) {
        switch failure.code {
        case .cancelled: _ = state.interrupt(.cancelled)
        case .deadlineExceeded: _ = state.interrupt(.deadlineExceeded)
        case .unsupported: state.finish(reason: .unsupported, stop: .unsupported)
        case .ambiguousTarget: state.finish(reason: .ambiguousTarget, stop: .ambiguousTarget)
        case .staleElement, .staleObservation, .targetNotFound: state.finish(reason: .targetStale, stop: .targetStale)
        default: state.finish(reason: .nativeFailed, stop: .failed)
        }
    }
}

private func milliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

extension MacOSAXBackend: AXMutating {
    public func setValue(_ value: String, on object: any AXObject, context: OperationContext,
                         willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(object, context: context)
        try requireEnabled(element, allowUnsupported: true, context: context)
        try requireSettable(kAXValueAttribute as CFString, element: element, context: context)
        try installTimeout(element, context: context)
        try willDispatch()
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString) == .success else {
            throw NativeFailure(.nativeFailed, "AXSetValue returned an error")
        }
    }
    public func press(_ object: any AXObject, context: OperationContext,
                      willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(object, context: context)
        try requireEnabled(element, allowUnsupported: false, context: context)
        try installTimeout(element, context: context)
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              (names as? [String])?.contains(kAXPressAction as String) == true else {
            throw NativeFailure(.unsupported, "AXPress is not currently advertised")
        }
        try installTimeout(element, context: context)
        try willDispatch()
        guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
            throw NativeFailure(.nativeFailed, "AXPress returned an error")
        }
    }
    public func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext,
                                    willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(object, context: context)
        try requireEnabled(element, allowUnsupported: true, context: context)
        try requireSettable(kAXSelectedTextAttribute as CFString, element: element, context: context)
        try installTimeout(element, context: context)
        try willDispatch()
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            throw NativeFailure(.nativeFailed, "AXSelectedText replacement returned an error")
        }
    }
}

private func nativeElement(_ object: any AXObject, context: OperationContext) throws -> AXUIElement {
    guard let object = object as? NativeAXObject else { throw NativeFailure(.unsupported, "not a native AX object") }
    try installTimeout(object.element, context: context)
    return object.element
}
private func installTimeout(_ element: AXUIElement, context: OperationContext) throws {
    let timeout = try context.nativeTimeoutSeconds()
    guard AXUIElementSetMessagingTimeout(element, timeout) == .success else {
        throw NativeFailure(.nativeFailed, "could not install exact-object AX timeout")
    }
}
private func requireSettable(_ attribute: CFString, element: AXUIElement, context: OperationContext) throws {
    try installTimeout(element, context: context)
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, attribute, &settable) == .success, settable.boolValue else {
        throw NativeFailure(.unsupported, "AX attribute is not currently settable")
    }
}
private func requireEnabledSnapshot(_ snapshot: AXNodeSnapshot, allowUnsupported: Bool) throws {
    if snapshot.enabledKnown {
        guard snapshot.enabled else { throw NativeFailure(.unsupported, "target is disabled") }
    } else {
        guard allowUnsupported && snapshot.enabledUnsupported && isWritableAXTextRole(snapshot.role) else {
            throw NativeFailure(.unsupported, "target enabled state is unavailable")
        }
    }
}
private func requireEnabled(_ element: AXUIElement, allowUnsupported: Bool, context: OperationContext) throws {
    try installTimeout(element, context: context)
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
    let enabled = try decodeAXEnabled(result, value: value, context: context)
    if enabled.value == true { return }
    if allowUnsupported && enabled.unsupported {
        try installTimeout(element, context: context)
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        try checkAXRead(result, context: context, allowMissing: true)
        if let role = role as? String, isWritableAXTextRole(role) { return }
    }
    throw NativeFailure(.unsupported, "AX target is disabled or its enabled state is unavailable")
}
