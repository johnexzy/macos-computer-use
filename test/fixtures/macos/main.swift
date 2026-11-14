import AppKit
import Foundation

enum WriteMode: String {
    case normal, ignored, delayed
}

@MainActor
final class FieldRecord {
    let key: String
    let generation: Int
    var modelValue: String
    var mode: WriteMode = .normal
    var delayMs = 250
    var attempts = 0
    var appliedWrites = 0
    var lastRequestedValue: String?
    var pending: [Int: String] = [:]
    var field: FixtureTextField!
    var row: NSStackView!

    init(key: String, generation: Int, value: String) {
        self.key = key
        self.generation = generation
        self.modelValue = value
    }
}

@MainActor
final class FixtureTextField: NSTextField {
    var onAccessibilityWrite: ((String) -> Void)?

    override func accessibilityTitle() -> String? { "Value" }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {
        guard let value = accessibilityValue as? String else { return }
        onAccessibilityWrite?(value)
    }
}

@MainActor
final class WindowRecord {
    let key: String
    var generation = 1
    var window: NSWindow!
    var stack: NSStackView!
    var fields: [String: FieldRecord] = [:]
    var order = ["first", "second"]

    init(key: String) { self.key = key }
}

@MainActor
final class FixtureController: NSObject, NSApplicationDelegate {
    var windows: [String: WindowRecord] = [:]
    var nextWrite = 0
    let runNonce = UUID().uuidString
    var revision = 0
    var resetGeneration = 0
    var activationCount = 0
    let startedForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        reset()
        emit(["event": "ready", "status": "ok", "state": state()])
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while let line = readLine() {
                DispatchQueue.main.async { self.handleLine(line) }
            }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) { activationCount += 1 }

    func defaultFrame(_ key: String) -> NSRect {
        NSRect(x: key == "primary" ? 90 : 570, y: 150, width: 440, height: 230)
    }

    func title(_ key: String) -> String {
        "CUA Fixture — \(key == "primary" ? "Primary" : "Secondary")"
    }

    func makeWindow(_ record: WindowRecord, title: String, frame: NSRect) {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("window.\(record.key)")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 24, bottom: 30, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor)
        ])
        record.window = window
        record.stack = stack
        for control in record.order {
            let field = record.fields[control]!
            makeControl(field, in: record)
        }
        // Ordering a window is deliberately separate from making it key or activating the app.
        window.orderBack(nil)
    }

    func makeControl(_ field: FieldRecord, in window: WindowRecord) {
        let label = NSTextField(labelWithString: "Value")
        let control = FixtureTextField(string: field.modelValue)
        control.setAccessibilityIdentifier(field.key)
        control.setAccessibilityLabel("Value")
        control.isEditable = true
        control.isSelectable = true
        control.onAccessibilityWrite = { [weak self, weak field, weak window] value in
            guard let self, let field, let window else { return }
            self.receiveWrite(value, field: field, window: window)
        }
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 16
        label.widthAnchor.constraint(equalToConstant: 45).isActive = true
        control.widthAnchor.constraint(equalToConstant: 300).isActive = true
        field.field = control
        field.row = row
        window.stack.addArrangedSubview(row)
    }

    func receiveWrite(_ value: String, field: FieldRecord, window: WindowRecord) {
        revision += 1
        field.attempts += 1
        field.lastRequestedValue = value
        switch field.mode {
        case .ignored:
            return
        case .normal:
            apply(value, to: field)
        case .delayed:
            nextWrite += 1
            let write = nextWrite
            field.pending[write] = value
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(field.delayMs)) { [weak self, weak field, weak window] in
                guard let self, let field, let window,
                      self.windows[window.key] === window,
                      window.fields.values.contains(where: { $0 === field }),
                      field.pending.removeValue(forKey: write) != nil else { return }
                self.apply(value, to: field)
            }
        }
    }

    func apply(_ value: String, to field: FieldRecord) {
        revision += 1
        field.modelValue = value
        field.field.stringValue = value
        field.appliedWrites += 1
    }

    func reset() {
        resetGeneration += 1
        for window in windows.values { window.window.close() }
        windows = [:]
        for key in ["primary", "secondary"] {
            let window = WindowRecord(key: key)
            for control in window.order {
                window.fields[control] = FieldRecord(key: "\(key).\(control)", generation: 1, value: "\(key)-\(control)-original")
            }
            windows[key] = window
            makeWindow(window, title: title(key), frame: defaultFrame(key))
        }
    }

    func state() -> [String: Any] {
        [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "runNonce": runNonce,
            "revision": revision,
            "resetGeneration": resetGeneration,
            "activationCount": activationCount,
            "startedForegroundPID": startedForegroundPID,
            "foregroundPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
            "windows": ["primary", "secondary"].compactMap { key -> [String: Any]? in
                guard let window = windows[key] else { return nil }
                let frame = window.window.frame
                return [
                    "key": key,
                    "generation": window.generation,
                    "windowId": window.window.windowNumber,
                    "title": window.window.title,
                    "visible": window.window.isVisible,
                    "keyWindow": window.window.isKeyWindow,
                    "frame": ["x": frame.origin.x, "y": frame.origin.y, "width": frame.width, "height": frame.height],
                    "order": window.order,
                    "controls": window.order.map { key -> [String: Any] in
                        let field = window.fields[key]!
                        return [
                            "key": key,
                            "identifier": field.key,
                            "label": "Value",
                            "generation": field.generation,
                            "mode": field.mode.rawValue,
                            "delayMs": field.delayMs,
                            "modelValue": field.modelValue,
                            "controlValue": field.field.stringValue,
                            "attempts": field.attempts,
                            "appliedWrites": field.appliedWrites,
                            "lastRequestedValue": field.lastRequestedValue as Any? ?? NSNull(),
                            "pendingWrites": field.pending.sorted(by: { $0.key < $1.key }).map { ["id": $0.key, "value": $0.value] as [String: Any] }
                        ]
                    }
                ]
            }
        ]
    }

    func handleLine(_ line: String) {
        var id: Any = NSNull()
        do {
            guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let command = request["command"] as? String else {
                throw FixtureError("request requires a command")
            }
            id = request["id"] ?? NSNull()
            switch command {
            case "reset":
                revision += 1
                reset()
            case "state": break
            case "configure", "reorder", "recreate", "close_reopen":
                let key = request["window"] as? String ?? "primary"
                guard let window = windows[key] else { throw FixtureError("unknown window: \(key)") }
                revision += 1
                switch command {
                case "configure":
                    if let control = request["control"] as? String {
                        guard let field = window.fields[control] else { throw FixtureError("unknown control: \(control)") }
                        if let raw = request["mode"] as? String {
                            guard let mode = WriteMode(rawValue: raw) else { throw FixtureError("mode must be normal, ignored, or delayed") }
                            field.mode = mode
                        }
                        if let delay = request["delayMs"] as? Int {
                            guard (0...10_000).contains(delay) else { throw FixtureError("delayMs must be between 0 and 10000") }
                            field.delayMs = delay
                        }
                    }
                    if let title = request["title"] as? String { window.window.title = title }
                    if let raw = request["frame"] as? [String: Double],
                       let x = raw["x"], let y = raw["y"], let width = raw["width"], let height = raw["height"] {
                        guard width >= 200, height >= 100 else { throw FixtureError("frame must be at least 200 by 100") }
                        window.window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
                    }
                case "reorder":
                    window.order.reverse()
                    for control in window.order {
                        let row = window.fields[control]!.row!
                        window.stack.removeArrangedSubview(row)
                        row.removeFromSuperview()
                    }
                    for control in window.order { window.stack.addArrangedSubview(window.fields[control]!.row) }
                case "recreate":
                    let control = request["control"] as? String ?? "first"
                    guard let old = window.fields[control] else { throw FixtureError("unknown control: \(control)") }
                    old.pending = [:]
                    window.stack.removeArrangedSubview(old.row)
                    old.row.removeFromSuperview()
                    let field = FieldRecord(key: old.key, generation: old.generation + 1, value: old.modelValue)
                    field.mode = old.mode
                    field.delayMs = old.delayMs
                    window.fields[control] = field
                    makeControl(field, in: window)
                    for key in window.order {
                        let row = window.fields[key]!.row!
                        window.stack.removeArrangedSubview(row)
                        row.removeFromSuperview()
                    }
                    for key in window.order { window.stack.addArrangedSubview(window.fields[key]!.row) }
                default:
                    let previousTitle = window.window.title
                    let frame = window.window.frame
                    window.window.close()
                    window.generation += 1
                    for key in window.order {
                        let old = window.fields[key]!
                        old.pending = [:]
                        let field = FieldRecord(key: old.key, generation: old.generation + 1, value: old.modelValue)
                        field.mode = old.mode
                        field.delayMs = old.delayMs
                        window.fields[key] = field
                    }
                    makeWindow(window, title: previousTitle, frame: frame)
                }
            case "quit":
                emit(["id": id, "status": "ok", "state": state()])
                NSApplication.shared.terminate(nil)
                return
            default: throw FixtureError("unknown command: \(command)")
            }
            emit(["id": id, "status": "ok", "state": state()])
        } catch {
            emit(["id": id, "status": "error", "error": String(describing: error), "state": state()])
        }
    }

    func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let fixture = FixtureController()
    application.delegate = fixture
    application.run()
}
