import AppKit
import Foundation

struct WorkflowConfig: Decodable {
    struct Field: Decodable {
        let id: String
        let label: String
        let initial: String
        let kind: String
    }
    struct Friction: Decodable {
        let trigger: String
        let recreate: [String]
        let delayed: String
        let decimal: String
        let cleared: String
    }
    let task: String
    let source: String
    let fields: [Field]
    let friction: Friction?
}

@MainActor
final class WorkflowFixture: NSObject, NSApplicationDelegate {
    private let config: WorkflowConfig
    private let nonce = UUID().uuidString
    private let startedForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    private var activationCount = 0
    private var windows: [String: NSWindow] = [:]
    private var fields: [String: NSControl] = [:]
    private var generations: [String: Int] = [:]
    private var events: [[String: Any]] = []
    private var submit: NSButton?
    private var status: NSTextField?
    private var activeTab = 0
    private var pending = 0
    private var recreated = false
    private var cleared = false
    private var submission: [String: String]?
    private var closedWorkWindowId: Int?

    init(_ config: WorkflowConfig) { self.config = config }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let invoice = config.task == "invoice"
        let source = window("source", title: invoice ? "Source Invoice" : "Settings Specification", x: 40, size: NSSize(width: 365, height: 380))
        let publicText = NSTextField(wrappingLabelWithString: config.source)
        publicText.setAccessibilityIdentifier("source.instructions")
        publicText.frame = NSRect(x: 16, y: 55, width: 333, height: 299)
        source.addSubview(publicText)
        let sourceNote = WorkflowConfig.Field(id: "source.notes", label: "Notes", initial: "Source reference", kind: "text")
        source.addSubview(makeField(sourceNote, at: NSRect(x: 86, y: 18, width: 230, height: 24)))
        label("Notes", in: source, x: 16, y: 18, width: 65)

