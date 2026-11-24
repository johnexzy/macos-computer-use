import AppKit
import QuartzCore
import UseUIProtocol
import os

@MainActor
final class LivePreviewPanel: NSObject, NSWindowDelegate {
    // The foreground hit-test can skip click-through cues, but the viewer itself receives input.
    nonisolated static let interactiveWindowID = OSAllocatedUnfairLock<UInt32?>(initialState: nil)

    private enum State {
        case connecting, live, unavailable, paused
    }

    private let capture = LivePreviewCapture()
    private let window = PreviewWindow()
    private let image = PreviewImageView()
    private let dotView = NSView()
    private let appLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let jumpButton = NSButton(title: "Jump", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private var target: LivePreviewTarget?
    private var event: DesktopActivity?
    private var eventExpiry: Task<Void, Never>?
    private var state: State = .connecting
    private var dismissed = false

    var isVisible: Bool { window.isVisible }

    override init() {
        super.init()
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.backgroundColor = UseUIBrand.ink.withAlphaComponent(0.84).cgColor
        window.contentView = blur
        window.delegate = self

        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4
        dotView.layer?.backgroundColor = UseUIBrand.mint.cgColor

        appLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        appLabel.textColor = UseUIBrand.paper
        titleLabel.font = .systemFont(ofSize: 11.5)
        titleLabel.textColor = UseUIBrand.paper.withAlphaComponent(0.68)
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = UseUIBrand.mint
        for label in [appLabel, titleLabel, statusLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        jumpButton.bezelStyle = .rounded
        jumpButton.controlSize = .small
        jumpButton.setAccessibilityLabel("Focus previewed window")
        jumpButton.target = self
        jumpButton.action = #selector(jumpToTarget)

        pauseButton.bezelStyle = .rounded
        pauseButton.controlSize = .small
        pauseButton.setAccessibilityLabel("Pause live view")
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)

        for view in [dotView, appLabel, titleLabel, image, statusLabel, jumpButton, pauseButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(view)
        }
        NSLayoutConstraint.activate([
            dotView.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 13),
            dotView.centerYAnchor.constraint(equalTo: appLabel.centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),

            appLabel.topAnchor.constraint(equalTo: blur.topAnchor, constant: 11),
            appLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 7),
            appLabel.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),

            titleLabel.topAnchor.constraint(equalTo: appLabel.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 13),
            titleLabel.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),

