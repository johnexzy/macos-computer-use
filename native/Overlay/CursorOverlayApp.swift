import Foundation
import CoreGraphics
import AppKit

final class AgentCursorView: NSView {
    private var feedback: AgentCursorFeedback = .idle
    private var feedbackStartedAt = CFAbsoluteTimeGetCurrent()
    private var animationTimer: Timer?

    override var isOpaque: Bool { false }

    func showFeedback(_ value: AgentCursorFeedback) {
        feedback = value
        feedbackStartedAt = CFAbsoluteTimeGetCurrent()
        animationTimer?.invalidate()

        let duration = value == .error ? 0.55 : 0.38
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if CFAbsoluteTimeGetCurrent() - self.feedbackStartedAt >= duration {
                self.feedback = .idle
                timer.invalidate()
            }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let duration = feedback == .error ? 0.55 : 0.38
        let progress = CGFloat(min(1.0, (CFAbsoluteTimeGetCurrent() - feedbackStartedAt) / duration))
        let clickCompression = feedback == .click
            ? 1.0 - (0.07 * CGFloat(sin(.pi * min(1.0, Double(progress) * 2.0))))
            : 1.0
        drawAgentCursor(
            context: context,
            tip: CGPoint(x: 20, y: 56),
            scale: clickCompression,
            feedback: feedback,
            feedbackProgress: progress
        )
    }
}

final class AgentCursorOverlayController {
    private let panel: NSPanel
    private let cursorView: AgentCursorView
    private var currentScreenPoint: CGPoint?
    private var hideWorkItem: DispatchWorkItem?

    init() {
        cursorView = AgentCursorView(frame: CGRect(x: 0, y: 0, width: 76, height: 76))
        panel = NSPanel(
            contentRect: cursorView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = cursorView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0
    }

    private func cocoaPoint(for screenPoint: CGPoint) -> CGPoint? {
        for screen in NSScreen.screens {
            guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(displayNumber.uint32Value))
            if displayBounds.contains(screenPoint) {
                return CGPoint(
                    x: screen.frame.minX + (screenPoint.x - displayBounds.minX),
                    y: screen.frame.maxY - (screenPoint.y - displayBounds.minY)
                )
            }
        }
        return nil
    }

    private func cancelScheduledHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }

    private func scheduleHide(after delay: TimeInterval) {
        cancelScheduledHide()
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide(duration: 0.22)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func move(to screenPoint: CGPoint, duration: TimeInterval, completion: @escaping (Bool) -> Void) {
        guard let cocoaPoint = cocoaPoint(for: screenPoint) else {
            completion(false)
            return
        }
        cancelScheduledHide()

        let origin = CGPoint(x: cocoaPoint.x - 20, y: cocoaPoint.y - 56)
        let firstPosition = currentScreenPoint == nil
        currentScreenPoint = screenPoint
        panel.orderFrontRegardless()

        if firstPosition || duration <= 0 {
            panel.setFrameOrigin(origin)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                panel.animator().alphaValue = 1
            } completionHandler: {
                self.scheduleHide(after: 3.0)
                completion(true)
            }
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().setFrameOrigin(origin)
            panel.animator().alphaValue = 1
        } completionHandler: {
            self.scheduleHide(after: 3.0)
            completion(true)
        }
    }

    func showFeedback(_ feedback: AgentCursorFeedback) {
        cancelScheduledHide()
        panel.orderFrontRegardless()
        panel.alphaValue = 1
        cursorView.showFeedback(feedback)
        scheduleHide(after: feedback == .error ? 1.4 : 0.9)
    }

    func hide(duration: TimeInterval = 0.18) {
        cancelScheduledHide()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        } completionHandler: {
            self.panel.orderOut(nil)
        }
    }
}

func emitCursorOverlayMessage(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else {
        return
    }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

func runCursorOverlay() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let controller = AgentCursorOverlayController()

    emitCursorOverlayMessage(["status": "ready"])

    DispatchQueue.global(qos: .userInitiated).async {
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            DispatchQueue.main.async {
                let id = message["id"] as? String ?? ""
                let action = message["action"] as? String ?? ""
                let respond: ([String: Any]) -> Void = { response in
                    var payload = response
                    payload["id"] = id
                    emitCursorOverlayMessage(payload)
                }

                switch action {
                case "move":
                    guard let x = message["x"] as? Double,
                          let y = message["y"] as? Double else {
                        respond(["status": "error", "error": "move requires x and y"])
                        return
                    }
                    let duration = max(0, (message["durationMs"] as? Double ?? 160) / 1000.0)
                    controller.move(to: CGPoint(x: x, y: y), duration: duration) { visible in
                        if visible {
                            respond(["status": "ok", "action": "move", "visible": true])
                        } else {
                            respond([
                                "status": "error",
                                "action": "move",
                                "visible": false,
                                "error": "Target coordinate is outside connected displays"
                            ])
                        }
                    }
                case "click":
                    controller.showFeedback(.click)
                    respond(["status": "ok", "action": "click"])
                case "scroll":
                    controller.showFeedback(.scroll)
                    respond(["status": "ok", "action": "scroll"])
                case "error":
                    controller.showFeedback(.error)
                    respond(["status": "ok", "action": "error"])
                case "hide":
                    controller.hide()
                    respond(["status": "ok", "action": "hide"])
                case "quit":
                    respond(["status": "ok", "action": "quit"])
                    NSApp.terminate(nil)
                default:
                    respond(["status": "error", "error": "Unknown overlay action \(action)"])
                }
            }
        }
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    app.run()
}
