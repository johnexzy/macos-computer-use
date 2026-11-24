import AppKit
import CoreGraphics
import Foundation
import QuartzCore
import UseUIProtocol
import os

struct DesktopActivity: Sendable {
    enum Phase: String {
        case observing = "Inspecting"
        case movingToControl = "Moving to control"
        case movingToText = "Moving to text"
        case pressed = "Control pressed"
        case written = "Text updated"
        case writingSent = "Text sent"
        case updated = "Control updated"
        case scrolled = "Scrolled"
        case sent = "Action sent"
        case skipped = "Input skipped"
        case rechecking = "Rechecking target"
        case check = "Check result"

        var badgeLabel: String {
            switch self {
            case .observing: "Reading"
            case .movingToControl, .movingToText: "Moving"
            case .pressed: "Pressed"
            case .updated: "Updated"
            case .skipped: "Skipped"
            case .rechecking: "Rechecking"
            case .written, .writingSent, .scrolled, .sent, .check: rawValue
            }
        }

        var showsWriting: Bool { self == .written || self == .writingSent }
        var isApproach: Bool { self == .movingToControl || self == .movingToText }
        var needsReadback: Bool { self == .skipped || self == .check }
    }

    let target: TargetKey
    let bounds: Rect
    let phase: Phase
    let point: CGPoint?
    let controlBounds: Rect?
    let label: String?
    let isForeground: Bool

    init(target: TargetKey, bounds: Rect, phase: Phase, point: CGPoint?,
         controlBounds: Rect? = nil, label: String? = nil, isForeground: Bool = false) {
        self.target = target
        self.bounds = bounds
        self.phase = phase
        self.point = point
        self.controlBounds = controlBounds
        self.label = label
        self.isForeground = isForeground
    }

    var pillText: String {
        if let label, !label.isEmpty { return label }
        return phase.badgeLabel
    }

    static func observing(_ observation: Observation) -> Self {
        Self(target: observation.target, bounds: observation.windowBounds, phase: .observing, point: nil)
    }

    func withPhase(_ phase: Phase, label: String? = nil) -> Self {
        Self(target: target, bounds: bounds, phase: phase, point: nil,
             controlBounds: nil, label: label ?? self.label, isForeground: isForeground)
    }

    static func approaching(_ target: Target, control: Rect, writing: Bool, label: String? = nil, isForeground: Bool = false) -> Self {
        let clean = sanitizeLabel(label)
        let narration: String
        if let clean {
            narration = writing ? "Typing in \"\(clean)\"" : "Clicking \"\(clean)\""
        } else {
            narration = writing ? "Moving to text field" : "Moving to control"
        }
        return Self(target: target.key, bounds: target.bounds,
                    phase: writing ? .movingToText : .movingToControl,
                    point: anchor(control: control, window: target.bounds, writing: writing),
                    controlBounds: control,
                    label: narration,
                    isForeground: isForeground)
    }

    static func approaching(_ target: Target, screenPoint: UseUIProtocol.Point, label: String? = nil, isForeground: Bool = true) -> Self {
        Self(target: target.key, bounds: target.bounds, phase: .movingToControl,
             point: CGPoint(x: screenPoint.x, y: screenPoint.y),
             controlBounds: nil,
             label: sanitizeLabel(label) ?? (isForeground ? "Foreground pointer" : "Moving to target"),
             isForeground: isForeground)
    }

    static func textRole(_ role: String) -> Bool {
        ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(role)
    }