            image.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 9),
            image.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            image.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),
            image.bottomAnchor.constraint(equalTo: pauseButton.topAnchor, constant: -9),

            pauseButton.trailingAnchor.constraint(equalTo: image.trailingAnchor),
            pauseButton.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -10),
            pauseButton.widthAnchor.constraint(equalToConstant: 68),

            jumpButton.trailingAnchor.constraint(equalTo: pauseButton.leadingAnchor, constant: -6),
            jumpButton.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            jumpButton.widthAnchor.constraint(equalToConstant: 56),

            statusLabel.leadingAnchor.constraint(equalTo: image.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: jumpButton.leadingAnchor, constant: -8),
        ])
    }

    func showIfPossible() {
        dismissed = false
        guard let target else {
            if !window.isVisible {
                appLabel.stringValue = "UseUI Live View"
                titleLabel.stringValue = "Waiting for next native window observation…"
                statusLabel.stringValue = "Standby"
                window.positionOnCurrentScreen()
                window.orderFrontRegardless()
                let windowID = UInt32(exactly: window.windowNumber)
                Self.interactiveWindowID.withLock { $0 = windowID }
            }
            return
        }
        follow(target, title: titleLabel.stringValue)
    }

    func follow(_ target: LivePreviewTarget, title: String) {
        guard !dismissed else { return }
        let changed = self.target != target
        if changed {
            self.target = target
            clearActivity()
        }

        let app = NSRunningApplication(processIdentifier: target.processId)?.localizedName ?? "Window"
        let windowTitle = title.isEmpty ? "Window" : title
        appLabel.stringValue = app
        titleLabel.stringValue = target.sheetBounds == nil ? windowTitle : "\(windowTitle)  ·  Dialog"
        image.setAccessibilityLabel("Live view of \(windowTitle) in \(app)")

        if !window.isVisible {
            window.positionOnCurrentScreen()
            window.orderFrontRegardless()
            let windowID = UInt32(exactly: window.windowNumber)
            Self.interactiveWindowID.withLock { $0 = windowID }
        }
        guard state != .paused, changed || state == .unavailable else { return }
        beginCapture(target)
    }

    func activity(_ activity: DesktopActivity) {
        guard let target, state != .paused,
              activity.target.pid == UInt32(exactly: target.processId), activity.target.windowId == target.windowId,
              activity.bounds == target.bounds else { return }
        event = activity
        eventExpiry?.cancel()
        eventExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            self?.clearActivity()
        }
        image.updateCue(activity)
        updateStatus()
    }

    func dismiss() {
        stop()
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    private func stop() {
        dismissed = true
        Self.interactiveWindowID.withLock { $0 = nil }
        capture.stop()
        clearActivity()
        image.clear()
    }

    @objc private func jumpToTarget() {
        guard let target else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        NSRunningApplication(processIdentifier: target.processId)?.activate(options: [])
    }

    @objc private func togglePause() {
        guard let target else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        if state == .paused {
            pauseButton.title = "Pause"
            pauseButton.setAccessibilityLabel("Pause live view")
            beginCapture(target)
        } else {
            capture.stop()
            state = .paused
            pauseButton.title = "Resume"
            pauseButton.setAccessibilityLabel("Resume live view")
            clearActivity()
            image.clear()
        }
    }

    private func beginCapture(_ target: LivePreviewTarget) {
        state = .connecting
        updateStatus()
        image.clear()
        capture.follow(target) { [weak self] frame, viewport in
            guard let self, self.target == target, self.state != .paused else { return }
            self.image.present(frame, viewport: viewport, cue: self.event)
            if self.state != .live {
                self.state = .live
                self.updateStatus()
            }
        } onUnavailable: { [weak self] in
            guard let self, self.target == target, self.state != .paused else { return }
            self.state = .unavailable
            self.clearActivity()
            self.image.clear()
        }
    }

    private func clearActivity() {
        eventExpiry?.cancel()
        eventExpiry = nil
        event = nil
        image.updateCue(nil)
        updateStatus()
    }

    private func updateStatus() {
        let accent: NSColor
        let status: String
        switch state {
        case .connecting:
            status = "Connecting…"
            accent = UseUIBrand.slate
        case .live:
            if let event {
                status = event.pillText
                accent = event.phase == .skipped ? UseUIBrand.coral : (event.isForeground ? UseUIBrand.amber : UseUIBrand.mint)
            } else {
                status = "Live"
                accent = UseUIBrand.mint
            }
        case .unavailable:
            status = "Window unavailable"
            accent = UseUIBrand.coral
        case .paused:
            status = "Paused"
            accent = UseUIBrand.amber
        }
        dotView.layer?.backgroundColor = accent.cgColor
        statusLabel.textColor = accent
        if status != statusLabel.stringValue { statusLabel.stringValue = status }
    }
}

private final class PreviewWindow: NSPanel {
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 376, height: 300),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        title = "UseUI Live View"
        titlebarAppearsTransparent = true
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 280, height: 220)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    func positionOnCurrentScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        setFrameTopLeftPoint(CGPoint(x: area.maxX - frame.width - 16, y: area.maxY - 16))
    }
}

private final class PreviewImageView: NSView {
    private let contents = CALayer()
    private let marker = CAShapeLayer()
    private let ripple = CAShapeLayer()
    private var viewport: CGRect?
    private var pixelSize = CGSize.zero
    private var currentCue: DesktopActivity?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = UseUIBrand.ink.cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        layer?.borderColor = UseUIBrand.mint.withAlphaComponent(0.28).cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(contents)
        layer?.addSublayer(ripple)
        layer?.addSublayer(marker)
        contents.contentsGravity = .resizeAspect
        contents.minificationFilter = .linear

