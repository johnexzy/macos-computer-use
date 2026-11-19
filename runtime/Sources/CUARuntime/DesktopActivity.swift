import AppKit
import CUAProtocol
import Foundation

struct DesktopActivity: Sendable {
    enum Phase: String {
        case observing = "Inspecting"
        case pressed = "Control pressed"
        case written = "Text updated"
        case writingSent = "Text sent"
        case updated = "Control updated"
        case sent = "Action sent"
        case check = "Check result"

        var showsWriting: Bool { self == .written || self == .writingSent }
    }

    let target: TargetKey
    let bounds: Rect
    let phase: Phase
    let point: CGPoint?

    static func observing(_ observation: Observation) -> Self {
        Self(target: observation.target, bounds: observation.windowBounds, phase: .observing, point: nil)
    }

    static func action(_ request: ActRequest, result: ActResult, observation: Observation) -> Self? {
        // In a batch, show the most recent dispatch or uncertain outcome.
        guard let index = result.steps.lastIndex(where: { $0.delivery != .notDispatched }),
              request.steps.indices.contains(index) else { return nil }
        let step = request.steps[index]
        let receipt = result.steps[index]
        guard step.actionId == receipt.actionId else { return nil }

        var phase: Phase = .updated
        var elementRef: String?
        var point: CGPoint?
        switch step.operation {
        case .setValue(let input): elementRef = input.elementRef
        case .typeText(let input): elementRef = input.elementRef; phase = .written
        case .press(let input): elementRef = input.elementRef; phase = .pressed
        case .key(let input): elementRef = input.elementRef
        case .click(let input):
            phase = .pressed
            let screen: CUAProtocol.Point?
            switch input.space {
            case .screenPoints: screen = input.point
            case .windowPoints:
                screen = .init(x: input.point.x + observation.windowBounds.x, y: input.point.y + observation.windowBounds.y)
            case .imagePixels: screen = try? observation.visual?.frame?.imageToScreen.toScreen(input.point)
            }
            point = screen.map { CGPoint(x: $0.x, y: $0.y) }
        case .scroll, .waitFor: return nil
        }
        if let elementRef, let element = observation.elements.first(where: { $0.reference == elementRef }) {
            if case .setValue = step.operation,
               ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(element.role) {
                phase = .written
            }
            let bounds = cgRect(element.bounds).intersection(cgRect(observation.windowBounds))
            if !bounds.isEmpty {
                point = phase.showsWriting
                    ? CGPoint(x: bounds.minX + min(12, bounds.width / 2), y: bounds.minY + min(14, bounds.height / 2))
                    : CGPoint(x: bounds.midX, y: bounds.midY)
            }
        }

        if receipt.delivery == .unknown || receipt.verification == .mismatch {
            phase = .check
            point = nil
        } else if receipt.verification == .unverified {
            phase = phase.showsWriting ? .writingSent : .sent
        }
        return Self(target: observation.target, bounds: observation.windowBounds, phase: phase, point: point)
    }
}

private func cgRect(_ rect: Rect) -> CGRect {
    CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
}

@MainActor
final class DesktopActivityOverlay {
    private static let displayDuration: TimeInterval = 2.2
    private lazy var panel = ActivityPanel()
    private lazy var view = DesktopActivityView()
    private var activity: DesktopActivity?
    private var timer: Timer?
    private var expiresAt: TimeInterval = 0

    nonisolated init() {}

    nonisolated func submit(_ activity: DesktopActivity) {
        DispatchQueue.main.async { self.show(activity) }
    }

    nonisolated func dismiss() {
        DispatchQueue.main.async { self.hide() }
    }

    private func show(_ event: DesktopActivity) {
        guard isCurrent(event), let primary = NSScreen.screens.first else { hide(); return }
        let bounds = cgRect(event.bounds)
        let frame = CGRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY, width: bounds.width, height: bounds.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) else { hide(); return }

