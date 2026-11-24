import AppKit
import Foundation

/// Unified entry shown in the macOS Menu Bar Live Island (covers both Native AX and Chrome Browser runs).
struct ActivityTimelineItem: Sendable {
    let source: String // "browser" | "native"
    let label: String
    let detail: String?
    let status: String // "active" | "done" | "error" | "foreground"
    let timestamp: Date
}

/// Native macOS Menu Bar Live Island (`NSStatusItem` + `NSPopover`).
/// Pulses Mint while UseUI is driving either Chrome or native macOS windows and provides
/// instant controls for Overlay visibility, Cursor Motion style, and Live PiP View.
@MainActor
final class MenuBarIsland: NSObject {
    private var statusItem: NSStatusItem?
    private lazy var popover = NSPopover()
    private var contentController: MenuBarPopoverController?
    private var items: [ActivityTimelineItem] = []
    private var idleTimer: Timer?
    private var currentActiveLabel: String?
    private var currentAccent: NSColor?

    private let onToggleOverlay: @MainActor @Sendable (Bool) -> Void
    private let onSelectMotion: @MainActor @Sendable (CursorMotionStyle) -> Void
    private let onToggleLiveView: @MainActor @Sendable () -> Void
    private let onHideOverlay: @MainActor @Sendable () -> Void

    private var overlayEnabled: Bool
    private var motionStyle: CursorMotionStyle = .signatureArc

    nonisolated init(
        overlayEnabled: Bool,
        onToggleOverlay: @escaping @MainActor @Sendable (Bool) -> Void,
        onSelectMotion: @escaping @MainActor @Sendable (CursorMotionStyle) -> Void,
        onToggleLiveView: @escaping @MainActor @Sendable () -> Void,
        onHideOverlay: @escaping @MainActor @Sendable () -> Void
    ) {
        self.overlayEnabled = overlayEnabled
        self.onToggleOverlay = onToggleOverlay
        self.onSelectMotion = onSelectMotion
        self.onToggleLiveView = onToggleLiveView
        self.onHideOverlay = onHideOverlay
        super.init()
        DispatchQueue.main.async { self.setupStatusItem() }
    }

    nonisolated func submitHostTelemetry(_ event: HostTelemetryEvent) {
        DispatchQueue.main.async { self.recordHostTelemetry(event) }
    }

    nonisolated func shutdown() {
        DispatchQueue.main.async { self.dismiss() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = UseUIBrand.menuBarIcon(activeAccent: nil)
            button.imagePosition = .imageLeading
            button.toolTip = "UseUI — Background control you can follow"
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item

        let vc = MenuBarPopoverController(
            overlayEnabled: overlayEnabled,
            motionStyle: motionStyle,
            onToggleOverlay: { [weak self] enabled in
                guard let self else { return }
                self.overlayEnabled = enabled
                self.onToggleOverlay(enabled)
            },
            onSelectMotion: { [weak self] style in
                guard let self else { return }
                self.motionStyle = style
                self.onSelectMotion(style)
            },
            onToggleLiveView: { [weak self] in
                self?.onToggleLiveView()
            },
            onHideOverlay: { [weak self] in
                self?.onHideOverlay()
            }
        )
        contentController = vc
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    func recordNative(_ activity: DesktopActivity) {
        let status: String
        let accent: NSColor
        if activity.phase == .skipped {
            status = "error"
            accent = UseUIBrand.coral
        } else if activity.isForeground || activity.phase == .check {
            status = "foreground"
            accent = UseUIBrand.amber
        } else {
            status = activity.phase.isApproach || activity.phase == .observing ? "active" : "done"
            accent = UseUIBrand.mint
        }
        let appName = NSRunningApplication(processIdentifier: pid_t(activity.target.pid))?.localizedName
        push(ActivityTimelineItem(
            source: "native",
            label: activity.pillText,
            detail: appName,
            status: status,
            timestamp: Date()
        ), accent: accent)
    }

    func recordHostTelemetry(_ event: HostTelemetryEvent) {
        let accent: NSColor
        switch event.phase {
        case "error": accent = UseUIBrand.coral
        case "foreground", "paused": accent = UseUIBrand.amber
        default: accent = UseUIBrand.mint
        }
        push(ActivityTimelineItem(
            source: event.source,
            label: event.label,
            detail: event.detail,
            status: event.phase,
            timestamp: Date()
        ), accent: accent)
    }

    private func push(_ item: ActivityTimelineItem, accent: NSColor) {
        // Deduplicate consecutive identical active/done updates cleanly.
        if let first = items.first, first.label == item.label && first.source == item.source {
            items[0] = item
        } else {
            items.insert(item, at: 0)
            if items.count > 12 { items.removeLast(items.count - 12) }
        }
        currentActiveLabel = item.status == "active" ? item.label : nil
        currentAccent = accent
        updateButton(active: true, accent: accent)
        contentController?.refresh(items: items, activeLabel: currentActiveLabel ?? item.label, accent: accent)

        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentActiveLabel = nil
                self.currentAccent = nil
                self.updateButton(active: false, accent: nil)
                self.contentController?.refresh(items: self.items, activeLabel: nil, accent: nil)
            }
        }
    }

