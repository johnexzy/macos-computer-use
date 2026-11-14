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
}

public struct BackgroundActions: Sendable {
    private let coordinator: MutationCoordinator
    private let foreground: @Sendable () -> UInt32?

    public init(coordinator: MutationCoordinator = MutationCoordinator(),
                foreground: @escaping @Sendable () -> UInt32? = {
                    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier, pid > 0 else { return nil }
                    return UInt32(pid)
                }) {
        self.coordinator = coordinator; self.foreground = foreground
    }

    public func act(_ request: ActRequest, entry: RetainedObservation, context: OperationContext,
                    state: ActionExecutionState) -> ActResult {
        guard request.steps.count == 1 else {
            state.finish(reason: .unsupported, stop: .unsupported); return state.snapshot()
        }
        do {
            try coordinator.withOwnership(context: context) {
                let before = foreground()
                guard before != nil else { throw NativeFailure(.unsupported, "foreground baseline is unavailable") }
                var failure: NativeFailure?
                var alreadySatisfied = false
                do { alreadySatisfied = try execute(request, entry: entry, context: context, state: state, before: before) }
                catch let error as NativeFailure { failure = error }
                catch { failure = NativeFailure(.nativeFailed, "background action failed") }
                if foreground() != before {
                    state.finish(reason: .nativeFailed, stop: .failed)
                } else if let failure {
                    finish(state, failure: failure)
                } else {
                    state.complete(context: context, alreadySatisfied: alreadySatisfied)
                }
            }
        } catch let error as NativeFailure { finish(state, failure: error) }
        catch { state.finish(reason: .nativeFailed, stop: .failed) }
        return state.snapshot()
    }

    public func wait(_ request: WaitRequest, entry: RetainedObservation, context: OperationContext) throws -> WaitEvaluation {
        guard case .valueEquals = request.condition else { throw NativeFailure(.unsupported, "only exact-value waiting is supported") }
        let handle = try semanticHandle(entry, observationId: request.observationId, target: request.target)
        var first = true
        while true {
            try context.check()
            if let check = try evaluate(request.condition, handle: handle, context: context), check.matched {
                return WaitEvaluation(outcome: .satisfied, alreadySatisfied: first)
            }
            first = false
            try pause(context)
        }
    }

    private func execute(_ request: ActRequest, entry: RetainedObservation, context: OperationContext,
                         state: ActionExecutionState, before: UInt32?) throws -> Bool {
        try context.check()
        let handle = try semanticHandle(entry, observationId: request.observationId, target: request.target)
        guard let writer = handle.backend as? any AXMutating else { throw NativeFailure(.unsupported, "semantic mutation backend unavailable") }
        let step = request.steps[0]
        try supported(step.precondition); try supported(step.expect)
        let reference: String
        let route: DeliveryRoute
        switch step.operation {
        case .setValue(let value): reference = value.elementRef; route = .axSetValue
        case .press(let value): reference = value.elementRef; route = .axPress
        case .typeText(let value): reference = value.elementRef; route = .axSelectedText
        default: throw NativeFailure(.unsupported, "background operation is not implemented")
        }
        let resolved = try handle.resolve(reference, includeValue: true, context: context)
        guard resolved.snapshot.enabledKnown else { throw NativeFailure(.unsupported, "target enabled state is unavailable") }
        guard resolved.snapshot.enabled else { throw NativeFailure(.unsupported, "target is disabled") }
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
        try checkForeground(before)
        try context.check()
        // Resolve again inside the shared mutation boundary; never reselect by a label.
        let typing: Bool
        if case .typeText = step.operation { typing = true } else { typing = false }
        let live = try handle.resolve(reference, includeValue: typing, context: context)
        guard handle.backend.same(live.object, resolved.object), live.snapshot.enabledKnown, live.snapshot.enabled else {
            throw NativeFailure(.staleElement, "target changed before dispatch")
        }
        if typing && (live.snapshot.value != resolved.snapshot.value || live.snapshot.selectedRange != resolved.snapshot.selectedRange) {
            throw NativeFailure(.staleElement, "text value or selection changed before dispatch")
        }
        let handoff: @Sendable () throws -> Void = {
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
            try checkForeground(before)
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
            try checkForeground(before)
            if let mutationFailure { throw mutationFailure }
            return false
        }
        while true {
            try context.check()
            let checks = try recordChecks(required, handle: handle, context: context, state: state)
            let privateMatched: Bool
            if let expected = privateTextExpectation {
                let current = try handle.resolve(reference, includeValue: true, context: context)
                guard handle.backend.same(current.object, resolved.object) else { throw NativeFailure(.staleElement, "readback target changed") }
                privateMatched = current.snapshot.value == expected
            } else { privateMatched = true }
            try checkForeground(before)
            if let mutationFailure { throw mutationFailure }
            if checks.count == required.count && checks.allSatisfy(\.matched) && privateMatched { return false }
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

    private func semanticHandle(_ entry: RetainedObservation, observationId: String, target: TargetKey) throws -> SemanticObservationHandle {
        guard entry.observation.observationId == observationId, entry.observation.target == target,
              let handle = entry.handle as? SemanticObservationHandle, handle.observationId == observationId,
              handle.target.key == target else { throw NativeFailure(.staleObservation, "semantic observation is unavailable or belongs to another target") }
        return handle
    }

    private func supported(_ condition: Condition?) throws {
        switch condition {
        case .valueEquals, .enabled, nil: break
        default: throw NativeFailure(.unsupported, "condition is not implemented")
        }
    }

    private func evaluate(_ condition: Condition, handle: SemanticObservationHandle, context: OperationContext) throws -> ActionWitness? {
        let started = milliseconds()
        let reference: String
        let matched: Bool
        switch condition {
        case .valueEquals(let value):
            reference = value.elementRef
            let node = try handle.resolve(reference, includeValue: true, context: context)
            guard let actual = node.snapshot.value else { return nil }
            matched = actual == value.value
        case .enabled(let value):
            reference = value.elementRef
            let node = try handle.resolve(reference, context: context)
            guard node.snapshot.enabledKnown else { return nil }
            matched = node.snapshot.enabled == value.enabled
        default: throw NativeFailure(.unsupported, "condition is not implemented")
        }
        return ActionWitness(observationId: "check-\(UUID().uuidString)",
            collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, milliseconds())),
            target: handle.target.key, elementRef: reference, condition: condition, matched: matched)
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
    private func checkForeground(_ before: UInt32?) throws {
        if foreground() != before { throw NativeFailure(.nativeFailed, "foreground changed during background operation") }
    }
    private func finish(_ state: ActionExecutionState, failure: NativeFailure) {
        switch failure.code {
        case .cancelled: state.finish(reason: .cancelled, stop: .cancelled)
        case .deadlineExceeded: state.finish(reason: .deadlineExceeded, stop: .deadlineExceeded)
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
        try requireEnabled(element, context: context)
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
        try requireEnabled(element, context: context)
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
        try requireEnabled(element, context: context)
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
private func requireEnabled(_ element: AXUIElement, context: OperationContext) throws {
    try installTimeout(element, context: context)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success,
          let enabled = value as? Bool, enabled else { throw NativeFailure(.unsupported, "AX target is not confirmed enabled") }
}
