import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import UseUIProtocol
import Foundation
import ImageIO

struct ForegroundSample: Equatable, Sendable {
    let pid: UInt32?
    let hardwareCounters: [UInt32]
    let inputHeld: Bool
}

enum ForegroundInput: Equatable, Sendable {
    case key(Key)
    case hotkey(key: String, modifiers: [Modifier])
    case typeKeys(String)
    case click(Point)
    case doubleClick(Point)
    case rightClick(Point)
    case hover(Point)
    case drag(from: Point, to: Point, steps: Int)
    case scrollWheel(point: Point, deltaX: Int, deltaY: Int)
    case focusWindow
}

struct ForegroundStopped: Error, Sendable {
    let reason: ForegroundInterruption
}

/// Tracks app activation beyond a before/after PID comparison. No input contents are collected.
final class ActivationWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var external = false
    private var observer: NSObjectProtocol?
    private var restorationPID: UInt32?

    init(expecting pid: UInt32, notifications: NotificationCenter? = nil) {
        center = notifications
        observer = notifications?.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let observed = app.flatMap { $0.processIdentifier > 0 ? UInt32($0.processIdentifier) : nil }
            self?.recordActivation(observed, expected: pid)
        }
    }

    private let center: NotificationCenter?
    deinit { if let observer { center?.removeObserver(observer) } }

    private func recordActivation(_ pid: UInt32?, expected: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if pid != expected && (pid == nil || pid != restorationPID) { external = true }
    }

    func allowRestoration(to pid: UInt32) {
        lock.lock(); restorationPID = pid; lock.unlock()
    }

    func recordExternalActivation() {
        lock.lock(); external = true; lock.unlock()
    }
    var sawExternalActivation: Bool {
        lock.lock(); defer { lock.unlock() }; return external
    }
}

protocol ForegroundPlatform: Sendable {
    func permissionAvailable() -> Bool
    func visualPermissionAvailable() -> Bool
    func sample() -> ForegroundSample
    func watch(expecting pid: UInt32) -> ActivationWatch
    func focusedWindow(pid: UInt32, context: OperationContext) throws -> (any AXObject)?
    func focusedElement(pid: UInt32, context: OperationContext) throws -> (any AXObject)?
    func activate(pid: UInt32, window: any AXObject, context: OperationContext, willChangeFocus: () throws -> Void) throws
    func hitTest(_ point: Point, in target: SemanticObservationHandle, context: OperationContext) throws -> Bool
    func visualHitTest(_ point: Point, in target: Target, context: OperationContext) throws -> Bool
    func post(_ input: ForegroundInput, willDispatch: () throws -> Void) throws
}

final class VisualObservationHandle: RetainedNativeHandle {
    private let window: WindowSnapshot
    private let catalog: any WindowCatalog
    let observationId: String
    var target: Target { window.target }

    init(window: WindowSnapshot, catalog: any WindowCatalog, observationId: String) {
        self.window = window; self.catalog = catalog; self.observationId = observationId
    }

    func validateWindow(context: OperationContext) throws {
        let current = try catalog.windowSnapshot(target.key, context: context)
        guard let generation = window.generation, current.generation == generation,
              current.target.key == target.key, current.target.bounds == target.bounds,
              current.target.bundleId == target.bundleId else {
            throw NativeFailure(.staleObservation, "observed visual window changed")
        }
    }
}

enum ForegroundTarget {
    case semantic(SemanticObservationHandle)
    case visual(VisualObservationHandle)

    var window: Target {
        switch self {
        case .semantic(let handle): handle.target
        case .visual(let handle): handle.target
        }
    }

    func validateWindow(context: OperationContext) throws {
        switch self {
        case .semantic(let handle): try handle.validateWindow(context: context)
        case .visual(let handle): try handle.validateWindow(context: context)
        }
    }
}

/// Owns one temporary foreground route under the runtime's shared mutation lock.
final class ForegroundControl {
    private let platform: any ForegroundPlatform
    private let capture: any VisualCapturing
    private let target: ForegroundTarget
    var window: Target { target.window }
    private let context: OperationContext
    private let state: ActionExecutionState
    private let watch: ActivationWatch
    private let initial: ForegroundSample
    private let priorWindow: (any AXObject)?
    private var last: ForegroundSample
    private var activationRequested = false
    private var ownsFocus = false
    private var keepFocus = false
    private var inputActivity = false
    private var externalActivation = false
    private var interruption: ForegroundInterruption?
    private var restoration: FocusRestoration = .notNeeded

    private func permissionAvailable() -> Bool {
        switch target {
        case .semantic: platform.permissionAvailable()
        case .visual: platform.visualPermissionAvailable()
        }
    }