    private func updateButton(active: Bool, accent: NSColor?) {
        guard let button = statusItem?.button else { return }
        button.image = UseUIBrand.menuBarIcon(activeAccent: active ? accent : nil)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            contentController?.refresh(items: items, activeLabel: currentActiveLabel, accent: currentAccent)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func dismiss() {
        idleTimer?.invalidate()
        idleTimer = nil
        popover.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }
}

@MainActor
private final class MenuBarPopoverController: NSViewController {
    private let dot = NSView()
    private let statusTitle = NSTextField(labelWithString: "UseUI")
    private let statusSubtitle = NSTextField(labelWithString: "Ready · Background control")
    private let overlaySwitch = NSSwitch()
    private let motionControl = NSSegmentedControl(labels: ["Arc", "Snappy", "Reduced"], trackingMode: .selectOne, target: nil, action: nil)
    private let liveViewButton = NSButton(title: "Open Live View", target: nil, action: nil)
    private let hideButton = NSButton(title: "Hide Cue", target: nil, action: nil)
    private let timelineStack = NSStackView()

    private let onToggleOverlay: @MainActor (Bool) -> Void
    private let onSelectMotion: @MainActor (CursorMotionStyle) -> Void
    private let onToggleLiveView: @MainActor () -> Void
    private let onHideOverlay: @MainActor () -> Void

    init(
        overlayEnabled: Bool,
        motionStyle: CursorMotionStyle,
        onToggleOverlay: @escaping @MainActor (Bool) -> Void,
        onSelectMotion: @escaping @MainActor (CursorMotionStyle) -> Void,
        onToggleLiveView: @escaping @MainActor () -> Void,
        onHideOverlay: @escaping @MainActor () -> Void
    ) {
        self.onToggleOverlay = onToggleOverlay
        self.onSelectMotion = onSelectMotion
        self.onToggleLiveView = onToggleLiveView
        self.onHideOverlay = onHideOverlay
        super.init(nibName: nil, bundle: nil)
        overlaySwitch.state = overlayEnabled ? .on : .off
        motionControl.selectedSegment = Self.index(for: motionStyle)
    }

    required init?(coder: NSCoder) { nil }

    private static func index(for style: CursorMotionStyle) -> Int {
        switch style {
        case .signatureArc: 0
        case .snappy: 1
        case .reduced: 2
        }
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 304, height: 320))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.backgroundColor = UseUIBrand.ink.withAlphaComponent(0.92).cgColor
        self.view = root

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = UseUIBrand.mint.cgColor

        statusTitle.font = .systemFont(ofSize: 13.5, weight: .semibold)
        statusTitle.textColor = UseUIBrand.paper
        statusSubtitle.font = .systemFont(ofSize: 11.5)
        statusSubtitle.textColor = UseUIBrand.paper.withAlphaComponent(0.70)
        statusSubtitle.lineBreakMode = .byTruncatingTail

        let overlayLabel = NSTextField(labelWithString: "Visual Overlay")
        overlayLabel.font = .systemFont(ofSize: 12, weight: .medium)
        overlayLabel.textColor = UseUIBrand.paper
        overlaySwitch.controlSize = .small
        overlaySwitch.target = self
        overlaySwitch.action = #selector(overlaySwitched)

        let motionLabel = NSTextField(labelWithString: "Cursor Motion")
        motionLabel.font = .systemFont(ofSize: 12, weight: .medium)
        motionLabel.textColor = UseUIBrand.paper
        motionControl.controlSize = .small
        motionControl.target = self
        motionControl.action = #selector(motionChanged)

        liveViewButton.bezelStyle = .rounded
        liveViewButton.controlSize = .small
        liveViewButton.target = self
        liveViewButton.action = #selector(liveViewClicked)

