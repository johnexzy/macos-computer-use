import AppKit
import CUAProtocol
import QuartzCore
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
    private let appLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private var target: LivePreviewTarget?
    private var event: DesktopActivity?
    private var eventExpiry: Task<Void, Never>?
    private var state: State = .connecting
    private var dismissed = false

    override init() {
        super.init()
        let content = NSView()
        window.contentView = content
        window.delegate = self

        appLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        for label in [appLabel, titleLabel, statusLabel] {
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        pauseButton.bezelStyle = .rounded
        pauseButton.setAccessibilityLabel("Pause live preview")
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)

        for view in [appLabel, titleLabel, image, statusLabel, pauseButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            appLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            appLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            appLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: appLabel.bottomAnchor, constant: 3),
            titleLabel.leadingAnchor.constraint(equalTo: appLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: appLabel.trailingAnchor),
            image.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            image.leadingAnchor.constraint(equalTo: appLabel.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: appLabel.trailingAnchor),
            image.bottomAnchor.constraint(equalTo: pauseButton.topAnchor, constant: -8),
            pauseButton.trailingAnchor.constraint(equalTo: image.trailingAnchor),
            pauseButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),
            pauseButton.widthAnchor.constraint(equalToConstant: 82),
            statusLabel.leadingAnchor.constraint(equalTo: image.leadingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: pauseButton.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: pauseButton.leadingAnchor, constant: -8),
        ])
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
        image.setAccessibilityLabel("Preview of \(windowTitle) in \(app)")

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
            try? await Task.sleep(for: .seconds(2.2))
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
        target = nil
        capture.stop()
        clearActivity()
        image.clear()
    }

    @objc private func togglePause() {
        guard let target else { return }
        if state == .paused {
            pauseButton.title = "Pause"
            pauseButton.setAccessibilityLabel("Pause live preview")
            beginCapture(target)
        } else {
            capture.stop()
            state = .paused
            pauseButton.title = "Resume"
            pauseButton.setAccessibilityLabel("Resume live preview")
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
        let status = switch state {
        case .connecting: "Connecting…"
        case .live: event.map { "Live  ·  \($0.phase.badgeLabel)" } ?? "Live"
        case .unavailable: "Window unavailable"
        case .paused: "Preview paused"
        }
        if status != statusLabel.stringValue { statusLabel.stringValue = status }
    }
}

private final class PreviewWindow: NSPanel {
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 290),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        title = "CUA Live Preview"
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
    private var viewport: CGRect?
    private var pixelSize = CGSize.zero
    private var currentCue: DesktopActivity?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        layer?.addSublayer(contents)
        layer?.addSublayer(marker)
        contents.contentsGravity = .resizeAspect
        contents.minificationFilter = .linear
        marker.bounds = CGRect(x: 0, y: -18, width: 14, height: 18)
        marker.anchorPoint = CGPoint(x: 0, y: 1)
        marker.lineJoin = .round
        marker.fillColor = NSColor.systemCyan.cgColor
        marker.strokeColor = NSColor.black.cgColor
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
        marker.lineWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 2 : 1.4
        marker.path = Self.markerPath(writing: cue.phase.showsWriting)
        marker.position = tip
        marker.isHidden = false

        guard animate, cue.phase.isApproach, !workspace.accessibilityDisplayShouldReduceMotion else { return }
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = wasVisible ? previous : CGPoint(x: max(left, tip.x - 22), y: min(bottom + height, tip.y + 14))
        movement.duration = 0.16
        movement.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        marker.add(movement, forKey: "approach")
    }

    private static func markerPath(writing: Bool) -> CGPath {
        let path = CGMutablePath()
        if writing {
            path.addRoundedRect(in: CGRect(x: 0, y: -7, width: 2, height: 14), cornerWidth: 1, cornerHeight: 1)
            path.addRoundedRect(in: CGRect(x: 4, y: -1, width: 8, height: 2), cornerWidth: 1, cornerHeight: 1)
        } else {
            path.addLines(between: [.zero, CGPoint(x: 1, y: -16), CGPoint(x: 5, y: -12), CGPoint(x: 9, y: -18),
                                    CGPoint(x: 12, y: -16), CGPoint(x: 8, y: -10), CGPoint(x: 14, y: -10)])
            path.closeSubpath()
        }
        return path
    }
}