    private static func sanitizeLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count > 34 {
            return String(collapsed.prefix(33)) + "…"
        }
        return collapsed
    }

    private static func anchor(control: Rect, window: Rect, writing: Bool) -> CGPoint? {
        let bounds = cgRect(control).intersection(cgRect(window))
        guard !bounds.isEmpty else { return nil }
        if writing {
            return CGPoint(x: bounds.minX + min(12, bounds.width / 2), y: bounds.minY + min(14, bounds.height / 2))
        }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private static func lastMutation(_ request: ActRequest, result: ActResult) -> (ActionStep, StepReceipt)? {
        for (step, receipt) in Array(zip(request.steps, result.steps)).reversed() {
            guard step.actionId == receipt.actionId else { return nil }
            if case .waitFor = step.operation { continue }
            if receipt.delivery == .notDispatched && (receipt.reason == nil || receipt.reason == .alreadySatisfied) { continue }
            return (step, receipt)
        }
        return nil
    }

    private static func recoveryPhase(for receipt: StepReceipt) -> Phase? {
        if receipt.delivery == .notDispatched { return .skipped }
        if receipt.delivery == .unknown || receipt.verification == .mismatch ||
            (receipt.verification == .unverified && receipt.reason != nil) { return .check }
        return nil
    }

    static func recoveryPhase(_ request: ActRequest, result: ActResult) -> Phase? {
        guard let (_, receipt) = lastMutation(request, result: result) else { return nil }
        return recoveryPhase(for: receipt)
    }

    static func action(_ request: ActRequest, result: ActResult, observation: Observation) -> Self? {
        guard let (step, receipt) = lastMutation(request, result: result) else { return nil }
        if let recovery = recoveryPhase(for: receipt) {
            return observing(observation).withPhase(recovery, label: recovery.badgeLabel)
        }

        var phase: Phase = .updated
        var elementRef: String?
        var point: CGPoint?
        var controlBounds: Rect?
        var label: String?

        func mapScreen(_ input: Point, space: CoordinateSpace) -> CGPoint? {
            let screen: UseUIProtocol.Point?
            switch space {
            case .screenPoints: screen = input
            case .windowPoints:
                screen = .init(x: input.x + observation.windowBounds.x, y: input.y + observation.windowBounds.y)
            case .imagePixels: screen = try? observation.visual?.frame?.imageToScreen.toScreen(input)
            }
            return screen.map { CGPoint(x: $0.x, y: $0.y) }
        }

        switch step.operation {
        case .setValue(let input): elementRef = input.elementRef
        case .typeText(let input): elementRef = input.elementRef; phase = .written
        case .typeKeys(let input): elementRef = input.elementRef; phase = .written
        case .press(let input), .confirm(let input), .showMenu(let input), .cancel(let input):
            elementRef = input.elementRef; phase = .pressed
        case .invokeMenu(let input):
            phase = .pressed
            if let last = input.path.last { label = "Menu \"\(last)\"" }
        case .setWindowFrame, .windowAction, .focusWindow:
            phase = .updated
            label = "Window updated"
        case .key(let input):
            elementRef = input.elementRef
            label = "Pressed \(input.key.rawValue)"
        case .hotkey(let input):
            elementRef = input.elementRef
            label = "Shortcut \(input.key)"
        case .click(let input), .doubleClick(let input), .rightClick(let input):
            phase = .pressed
            point = mapScreen(input.point, space: input.space)
            label = request.foreground ? "Foreground click" : "Clicked"
        case .hover(let input):
            phase = .movingToControl
            point = mapScreen(input.point, space: input.space)
            label = "Hovering"
        case .drag(let input):
            phase = .pressed
            point = mapScreen(input.to, space: input.space)
            label = "Dragged"
        case .scrollWheel(let input):
            phase = .scrolled
            point = mapScreen(input.point, space: input.space)
            label = "Scrolled"
        case .scroll(let input): elementRef = input.elementRef; phase = .scrolled
        case .scrollToVisible(let input): elementRef = input.elementRef; phase = .scrolled
        case .waitFor: return nil
        }

        if let elementRef, let element = observation.elements.first(where: { $0.reference == elementRef }) {
            if case .setValue = step.operation, textRole(element.role) { phase = .written }
            controlBounds = element.bounds
            point = anchor(control: element.bounds, window: observation.windowBounds, writing: phase.showsWriting)
            if let clean = sanitizeLabel(element.label) {
                if phase.showsWriting { label = "Updated \"\(clean)\"" }
                else if phase == .pressed { label = "Clicked \"\(clean)\"" }
                else if phase == .scrolled { label = "Scrolled \"\(clean)\"" }
                else if label == nil { label = "Updated \"\(clean)\"" }
            }
        }

        if receipt.verification == .unverified && phase != .scrolled {
            phase = phase.showsWriting ? .writingSent : .sent
        }
        return Self(target: observation.target, bounds: observation.windowBounds,
                    phase: phase, point: point, controlBounds: controlBounds,
                    label: label, isForeground: request.foreground)
    }
}

