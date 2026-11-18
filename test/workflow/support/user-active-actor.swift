import AppKit
import ApplicationServices
import Foundation

private struct Request: Decodable, Sendable {
    let id: String
    let command: String
    let ownedPIDs: [Int32]?
    let expectedForegroundPID: Int32?
    let nextActorPID: Int32?
}

@MainActor
private final class Actor: NSObject, NSApplicationDelegate {
    let label = CommandLine.arguments[1]
    let nonce = CommandLine.arguments[2]
    let previous: NSRunningApplication?
    let previousBirth: Date?
    var window: NSWindow!
    var activationCount = 0
    var busy = false

    override init() {
        let app = NSWorkspace.shared.frontmostApplication
        previous = app
        previousBirth = app?.launchDate
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 120, y: 140, width: 300, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CUA disposable activity \(label)"
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        let text = NSTextField(labelWithString: "Owned foreground actor \(label)\nNo keyboard or mouse input")
        text.frame = NSRect(x: 20, y: 30, width: 260, height: 60)
        window.contentView!.addSubview(text)
        window.orderBack(nil)
        emit(["event": "ready", "state": state()])
        DispatchQueue.global().async {
            while let line = readLine() {
                guard line.utf8.count <= 1024,
                      let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { exit(2) }
                DispatchQueue.main.async { self.handle(request) }
            }
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) { activationCount += 1 }
    func currentPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func state() -> [String: Any] {
        ["pid": ProcessInfo.processInfo.processIdentifier, "label": label, "nonce": nonce,
         "activationCount": activationCount, "foregroundPID": currentPID() as Any? ?? NSNull(),
         "previousIdentityKnown": previousBirth != nil,
         "previousForegroundPID": previous?.processIdentifier as Any? ?? NSNull()]
    }
    func emit(_ value: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes + Data([10]))
    }
    func reply(_ request: Request, reason: String? = nil, restored: Bool? = nil) {
        busy = false
        var result: [String: Any] = ["id": request.id, "state": state(), "status": "ok"]
        if let reason { result["reason"] = reason }
        if let restored { result["restored"] = restored }
        emit(result)
    }
    func reject(_ request: Request, _ reason: String) {
        emit(["id": request.id, "status": "error", "reason": reason, "state": state()])
    }
    func handle(_ request: Request) {
        if request.command == "quit" {
            reply(request)
            NSApplication.shared.terminate(nil)
            return
        }
        guard !busy else { reject(request, "operation_pending"); return }
        guard let owned = request.ownedPIDs, owned.count == 2, Set(owned).count == 2,
              owned.allSatisfy({ $0 > 0 }), owned.contains(ProcessInfo.processInfo.processIdentifier),
              let current = currentPID() else { reject(request, "invalid_owned_processes"); return }
        switch request.command {
        case "yield":
            guard current == ProcessInfo.processInfo.processIdentifier,
                  let next = request.nextActorPID, next != current, owned.contains(next),
                  let actor = NSRunningApplication(processIdentifier: next), !actor.isTerminated else {
                reject(request, "foreground_changed_before_actor_yield"); return
            }
            if #available(macOS 14, *) { NSApplication.shared.yieldActivation(to: actor) }
            reply(request, reason: "actor_yielded")
        case "activate":
            guard current == request.expectedForegroundPID,
                  owned.contains(current) || current == previous?.processIdentifier else {
                reject(request, "foreground_changed_before_actor_activation"); return
            }
            busy = true
            window.makeKeyAndOrderFront(nil)
            if #available(macOS 14, *) {
                if owned.contains(current) || !AXIsProcessTrusted() {
                    NSApplication.shared.activate()
                } else {
                    // Initial entry starts from an unrelated application. Target only this disposable actor.
                    let selfApp = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                    guard currentPID() == current else {
                        busy = false
                        reject(request, "foreground_changed_before_actor_activation")
                        return
                    }
                    guard AXUIElementSetAttributeValue(selfApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success else {
                        busy = false
                        reject(request, "owned_actor_activation_refused")
                        return
                    }
                }
            } else { NSApplication.shared.activate(ignoringOtherApps: true) }
            awaitForeground(request, pid: ProcessInfo.processInfo.processIdentifier,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000, restoring: false)
        case "restore":
            // Never reclaim focus after the person has switched to an unowned application.
            guard current == ProcessInfo.processInfo.processIdentifier else { reply(request, reason: "new_foreground_preserved", restored: false); return }
            guard let previous, !owned.contains(previous.processIdentifier), !previous.isTerminated,
                  let birth = previousBirth,
                  let live = NSRunningApplication(processIdentifier: previous.processIdentifier),
                  !live.isTerminated, live.launchDate == birth,
                  live.bundleIdentifier == previous.bundleIdentifier else {
                reply(request, reason: "prior_process_unavailable", restored: false); return
            }
            busy = true
            // Public AppKit provides no atomic compare-and-activate operation.
            let requested: Bool
            if #available(macOS 14, *), let currentApp = NSRunningApplication(processIdentifier: current) {
                NSApplication.shared.yieldActivation(to: live)
                requested = live.activate(from: currentApp, options: [])
            } else {
                requested = live.activate(options: [])
            }
            guard requested else {
                reply(request, reason: "prior_activation_refused", restored: false); return
            }
            awaitForeground(request, pid: previous.processIdentifier,
                deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000, restoring: true)
        default: reject(request, "unsupported_command")
        }
    }
    func awaitForeground(_ request: Request, pid: Int32, deadline: UInt64, restoring: Bool) {
        if currentPID() == pid && (restoring || (NSApplication.shared.isActive && activationCount > 0)) {
            reply(request, reason: restoring ? "prior_focus_restored" : "actor_active", restored: restoring ? true : nil)
        } else if DispatchTime.now().uptimeNanoseconds >= deadline {
            busy = false
            reject(request, restoring ? "restore_not_observed" : "actor_activation_not_observed")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
                self.awaitForeground(request, pid: pid, deadline: deadline, restoring: restoring)
            }
        }
    }
}

guard CommandLine.arguments.count == 3 else { exit(2) }
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let actor = Actor()
    app.delegate = actor
    withExtendedLifetime(actor) { app.run() }
}