    init(platform: any ForegroundPlatform, capture: any VisualCapturing, target: ForegroundTarget,
         context: OperationContext, state: ActionExecutionState) throws {
        self.platform = platform; self.capture = capture; self.target = target; self.context = context; self.state = state
        let first = platform.sample()
        initial = first
        last = first
        watch = platform.watch(expecting: target.window.key.pid)
        priorWindow = if case .semantic = target, let pid = first.pid, platform.permissionAvailable() {
            try? platform.focusedWindow(pid: pid, context: context)
        } else { nil }
        publish()
    }

    private func checkInterference(checkingState: Bool = true) throws {
        if checkingState { try state.checkActive(context: context) }
        else { try context.check() }
        last = platform.sample()
        inputActivity = inputActivity || last.hardwareCounters != initial.hardwareCounters || last.inputHeld
        externalActivation = externalActivation || watch.sawExternalActivation
            || (activationRequested ? last.pid != initial.pid && last.pid != window.key.pid : last.pid != initial.pid)
        if inputActivity { throw stop(.inputActivity) }
        if initial.pid == nil || externalActivation { throw stop(.focusChanged) }
        publish()
    }

    func checkContext() throws {
        if ownsFocus { try checkFocused() }
        else { try checkInterference() }
    }

    private func checkFocused(checkingState: Bool = true) throws {
        try checkInterference(checkingState: checkingState)
        guard last.pid == window.key.pid else {
            externalActivation = true
            throw stop(.focusChanged)
        }
        guard permissionAvailable() else { throw stop(.permissionUnavailable) }
        do { try target.validateWindow(context: context) }
        catch let failure as NativeFailure where failure.code == .staleObservation || failure.code == .staleElement
            || failure.code == .targetNotFound || failure.code == .ambiguousTarget {
            throw stop(.windowChanged)
        }
        if case .semantic(let handle) = target {
            guard let focused = try platform.focusedWindow(pid: window.key.pid, context: context),
                  handle.backend.same(focused, handle.retainedWindow) else { throw stop(.windowChanged) }
        }
    }

    func post(_ operation: UseUIProtocol.Operation, observation: Observation, checkGuard: () throws -> Void,
              beforeClick: ((Point) throws -> Void)? = nil, willDispatch: () throws -> Void) throws {
        try checkContext()
        guard permissionAvailable() else { throw stop(.permissionUnavailable) }
        // Resolve coordinates from the original image before making any activation request.
        let visualOnly: Bool
        if case .visual = target { visualOnly = true } else { visualOnly = false }
        let click: ClickWitness?
        let dragEnd: Point?
        switch operation {
        case .click(let value), .doubleClick(let value), .rightClick(let value), .hover(let value):
            guard let witness = ClickWitness(point: value.point, space: value.space, observation: observation, visualOnly: visualOnly) else {
                throw stop(.frameChanged)
            }
            click = witness
            dragEnd = nil
        case .scrollWheel(let value):
            guard let witness = ClickWitness(point: value.point, space: value.space, observation: observation, visualOnly: visualOnly) else {
                throw stop(.frameChanged)
            }
            click = witness
            dragEnd = nil
        case .drag(let value):
            guard let startWitness = ClickWitness(point: value.from, space: value.space, observation: observation, visualOnly: visualOnly),
                  let endScreen = ClickWitness.mapToScreen(point: value.to, space: value.space, observation: observation, visualOnly: visualOnly) else {
                throw stop(.frameChanged)
            }
            click = startWitness
            dragEnd = endScreen
        case .key, .hotkey, .typeKeys, .focusWindow:
            click = nil
            dragEnd = nil
        default: throw NativeFailure(.unsupported, "foreground operation is not implemented")
        }

        try focus()
        let input: ForegroundInput
        switch operation {
        case .key(let value):
            try checkKeyTarget(value)
            input = .key(value.key)
        case .hotkey(let value):
            try checkWindowTextOrKeyTarget(elementRef: value.elementRef)
            input = .hotkey(key: value.key, modifiers: value.modifiers)
        case .typeKeys(let value):
            try checkWindowTextOrKeyTarget(elementRef: value.elementRef)
            input = .typeKeys(value.text)
        case .focusWindow:
            input = .focusWindow
        case .click, .doubleClick, .rightClick, .hover, .drag, .scrollWheel:
            guard let click else { throw stop(.frameChanged) }
            if let beforeClick {
                try beforeClick(click.screen)
                try checkFocused()
            }
            do { try click.validate(capture: capture, target: window, context: context) }
            catch is ForegroundStopped { throw stop(.frameChanged) }
            catch is VisualCaptureFailure { throw stop(.frameChanged) }
            switch operation {
            case .click: input = .click(click.screen)
            case .doubleClick: input = .doubleClick(click.screen)
            case .rightClick: input = .rightClick(click.screen)
            case .hover: input = .hover(click.screen)
            case .drag(let value):
                guard let dragEnd else { throw stop(.frameChanged) }
                input = .drag(from: click.screen, to: dragEnd, steps: Int(value.steps ?? 12))
            case .scrollWheel(let value):
                input = .scrollWheel(point: click.screen, deltaX: Int(value.deltaX), deltaY: Int(value.deltaY))
            default: throw NativeFailure(.unsupported, "foreground operation is not implemented")
            }
        default: throw NativeFailure(.unsupported, "foreground operation is not implemented")
        }
        try platform.post(input) {
            try checkGuard()
            try checkFocused()
            if let click {
                let hits: Bool
                switch target {
                case .semantic(let handle): hits = try platform.hitTest(click.screen, in: handle, context: context)
                case .visual: hits = try platform.visualHitTest(click.screen, in: window, context: context)
                }
                guard hits else { throw stop(.windowChanged) }
                if let dragEnd {
                    let b = window.bounds
                    guard dragEnd.x >= b.x && dragEnd.x < b.x + b.width && dragEnd.y >= b.y && dragEnd.y < b.y + b.height else {
                        throw stop(.windowChanged)
                    }
                }
            }
            switch operation {
            case .key(let value): try checkKeyTarget(value)
            case .hotkey(let value): try checkWindowTextOrKeyTarget(elementRef: value.elementRef)
            case .typeKeys(let value): try checkWindowTextOrKeyTarget(elementRef: value.elementRef)
            default: break
            }
            // Final lightweight sample follows window/element reads. macOS does not offer atomic validate-and-post.
            try checkInterference()
            guard last.pid == window.key.pid else { throw stop(.focusChanged) }
            try willDispatch()
        }
        if case .focusWindow = operation {
            keepFocus = true
            restoration = .notNeeded
            publish()
        }
    }

