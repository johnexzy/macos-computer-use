import AppKit
import ApplicationServices
import UseUIProtocol
import Foundation

/// Setters must call willDispatch immediately before entering the actual mutation API.
public protocol AXMutating: Sendable {
    func setValue(_ value: String, on object: any AXObject, context: OperationContext,
                  willDispatch: @Sendable () throws -> Void) throws
    func press(_ object: any AXObject, context: OperationContext,
               willDispatch: @Sendable () throws -> Void) throws
    func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext,
                             willDispatch: @Sendable () throws -> Void) throws
    func scrollToVisible(_ object: any AXObject, context: OperationContext,
                         willDispatch: @Sendable () throws -> Void) throws
    func confirm(_ object: any AXObject, context: OperationContext,
                 willDispatch: @Sendable () throws -> Void) throws
    func showMenu(_ object: any AXObject, context: OperationContext,
                  willDispatch: @Sendable () throws -> Void) throws
    func cancel(_ object: any AXObject, context: OperationContext,
                willDispatch: @Sendable () throws -> Void) throws
    func invokeMenu(_ path: [String], on application: any AXObject, window: any AXObject, context: OperationContext,
                    willDispatch: @Sendable () throws -> Void) throws
    func setWindowFrame(_ bounds: Rect, on window: any AXObject, windowId: UInt32, context: OperationContext,
                        willDispatch: @Sendable () throws -> Void) throws
    func windowAction(_ action: WindowActionKind, on window: any AXObject, context: OperationContext,
                      willDispatch: @Sendable () throws -> Void) throws
}