private func cgRect(_ rect: Rect) -> CGRect {
    CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
}

@MainActor
final class DesktopActivityOverlay {
    private static let displayDuration: TimeInterval = 2.4
    private lazy var panel = ActivityPanel()
    private lazy var view = DesktopActivityView()
    private var activity: DesktopActivity?
    private var lastObservation: DesktopActivity?
    private var recoveryTarget: TargetKey?
    private var timer: Timer?
    private var expiresAt: TimeInterval = 0
    var onActivity: @MainActor @Sendable (DesktopActivity) -> Void

    var isEnabled: Bool = true {
        didSet {
            if !isEnabled { hide() }
        }
    }

    var motionStyle: CursorMotionStyle = .signatureArc

    nonisolated init(onActivity: @escaping @MainActor @Sendable (DesktopActivity) -> Void = { _ in }) {
        self.onActivity = onActivity
    }

    nonisolated func submit(_ activity: DesktopActivity) {
        DispatchQueue.main.async { self.present(activity) }
    }

    nonisolated func showRecovery(_ phase: DesktopActivity.Phase, target: TargetKey) {
        DispatchQueue.main.async {
            // An expired reference or interrupted request may lack geometry.
            // Reuse only a matching observation from this session.
            guard let anchor = self.lastObservation, anchor.target == target else { return }
            self.present(anchor.withPhase(phase, label: phase.badgeLabel))
        }
    }

    nonisolated func beginObservation(_ target: TargetKey) {
        DispatchQueue.main.async {
            guard self.recoveryTarget == target, let anchor = self.lastObservation, anchor.target == target else { return }
            self.show(anchor.withPhase(.rechecking, label: "Rechecking target"))
        }
    }

    private func present(_ event: DesktopActivity) {
        if event.phase == .observing {
            lastObservation = event
            if recoveryTarget == event.target {
                recoveryTarget = nil
                if activity?.phase != .rechecking || activity?.target != event.target || activity?.bounds != event.bounds {
                    show(event.withPhase(.rechecking, label: "Rechecking target"))
                }
                return
            }
        } else if event.phase.needsReadback {
            recoveryTarget = event.target
        } else if recoveryTarget == event.target {
            recoveryTarget = nil
        }
        show(event)
    }