    private func checkWindowTextOrKeyTarget(elementRef: String?) throws {
        guard case .semantic(let handle) = target else { throw stop(.windowChanged) }
        if let elementRef {
            let resolved = try handle.resolve(elementRef, context: context)
            let snapshot = resolved.snapshot
            guard (snapshot.enabledKnown && snapshot.enabled) || snapshot.enabledUnsupported else {
                throw stop(.windowChanged)
            }
        }
        if let focused = try platform.focusedElement(pid: window.key.pid, context: context) {
            do { try handle.validateOwner(of: focused, context: context) }
            catch { throw stop(.windowChanged) }
        }
    }

    private static func isWindowBrowserShortcut(_ key: Key) -> Bool {
        switch key {
        case .focusAddressBar, .reload, .newTab, .closeTab, .navigateBack, .navigateForward:
            return true
        default:
            return false
        }
    }

    private func checkKeyTarget(_ operation: KeyOperation) throws {
        guard case .semantic(let handle) = target else { throw stop(.windowChanged) }
        let resolved = try handle.resolve(operation.elementRef, context: context)
        let snapshot = resolved.snapshot
        if Self.isWindowBrowserShortcut(operation.key) {
            // Window-scoped browser shortcuts target the validated focused window even when focus
            // sits on a child control inside AXWebArea or the browser toolbar.
            guard (snapshot.enabledKnown && snapshot.enabled) || snapshot.enabledUnsupported else {
                throw stop(.windowChanged)
            }
            if let focused = try platform.focusedElement(pid: window.key.pid, context: context) {
                do { try handle.validateOwner(of: focused, context: context) }
                catch { throw stop(.windowChanged) }
            }
            return
        }
        // A document editor can expose focus and writable text while declaring AXEnabled unsupported.
        let writableEditor = operation.key == .saveAs && snapshot.role == "AXTextArea"
            && snapshot.valueSettable && snapshot.enabledUnsupported
        guard (snapshot.enabledKnown && snapshot.enabled) || writableEditor,
              let focused = try platform.focusedElement(pid: window.key.pid, context: context),
              handle.backend.same(focused, resolved.object) else { throw stop(.windowChanged) }
    }