public extension AXMutating {
    func scrollToVisible(_ object: any AXObject, context: OperationContext,
                         willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "AXScrollToVisible is not supported by this backend")
    }
    func confirm(_ object: any AXObject, context: OperationContext,
                 willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "AXConfirm is not supported by this backend")
    }
    func showMenu(_ object: any AXObject, context: OperationContext,
                  willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "AXShowMenu is not supported by this backend")
    }
    func cancel(_ object: any AXObject, context: OperationContext,
                willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "AXCancel is not supported by this backend")
    }
    func invokeMenu(_ path: [String], on application: any AXObject, window: any AXObject, context: OperationContext,
                    willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "AXMenuBar invocation is not supported by this backend")
    }
    func setWindowFrame(_ bounds: Rect, on window: any AXObject, windowId: UInt32, context: OperationContext,
                        willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "AX window frame mutation is not supported by this backend")
    }
    func windowAction(_ action: WindowActionKind, on window: any AXObject, context: OperationContext,
                      willDispatch: @Sendable () throws -> Void) throws {
        throw NativeFailure(.unsupported, "AX window actions are not supported by this backend")
    }
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
        act(request, entry: entry, context: context, state: state, progress: progress, activityOverlay: nil)
    }

    func act(_ request: ActRequest, entry: RetainedObservation, context: OperationContext,
             state: ActionExecutionState, progress: ProgressSink?, activityOverlay: DesktopActivityOverlay?) -> ActResult {
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
            let handle: SemanticObservationHandle?
            let foreground: ForegroundControl?
            if request.foreground, let visual = entry.handle as? VisualObservationHandle {
                guard visual.observationId == request.observationId, visual.target.key == request.target,
                      entry.observation.target == request.target else {
                    throw NativeFailure(.staleObservation, "visual observation does not belong to this request")
                }
                guard request.steps.allSatisfy({ step in
                    switch step.operation {
                    case .click, .doubleClick, .rightClick, .hover, .drag, .scrollWheel:
                        return step.precondition == nil && step.expect == nil
                    default:
                        return false
                    }
                }) else {
                    throw NativeFailure(.unsupported, "visual observations support only foreground pointer actions without AX conditions")
                }
                handle = nil
                foreground = try ForegroundControl(platform: foregroundPlatform, capture: coordinateCapture,
                    target: .visual(visual), context: context, state: state)
            } else {
                let semantic = try semanticHandle(entry, observationId: request.observationId, target: request.target)
                handle = semantic
                foreground = request.foreground ? try ForegroundControl(platform: foregroundPlatform, capture: coordinateCapture,
                    target: .semantic(semantic), context: context, state: state) : nil
            }
            defer { foreground?.restore() }
            for step in request.steps {
                try state.checkActive(context: context)
                try checkLifetime(entry)
                try foreground?.checkContext()
                let reason: ReceiptReason?
                if case .waitFor(let wait) = step.operation, let handle {
                    reason = try waitStep(wait.condition, entry: entry, handle: handle, context: context,
                                          state: state, foreground: foreground)
                } else if let foreground {
                    let already = try executeForeground(step, entry: entry, handle: handle, context: context,
                                                        state: state, control: foreground, activityOverlay: activityOverlay)
                    reason = already ? .alreadySatisfied : nil
                } else if let handle {
                    let already = try execute(step, entry: entry, handle: handle, context: context,
                                              state: state, before: before, activityOverlay: activityOverlay)
                    reason = already ? .alreadySatisfied : nil
                } else { throw NativeFailure(.unsupported, "action requires a semantic observation") }
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
        if let visual = entry.handle as? VisualObservationHandle {
            guard entry.observation.observationId == request.observationId, entry.observation.target == request.target,
                  visual.observationId == request.observationId, visual.target.key == request.target else {
                throw NativeFailure(.staleObservation, "visual observation is unavailable or belongs to another target")
            }
            var first = true
            while true {
                try context.check()
                try checkLifetime(entry)
                let evaluation = try predicates.evaluate(request.condition, visualHandle: visual, context: context)
                if evaluation.matched == true {
                    return WaitEvaluation(outcome: .satisfied, alreadySatisfied: first, evidence: evaluation.evidence)
                }
                first = false
                try pause(context, for: request.condition)
            }
        }
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
            try pause(context, for: request.condition)
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
            try pause(context, for: condition)
        }
    }

    private func executeForeground(_ step: ActionStep, entry: RetainedObservation, handle: SemanticObservationHandle?,
                                   context: OperationContext, state: ActionExecutionState, control: ForegroundControl,
                                   activityOverlay: DesktopActivityOverlay?) throws -> Bool {
        let route: DeliveryRoute
        switch step.operation {
        case .click: route = .foregroundClick
        case .doubleClick: route = .foregroundDoubleClick
        case .rightClick: route = .foregroundRightClick
        case .hover: route = .foregroundHover
        case .drag: route = .foregroundDrag
        case .scrollWheel: route = .foregroundScrollWheel
        case .focusWindow: route = .foregroundFocus
        case .key: route = .foregroundKey
        case .hotkey: route = .foregroundHotkey
        case .typeKeys: route = .foregroundTypeKeys
        default: throw NativeFailure(.unsupported, "foreground operation is not available")
        }
        func checkGuard() throws {
            guard let condition = step.precondition else { return }
            guard let handle, let check = try evaluate(condition, handle: handle, context: context) else {
                throw NativeFailure(.unsupported, "foreground precondition cannot be read")
            }
            if !check.matched {
                state.checked([check], verification: .unverified)
                state.finish(reason: .preconditionFailed, stop: .preconditionFailed)
                throw NativeFailure(.nativeFailed, "foreground precondition no longer holds")
            }
        }
        try checkGuard()
        if let expected = step.expect, let handle, let check = try evaluate(expected, handle: handle, context: context), check.matched {
            state.checked([check], verification: .confirmed)
            return true
        }

        let approach: ((Point) throws -> Void)? = activityOverlay.map { overlay in
            { point in
                _ = try overlay.approach(.approaching(control.window, screenPoint: point), context: context)
                try checkLifetime(entry)
            }
        }
        try control.post(step.operation, observation: entry.observation, checkGuard: checkGuard, beforeClick: approach) {
            try checkLifetime(entry)
            try state.beginDispatch(context: context, route: route)
        }
        state.returnedSuccessfully()
        guard let expected = step.expect, let handle else { return false }
        while true {
            try context.check()
            try checkLifetime(entry)
            do {
                let checks = try recordChecks([expected], handle: handle, context: context, state: state)
                if checks.first?.matched == true { return false }
            } catch is AXReadUnavailable { /* No usable observation at this sample. */ }
            try control.checkContext()
            try pause(context, for: expected)
        }
    }

    private func execute(_ step: ActionStep, entry: RetainedObservation, handle: SemanticObservationHandle, context: OperationContext,
                         state: ActionExecutionState, before: UInt32?, activityOverlay: DesktopActivityOverlay?) throws -> Bool {
        try context.check()
        guard let writer = handle.backend as? any AXMutating else { throw NativeFailure(.unsupported, "semantic mutation backend unavailable") }

        if case .invokeMenu(let menu) = step.operation {
            return try executeWindowOperation(route: .axMenu, step: step, entry: entry, handle: handle,
                                              context: context, state: state, before: before) { handoff in
                try writer.invokeMenu(menu.path, on: handle.application, window: handle.retainedWindow,
                                      context: context, willDispatch: handoff)
            }
        }
        if case .setWindowFrame(let frame) = step.operation {
            return try executeWindowOperation(route: .axWindowFrame, step: step, entry: entry, handle: handle,
                                              context: context, state: state, before: before) { handoff in
                try writer.setWindowFrame(frame.bounds, on: handle.retainedWindow, windowId: handle.target.key.windowId,
                                          context: context, willDispatch: handoff)
            }
        }
        if case .windowAction(let winAction) = step.operation {
            return try executeWindowOperation(route: .axWindowAction, step: step, entry: entry, handle: handle,
                                              context: context, state: state, before: before) { handoff in
                try writer.windowAction(winAction.action, on: handle.retainedWindow, context: context, willDispatch: handoff)
            }
        }

        let reference: String
        let route: DeliveryRoute
        switch step.operation {
        case .setValue(let value): reference = value.elementRef; route = .axSetValue
        case .press(let value): reference = value.elementRef; route = .axPress
        case .typeText(let value): reference = value.elementRef; route = .axSelectedText
        case .scroll(let value): reference = value.elementRef; route = .axScroll
        case .scrollToVisible(let value): reference = value.elementRef; route = .axScrollToVisible
        case .confirm(let value): reference = value.elementRef; route = .axConfirm
        case .showMenu(let value): reference = value.elementRef; route = .axShowMenu
        case .cancel(let value): reference = value.elementRef; route = .axCancel
        default: throw NativeFailure(.unsupported, "background operation is not implemented")
        }
        let needsValue = route == .axSetValue || route == .axSelectedText
        let resolved = try handle.resolve(reference, includeValue: needsValue, context: context)
        if route == .axScroll {
            guard resolved.snapshot.availableActions(backend: handle.backend).contains(.scroll),
                  !resolved.snapshot.enabledKnown || resolved.snapshot.enabled else {
                throw NativeFailure(.unsupported, "scroll requires a live AX scroll area")
            }
        } else if route == .axScrollToVisible {
            guard resolved.snapshot.actions.contains("AXScrollToVisible"),
                  !resolved.snapshot.enabledKnown || resolved.snapshot.enabled else {
                throw NativeFailure(.unsupported, "AXScrollToVisible is not advertised or target is disabled")
            }
        } else {
            let allowUnsupportedEnabled = route == .axSetValue || route == .axSelectedText || route == .axConfirm || route == .axCancel
            try requireEnabledSnapshot(resolved.snapshot, allowUnsupported: allowUnsupportedEnabled)
        }
        switch step.operation {
        case .setValue: guard resolved.snapshot.valueSettable else { throw NativeFailure(.unsupported, "AXValue is not settable") }
        case .press: guard resolved.snapshot.actions.contains(kAXPressAction as String) else { throw NativeFailure(.unsupported, "AXPress is not advertised") }
        case .typeText: guard resolved.snapshot.selectedTextSettable else { throw NativeFailure(.unsupported, "AXSelectedText is not settable") }
        case .confirm: guard resolved.snapshot.actions.contains(kAXConfirmAction as String) else { throw NativeFailure(.unsupported, "AXConfirm is not advertised") }
        case .showMenu: guard resolved.snapshot.actions.contains(kAXShowMenuAction as String) else { throw NativeFailure(.unsupported, "AXShowMenu is not advertised") }
        case .cancel: guard resolved.snapshot.actions.contains(kAXCancelAction as String) else { throw NativeFailure(.unsupported, "AXCancel is not advertised") }
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
        let writing = route == .axSelectedText || (route == .axSetValue && DesktopActivity.textRole(resolved.snapshot.role))
        let approached = try activityOverlay?.approach(.approaching(handle.target, control: resolved.snapshot.bounds, writing: writing),
                                                       context: context) ?? false
        if approached { try checkLifetime(entry) }
        // Resolve again inside the shared mutation boundary; never reselect by a label.
        let typing: Bool
        if case .typeText = step.operation { typing = true } else { typing = false }
        let live = try handle.resolve(reference, includeValue: typing, context: context)
        guard handle.backend.same(live.object, resolved.object) else {
            throw NativeFailure(.staleElement, "target changed before dispatch")
        }
        if approached && live.snapshot.bounds != resolved.snapshot.bounds {
            throw NativeFailure(.staleElement, "control moved during visual approach")
        }
        if route == .axScroll || route == .axScrollToVisible {
            if live.snapshot.enabledKnown && !live.snapshot.enabled {
                throw NativeFailure(.unsupported, "scroll target is disabled")
            }
        } else {
            let allowUnsupportedEnabled = route == .axSetValue || route == .axSelectedText || route == .axConfirm || route == .axCancel
            try requireEnabledSnapshot(live.snapshot, allowUnsupported: allowUnsupportedEnabled)
        }
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
            case .scroll(let value):
                let moved = try scroll(value, area: live.object, handle: handle, entry: entry, state: state,
                                       context: context, before: before, willDispatch: handoff)
                if !moved {
                    state.finish(reason: .verificationFailed, stop: .verificationFailed)
                    return false
                }
            case .scrollToVisible:
                try writer.scrollToVisible(resolved.object, context: context, willDispatch: handoff)
            case .confirm:
                try writer.confirm(resolved.object, context: context, willDispatch: handoff)
            case .showMenu:
                try writer.showMenu(resolved.object, context: context, willDispatch: handoff)
            case .cancel:
                try writer.cancel(resolved.object, context: context, willDispatch: handoff)
            default: break
            }
            if route != .axScroll { state.returnedSuccessfully() }
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
            try pause(context, for: step.expect)
        }
    }

    private func executeWindowOperation(route: DeliveryRoute, step: ActionStep, entry: RetainedObservation,
                                        handle: SemanticObservationHandle, context: OperationContext,
                                        state: ActionExecutionState, before: UInt32?,
                                        perform: (@Sendable () throws -> Void) throws -> Void) throws -> Bool {
        try handle.validateWindow(context: context)
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
        if let expected = step.expect, let check = try evaluate(expected, handle: handle, context: context), check.matched {
            state.checked([check], verification: .confirmed)
            return true
        }
        try checkForeground(before, targetPID: handle.target.key.pid)
        try context.check()
        let handoff: @Sendable () throws -> Void = {
            try checkLifetime(entry)
            try handle.validateWindow(context: context)
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
            try perform(handoff)
            state.returnedSuccessfully()
        } catch let error as NativeFailure { mutationFailure = error }
        catch { mutationFailure = NativeFailure(.nativeFailed, "native window operation returned an error") }
        if !state.hasEnteredDispatch, let mutationFailure { throw mutationFailure }
        guard let expected = step.expect else {
            try checkForeground(before, targetPID: handle.target.key.pid)
            if let mutationFailure { throw mutationFailure }
            return false
        }
        while true {
            try context.check()
            try checkLifetime(entry)
            do {
                let checks = try recordChecks([expected], handle: handle, context: context, state: state)
                try checkForeground(before, targetPID: handle.target.key.pid)
                if let mutationFailure { throw mutationFailure }
                if checks.first?.matched == true { return false }
            } catch is AXReadUnavailable {
                if let mutationFailure { throw mutationFailure }
                try checkForeground(before, targetPID: handle.target.key.pid)
            }
            try pause(context, for: expected)
        }
    }

    private func scroll(_ operation: ScrollOperation, area: any AXObject, handle: SemanticObservationHandle,
                        entry: RetainedObservation, state: ActionExecutionState, context: OperationContext, before: UInt32?,
                        willDispatch: @Sendable () throws -> Void) throws -> Bool {
        guard let scroller = handle.backend as? any AXScrolling,
              let initial = try scroller.scrollbar(in: area, axis: operation.axis, context: context) else {
            throw NativeFailure(.unsupported, "axis has no readable, writable scrollbar")
        }
        let requested = min(1, max(0, initial.position + Double(operation.amount) / 1000))
        guard requested != initial.position else { return false }
        try handle.validateOwner(of: initial.object, context: context)
        try handle.validateWindow(context: context)
        try scroller.setScrollPosition(requested, on: initial.object, context: context, willDispatch: willDispatch)
        state.returnedSuccessfully()
        while true {
            try context.check()
            try checkLifetime(entry)
            try checkForeground(before, targetPID: handle.target.key.pid)
            do {
                guard let current = try scroller.scrollbar(in: area, axis: operation.axis, context: context),
                      handle.backend.same(current.object, initial.object) else {
                    throw NativeFailure(.staleElement, "scrollbar changed before readback")
                }
                if operation.amount > 0 ? current.position > initial.position : current.position < initial.position {
                    try handle.validateWindow(context: context)
                    return true
                }
            } catch is AXReadUnavailable { /* A transient AX read can be repeated. */ }
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

    private func pause(_ context: OperationContext, for condition: Condition? = nil) throws {
        let maxDelay: Double
        if case .ocrContains = condition { maxDelay = 0.1 } else { maxDelay = 0.005 }
        Thread.sleep(forTimeInterval: Double(try context.nativeTimeoutSeconds(maximum: maxDelay)))
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
        try checkAXMutation(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString),
                            action: "AXSetValue", context: context)
    }
    public func press(_ object: any AXObject, context: OperationContext,
                      willDispatch: @Sendable () throws -> Void) throws {
        try performAXAction(kAXPressAction as String, on: object, allowUnsupportedEnabled: false,
                            context: context, willDispatch: willDispatch)
    }
    public func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext,
                                    willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(object, context: context)
        try requireEnabled(element, allowUnsupported: true, context: context)
        try requireSettable(kAXSelectedTextAttribute as CFString, element: element, context: context)
        try installTimeout(element, context: context)
        try willDispatch()
        try checkAXMutation(AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString),
                            action: "AXSelectedText", context: context)
    }
    public func scrollToVisible(_ object: any AXObject, context: OperationContext,
                                willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(object, context: context)
        try installTimeout(element, context: context)
        var enabledValue: CFTypeRef?
        let enabledResult = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue)
        let enabled = try decodeAXEnabled(enabledResult, value: enabledValue, context: context)
        if enabled.value == false {
            throw NativeFailure(.unsupported, "AX target is disabled")
        }
        try installTimeout(element, context: context)
        guard try readAXActionNames(element, context: context).contains("AXScrollToVisible") else {
            throw NativeFailure(.unsupported, "AXScrollToVisible is not currently advertised")
        }
        try installTimeout(element, context: context)
        try willDispatch()
        try checkAXMutation(AXUIElementPerformAction(element, "AXScrollToVisible" as CFString),
                            action: "AXScrollToVisible", context: context)
    }
    public func confirm(_ object: any AXObject, context: OperationContext,
                        willDispatch: @Sendable () throws -> Void) throws {
        try performAXAction(kAXConfirmAction as String, on: object, allowUnsupportedEnabled: true,
                            context: context, willDispatch: willDispatch)
    }
    public func showMenu(_ object: any AXObject, context: OperationContext,
                         willDispatch: @Sendable () throws -> Void) throws {
        try performAXAction(kAXShowMenuAction as String, on: object, allowUnsupportedEnabled: false,
                            context: context, willDispatch: willDispatch)
    }
    public func cancel(_ object: any AXObject, context: OperationContext,
                       willDispatch: @Sendable () throws -> Void) throws {
        try performAXAction(kAXCancelAction as String, on: object, allowUnsupportedEnabled: true,
                            context: context, willDispatch: willDispatch)
    }
    public func invokeMenu(_ path: [String], on application: any AXObject, window: any AXObject, context: OperationContext,
                           willDispatch: @Sendable () throws -> Void) throws {
        guard path.count >= 2 else { throw NativeFailure(.invalidRequest, "menu path requires at least two segments") }
        guard let barObj = try menuBar(of: application, context: context) else {
            throw NativeFailure(.unsupported, "application menu bar is unavailable")
        }
        var current: AXUIElement = try nativeElement(barObj, context: context)
        var leaf: AXUIElement?
        for (index, segment) in path.enumerated() {
            try context.check()
            let children = try menuChildren(of: current, context: context)
            var matches: [AXUIElement] = []
            for child in children {
                if try menuTitle(of: child, context: context) == segment {
                    matches.append(child)
                }
            }
            guard !matches.isEmpty else {
                throw NativeFailure(.targetNotFound, "menu item '\(segment)' not found")
            }
            guard matches.count == 1 else {
                throw NativeFailure(.ambiguousTarget, "multiple menu items match '\(segment)'")
            }
            let item = matches[0]
            if index + 1 == path.count {
                leaf = item
            } else {
                // Top-level AXMenuBarItem or submenu AXMenuItem wraps an AXMenu child.
                let sub = try menuChildren(of: item, context: context)
                guard let submenu = sub.first else {
                    throw NativeFailure(.targetNotFound, "submenu unavailable under '\(segment)'")
                }
                current = submenu
            }
        }
        guard let targetItem = leaf else { throw NativeFailure(.targetNotFound, "menu item not found") }
        try requireEnabled(targetItem, allowUnsupported: false, context: context)
        try installTimeout(targetItem, context: context)
        guard try readAXActionNames(targetItem, context: context).contains(kAXPressAction as String) else {
            throw NativeFailure(.unsupported, "menu item does not advertise AXPress")
        }
        let windowElement = try nativeElement(window, context: context)
        var shouldSetMain = false
        var rawMain: CFTypeRef?
        let mainRead = AXUIElementCopyAttributeValue(windowElement, kAXMainAttribute as CFString, &rawMain)
        try checkAXRead(mainRead, context: context, allowMissing: true)
        if mainRead == .success, let flag = rawMain as? NSNumber, !flag.boolValue {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(windowElement, kAXMainAttribute as CFString, &settable) == .success,
               settable.boolValue {
                shouldSetMain = true
            }
        }
        try installTimeout(targetItem, context: context)
        try willDispatch()
        // Target the requested window within the background application without activating it.
        if shouldSetMain {
            try installTimeout(windowElement, context: context)
            _ = AXUIElementSetAttributeValue(windowElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        try checkAXMutation(AXUIElementPerformAction(targetItem, kAXPressAction as CFString),
                            action: "AXMenuPress", context: context)
    }

    public func setWindowFrame(_ bounds: Rect, on window: any AXObject, windowId: UInt32, context: OperationContext,
                               willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(window, context: context)
        try requireSettable(kAXPositionAttribute as CFString, element: element, context: context)
        try requireSettable(kAXSizeAttribute as CFString, element: element, context: context)
        var origin = CGPoint(x: bounds.x, y: bounds.y)
        var size = CGSize(width: bounds.width, height: bounds.height)
        guard let posValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else {
            throw NativeFailure(.nativeFailed, "unable to encode window frame AXValue")
        }
        func readCGRect() -> CGRect? {
            guard windowId > 0,
                  let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(windowId)) as? [[String: Any]],
                  let b = rows.first?[kCGWindowBounds as String] as? [String: Double],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"] else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        // Poll the live WindowServer bounds (O(1) per-window lookup) rather than AXPosition/AXSize,
        // because apps with AXEnhancedUserInterface report target AX values immediately while AppKit
        // still animates the window frame asynchronously (~150-200ms). Waiting for live bounds to
        // settle prevents AXSize from colliding with an in-flight AXPosition animation.
        func settle<T: Equatable>(_ read: () -> T?, initial: T?, target: T) {
            let deadline = min(context.deadlineNanoseconds, DispatchTime.now().uptimeNanoseconds + 500_000_000)
            var last = read()
            if last == target { return }
            var stable = 0
            while DispatchTime.now().uptimeNanoseconds < deadline, context.interruption == nil {
                Thread.sleep(forTimeInterval: 0.025)
                let cur = read()
                if cur == target { return }
                if cur == last {
                    stable += 1
                    if cur != initial && stable >= 3 { return }
                    if cur == initial && stable >= 8 { return }
                } else {
                    stable = 0
                    last = cur
                }
            }
        }
        let initialRect = readCGRect()
        try installTimeout(element, context: context)
        try willDispatch()
        try checkAXMutation(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue),
                            action: "AXSetWindowPosition", context: context)
        settle({ readCGRect()?.origin }, initial: initialRect?.origin, target: origin)
        let midRect = readCGRect()
        try installTimeout(element, context: context)
        try checkAXMutation(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue),
                            action: "AXSetWindowSize", context: context)
        settle({ readCGRect()?.size }, initial: midRect?.size ?? initialRect?.size, target: size)
        // Re-apply position only if resizing or screen-edge clamping shifted origin away from target.
        if let afterPos = readCGRect()?.origin, afterPos != origin {
            try installTimeout(element, context: context)
            _ = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posValue)
            settle({ readCGRect()?.origin }, initial: afterPos, target: origin)
        }
    }

    public func windowAction(_ action: WindowActionKind, on window: any AXObject, context: OperationContext,
                             willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(window, context: context)
        switch action {
        case .minimize:
            try requireSettable(kAXMinimizedAttribute as CFString, element: element, context: context)
            try installTimeout(element, context: context)
            try willDispatch()
            try checkAXMutation(AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue),
                                action: "AXMinimize", context: context)
        case .close:
            try installTimeout(element, context: context)
            var rawButton: CFTypeRef?
            let readResult = AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &rawButton)
            try checkAXRead(readResult, context: context, allowMissing: true)
            guard readResult == .success, let rawButton, CFGetTypeID(rawButton) == AXUIElementGetTypeID() else {
                throw NativeFailure(.unsupported, "AXCloseButton is unavailable on this window")
            }
            let closeButton = unsafeDowncast(rawButton, to: AXUIElement.self)
            try requireEnabled(closeButton, allowUnsupported: false, context: context)
            try installTimeout(closeButton, context: context)
            guard try readAXActionNames(closeButton, context: context).contains(kAXPressAction as String) else {
                throw NativeFailure(.unsupported, "AXCloseButton does not advertise AXPress")
            }
            try installTimeout(closeButton, context: context)
            try willDispatch()
            try checkAXMutation(AXUIElementPerformAction(closeButton, kAXPressAction as CFString),
                                action: "AXClose", context: context)
        }
    }

    private func performAXAction(_ actionName: String, on object: any AXObject, allowUnsupportedEnabled: Bool,
                                 context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        let element = try nativeElement(object, context: context)
        try requireEnabled(element, allowUnsupported: allowUnsupportedEnabled, context: context)
        try installTimeout(element, context: context)
        guard try readAXActionNames(element, context: context).contains(actionName) else {
            throw NativeFailure(.unsupported, "\(actionName) is not currently advertised")
        }
        try installTimeout(element, context: context)
        try willDispatch()
        try checkAXMutation(AXUIElementPerformAction(element, actionName as CFString),
                            action: actionName, context: context)
    }

    private func menuChildren(of element: AXUIElement, context: OperationContext) throws -> [AXUIElement] {
        try installTimeout(element, context: context)
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        try checkAXRead(result, context: context, allowMissing: true)
        return result == .success ? (raw as? [AXUIElement] ?? []) : []
    }

    private func menuTitle(of element: AXUIElement, context: OperationContext) throws -> String? {
        try installTimeout(element, context: context)
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &raw)
        try checkAXRead(result, context: context, allowMissing: true)
        return result == .success ? (raw as? String) : nil
    }
}

private func checkAXMutation(_ result: AXError, action: String, context: OperationContext) throws {
    try context.check()
    switch result {
    case .success: return
    case .invalidUIElement:
        throw NativeFailure(.staleElement, "\(action): AX object is no longer valid")
    case .apiDisabled:
        throw NativeFailure(.permissionDenied, "Accessibility permission is unavailable")
    case .actionUnsupported, .attributeUnsupported, .notImplemented:
        throw NativeFailure(.unsupported, "\(action) is not supported on this AX object")
    default:
        throw NativeFailure(.nativeFailed, "\(action) failed (AXError \(result.rawValue))")
    }
}

private func nativeElement(_ object: any AXObject, context: OperationContext) throws -> AXUIElement {
    guard let object = object as? NativeAXObject else { throw NativeFailure(.unsupported, "not a native AX object") }
    try installTimeout(object.element, context: context)
    return object.element
}
private func installTimeout(_ element: AXUIElement, context: OperationContext) throws {
    let timeout = try context.nativeTimeoutSeconds()
    try checkAXRead(AXUIElementSetMessagingTimeout(element, timeout), context: context)
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
