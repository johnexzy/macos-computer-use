import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import CUAProtocol
import Foundation
import ImageIO

struct ForegroundSample: Equatable, Sendable {
    let pid: UInt32?
    let hardwareCounters: [UInt32]
    let inputHeld: Bool
}

enum ForegroundInput: Sendable {
    case key(Key)
    case click(Point)
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
    func sample() -> ForegroundSample
    func watch(expecting pid: UInt32) -> ActivationWatch
    func focusedWindow(pid: UInt32, context: OperationContext) throws -> (any AXObject)?
    func focusedElement(pid: UInt32, context: OperationContext) throws -> (any AXObject)?
    func activate(pid: UInt32, window: any AXObject, context: OperationContext, willChangeFocus: () throws -> Void) throws
    func hitTest(_ point: Point, in target: SemanticObservationHandle, context: OperationContext) throws -> Bool
    func post(_ input: ForegroundInput, willDispatch: () throws -> Void) throws
}

/// Owns one temporary foreground route under the runtime's shared mutation lock.
final class ForegroundControl {
    private let platform: any ForegroundPlatform
    private let capture: any VisualCapturing
    private let target: SemanticObservationHandle
    private let context: OperationContext
    private let state: ActionExecutionState
    private let watch: ActivationWatch
    private let initial: ForegroundSample
    private let priorWindow: (any AXObject)?
    private var last: ForegroundSample
    private var activationRequested = false
    private var ownsFocus = false
    private var inputActivity = false
    private var externalActivation = false
    private var interruption: ForegroundInterruption?
    private var restoration: FocusRestoration = .notNeeded

    init(platform: any ForegroundPlatform, capture: any VisualCapturing, target: SemanticObservationHandle,
         context: OperationContext, state: ActionExecutionState) throws {
        self.platform = platform; self.capture = capture; self.target = target; self.context = context; self.state = state
        let first = platform.sample()
        initial = first
        last = first
        watch = platform.watch(expecting: target.target.key.pid)
        priorWindow = if let pid = first.pid, platform.permissionAvailable() {
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
            || (activationRequested ? last.pid != initial.pid && last.pid != target.target.key.pid : last.pid != initial.pid)
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
        guard last.pid == target.target.key.pid else {
            externalActivation = true
            throw stop(.focusChanged)
        }
        guard platform.permissionAvailable() else { throw stop(.permissionUnavailable) }
        do { try target.validateWindow(context: context) }
        catch let failure as NativeFailure where failure.code == .staleObservation || failure.code == .staleElement
            || failure.code == .targetNotFound || failure.code == .ambiguousTarget {
            throw stop(.windowChanged)
        }
        guard let focused = try platform.focusedWindow(pid: target.target.key.pid, context: context),
              target.backend.same(focused, target.retainedWindow) else { throw stop(.windowChanged) }
    }

    func post(_ operation: CUAProtocol.Operation, observation: Observation, checkGuard: () throws -> Void, willDispatch: () throws -> Void) throws {
        try checkContext()
        guard platform.permissionAvailable() else { throw stop(.permissionUnavailable) }
        // Resolve coordinates from the original image before making any activation request.
        let click: ClickWitness?
        switch operation {
        case .click(let value):
            guard let value = ClickWitness(operation: value, observation: observation) else { throw stop(.frameChanged) }
            click = value
        case .key: click = nil
        default: throw NativeFailure(.unsupported, "foreground operation is not implemented")
        }

        try focus()
        let input: ForegroundInput
        switch operation {
        case .key(let value):
            try checkKeyTarget(value.elementRef)
            input = .key(value.key)
        case .click:
            guard let click else { throw stop(.frameChanged) }
            do { try click.validate(capture: capture, target: target.target, context: context) }
            catch is ForegroundStopped { throw stop(.frameChanged) }
            catch is VisualCaptureFailure { throw stop(.frameChanged) }
            input = .click(click.screen)
        default: throw NativeFailure(.unsupported, "foreground operation is not implemented")
        }
        try platform.post(input) {
            try checkGuard()
            try checkFocused()
            if let click, try !platform.hitTest(click.screen, in: target, context: context) { throw stop(.windowChanged) }
            if case .key(let value) = operation { try checkKeyTarget(value.elementRef) }
            // Final lightweight sample follows window/element reads. macOS does not offer atomic validate-and-post.
            try checkInterference()
            guard last.pid == target.target.key.pid else { throw stop(.focusChanged) }
            try willDispatch()
        }
    }

    private func checkKeyTarget(_ reference: String) throws {
        let resolved = try target.resolve(reference, context: context)
        guard resolved.snapshot.enabledKnown && resolved.snapshot.enabled,
              let focused = try platform.focusedElement(pid: target.target.key.pid, context: context),
              target.backend.same(focused, resolved.object) else { throw stop(.windowChanged) }
    }

    private func focus() throws {
        if ownsFocus { try checkFocused(); return }
        try target.validateWindow(context: context)
        let pid = target.target.key.pid
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
        guard activationRequested, restoration == .pending else { return }
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
        let runtimePID = UInt32(getpid())
        var displayCount: UInt32 = 0
        var display: CGDirectDisplayID = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: point.x, y: point.y), 1, &display, &displayCount) == .success, displayCount > 0,
              let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
              let frontWindow = windows.first(where: { row in
                  guard row[kCGWindowLayer as String] as? Int == 0,
                        (row[kCGWindowOwnerPID as String] as? UInt32) != runtimePID,
                        let alpha = row[kCGWindowAlpha as String] as? Double, alpha > 0,
                        let bounds = row[kCGWindowBounds as String] as? [String: Double],
                        let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"] else { return false }
                  return point.x >= x && point.x < x + w && point.y >= y && point.y < y + h
              }),
              frontWindow[kCGWindowNumber as String] as? UInt32 == target.target.key.windowId,
              frontWindow[kCGWindowOwnerPID as String] as? UInt32 == target.target.key.pid else { return false }

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

