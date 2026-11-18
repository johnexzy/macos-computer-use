import AppKit
import Foundation

@MainActor
final class SelectiveField: NSTextField {
    var write: ((String) -> Void)?
    override func setAccessibilityValue(_ value: Any?) { if let text = value as? String { write?(text) } }
}

/// An independent native model/oracle, deliberately separate from AX readback.
@MainActor
final class SelectiveFixture: NSObject, NSApplicationDelegate {
    let nonce = UUID().uuidString
    let window = NSWindow(contentRect: NSRect(x: 80, y: 110, width: 900, height: 500),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let field = SelectiveField(string: "pending")
    let animation = NSTextField(labelWithString: "Animation 0")
    var toast: NSTextField?, dialog: NSBox?, button: NSButton?
    var modelValue = "pending", writes = 0, acknowledged = 0, activationCount = 0
    var generation = 0, revision = 0, animationTicks = 0
    var journal: [[String: Any]] = []
    var animationTimer: Timer?
    let startedForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "CUA Selective Fixture — \(nonce)"
        window.animationBehavior = .none; window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("selective.window")
        let content = window.contentView!
        field.frame = NSRect(x: 20, y: 445, width: 250, height: 24)
        field.setAccessibilityIdentifier("field"); field.setAccessibilityLabel("Result")
        field.write = { [weak self] value in
            guard let self else { return }; modelValue = value; field.stringValue = value; writes += 1; record("field_write")
        }
        content.addSubview(field)
        animation.frame = NSRect(x: 20, y: 18, width: 200, height: 20)
        animation.setAccessibilityIdentifier("animation"); content.addSubview(animation)
        for index in 0..<48 {
            let label = NSTextField(labelWithString: "Unrelated \(index): \(String(repeating: "detail ", count: 8))")
            label.frame = NSRect(x: 20 + (index % 4) * 220, y: 65 + (index / 4) * 24, width: 212, height: 20)
            label.setAccessibilityIdentifier("detail.\(index)"); content.addSubview(label)
        }
        window.orderBack(nil)
        emit(["event": "ready", "status": "ok", "state": state()])
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while let line = readLine() { DispatchQueue.main.async { self.handle(line) } }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) { activationCount += 1 }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func milliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
    func record(_ kind: String) {
        revision += 1
        journal.append(["kind": kind, "unixMs": milliseconds(), "revision": revision,
            "toastPresent": toast != nil, "dialogPresent": dialog != nil, "modelValue": modelValue, "acknowledged": acknowledged])
    }
    func notifyLayout() { NSAccessibility.post(element: window, notification: .layoutChanged) }
    func schedule(_ milliseconds: Int, generation token: Int, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            guard let self, generation == token else { return }; body()
        }
    }
    func scenario(toastDelay: Int, toastDuration: Int, dialogDelay: Int) {
        generation += 1; let token = generation
        animationTimer?.invalidate(); toast?.removeFromSuperview(); dialog?.removeFromSuperview()
        toast = nil; dialog = nil; button = nil; journal = []; acknowledged = 0; writes = 0
        modelValue = "pending"; field.stringValue = modelValue; animationTicks = 0
        record("scenario_started"); notifyLayout()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.animationTicks += 1; self.animation.stringValue = "Animation \(self.animationTicks)"
                NSAccessibility.post(element: self.animation, notification: .valueChanged)
            }
        }
        schedule(toastDelay, generation: token) { [weak self] in
            guard let self else { return }
            let label = NSTextField(labelWithString: "Saved transiently")
            label.frame = NSRect(x: 300, y: 445, width: 220, height: 24)
            label.setAccessibilityIdentifier("toast"); label.setAccessibilityLabel("Saved transiently")
            window.contentView!.addSubview(label); toast = label; record("toast_shown"); notifyLayout()
        }
        schedule(toastDelay + toastDuration, generation: token) { [weak self] in
            guard let self else { return }; toast?.removeFromSuperview(); toast = nil; record("toast_removed"); notifyLayout()
        }
        schedule(dialogDelay, generation: token) { [weak self] in
            guard let self else { return }
            let panel = NSBox(frame: NSRect(x: 570, y: 370, width: 300, height: 105))
            panel.title = "Confirmation"; panel.setAccessibilityIdentifier("dialog")
            panel.setAccessibilityElement(true); panel.setAccessibilityRole(.group); panel.setAccessibilityLabel("Confirmation")
            let button = NSButton(title: "Acknowledge", target: self, action: #selector(acknowledge(_:)))
            button.frame = NSRect(x: 15, y: 15, width: 160, height: 28); button.setAccessibilityIdentifier("dialog.ack")
            panel.contentView!.addSubview(button); window.contentView!.addSubview(panel)
            dialog = panel; self.button = button; record("dialog_shown"); notifyLayout()
        }
    }
    @objc func acknowledge(_ sender: NSButton) {
        guard sender === button, dialog != nil else { return }
        acknowledged += 1; dialog?.removeFromSuperview(); dialog = nil; button = nil; record("dialog_acknowledged"); notifyLayout()
    }
    func state() -> [String: Any] {
        ["pid": ProcessInfo.processInfo.processIdentifier, "runNonce": nonce, "windowId": window.windowNumber,
         "windowTitle": window.title, "generation": generation, "revision": revision, "modelValue": modelValue,
         "controlValue": field.stringValue, "writes": writes, "acknowledged": acknowledged,
         "toastPresent": toast != nil, "dialogPresent": dialog != nil, "journal": journal,
         "animationTicks": animationTicks, "activationCount": activationCount, "startedForegroundPID": startedForegroundPID,
         "foregroundPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0]
    }
    func handle(_ line: String) {
        guard let data = line.data(using: .utf8), let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String, let command = request["command"] as? String else { return }
        switch command {
        case "state": break
        case "scenario":
            let delay = request["toastDelayMs"] as? Int ?? 120, duration = request["toastDurationMs"] as? Int ?? 180
            let dialogDelay = request["dialogDelayMs"] as? Int ?? 450
            guard (20...1000).contains(delay), (50...1000).contains(duration), (20...1500).contains(dialogDelay) else {
                emit(["id": id, "status": "error", "error": "invalid fixture timing"]); return
            }
            scenario(toastDelay: delay, toastDuration: duration, dialogDelay: dialogDelay)
        case "quit":
            animationTimer?.invalidate(); emit(["id": id, "status": "ok", "state": state()]); NSApplication.shared.terminate(nil); return
        default: emit(["id": id, "status": "error", "error": "unknown fixture command"]); return
        }
        emit(["id": id, "status": "ok", "state": state()])
    }
    func emit(_ value: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) else { return }
        print(text); fflush(stdout)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = SelectiveFixture()
application.delegate = controller
application.run()
