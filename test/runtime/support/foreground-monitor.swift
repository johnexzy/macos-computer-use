import AppKit
import Foundation

struct Request: Decodable, Sendable {
    let id: String
    let command: String
    let targetPID: Int32?
}

// This observer measures app activation. It does not activate or control apps.
final class Monitor: @unchecked Sendable {
    var targetPID: Int32?
    var startedPID: Int32?
    var targetActivations = 0
    var events: [[String: Any]] = []
    var truncated = false
    var token: NSObjectProtocol?

    func currentPID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func state() -> [String: Any] {
        let current = currentPID()
        return ["available": targetPID != nil && startedPID != nil && current != nil && !truncated,
                "targetPID": targetPID as Any? ?? NSNull(),
                "startedForegroundPID": startedPID as Any? ?? NSNull(),
                "finishedForegroundPID": current as Any? ?? NSNull(),
                "targetActivations": targetActivations, "truncated": truncated, "events": events]
    }
    func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { exit(2) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    func handle(_ request: Request) {
        switch request.command {
        case "begin":
            guard let pid = request.targetPID, pid > 0 else {
                write(["id": request.id, "error": "positive target PID required"]); return
            }
            targetPID = pid; startedPID = currentPID()
            events = []; targetActivations = 0; truncated = false
            write(["id": request.id, "state": state()])
        case "snapshot": write(["id": request.id, "state": state()])
        case "stop": write(["id": request.id, "state": state()]); exit(0)
        default: write(["id": request.id, "error": "unsupported monitor command"])
        }
    }
}

let monitor = Monitor()
monitor.token = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
    guard monitor.targetPID != nil,
          let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    if app.processIdentifier == monitor.targetPID { monitor.targetActivations += 1 }
    if monitor.events.count < 128 {
        monitor.events.append(["pid": app.processIdentifier,
                               "observedUptimeNs": DispatchTime.now().uptimeNanoseconds])
    } else { monitor.truncated = true }
}
monitor.write(["event": "ready"])
DispatchQueue.global().async {
    while let line = readLine() {
        guard line.utf8.count <= 1024, let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data) else { exit(2) }
        DispatchQueue.main.async { monitor.handle(request) }
    }
    DispatchQueue.main.async { exit(0) }
}
RunLoop.main.run()