        let sameTarget = activity?.target == event.target && activity?.bounds == event.bounds
        let now = ProcessInfo.processInfo.systemUptime
        if sameTarget && event.phase == .observing && activity?.phase != .observing &&
            now < expiresAt - Self.displayDuration + 0.45 { return }
        let point = event.point.flatMap { bounds.contains($0) ? CGPoint(x: $0.x - bounds.minX, y: bounds.maxY - $0.y) : nil }
        let workspace = NSWorkspace.shared
        let changed = !sameTarget || activity?.phase != event.phase
        activity = event
        expiresAt = now + Self.displayDuration
        panel.setFrame(frame, display: false)
        if panel.contentView !== view { panel.contentView = view }
        view.update(phase: event.phase, point: point, retainPosition: sameTarget,
                    reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                    highContrast: workspace.accessibilityDisplayShouldIncreaseContrast)
        panel.order(.above, relativeTo: Int(event.target.windowId))
        if changed && workspace.isVoiceOverEnabled {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested, userInfo: [
                .announcement: "Computer use. " + event.phase.rawValue,
                .priority: NSAccessibilityPriorityLevel.low.rawValue,
            ])
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard let activity, ProcessInfo.processInfo.systemUptime < expiresAt, isCurrent(activity) else { hide(); return }
    }

    private func hide() {
        guard activity != nil else { return }
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

private final class DesktopActivityView: NSView {
    private var phase = DesktopActivity.Phase.observing
    private var point: CGPoint?
    private var lastPoint: CGPoint?
    private var startPoint: CGPoint?
    private var reduceMotion = false
    private var highContrast = false
    private var started: TimeInterval = 0
    private var animation: Timer?
    private let accent = NSColor(srgbRed: 0.32, green: 0.73, blue: 1, alpha: 1)
    private let ink = NSColor(srgbRed: 0.05, green: 0.10, blue: 0.17, alpha: 1)

    override var isOpaque: Bool { false }

    func update(phase: DesktopActivity.Phase, point: CGPoint?, retainPosition: Bool,
                reduceMotion: Bool, highContrast: Bool) {
        stopAnimation()
        self.phase = phase
        self.point = point
        self.reduceMotion = reduceMotion
        self.highContrast = highContrast
        started = ProcessInfo.processInfo.systemUptime
        startPoint = retainPosition ? lastPoint : nil
        lastPoint = point ?? (retainPosition ? lastPoint : nil)
        needsDisplay = true
        guard let point, !reduceMotion else { return }
        if startPoint == nil {
            startPoint = CGPoint(x: min(bounds.maxX - 4, point.x + 14), y: min(bounds.maxY - 4, point.y + 10))
        }
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 45, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.needsDisplay = true
                if ProcessInfo.processInfo.systemUptime - self.started >= 0.32 { self.stopAnimation() }
            }
        }
    }

    func stopAnimation() {
        animation?.invalidate()
        animation = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 24, bounds.height > 24 else { return }
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 10, yRadius: 10)
        ink.withAlphaComponent(0.9).setStroke()
        outline.lineWidth = highContrast ? 5 : 4
        outline.stroke()
        accent.setStroke()
        outline.lineWidth = highContrast ? 3 : 2
        outline.stroke()
        drawStatus()
        guard let point else { return }

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let t = reduceMotion ? 1 : min(1, elapsed / 0.14)
        let eased = t * t * (3 - 2 * t)
        let from = startPoint ?? point
        let tip = CGPoint(x: from.x + (point.x - from.x) * eased, y: from.y + (point.y - from.y) * eased)
        if phase.showsWriting {
            drawWriting(at: tip, progress: reduceMotion ? 1 : min(1, elapsed / 0.29))
        } else {
            if phase == .pressed || phase == .sent { drawRing(at: point, elapsed: elapsed) }
            drawPointer(at: tip)
        }
    }

    private func drawStatus() {
        let label = "Agent  ·  " + phase.rawValue
        let font = NSFont.systemFont(ofSize: highContrast ? 13 : 12, weight: .semibold)
        let style: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (label as NSString).size(withAttributes: style)
        guard size.width + 34 <= bounds.width else { return }
        let chip = CGRect(x: bounds.maxX - size.width - 32, y: bounds.maxY - 33, width: size.width + 22, height: 24)
        let path = NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8)
        ink.setFill()
        path.fill()
        (highContrast ? NSColor.white : accent).setStroke()
        path.lineWidth = highContrast ? 2 : 1
        path.stroke()
        (label as NSString).draw(at: CGPoint(x: chip.minX + 11, y: chip.midY - size.height / 2), withAttributes: style)
    }

    private func drawPointer(at tip: CGPoint) {
        let arrow = NSBezierPath()
        arrow.move(to: tip)
        arrow.line(to: CGPoint(x: tip.x + 2, y: tip.y - 21))
        arrow.line(to: CGPoint(x: tip.x + 7, y: tip.y - 16))
        arrow.line(to: CGPoint(x: tip.x + 12, y: tip.y - 24))
        arrow.line(to: CGPoint(x: tip.x + 16, y: tip.y - 21))
        arrow.line(to: CGPoint(x: tip.x + 11, y: tip.y - 14))
        arrow.line(to: CGPoint(x: tip.x + 19, y: tip.y - 14))
        arrow.close()
        fillCue(arrow)
    }

    private func drawRing(at point: CGPoint, elapsed: TimeInterval) {
        let t = reduceMotion ? 0 : min(1, max(0, elapsed - 0.10) / 0.22)
        guard t < 1 else { return }
        let radius = 7 + 13 * t
        let ring = NSBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
        accent.withAlphaComponent(1 - t).setStroke()
        ring.lineWidth = highContrast ? 3 : 2
        ring.stroke()
    }

    private func drawWriting(at tip: CGPoint, progress: Double) {
        // Reveal three abstract strokes and a caret. Typed characters never reach this view.
        let writing = NSBezierPath()
        let lengths: [CGFloat] = [10, 8, 12]
        var x = tip.x
        for (index, length) in lengths.enumerated() {
            let reveal = min(1, max(0, progress * 3 - Double(index)))
            guard reveal > 0 else { break }
            writing.appendRoundedRect(CGRect(x: x, y: tip.y - 2, width: length * reveal, height: 4), xRadius: 2, yRadius: 2)
            x += (length + 3) * reveal
        }
        writing.appendRoundedRect(CGRect(x: x + 2, y: tip.y - 7, width: 3, height: 14), xRadius: 1, yRadius: 1)
        fillCue(writing)
    }

    private func fillCue(_ path: NSBezierPath) {
        accent.setFill()
        ink.setStroke()
        path.lineJoinStyle = .round
        path.lineWidth = highContrast ? 2.5 : 1.6
        path.fill()
        path.stroke()
    }
}
