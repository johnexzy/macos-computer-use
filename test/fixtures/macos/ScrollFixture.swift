import AppKit
import Foundation

@MainActor
private final class ScrollDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class ScrollFixture: NSObject, NSApplicationDelegate {
    private let window = NSWindow(contentRect: NSRect(x: 90, y: 150, width: 570, height: 300),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let primary = NSScrollView(frame: NSRect(x: 20, y: 20, width: 255, height: 260))
    private let secondary = NSScrollView(frame: NSRect(x: 295, y: 20, width: 255, height: 260))
    private let startedForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    private var activationCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "CUA Fixture — Scroll"
        window.animationBehavior = .none
        configure(primary, identifier: "scroll.primary", horizontal: true)
        configure(secondary, identifier: "scroll.secondary", horizontal: false)
        window.orderBack(nil)
        emit(["event": "ready", "state": state()])
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            while let line = readLine() { DispatchQueue.main.async { self.handle(line) } }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { activationCount += 1 }

    private func configure(_ view: NSScrollView, identifier: String, horizontal: Bool) {
        view.setAccessibilityIdentifier(identifier)
        view.scrollerStyle = .legacy
        view.hasVerticalScroller = true
        view.hasHorizontalScroller = horizontal
        view.autohidesScrollers = false
        let document = ScrollDocument(frame: NSRect(x: 0, y: 0, width: horizontal ? 1040 : 200, height: 1080))
        for index in 0..<6 {
            let label = NSTextField(labelWithString: "Row \(index + 1)")
            label.frame = NSRect(x: horizontal ? index * 130 + 12 : 12, y: index * 170 + 20, width: 100, height: 24)
            document.addSubview(label)
        }
        view.documentView = document
        window.contentView?.addSubview(view)
    }

    private func state() -> [String: Any] {
        func origin(_ view: NSScrollView) -> [String: CGFloat] {
            let origin = view.contentView.bounds.origin
            return ["x": origin.x, "y": origin.y]
        }
        return ["pid": ProcessInfo.processInfo.processIdentifier, "windowId": window.windowNumber,
                "foregroundPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                "startedForegroundPID": startedForegroundPID, "activationCount": activationCount,
                "primary": origin(primary), "secondary": origin(secondary)]
    }

    private func handle(_ line: String) {
        guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = request["id"] as? String, let command = request["command"] as? String else { return }
        switch command {
        case "state": emit(["id": id, "status": "ok", "state": state()])
        case "quit":
            emit(["id": id, "status": "ok"])
            NSApplication.shared.terminate(nil)
        default: emit(["id": id, "status": "error", "error": "unknown fixture command"])
        }
    }

    private func emit(_ message: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([0x0a]))
    }
}