    private func focus() throws {
        if ownsFocus { try checkFocused(); return }
        let pid = window.key.pid
        guard case .semantic(let target) = target else {
            // Without an AX window, raising the application could select a different window.
            guard last.pid == pid else { throw stop(.activationFailed) }
            try checkFocused()
            ownsFocus = true
            return
        }
        try target.validateWindow(context: context)
        if last.pid == pid,
           let focused = try platform.focusedWindow(pid: pid, context: context),
           target.backend.same(focused, target.retainedWindow) { ownsFocus = true; return }
        try checkInterference()
        activationRequested = true
        restoration = .pending
        publish()
        do {
            try platform.activate(pid: pid, window: target.retainedWindow, context: context) { try checkInterference() }
            let until = DispatchTime.now().uptimeNanoseconds + 400_000_000
            while DispatchTime.now().uptimeNanoseconds < until {
                try checkInterference()
                if last.pid == pid,
                   let focused = try platform.focusedWindow(pid: pid, context: context),
                   target.backend.same(focused, target.retainedWindow) { ownsFocus = true; return }
                Thread.sleep(forTimeInterval: Double(try context.nativeTimeoutSeconds(maximum: 0.01)))
            }
        } catch let failure as NativeFailure where failure.code != .deadlineExceeded && failure.code != .cancelled {
            throw stop(.activationFailed)
        }
        throw stop(.activationFailed)
    }

    /// Restore only while the original route still owns focus and the original hardware baseline.
    func restore() {
        guard activationRequested, restoration == .pending, !keepFocus else { return }
        guard case .semantic(let target) = target else { return }
        defer { publish() }
        if context.interruption != nil || inputActivity || externalActivation || interruption == .windowChanged {
            restoration = .skipped; return
        }
        guard let prior = initial.pid, let priorWindow,
              prior != target.target.key.pid || !target.backend.same(priorWindow, target.retainedWindow) else {
            restoration = .skipped; return
        }
        do {
            try checkFocused(checkingState: false)
            watch.allowRestoration(to: prior)
            try platform.activate(pid: prior, window: priorWindow, context: context) {
                try context.check()
                last = platform.sample()
                if last.hardwareCounters != initial.hardwareCounters || last.inputHeld {
                    inputActivity = true
                    throw stop(.inputActivity)
                }
                if watch.sawExternalActivation || (last.pid != target.target.key.pid && last.pid != prior) {
                    externalActivation = true
                    throw stop(.focusChanged)
                }
                if last.pid == target.target.key.pid {
                    guard let current = try platform.focusedWindow(pid: target.target.key.pid, context: context),
                          target.backend.same(current, target.retainedWindow) else { throw stop(.windowChanged) }
                }
            }
            let until = DispatchTime.now().uptimeNanoseconds + 200_000_000
            while DispatchTime.now().uptimeNanoseconds < until {
                last = platform.sample()
                if last.hardwareCounters != initial.hardwareCounters || last.inputHeld {
                    inputActivity = true
                    interruption = .inputActivity
                    restoration = .skipped
                    return
                }
                if last.pid == prior,
                   let window = try platform.focusedWindow(pid: prior, context: context),
                   target.backend.same(window, priorWindow) { restoration = .restored; return }
                if watch.sawExternalActivation || (last.pid != target.target.key.pid && last.pid != prior) {
                    externalActivation = true
                    interruption = .focusChanged
                    restoration = .skipped
                    return
                }
                Thread.sleep(forTimeInterval: Double(try context.nativeTimeoutSeconds(maximum: 0.01)))
            }
            restoration = .failed
        } catch is ForegroundStopped { restoration = .skipped }
        catch { restoration = context.interruption == nil ? .failed : .skipped }
    }

    private func stop(_ reason: ForegroundInterruption) -> ForegroundStopped {
        if interruption == nil { interruption = reason }
        publish()
        return ForegroundStopped(reason: reason)
    }

    private func publish() {
        state.recordForeground(ForegroundEvidence(initialPid: initial.pid, lastPid: last.pid, activationRequested: activationRequested,
            inputActivity: inputActivity, externalActivation: externalActivation, interruption: interruption, restoration: restoration))
    }
}

