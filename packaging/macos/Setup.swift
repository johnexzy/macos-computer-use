import AppKit

@main
struct CUASetup {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let window = SetupWindow(configuration: configuration())
        app.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(window) { app.run() }
    }

    private static func configuration() -> String? {
        guard let executable = Bundle.main.executableURL else { return nil }
        let host = executable.deletingLastPathComponent().appendingPathComponent("cua-host")
        guard FileManager.default.isExecutableFile(atPath: host.path) else { return nil }

        let value = [
            "mcpServers": [
                "macos-computer-use-native": [
                    "command": host.path,
                    "args": [String](),
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
    private let configuration: String?
    private let status = NSTextField(labelWithString: "")

    init(configuration: String?) {
        self.configuration = configuration
        super.init(contentRect: NSRect(x: 0, y: 0, width: 510, height: 195),
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
            "Add the copied configuration to your MCP client and reconnect. It enables background control, the agent pointer, and the live preview.")
        help.font = .systemFont(ofSize: 13)
        help.textColor = .secondaryLabelColor
        status.textColor = .secondaryLabelColor
        if configuration == nil { status.stringValue = "The bundled MCP server is missing." }

        let copy = NSButton(title: "Copy MCP Configuration", target: self, action: #selector(copyConfiguration))
        copy.bezelStyle = .rounded
        copy.isEnabled = configuration != nil
        copy.keyEquivalent = "\r"
        let install = NSButton(title: "Install Claude Code Skill…", target: self, action: #selector(chooseSkillProject))
        install.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [done, install, copy])
        buttons.spacing = 8

        let content = NSView()
        for view in [icon, heading, help, status, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        contentView = content
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalTo: icon.widthAnchor),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 25),
            heading.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            help.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            help.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            status.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 14),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            buttons.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -19),
        ])
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }

    @objc private func copyConfiguration() {
        guard let configuration else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(configuration, forType: .string)
        showStatus(copied ? "Configuration copied" : "The clipboard could not be updated.")
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