        let work = window("work", title: invoice ? "Invoice Entry" : "Workflow Settings", x: 425, size: NSSize(width: 540, height: 428))
        if invoice {
            for (index, name) in ["Item", "Quantity", "Unit price"].enumerated() {
                label(name, in: work, x: 20 + index * 168, y: 322, width: 148)
            }
            let workNote = WorkflowConfig.Field(id: "work.notes", label: "Notes", initial: "Form reference", kind: "text")
            work.addSubview(makeField(workNote, at: NSRect(x: 86, y: 52, width: 282, height: 24)))
            label("Notes", in: work, x: 20, y: 52, width: 65)
            let button = NSButton(title: "Submit", target: self, action: #selector(submitInvoice))
            button.setAccessibilityIdentifier("invoice.submit")
            button.frame = NSRect(x: 420, y: 48, width: 100, height: 30)
            work.addSubview(button)
            submit = button
        } else {
            for (index, title) in ["General", "Delivery", "Reports"].enumerated() {
                let button = NSButton(title: title, target: self, action: #selector(selectTab(_:)))
                button.tag = index
                button.setAccessibilityIdentifier("settings.tab.\(index)")
                button.frame = NSRect(x: 20 + index * 166, y: 367, width: 150, height: 30)
                work.addSubview(button)
            }
        }

        for (index, spec) in config.fields.enumerated() {
            let frame = fieldFrame(index)
            let field = makeField(spec, at: frame)
            if invoice || index < 5 { work.addSubview(field) }
            if invoice && index < 3 { label(spec.label, in: work, x: Int(frame.minX), y: 389, width: 150) }
        }
        status = label("", in: work, x: 20, y: 15, width: 500)
        updateSubmit()
        windows["source"]?.orderBack(nil)
        windows["work"]?.orderBack(nil)
        emit(["event": "ready", "status": "ok", "state": state()])
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while let line = readLine() {
                DispatchQueue.main.async { self.handle(line) }
            }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { activationCount += 1 }

    private func window(_ key: String, title: String, x: Int, size: NSSize) -> NSView {
        let frame = NSRect(origin: NSPoint(x: x, y: 85), size: size)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.title = title
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("window.\(key)")
        windows[key] = window
        return window.contentView!
    }

    @discardableResult
    private func label(_ value: String, in view: NSView, x: Int, y: Int, width: Int) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.frame = NSRect(x: x, y: y, width: width, height: 24)
        view.addSubview(label)
        return label
    }

    private func fieldFrame(_ index: Int) -> NSRect {
        if config.task == "settings" { return NSRect(x: 20, y: 320 - (index % 5) * 52, width: 480, height: 26) }
        let row = index < 3 ? -1 : (index - 3) / 3
        return NSRect(x: 20 + (index % 3) * 168, y: row < 0 ? 358 : 296 - row * 28, width: 148, height: 24)
    }

    private func makeField(_ spec: WorkflowConfig.Field, at frame: NSRect) -> NSControl {
        generations[spec.id, default: 0] += 1
        let generation = generations[spec.id]!
        let field: NSControl
        if spec.kind == "checkbox" {
            let button = NSButton(checkboxWithTitle: spec.label, target: self, action: #selector(toggle(_:)))
            button.state = spec.initial == "1" ? .on : .off
            button.tag = generation
            field = button
        } else {
            let text = FixtureTextField(string: spec.initial)
            text.controlTitle = spec.label
            text.placeholderString = spec.label
            text.onAccessibilityWrite = { [weak self, weak text] value in
                guard let text else { return }
                self?.write(spec.id, value, from: text, generation: generation)
            }
            field = text
        }
        field.frame = frame
        field.setAccessibilityIdentifier(spec.id)
        field.setAccessibilityLabel(spec.label)
        fields[spec.id] = field
        return field
    }

    @objc private func toggle(_ sender: NSButton) {
        write(sender.accessibilityIdentifier(), sender.state == .on ? "1" : "0", from: sender, generation: sender.tag)
    }

    @objc private func selectTab(_ sender: NSButton) {
        record("tab", id: "settings.tab.\(sender.tag)")
        if activeTab != sender.tag {
            for index in (activeTab * 5)..<(activeTab * 5 + 5) {
                fields[config.fields[index].id]?.removeFromSuperview()
            }
            activeTab = sender.tag
            for index in (activeTab * 5)..<(activeTab * 5 + 5) {
                windows["work"]?.contentView?.addSubview(fields[config.fields[index].id]!)
            }
        }
    }

    private func record(_ kind: String, id: String, value: String? = nil, generation: Int? = nil) {
        var event: [String: Any] = ["kind": kind, "id": id, "generation": generation ?? generations[id, default: 0]]
        if let value { event["value"] = value }
        events.append(event)
    }

    private func write(_ id: String, _ value: String, from field: NSControl, generation: Int) {
        guard fields[id] === field, field.superview != nil else {
            record("stale_attempt", id: id, value: value, generation: generation)
            return
        }
        record("attempt", id: id, value: value)
        if let friction = config.friction {
            if !recreated && id == friction.trigger {
                recreated = true
                for replacement in friction.recreate { recreate(replacement) }
            }
            if !cleared && id == friction.cleared {
                cleared = true
                apply("", id: id, field: field)
                status?.stringValue = "Validation cleared \(field.accessibilityLabel() ?? id). Enter the value again."
                record("validation_cleared", id: id)
                return
            }
            if id == friction.delayed {
                pending += 1
                updateSubmit()
                record("delayed", id: id)
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [self] in
                    pending -= 1
                    if fields[id] === field { apply(value, id: id, field: field) }
                    else { updateSubmit() }
                }
                return
            }
            if id == friction.decimal, let amount = Double(value), amount.isFinite {
                let canonical = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), amount)
                if canonical != value { record("normalized", id: id, value: canonical) }
                apply(canonical, id: id, field: field)
                return
            }
        }
        apply(value, id: id, field: field)
    }

    private func recreate(_ id: String) {
        guard let old = fields[id], let spec = config.fields.first(where: { $0.id == id }) else { return }
        let owner = old.superview
        old.removeFromSuperview()
        let replacement = WorkflowConfig.Field(id: id, label: spec.label, initial: value(old), kind: spec.kind)
        let field = makeField(replacement, at: old.frame)
        owner?.addSubview(field)
        record("recreated", id: id)
    }

    private func apply(_ value: String, id: String, field: NSControl) {
        if let button = field as? NSButton { button.state = value == "1" ? .on : .off }
        else { field.stringValue = value }
        record("applied", id: id, value: value)
        updateSubmit()
    }

    private func value(_ field: NSControl) -> String {
        if let button = field as? NSButton { return button.state == .on ? "1" : "0" }
        return field.stringValue
    }

    private func valid(_ spec: WorkflowConfig.Field) -> Bool {
        let text = value(fields[spec.id]!)
        if spec.kind == "quantity" { return Int(text).map { $0 > 0 } ?? false }
        if spec.kind == "price" { return Double(text).map { $0.isFinite && $0 > 0 } ?? false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateSubmit() {
        submit?.isEnabled = pending == 0 && config.fields.allSatisfy { valid($0) } && submission == nil
    }

    @objc private func submitInvoice() {
        record("submit_attempt", id: "invoice.submit")
        guard submit?.isEnabled == true else { return }
        submission = Dictionary(uniqueKeysWithValues: config.fields.map { ($0.id, value(fields[$0.id]!)) })
        record("submitted", id: "invoice.submit")
        updateSubmit()
        let confirmation = window("confirmation", title: "Invoice Confirmation", x: 425, size: NSSize(width: 360, height: 140))
        let message = label("Submitted PO \(submission!["invoice.po"]!)", in: confirmation, x: 20, y: 70, width: 315)
        message.setAccessibilityIdentifier("invoice.confirmed")
        windows["confirmation"]?.orderBack(nil)
        if let work = windows.removeValue(forKey: "work") {
            closedWorkWindowId = work.windowNumber
            work.close()
        }
    }

    private func state() -> [String: Any] {
        var activeWindows = windows.sorted(by: { $0.key < $1.key }).map { key, window in
            ["key": key, "windowId": window.windowNumber, "title": window.title, "visible": window.isVisible] as [String: Any]
        }
        if let closedWorkWindowId {
            activeWindows.append(["key": "work", "windowId": closedWorkWindowId, "title": "Invoice Entry", "visible": false])
        }
        return ["pid": ProcessInfo.processInfo.processIdentifier, "runNonce": nonce,
         "activationCount": activationCount, "startedForegroundPID": startedForegroundPID,
         "foregroundPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
         "windows": activeWindows, "submitEnabled": submit?.isEnabled ?? false,
         "values": fields.mapValues { value($0) }, "generations": generations, "events": events,
         "pending": pending, "activeTab": activeTab, "submission": submission as Any? ?? NSNull()]
    }

    private func handle(_ line: String) {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let command = request["command"] as? String else { return }
        let reply: [String: Any] = ["id": request["id"] ?? NSNull(), "state": state()]
        if command == "state" || command == "quit" {
            emit(reply.merging(["status": "ok"]) { _, new in new })
            if command == "quit" { NSApplication.shared.terminate(nil) }
        } else {
            emit(reply.merging(["status": "error", "error": "unknown workflow command"]) { _, new in new })
        }
    }

    private func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}