struct NativeForegroundPlatform: ForegroundPlatform {
    func permissionAvailable() -> Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }
    func visualPermissionAvailable() -> Bool { CGPreflightPostEventAccess() && CGPreflightScreenCaptureAccess() }

    func sample() -> ForegroundSample {
        let events: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp,
            .leftMouseDragged, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel]
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let counters = events.map { CGEventSource.counterForEventType(.hidSystemState, eventType: $0) }
        let flags = CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let held = !flags.isEmpty || [CGMouseButton.left, .right, .center].contains { CGEventSource.buttonState(.hidSystemState, button: $0) }
        return ForegroundSample(pid: pid.flatMap { $0 > 0 ? UInt32($0) : nil }, hardwareCounters: counters, inputHeld: held)
    }

    func watch(expecting pid: UInt32) -> ActivationWatch {
        ActivationWatch(expecting: pid, notifications: NSWorkspace.shared.notificationCenter)
    }

    func focusedWindow(pid: UInt32, context: OperationContext) throws -> (any AXObject)? {
        try readObject(kAXFocusedWindowAttribute, pid: pid, context: context)
    }

    func focusedElement(pid: UInt32, context: OperationContext) throws -> (any AXObject)? {
        try readObject(kAXFocusedUIElementAttribute, pid: pid, context: context)
    }

    func activate(pid: UInt32, window: any AXObject, context: OperationContext, willChangeFocus: () throws -> Void) throws {
        guard let window = window as? NativeAXObject else { throw NativeFailure(.unsupported, "native window is unavailable") }
        let app = AXUIElementCreateApplication(pid_t(pid))
        try installTimeout(app, context: context)
        try installTimeout(window.element, context: context)
        var owner: pid_t = 0
        try checkAXRead(AXUIElementGetPid(window.element, &owner), context: context)
        guard owner == pid_t(pid) else { throw NativeFailure(.staleObservation, "window owner changed before activation") }
        try willChangeFocus()
        try checkAXRead(AXUIElementPerformAction(window.element, kAXRaiseAction as CFString), context: context)
        try installTimeout(app, context: context)
        try willChangeFocus()
        try checkAXRead(AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue), context: context)
    }

    func hitTest(_ point: Point, in target: SemanticObservationHandle, context: OperationContext) throws -> Bool {
        try context.check()
        guard screenHit(point, target: target.target, includeOverlaySurfaces: false) else { return false }

        // Compositor-only surfaces can cover the screen in the window list. Use the system-wide AX hit for input context.
        let system = AXUIElementCreateSystemWide()
        try installTimeout(system, context: context)
        var hit: AXUIElement?
        try checkAXRead(AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit), context: context, allowMissing: true)
        guard let hit else { return false }
        let object = NativeAXObject(hit)
        guard try target.backend.ownerPID(of: object, context: context) == target.target.key.pid else { return false }
        if target.backend.same(object, target.retainedWindow) { return true }
        guard let owning = try target.backend.window(of: object, context: context) else { return false }
        return target.backend.same(owning, target.retainedWindow)
    }

    func visualHitTest(_ point: Point, in target: Target, context: OperationContext) throws -> Bool {
        try context.check()
        return screenHit(point, target: target, includeOverlaySurfaces: true)
    }

    private func screenHit(_ point: Point, target: Target, includeOverlaySurfaces: Bool) -> Bool {
        let runtimePID = UInt32(getpid())
        let previewID = LivePreviewPanel.interactiveWindowID.withLock { $0 }
        var displayCount: UInt32 = 0
        var display: CGDirectDisplayID = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: point.x, y: point.y), 1, &display, &displayCount) == .success, displayCount > 0,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let frontWindow = windows.first(where: { row in
                  let owner = row[kCGWindowOwnerPID as String] as? UInt32
                  let interactivePreview = previewID != nil && row[kCGWindowNumber as String] as? UInt32 == previewID && owner == runtimePID
                  guard let layer = row[kCGWindowLayer as String] as? Int,
                        interactivePreview || (owner != runtimePID && (includeOverlaySurfaces ? layer >= 0 : layer == 0)),
                        let alpha = row[kCGWindowAlpha as String] as? Double, alpha > 0,
                        let bounds = row[kCGWindowBounds as String] as? [String: Double],
                        let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { return false }
                  return point.x >= x && point.x < x + w && point.y >= y && point.y < y + h
              }),
              frontWindow[kCGWindowNumber as String] as? UInt32 == target.key.windowId,
              frontWindow[kCGWindowOwnerPID as String] as? UInt32 == target.key.pid,
              let bounds = frontWindow[kCGWindowBounds as String] as? [String: Double],
              bounds["X"] == target.bounds.x, bounds["Y"] == target.bounds.y,
              bounds["Width"] == target.bounds.width, bounds["Height"] == target.bounds.height else { return false }
        return true
    }

    func post(_ input: ForegroundInput, willDispatch: () throws -> Void) throws {
        guard let source = CGEventSource(stateID: .privateState) else { throw NativeFailure(.nativeFailed, "event source unavailable") }
        source.localEventsSuppressionInterval = 0
        switch input {
        case .key(let key):
            let code: Int
            let flags: CGEventFlags
            switch key {
            case .return: code = kVK_Return; flags = []
            case .tab: code = kVK_Tab; flags = []
            case .escape: code = kVK_Escape; flags = []
            case .backspace: code = kVK_Delete; flags = []
            case .left: code = kVK_LeftArrow; flags = []
            case .right: code = kVK_RightArrow; flags = []
            case .up: code = kVK_UpArrow; flags = []
            case .down: code = kVK_DownArrow; flags = []
            case .saveAs: code = kVK_ANSI_S; flags = [.maskCommand, .maskAlternate, .maskShift]
            case .focusAddressBar: code = kVK_ANSI_L; flags = [.maskCommand]
            case .reload: code = kVK_ANSI_R; flags = [.maskCommand]
            case .newTab: code = kVK_ANSI_T; flags = [.maskCommand]
            case .closeTab: code = kVK_ANSI_W; flags = [.maskCommand]
            case .navigateBack: code = kVK_ANSI_LeftBracket; flags = [.maskCommand]
            case .navigateForward: code = kVK_ANSI_RightBracket; flags = [.maskCommand]
            }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else {
                throw NativeFailure(.nativeFailed, "input event creation failed")
            }
            down.flags = flags
            up.flags = flags
            try willDispatch()
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        case .hotkey(let key, let modifiers):
            guard let code = Self.virtualKeyCode(for: key) else {
                throw NativeFailure(.invalidRequest, "unknown hotkey name")
            }
            var flags: CGEventFlags = []
            for modifier in modifiers {
                switch modifier {
                case .command: flags.insert(.maskCommand)
                case .control: flags.insert(.maskControl)
                case .option: flags.insert(.maskAlternate)
                case .shift: flags.insert(.maskShift)
                }
            }
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else {
                throw NativeFailure(.nativeFailed, "hotkey event creation failed")
            }
            down.flags = flags
            up.flags = flags
            try willDispatch()
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        case .typeKeys(let text):
            var events: [CGEvent] = []
            let scalars = Array(text.unicodeScalars)
            var buffer: [UniChar] = []
            func flushBuffer() throws {
                guard !buffer.isEmpty else { return }
                var offset = 0
                while offset < buffer.count {
                    let end = min(offset + 16, buffer.count)
                    var chunk = Array(buffer[offset..<end])
                    guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                        throw NativeFailure(.nativeFailed, "text input event creation failed")
                    }
                    down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                    events.append(down)
                    events.append(up)
                    offset = end
                }
                buffer.removeAll(keepingCapacity: true)
            }
            func appendKey(_ code: Int) throws {
                try flushBuffer()
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false) else {
                    throw NativeFailure(.nativeFailed, "text control key creation failed")
                }
                events.append(down)
                events.append(up)
            }
            for scalar in scalars {
                if scalar == "\r" { continue }
                if scalar == "\n" { try appendKey(kVK_Return) }
                else if scalar == "\t" { try appendKey(kVK_Tab) }
                else { buffer.append(contentsOf: scalar.utf16) }
            }
            try flushBuffer()
            try willDispatch()
            for (index, event) in events.enumerated() {
                event.post(tap: .cgSessionEventTap)
                if index % 2 == 1 && index + 1 < events.count {
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
        case .click(let point):
            let location = CGPoint(x: point.x, y: point.y)
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else {
                throw NativeFailure(.nativeFailed, "input event creation failed")
            }
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            try willDispatch()
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        case .doubleClick(let point):
            let location = CGPoint(x: point.x, y: point.y)
            guard let down1 = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
                  let up1 = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left),
                  let down2 = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left),
                  let up2 = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left) else {
                throw NativeFailure(.nativeFailed, "double-click event creation failed")
            }
            down1.setIntegerValueField(.mouseEventClickState, value: 1)
            up1.setIntegerValueField(.mouseEventClickState, value: 1)
            down2.setIntegerValueField(.mouseEventClickState, value: 2)
            up2.setIntegerValueField(.mouseEventClickState, value: 2)
            try willDispatch()
            down1.post(tap: .cgSessionEventTap)
            up1.post(tap: .cgSessionEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            down2.post(tap: .cgSessionEventTap)
            up2.post(tap: .cgSessionEventTap)
        case .rightClick(let point):
            let location = CGPoint(x: point.x, y: point.y)
            guard let down = CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: location, mouseButton: .right),
                  let up = CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: location, mouseButton: .right) else {
                throw NativeFailure(.nativeFailed, "right-click event creation failed")
            }
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            try willDispatch()
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
        case .hover(let point):
            let location = CGPoint(x: point.x, y: point.y)
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left) else {
                throw NativeFailure(.nativeFailed, "hover event creation failed")
            }
            try willDispatch()
            move.post(tap: .cgSessionEventTap)
        case .drag(let from, let to, let steps):
            let start = CGPoint(x: from.x, y: from.y)
            let end = CGPoint(x: to.x, y: to.y)
            let count = max(1, min(50, steps))
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left),
                  let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else {
                throw NativeFailure(.nativeFailed, "drag event creation failed")
            }
            down.setIntegerValueField(.mouseEventClickState, value: 1)
            up.setIntegerValueField(.mouseEventClickState, value: 1)
            var moves: [CGEvent] = []
            moves.reserveCapacity(count)
            for i in 1...count {
                let t = Double(i) / Double(count)
                let pos = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                guard let dragged = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: pos, mouseButton: .left) else {
                    throw NativeFailure(.nativeFailed, "drag motion event creation failed")
                }
                moves.append(dragged)
            }
            try willDispatch()
            move.post(tap: .cgSessionEventTap)
            down.post(tap: .cgSessionEventTap)
            defer { up.post(tap: .cgSessionEventTap) }
            for dragged in moves {
                Thread.sleep(forTimeInterval: 0.008)
                dragged.post(tap: .cgSessionEventTap)
            }
            Thread.sleep(forTimeInterval: 0.008)
        case .scrollWheel(let point, let deltaX, let deltaY):
            let location = CGPoint(x: point.x, y: point.y)
            guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left) else {
                throw NativeFailure(.nativeFailed, "scroll wheel cursor event creation failed")
            }
            let maxAxis = max(abs(deltaX), abs(deltaY))
            let steps = max(1, min(10, (maxAxis + 39) / 40))
            var events: [CGEvent] = []
            events.reserveCapacity(steps)
            var sentX = 0
            var sentY = 0
            for i in 1...steps {
                let targetX = i == steps ? deltaX : (deltaX * i) / steps
                let targetY = i == steps ? deltaY : (deltaY * i) / steps
                let stepX = targetX - sentX
                let stepY = targetY - sentY
                sentX = targetX
                sentY = targetY
                guard stepX != 0 || stepY != 0 else { continue }
                // Protocol positive deltaY = scroll down, positive deltaX = scroll right.
                // macOS CGEvent pixel scroll uses negative wheel1 for down and negative wheel2 for right.
                guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                           wheel1: Int32(-stepY), wheel2: Int32(-stepX), wheel3: 0) else {
                    throw NativeFailure(.nativeFailed, "scroll wheel event creation failed")
                }
                scroll.location = location
                events.append(scroll)
            }
            try willDispatch()
            move.post(tap: .cgSessionEventTap)
            for (index, event) in events.enumerated() {
                event.post(tap: .cgSessionEventTap)
                if index + 1 < events.count { Thread.sleep(forTimeInterval: 0.008) }
            }
        case .focusWindow:
            try willDispatch()
        }
    }

    static func virtualKeyCode(for key: String) -> Int? {
        switch key {
        case "a": kVK_ANSI_A
        case "b": kVK_ANSI_B
        case "c": kVK_ANSI_C
        case "d": kVK_ANSI_D
        case "e": kVK_ANSI_E
        case "f": kVK_ANSI_F
        case "g": kVK_ANSI_G
        case "h": kVK_ANSI_H
        case "i": kVK_ANSI_I
        case "j": kVK_ANSI_J
        case "k": kVK_ANSI_K
        case "l": kVK_ANSI_L
        case "m": kVK_ANSI_M
        case "n": kVK_ANSI_N
        case "o": kVK_ANSI_O
        case "p": kVK_ANSI_P
        case "q": kVK_ANSI_Q
        case "r": kVK_ANSI_R
        case "s": kVK_ANSI_S
        case "t": kVK_ANSI_T
        case "u": kVK_ANSI_U
        case "v": kVK_ANSI_V
        case "w": kVK_ANSI_W
        case "x": kVK_ANSI_X
        case "y": kVK_ANSI_Y
        case "z": kVK_ANSI_Z
        case "0": kVK_ANSI_0
        case "1": kVK_ANSI_1
        case "2": kVK_ANSI_2
        case "3": kVK_ANSI_3
        case "4": kVK_ANSI_4
        case "5": kVK_ANSI_5
        case "6": kVK_ANSI_6
        case "7": kVK_ANSI_7
        case "8": kVK_ANSI_8
        case "9": kVK_ANSI_9
        case "minus": kVK_ANSI_Minus
        case "equal": kVK_ANSI_Equal
        case "leftBracket": kVK_ANSI_LeftBracket
        case "rightBracket": kVK_ANSI_RightBracket
        case "backslash": kVK_ANSI_Backslash
        case "semicolon": kVK_ANSI_Semicolon
        case "quote": kVK_ANSI_Quote
        case "comma": kVK_ANSI_Comma
        case "period": kVK_ANSI_Period
        case "slash": kVK_ANSI_Slash
        case "grave": kVK_ANSI_Grave
        case "space": kVK_Space
        case "return": kVK_Return
        case "tab": kVK_Tab
        case "escape": kVK_Escape
        case "backspace": kVK_Delete
        case "delete": kVK_ForwardDelete
        case "left": kVK_LeftArrow
        case "right": kVK_RightArrow
        case "up": kVK_UpArrow
        case "down": kVK_DownArrow
        case "home": kVK_Home
        case "end": kVK_End
        case "pageUp": kVK_PageUp
        case "pageDown": kVK_PageDown
        case "f1": kVK_F1
        case "f2": kVK_F2
        case "f3": kVK_F3
        case "f4": kVK_F4
        case "f5": kVK_F5
        case "f6": kVK_F6
        case "f7": kVK_F7
        case "f8": kVK_F8
        case "f9": kVK_F9
        case "f10": kVK_F10
        case "f11": kVK_F11
        case "f12": kVK_F12
        default: nil
        }
    }

    private func readObject(_ attribute: String, pid: UInt32, context: OperationContext) throws -> (any AXObject)? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        try installTimeout(app, context: context)
        var value: CFTypeRef?
        try checkAXRead(AXUIElementCopyAttributeValue(app, attribute as CFString, &value), context: context, allowMissing: true)
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return NativeAXObject(unsafeDowncast(value, to: AXUIElement.self))
    }

    private func installTimeout(_ element: AXUIElement, context: OperationContext) throws {
        try checkAXRead(AXUIElementSetMessagingTimeout(element, try context.nativeTimeoutSeconds()), context: context)
    }
}