    /// Wait on the native worker only. A late main queue or tight action budget can skip the cue.
    nonisolated func approach(_ event: DesktopActivity, context: OperationContext) throws -> Bool {
        guard let point = event.point, cgRect(event.bounds).contains(point),
              try context.nativeTimeoutSeconds(maximum: 0.35) >= 0.30 else { return false }
        let startBy = DispatchTime.now() + .milliseconds(45)
        let endBy = startBy + .milliseconds(270)
        let arrived = DispatchSemaphore(value: 0)
        let presented = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.main.async {
            guard self.isEnabled, DispatchTime.now() < startBy, context.interruption == nil,
                  let motion = self.show(event) else {
                arrived.signal()
                return
            }
            presented.withLock { $0 = true }
            let complete: @MainActor @Sendable () -> Void = {
                arrived.signal()
            }
            if motion > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + motion + 0.015, execute: complete) }
            else { complete() }
        }
        while DispatchTime.now() < endBy {
            try context.check()
            if arrived.wait(timeout: min(.now() + .milliseconds(8), endBy)) == .success { break }
        }
        try context.check()
        return presented.withLock { $0 }
    }

    nonisolated func discardApproach(for target: TargetKey) {
        DispatchQueue.main.async {
            if self.activity?.target == target && self.activity?.phase.isApproach == true { self.hide() }
        }
    }

    nonisolated func dismiss() {
        DispatchQueue.main.async { self.hide() }
    }

    @discardableResult
    private func show(_ event: DesktopActivity) -> TimeInterval? {
        onActivity(event)
        guard isEnabled else { hide(); return nil }
        guard isCurrent(event), let primary = NSScreen.screens.first else { hide(); return nil }
        let bounds = cgRect(event.bounds)
        let frame = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { hide(); return nil }

        let sameTarget = activity?.target == event.target && activity?.bounds == event.bounds
        let now = ProcessInfo.processInfo.systemUptime
        if sameTarget && event.phase == .observing && activity?.phase != .observing &&
            now < expiresAt - Self.displayDuration + 0.45 { return nil }

        let point = event.point.flatMap { bounds.contains($0) ? CGPoint(x: $0.x - bounds.minX, y: bounds.maxY - $0.y) : nil }
        let localControlRect: CGRect? = event.controlBounds.flatMap { raw in
            let inter = cgRect(raw).intersection(bounds)
            guard !inter.isEmpty else { return nil }
            return CGRect(x: inter.minX - bounds.minX, y: bounds.maxY - inter.maxY,
                          width: inter.width, height: inter.height)
        }
        let workspace = NSWorkspace.shared
        let changed = !sameTarget || activity?.phase != event.phase || activity?.pillText != event.pillText
        activity = event
        expiresAt = now + Self.displayDuration
        panel.setFrame(frame, display: false)
        if panel.contentView !== view { panel.contentView = view }
        let motion = view.update(event: event, point: point, controlRect: localControlRect,
                                 retainPosition: sameTarget, style: motionStyle,
                                 reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                                 highContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        panel.order(.above, relativeTo: Int(event.target.windowId))
        if changed && workspace.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
                .announcement: "UseUI. " + event.pillText,
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ])
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        return motion
    }

    private func refresh() {
        guard let activity, ProcessInfo.processInfo.systemUptime < expiresAt, isCurrent(activity) else { hide(); return }
    }

    func hide() {
        guard activity != nil || panel.isVisible else { return }
        activity = nil
        timer?.invalidate()
        timer = nil
        view.stopAnimation()
        panel.orderOut(nil)
    }

    private func isCurrent(_ event: DesktopActivity) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let window = windows.first(where: {
                  $0[kCGWindowNumber as String] as? UInt32 == event.target.windowId &&
                  $0[kCGWindowOwnerPID as String] as? UInt32 == event.target.pid &&
                  $0[kCGWindowLayer as String] as? Int == 0
              }),
              let bounds = window[kCGWindowBounds as String] as? [String: Double] else { return false }
        return bounds["X"] == event.bounds.x && bounds["Y"] == event.bounds.y &&
               bounds["Width"] == event.bounds.width && bounds["Height"] == event.bounds.height
    }
}

private final class ActivityPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        setAccessibilityElement(false)
    }
}

/// GPU-composited CoreAnimation overlay rendering UseUI's Open Frame, Target Lock-On Brackets,
/// Brand Mint/Ink Bezier Cursor, Dual Concentric Ripples, and Floating Intent Pill.
private final class DesktopActivityView: NSView {
    private let frameInkLayer = CAShapeLayer()
    private let frameAccentLayer = CAShapeLayer()
    private let cornerBracketLayer = CAShapeLayer()
    private let lockFillLayer = CAShapeLayer()
    private let lockBracketLayer = CAShapeLayer()
    private let ripple1 = CAShapeLayer()
    private let ripple2 = CAShapeLayer()
    private let cursorGroup = CALayer()
    private let cursorShape = CAShapeLayer()
    private let cursorRim = CAShapeLayer()
    private let pillBackdrop = CALayer()
    private let pillDot = CAShapeLayer()
    private let pillBrand = CATextLayer()
    private let pillLabel = CATextLayer()