    func post(_ input: ForegroundInput, willDispatch: () throws -> Void) throws {
        guard let source = CGEventSource(stateID: .privateState) else { throw NativeFailure(.nativeFailed, "event source unavailable") }
        source.localEventsSuppressionInterval = 0
        let down: CGEvent?
        let up: CGEvent?
        switch input {
        case .key(let key):
            let code: Int
            switch key {
            case .return: code = kVK_Return
            case .tab: code = kVK_Tab
            case .escape: code = kVK_Escape
            case .backspace: code = kVK_Delete
            case .left: code = kVK_LeftArrow
            case .right: code = kVK_RightArrow
            case .up: code = kVK_UpArrow
            case .down: code = kVK_DownArrow
            }
            down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
            up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: false)
            down?.flags = []
            up?.flags = []
        case .click(let point):
            let location = CGPoint(x: point.x, y: point.y)
            down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left)
            up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)
            down?.setIntegerValueField(.mouseEventClickState, value: 1)
            up?.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        guard let down, let up else { throw NativeFailure(.nativeFailed, "input event creation failed") }
        try willDispatch()
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
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

    init?(operation: ClickOperation, observation: Observation) {
        guard let frame = observation.visual?.frame, let screenshot = observation.screenshot,
              observation.visual?.geometryMatchesAX == true, let data = Data(base64Encoded: screenshot.dataBase64),
              let original = Self.decode(data), original.width == frame.widthPx, original.height == frame.heightPx else { return nil }
        let image: Point
        switch operation.space {
        case .imagePixels: image = operation.point
        case .screenPoints:
            image = Point(x: (operation.point.x - frame.imageToScreen.offsetX) / frame.imageToScreen.scaleX,
                          y: (operation.point.y - frame.imageToScreen.offsetY) / frame.imageToScreen.scaleY)
        case .windowPoints:
            image = Point(x: (operation.point.x - frame.imageToWindow.offsetX) / frame.imageToWindow.scaleX,
                          y: (operation.point.y - frame.imageToWindow.offsetY) / frame.imageToWindow.scaleY)
        }
        guard let screen = try? frame.imageToScreen.toScreen(image) else { return nil }
        let raster = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let region = CGRect(x: floor(image.x) - 12, y: floor(image.y) - 12, width: 25, height: 25).intersection(raster)
        guard region.width >= 8, region.height >= 8 else { return nil }
        self.screen = screen; self.frame = frame; self.original = original; self.region = region
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