struct ClickWitness {
    let screen: Point
    private let frame: VisualFrame
    private let original: CGImage
    private let region: CGRect

    init?(point: Point, space: CoordinateSpace, observation: Observation, visualOnly: Bool) {
        guard let frame = observation.visual?.frame, let screenshot = observation.screenshot,
              observation.visual?.captureStatus == .captured,
              visualOnly
                ? observation.accessibility == .unavailable && observation.visual?.geometryMatchesAX == nil
                    && observation.windowBounds == frame.captureWindowBounds
                : observation.visual?.geometryMatchesAX == true,
              let data = Data(base64Encoded: screenshot.dataBase64),
              let original = Self.decode(data), original.width == frame.widthPx, original.height == frame.heightPx else { return nil }
        let image = Self.toImage(point: point, space: space, frame: frame)
        guard let screen = try? frame.imageToScreen.toScreen(image) else { return nil }
        let raster = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let region = CGRect(x: floor(image.x) - 12, y: floor(image.y) - 12, width: 25, height: 25).intersection(raster)
        guard region.width >= 8, region.height >= 8 else { return nil }
        self.screen = screen; self.frame = frame; self.original = original; self.region = region
    }

    static func mapToScreen(point: Point, space: CoordinateSpace, observation: Observation, visualOnly: Bool) -> Point? {
        guard let frame = observation.visual?.frame, observation.visual?.captureStatus == .captured,
              visualOnly
                ? observation.accessibility == .unavailable && observation.visual?.geometryMatchesAX == nil
                    && observation.windowBounds == frame.captureWindowBounds
                : observation.visual?.geometryMatchesAX == true else { return nil }
        return try? frame.imageToScreen.toScreen(toImage(point: point, space: space, frame: frame))
    }