    private var lastPoint: CGPoint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }
        root.masksToBounds = false

        // Open Frame window outline
        frameInkLayer.fillColor = nil
        frameAccentLayer.fillColor = nil
        cornerBracketLayer.fillColor = nil
        cornerBracketLayer.lineCap = .round
        cornerBracketLayer.lineJoin = .round
        cornerBracketLayer.shadowColor = UseUIBrand.ink.cgColor
        cornerBracketLayer.shadowOpacity = 0.55
        cornerBracketLayer.shadowRadius = 4
        cornerBracketLayer.shadowOffset = .zero

        // Target control lock-on spotlight
        lockFillLayer.strokeColor = nil
        lockFillLayer.opacity = 0
        lockBracketLayer.fillColor = nil
        lockBracketLayer.lineCap = .round
        lockBracketLayer.lineJoin = .round
        lockBracketLayer.opacity = 0

        // Dual click ripple rings
        for ring in [ripple1, ripple2] {
            ring.fillColor = nil
            ring.lineWidth = 2.0
            ring.opacity = 0
            ring.bounds = CGRect(x: -16, y: -16, width: 32, height: 32)
            ring.path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        }

        // Brand cursor group (tip anchored at (0, 0))
        cursorGroup.anchorPoint = .zero
        cursorGroup.bounds = .zero
        cursorGroup.isHidden = true
        cursorGroup.shadowColor = UseUIBrand.ink.cgColor
        cursorGroup.shadowOpacity = 0.42
        cursorGroup.shadowRadius = 5
        cursorGroup.shadowOffset = CGSize(width: 0, height: -2)

        cursorShape.lineJoin = .round
        cursorShape.lineCap = .round
        cursorShape.strokeColor = UseUIBrand.ink.cgColor
        cursorRim.fillColor = nil
        cursorRim.strokeColor = UseUIBrand.paper.withAlphaComponent(0.45).cgColor
        cursorRim.lineWidth = 0.8
        cursorRim.lineJoin = .round
        cursorGroup.addSublayer(cursorShape)
        cursorGroup.addSublayer(cursorRim)

        // Floating Intent Pill
        pillBackdrop.backgroundColor = UseUIBrand.ink.withAlphaComponent(0.92).cgColor
        pillBackdrop.cornerRadius = 13
        pillBackdrop.borderWidth = 1
        pillBackdrop.shadowColor = UseUIBrand.ink.cgColor
        pillBackdrop.shadowOpacity = 0.36
        pillBackdrop.shadowRadius = 10
        pillBackdrop.shadowOffset = CGSize(width: 0, height: -3)

        pillDot.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 7, height: 7), transform: nil)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        for textLayer in [pillBrand, pillLabel] {
            textLayer.contentsScale = scale
            textLayer.truncationMode = .end
            textLayer.alignmentMode = .left
        }
        pillBrand.string = "UseUI"
        pillBrand.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        pillBrand.fontSize = 11
        pillLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        pillLabel.fontSize = 11.5
        pillLabel.foregroundColor = UseUIBrand.paper.cgColor

        pillBackdrop.addSublayer(pillDot)
        pillBackdrop.addSublayer(pillBrand)
        pillBackdrop.addSublayer(pillLabel)

        for sub in [frameInkLayer, frameAccentLayer, cornerBracketLayer,
                    lockFillLayer, lockBracketLayer, ripple1, ripple2,
                    cursorGroup, pillBackdrop] {
            root.addSublayer(sub)
        }
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }

    func stopAnimation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorGroup.removeAllAnimations()
        ripple1.removeAllAnimations()
        ripple2.removeAllAnimations()
        lockBracketLayer.removeAllAnimations()
        lockFillLayer.removeAllAnimations()
        CATransaction.commit()
    }

    private func accentColor(for event: DesktopActivity) -> NSColor {
        if event.phase == .skipped { return UseUIBrand.coral }
        if event.phase == .check || event.isForeground { return UseUIBrand.amber }
        return UseUIBrand.mint
    }

    func update(event: DesktopActivity, point: CGPoint?, controlRect: CGRect?,
                retainPosition: Bool, style: CursorMotionStyle,
                reduceMotion: Bool, highContrast: Bool) -> TimeInterval {
        let accent = accentColor(for: event)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        pillBrand.contentsScale = scale
        pillLabel.contentsScale = scale

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // 1. Open Frame border + signature corner brackets
        let inset = bounds.insetBy(dx: 2.5, dy: 2.5)
        let framePath = CGPath(roundedRect: inset, cornerWidth: 10, cornerHeight: 10, transform: nil)
        frameInkLayer.path = framePath
        frameInkLayer.strokeColor = UseUIBrand.ink.withAlphaComponent(highContrast ? 0.92 : 0.55).cgColor
        frameInkLayer.lineWidth = highContrast ? 4.5 : 3.0

        frameAccentLayer.path = framePath
        frameAccentLayer.strokeColor = accent.withAlphaComponent(highContrast ? 1.0 : 0.78).cgColor
        frameAccentLayer.lineWidth = highContrast ? 2.5 : 1.5

        let bracketInset = bounds.insetBy(dx: 7, dy: 7)
        cornerBracketLayer.path = UseUIBrand.cornerBracketsPath(around: bracketInset, armLength: 18, radius: 5)
        cornerBracketLayer.strokeColor = accent.cgColor
        cornerBracketLayer.lineWidth = highContrast ? 3.2 : 2.4

        // 2. Target control Lock-On spotlight brackets
        if let controlRect, controlRect.width > 2, controlRect.height > 2 {
            let padRect = controlRect.insetBy(dx: -4, dy: -4).intersection(bounds.insetBy(dx: 4, dy: 4))
            lockFillLayer.path = CGPath(roundedRect: padRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            lockFillLayer.fillColor = accent.withAlphaComponent(event.phase.showsWriting ? 0.14 : 0.09).cgColor
            lockFillLayer.opacity = 1

            lockBracketLayer.path = UseUIBrand.cornerBracketsPath(around: padRect, armLength: 12, radius: 4)
            lockBracketLayer.strokeColor = accent.cgColor
            lockBracketLayer.lineWidth = highContrast ? 2.8 : 2.0
            lockBracketLayer.opacity = 1
        } else {
            lockFillLayer.opacity = 0
            lockBracketLayer.opacity = 0
        }

        // 3. Floating Intent Pill (top-right for compact windows, bottom-center for larger windows)
        layoutIntentPill(text: event.pillText, accent: accent, highContrast: highContrast)

        // 4. Cursor & physics
        var travel: TimeInterval = 0
        let prevPoint = retainPosition ? lastPoint : nil
        lastPoint = point ?? prevPoint

        if let point {
            let isCaret = event.phase.showsWriting || event.phase == .movingToText
            cursorShape.path = isCaret ? UseUIBrand.caretPath(scale: 1.0) : UseUIBrand.pointerPath(scale: 1.0)
            cursorShape.fillColor = accent.cgColor
            cursorShape.lineWidth = highContrast ? 2.4 : 1.8
            cursorRim.path = isCaret ? nil : UseUIBrand.pointerPath(scale: 0.90)
            cursorGroup.isHidden = false
            cursorGroup.removeAllAnimations()

            if event.phase.isApproach {
                let start = prevPoint ?? CGPoint(
                    x: max(12, min(bounds.maxX - 12, point.x - 46)),
                    y: max(12, min(bounds.maxY - 12, point.y + 30))
                )
                let traj = CursorTrajectory.build(from: start, to: point, style: style, reduceMotion: reduceMotion)
                travel = traj.duration
                cursorGroup.position = point
                cursorGroup.transform = CATransform3DIdentity

                if traj.duration > 0 {
                    let moveAnim = CAKeyframeAnimation(keyPath: "position")
                    moveAnim.path = traj.cgPath()
                    moveAnim.duration = traj.duration
                    moveAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    moveAnim.fillMode = .backwards
                    cursorGroup.add(moveAnim, forKey: "glide")

                    let bankValues: [CGFloat] = [0.0, 0.25, 0.5, 0.78, 1.0].map { traj.bankAngleRadians(at: $0) }
                    let bankAnim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
                    bankAnim.values = bankValues
                    bankAnim.keyTimes = [0, 0.25, 0.5, 0.78, 1.0]
                    bankAnim.duration = traj.duration
                    cursorGroup.add(bankAnim, forKey: "bank")
                }
            } else {
                cursorGroup.position = point
                cursorGroup.transform = CATransform3DIdentity
                if (event.phase == .pressed || event.phase == .sent) && !reduceMotion && style != .reduced {
                    animateClickImpact(at: point, accent: accent)
                }
            }
        } else {
            cursorGroup.isHidden = true
        }

        CATransaction.commit()
        return travel
    }

    private func animateClickImpact(at point: CGPoint, accent: NSColor) {
        // Tactile press-down squish -> spring rebound
        let squish = CAKeyframeAnimation(keyPath: "transform.scale")
        squish.values = [1.0, 0.85, 1.05, 1.0]
        squish.keyTimes = [0.0, 0.30, 0.72, 1.0]
        squish.duration = 0.22
        squish.timingFunction = CAMediaTimingFunction(name: .easeOut)
        cursorGroup.add(squish, forKey: "squish")

        // Dual concentric Mint ripples
        let configs: [(CAShapeLayer, CFTimeInterval, CGFloat, Double)] = [
            (ripple1, 0.0, 2.7, 0.40),
            (ripple2, 0.055, 3.6, 0.48),
        ]
        let now = CACurrentMediaTime()
        for (ring, delay, maxScale, duration) in configs {
            ring.removeAllAnimations()
            ring.position = point
            ring.strokeColor = accent.cgColor

            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = 0.45
            scaleAnim.toValue = maxScale

            let alphaAnim = CABasicAnimation(keyPath: "opacity")
            alphaAnim.fromValue = 0.92
            alphaAnim.toValue = 0.0

            let group = CAAnimationGroup()
            group.animations = [scaleAnim, alphaAnim]
            group.duration = duration
            group.beginTime = now + delay
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            group.fillMode = .backwards
            ring.add(group, forKey: "ripple")
        }
    }

    private func layoutIntentPill(text: String, accent: NSColor, highContrast: Bool) {
        let brandFont = NSFont.systemFont(ofSize: 11, weight: .bold)
        let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let brandW = ("UseUI" as NSString).size(withAttributes: [.font: brandFont]).width
        let maxLabelW = max(60, min(280, bounds.width - brandW - 72))
        let rawLabelW = (text as NSString).size(withAttributes: [.font: labelFont]).width
        let labelW = min(maxLabelW, rawLabelW + 4)

        let pillW = 12 + 7 + 7 + brandW + 10 + labelW + 12
        let pillH: CGFloat = 26
        guard pillW + 20 <= bounds.width, bounds.height > 44 else {
            pillBackdrop.isHidden = true
            return
        }
        pillBackdrop.isHidden = false

        // Bottom-center for roomy windows; top-right for compact utility windows
        let pillX = bounds.width >= 320 ? (bounds.width - pillW) / 2.0 : bounds.maxX - pillW - 14
        let pillY: CGFloat = bounds.height >= 180 ? 14 : bounds.maxY - pillH - 10
        pillBackdrop.frame = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
        pillBackdrop.borderColor = accent.withAlphaComponent(highContrast ? 0.95 : 0.42).cgColor
        pillBackdrop.borderWidth = highContrast ? 2.0 : 1.0

        pillDot.fillColor = accent.cgColor
        pillDot.frame = CGRect(x: 11, y: (pillH - 7) / 2.0, width: 7, height: 7)

        pillBrand.foregroundColor = accent.cgColor
        pillBrand.frame = CGRect(x: 24, y: 5, width: brandW + 2, height: 15)

        pillLabel.string = text
        pillLabel.frame = CGRect(x: 24 + brandW + 9, y: 5, width: labelW, height: 15)
    }
}