        hideButton.bezelStyle = .rounded
        hideButton.controlSize = .small
        hideButton.target = self
        hideButton.action = #selector(hideClicked)

        let timelineHeader = NSTextField(labelWithString: "RECENT ACTIVITY")
        timelineHeader.font = .systemFont(ofSize: 10, weight: .bold)
        timelineHeader.textColor = UseUIBrand.slate

        timelineStack.orientation = .vertical
        timelineStack.alignment = .leading
        timelineStack.spacing = 5

        let sep1 = NSBox(); sep1.boxType = .separator
        let sep2 = NSBox(); sep2.boxType = .separator

        for sub in [dot, statusTitle, statusSubtitle, sep1,
                    overlayLabel, overlaySwitch, motionLabel, motionControl,
                    liveViewButton, hideButton, sep2, timelineHeader, timelineStack] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(sub)
        }

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: statusTitle.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),

            statusTitle.topAnchor.constraint(equalTo: root.topAnchor, constant: 13),
            statusTitle.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            statusTitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            statusSubtitle.topAnchor.constraint(equalTo: statusTitle.bottomAnchor, constant: 2),
            statusSubtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            statusSubtitle.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            sep1.topAnchor.constraint(equalTo: statusSubtitle.bottomAnchor, constant: 10),
            sep1.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            sep1.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            overlayLabel.topAnchor.constraint(equalTo: sep1.bottomAnchor, constant: 10),
            overlayLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            overlaySwitch.centerYAnchor.constraint(equalTo: overlayLabel.centerYAnchor),
            overlaySwitch.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            motionLabel.topAnchor.constraint(equalTo: overlayLabel.bottomAnchor, constant: 10),
            motionLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            motionControl.centerYAnchor.constraint(equalTo: motionLabel.centerYAnchor),
            motionControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            liveViewButton.topAnchor.constraint(equalTo: motionLabel.bottomAnchor, constant: 12),
            liveViewButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            hideButton.centerYAnchor.constraint(equalTo: liveViewButton.centerYAnchor),
            hideButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            sep2.topAnchor.constraint(equalTo: liveViewButton.bottomAnchor, constant: 12),
            sep2.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            sep2.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            timelineHeader.topAnchor.constraint(equalTo: sep2.bottomAnchor, constant: 9),
            timelineHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            timelineStack.topAnchor.constraint(equalTo: timelineHeader.bottomAnchor, constant: 6),
            timelineStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            timelineStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            timelineStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
        ])

        refresh(items: [], activeLabel: nil, accent: nil)
    }

    func refresh(items: [ActivityTimelineItem], activeLabel: String?, accent: NSColor?) {
        dot.layer?.backgroundColor = (accent ?? UseUIBrand.mint).cgColor
        statusSubtitle.stringValue = activeLabel ?? "Ready · Background control"

        for view in timelineStack.arrangedSubviews {
            timelineStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        if items.isEmpty {
            let empty = NSTextField(labelWithString: "No recent agent actions yet")
            empty.font = .systemFont(ofSize: 11.5)
            empty.textColor = UseUIBrand.slate
            timelineStack.addArrangedSubview(empty)
            return
        }

        for item in items.prefix(5) {
            let icon = item.status == "error" ? "✕" : (item.status == "active" ? "●" : "✓")
            let sourceTag = item.source == "browser" ? "Chrome" : (item.detail ?? "macOS")
            let row = NSTextField(labelWithString: "\(icon) \(item.label)  ·  \(sourceTag)")
            row.font = .systemFont(ofSize: 11.5)
            row.textColor = item.status == "error"
                ? UseUIBrand.coral
                : (item.status == "active" ? UseUIBrand.mint : UseUIBrand.paper.withAlphaComponent(0.86))
            row.lineBreakMode = .byTruncatingTail
            row.maximumNumberOfLines = 1
            timelineStack.addArrangedSubview(row)
        }
    }

    @objc private func overlaySwitched() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        onToggleOverlay(overlaySwitch.state == .on)
    }

    @objc private func motionChanged() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        let style: CursorMotionStyle
        switch motionControl.selectedSegment {
        case 1: style = .snappy
        case 2: style = .reduced
        default: style = .signatureArc
        }
        onSelectMotion(style)
    }

    @objc private func liveViewClicked() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
        onToggleLiveView()
    }

    @objc private func hideClicked() {
        onHideOverlay()
    }
}
