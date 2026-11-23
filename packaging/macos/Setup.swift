import AppKit

@main
struct CUASetup {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let window = SetupWindow(hostURL: hostURL())
        app.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(window) { app.run() }
    }

    private static func hostURL() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let host = executable.deletingLastPathComponent().appendingPathComponent("cua-host")
        return FileManager.default.isExecutableFile(atPath: host.path) ? host : nil
    }

    static func configuration(hostURL: URL?, allowForeground: Bool) -> String? {
        guard let host = hostURL else { return nil }
        let args = allowForeground ? ["--allow-foreground"] : [String]()
        let value = [
            "mcpServers": [
                "macos-computer-use": [
                    "command": host.path,
                    "args": args,
                    "env": ["CUA_VISUAL_FEEDBACK": "1", "CUA_LIVE_PREVIEW": "1"],
                ] as [String: Any],
            ],
        ]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: options) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
private final class SetupWindow: NSWindow, NSWindowDelegate {
    private static let skillName = "macos-computer-use-native"
    private let hostURL: URL?
    private let allowForegroundToggle = NSButton(
        checkboxWithTitle: "Allow temporary foreground fallback (file pickers, canvas, hotkeys)",
        target: nil,
        action: nil
    )
    private let status = NSTextField(labelWithString: "")

    init(hostURL: URL?) {
        self.hostURL = hostURL
        super.init(contentRect: NSRect(x: 0, y: 0, width: 560, height: 245),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "macOS Computer Use"
        delegate = self
        isReleasedWhenClosed = false

        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: url)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)

        let heading = NSTextField(labelWithString: "Connect your MCP client")
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        let help = NSTextField(wrappingLabelWithString:
            "Add the copied configuration to your MCP client and reconnect. Runs background-first with optional temporary foreground escalation and the MV3 Chromium browser accelerator.")
        help.font = .systemFont(ofSize: 13)
        help.textColor = .secondaryLabelColor
        allowForegroundToggle.state = .on
        allowForegroundToggle.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        if hostURL == nil { status.stringValue = "The bundled MCP server is missing." }

        let copy = NSButton(title: "Copy MCP Config", target: self, action: #selector(copyConfiguration))
        copy.bezelStyle = .rounded
        copy.isEnabled = hostURL != nil
        copy.keyEquivalent = "\r"
        let bridge = NSButton(title: "Install Browser Bridge", target: self, action: #selector(installBrowserBridge))
        bridge.bezelStyle = .rounded
        bridge.isEnabled = hostURL != nil
        let install = NSButton(title: "Install Skill…", target: self, action: #selector(chooseSkillProject))
        install.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [done, install, bridge, copy])
        buttons.spacing = 8

        let content = NSView()
        for view in [icon, heading, help, allowForegroundToggle, status, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        contentView = content
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            heading.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            help.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
            help.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            allowForegroundToggle.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 10),
            allowForegroundToggle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            allowForegroundToggle.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            status.topAnchor.constraint(equalTo: allowForegroundToggle.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    @objc private func copyConfiguration() {
        let allowForeground = allowForegroundToggle.state == .on
        guard let configuration = CUASetup.configuration(hostURL: hostURL, allowForeground: allowForeground) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(configuration, forType: .string)
        let modeNote = allowForeground ? "background-first + foreground fallback" : "background-only"
        showStatus(copied ? "Copied MCP config (\(modeNote))." : "The clipboard could not be updated.")
    }

    @objc private func installBrowserBridge() {
        guard let hostURL else { return }
        let process = Process()
        process.executableURL = hostURL
        process.arguments = ["--install-browser-bridge"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                showStatus("Failed to install Native Messaging manifest (exit \(process.terminationStatus)).")
                return
            }
            let unpackedDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/macOS Computer Use/browser-extension")
            if FileManager.default.fileExists(atPath: unpackedDir.path) {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(unpackedDir.path, forType: .string)
                showStatus("Bridge installed. Extension path copied — press ⌘⇧G in Load unpacked and paste.")
            } else {
                showStatus("Native Messaging bridge installed.")
            }
        } catch {
            showStatus("Could not run cua-host --install-browser-bridge.")
        }
    }

    @objc private func chooseSkillProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Install Skill"
        panel.message = "Choose the folder you open as a project in Claude Code."
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let project = panel.url else { return }
            self?.installSkill(in: project)
        }
    }

    private func installSkill(in project: URL) {
        let skill = Self.skillName
        guard let source = Bundle.main.url(forResource: "SKILL", withExtension: "md", subdirectory: "skills/\(skill)") else {
            showStatus("The bundled Claude Code skill is missing.")
            return
        }

        let root = project.resolvingSymlinksInPath()
        var directory = root
        for component in [".claude", "skills", skill] {
            directory = directory.appendingPathComponent(component, isDirectory: true).resolvingSymlinksInPath()
            guard directory.pathComponents.starts(with: root.pathComponents) else {
                showStatus("The skills folder points outside this project.")
                return
            }
        }

        let files = FileManager.default
        let destination = directory.appendingPathComponent("SKILL.md")
        if files.fileExists(atPath: destination.path) {
            if let existing = try? Data(contentsOf: destination),
               let bundled = try? Data(contentsOf: source), existing == bundled {
                showStatus("Skill already installed. Reopen the project in Claude Code.")
            } else {
                showStatus("A different skill already exists in this project.")
            }
            return
        }

        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            try files.copyItem(at: source, to: destination)
            showStatus("Skill installed. Reopen the project in Claude Code.")
        } catch {
            showStatus("Could not install the skill in this project.")
        }
    }

    private func showStatus(_ message: String) {
        status.stringValue = message
        if NSWorkspace.shared.isVoiceOverEnabled {
            NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
        }
    }
}