    private static func toImage(point: Point, space: CoordinateSpace, frame: VisualFrame) -> Point {
        switch space {
        case .imagePixels: return point
        case .screenPoints:
            return Point(x: (point.x - frame.imageToScreen.offsetX) / frame.imageToScreen.scaleX,
                         y: (point.y - frame.imageToScreen.offsetY) / frame.imageToScreen.scaleY)
        case .windowPoints:
            return Point(x: (point.x - frame.imageToWindow.offsetX) / frame.imageToWindow.scaleX,
                         y: (point.y - frame.imageToWindow.offsetY) / frame.imageToWindow.scaleY)
        }
    }

    func validate(capture: any VisualCapturing, target: Target, context: OperationContext) throws {
        let bounds = frame.captureWindowBounds
        let screenCrop = frame.captureScreenBounds
        let crop = bounds == screenCrop ? nil : Rect(x: frame.imageToWindow.offsetX, y: frame.imageToWindow.offsetY,
                                                     width: screenCrop.width, height: screenCrop.height)
        let fresh = try capture.capture(target: target, crop: crop, maxDimension: Int(max(frame.widthPx, frame.heightPx)), context: context)
        guard fresh.frame == frame,
              let bytes = jpegData(fresh.image), let image = Self.decode(bytes),
              let old = Self.pixels(original, region: region),
              let new = Self.pixels(image, region: region), old == new else {
            throw ForegroundStopped(reason: .frameChanged)
        }
        try context.check()
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pixels(_ image: CGImage, region: CGRect) -> Data? {
        guard let part = image.cropping(to: region),
              let context = CGContext(data: nil, width: part.width, height: part.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let bytes = context.data else { return nil }
        context.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        return Data(bytes: bytes, count: context.bytesPerRow * context.height)
    }
}