        ripple.fillColor = nil
        ripple.strokeColor = UseUIBrand.mint.cgColor
        ripple.lineWidth = 1.6
        ripple.opacity = 0
        ripple.bounds = CGRect(x: -10, y: -10, width: 20, height: 20)
        ripple.path = CGPath(ellipseIn: CGRect(x: -7, y: -7, width: 14, height: 14), transform: nil)

        marker.anchorPoint = .zero
        marker.bounds = .zero
        marker.lineJoin = .round
        marker.fillColor = UseUIBrand.mint.cgColor
        marker.strokeColor = UseUIBrand.ink.cgColor
        marker.isHidden = true
        setAccessibilityRole(.image)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents.frame = bounds
        CATransaction.commit()
        updateMarker(animate: false)
    }

    func present(_ image: CGImage, viewport: CGRect, cue: DesktopActivity?) {
        let size = CGSize(width: image.width, height: image.height)
        let geometryChanged = self.viewport != viewport || pixelSize != size
        self.viewport = viewport
        pixelSize = size
        if geometryChanged { setAccessibilityElement(true) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents.contents = image
        CATransaction.commit()

        if geometryChanged {
            currentCue = cue
            updateMarker(animate: false)
        }
    }

    func clear() {
        viewport = nil
        pixelSize = .zero
        currentCue = nil
        setAccessibilityElement(false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents.contents = nil
        marker.removeAllAnimations()
        ripple.removeAllAnimations()
        marker.isHidden = true
        CATransaction.commit()
    }

    func updateCue(_ activity: DesktopActivity?) {
        currentCue = activity
        updateMarker(animate: true)
    }

    private func updateMarker(animate: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let wasVisible = !marker.isHidden
        let previous = marker.presentation()?.position ?? marker.position
        marker.removeAllAnimations()
        guard let cue = currentCue, let point = cue.point, let viewport, viewport.contains(point),
              pixelSize.width > 0, pixelSize.height > 0, !bounds.isEmpty else {
            marker.isHidden = true
            return
        }

        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let width = pixelSize.width * scale
        let height = pixelSize.height * scale
        let left = bounds.midX - width / 2
        let bottom = bounds.midY - height / 2
        let tip = CGPoint(x: left + width * (point.x - viewport.minX) / viewport.width,
                          y: bottom + height * (viewport.maxY - point.y) / viewport.height)
        let workspace = NSWorkspace.shared
        let accent = cue.isForeground ? UseUIBrand.amber : UseUIBrand.mint
        marker.fillColor = accent.cgColor
        marker.lineWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 2.0 : 1.4
        marker.path = cue.phase.showsWriting ? UseUIBrand.caretPath(scale: 0.72) : UseUIBrand.pointerPath(scale: 0.75)
        marker.position = tip
        marker.isHidden = false

        guard animate, !workspace.accessibilityDisplayShouldReduceMotion else { return }
        if cue.phase.isApproach {
            let start = wasVisible ? previous : CGPoint(x: max(left, tip.x - 24), y: min(bottom + height, tip.y + 16))
            let traj = CursorTrajectory.build(from: start, to: tip, style: .signatureArc, reduceMotion: false)
            if traj.duration > 0 {
                let move = CAKeyframeAnimation(keyPath: "position")
                move.path = traj.cgPath()
                move.duration = traj.duration
                move.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                marker.add(move, forKey: "approach")
            }
        } else if cue.phase == .pressed || cue.phase == .sent {
            ripple.removeAllAnimations()
            ripple.position = tip
            ripple.strokeColor = accent.cgColor
            let sAnim = CABasicAnimation(keyPath: "transform.scale")
            sAnim.fromValue = 0.5
            sAnim.toValue = 2.6
            let oAnim = CABasicAnimation(keyPath: "opacity")
            oAnim.fromValue = 0.9
            oAnim.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [sAnim, oAnim]
            group.duration = 0.36
            ripple.add(group, forKey: "ripple")
        }
    }
}
