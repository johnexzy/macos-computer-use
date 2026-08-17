import Foundation
import CoreGraphics
import AppKit
import ImageIO
import Vision

func printJson(_ dict: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

func getDisplaySize() {
    let mainDisplay = CGMainDisplayID()
    let bounds = CGDisplayBounds(mainDisplay)
    let screen = NSScreen.main
    let scale = screen?.backingScaleFactor ?? 1.0
    
    printJson([
        "width": bounds.width,
        "height": bounds.height,
        "scale": scale,
        "pixelWidth": bounds.width * scale,
        "pixelHeight": bounds.height * scale
    ])
}

// -------------------------------------------------------------------------
// Window & Process Discovery
// -------------------------------------------------------------------------

func listWindows(targetApp: String? = nil, minSize: Double = 80.0) {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        printJson(["windows": []])
        return
    }
    
    var results: [[String: Any]] = []
    
    for win in windowList {
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        let name = win[kCGWindowName as String] as? String ?? ""
        let wid = win[kCGWindowNumber as String] as? Int ?? 0
        let pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let layer = win[kCGWindowLayer as String] as? Int ?? -1
        let isOnScreen = win[kCGWindowIsOnscreen as String] as? Bool ?? true
        let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
        
        let width = boundsDict["Width"] as? Double ?? 0
        let height = boundsDict["Height"] as? Double ?? 0
        let x = boundsDict["X"] as? Double ?? 0
        let y = boundsDict["Y"] as? Double ?? 0
        
        if layer == 0 && width >= minSize && height >= minSize {
            if let target = targetApp, !target.isEmpty {
                if !owner.localizedCaseInsensitiveContains(target) && !name.localizedCaseInsensitiveContains(target) {
                    continue
                }
            }
            results.append([
                "windowId": wid,
                "pid": pid,
                "appName": owner,
                "title": name,
                "isOnScreen": isOnScreen,
                "bounds": [
                    "x": x,
                    "y": y,
                    "width": width,
                    "height": height
                ]
            ])
        }
    }
    
    if let data = try? JSONSerialization.data(withJSONObject: results, options: []),
       let str = String(data: data, encoding: .utf8) {
        print(str)
    } else {
        print("[]")
    }
}

func findTargetWindowInfo(targetApp: String) -> (wid: Int, pid: pid_t, bounds: [String: Double], appName: String, title: String)? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let windowList = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) ?? CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)) as? [[String: Any]] else {
        return nil
    }
    
    // CGWindowListCopyWindowInfo returns windows in front-to-back Z-order.
    // The first window matching the application name with area >= 200x200 is the frontmost active window.
    for win in windowList {
        let owner = win[kCGWindowOwnerName as String] as? String ?? ""
        let name = win[kCGWindowName as String] as? String ?? ""
        let wid = win[kCGWindowNumber as String] as? Int ?? 0
        let pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
        let layer = win[kCGWindowLayer as String] as? Int ?? -1
        let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = boundsDict["Width"] as? Double ?? 0
        let height = boundsDict["Height"] as? Double ?? 0
        let x = boundsDict["X"] as? Double ?? 0
        let y = boundsDict["Y"] as? Double ?? 0
        
        if layer == 0 && width >= 250 && height >= 250 {
            if owner.localizedCaseInsensitiveContains(targetApp) || name.localizedCaseInsensitiveContains(targetApp) {
                return (
                    wid: wid,
                    pid: pid,
                    bounds: ["x": x, "y": y, "width": width, "height": height],
                    appName: owner,
                    title: name
                )
            }
        }
    }
    
    return nil
}

func findWindow(targetApp: String) {
    if let target = findTargetWindowInfo(targetApp: targetApp) {
        printJson([
            "status": "ok",
            "windowId": target.wid,
            "pid": target.pid,
            "appName": target.appName,
            "title": target.title,
            "bounds": target.bounds
        ])
    } else {
        printJson(["error": "No window found matching \(targetApp)"])
    }
}

func getWindowBounds(windowId: Int) {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        printJson(["error": "Could not fetch window list"])
        return
    }
    
    for win in windowList {
        let wid = win[kCGWindowNumber as String] as? Int ?? 0
        if wid == windowId {
            let owner = win[kCGWindowOwnerName as String] as? String ?? ""
            let name = win[kCGWindowName as String] as? String ?? ""
            let pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = boundsDict["Width"] as? Double ?? 0
            let height = boundsDict["Height"] as? Double ?? 0
            let x = boundsDict["X"] as? Double ?? 0
            let y = boundsDict["Y"] as? Double ?? 0
            
            printJson([
                "status": "ok",
                "windowId": wid,
                "pid": pid,
                "appName": owner,
                "title": name,
                "bounds": [
                    "x": x,
                    "y": y,
                    "width": width,
                    "height": height
                ]
            ])
            return
        }
    }
    printJson(["error": "Window ID \(windowId) not found"])
}

// -------------------------------------------------------------------------
// Non-Intrusive Targeted Event Dispatch (postToPid) & Virtual Cursor
// -------------------------------------------------------------------------

func dispatchMouseClick(x: Double, y: Double, button: String = "left", count: Int = 1, targetPid: pid_t? = nil) {
    let point = CGPoint(x: x, y: y)
    
    var downType = CGEventType.leftMouseDown
    var upType = CGEventType.leftMouseUp
    var cgButton = CGMouseButton.left
    
    if button == "right" {
        downType = .rightMouseDown
        upType = .rightMouseUp
        cgButton = .right
    } else if button == "middle" {
        downType = .otherMouseDown
        upType = .otherMouseUp
        cgButton = .center
    }
    
    for i in 1...count {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
            continue
        }
        
        down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
        
        if let pid = targetPid, pid > 0 {
            down.postToPid(pid)
            usleep(25000)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            usleep(25000)
            up.post(tap: .cghidEventTap)
        }
        
        if i < count {
            usleep(40000)
        }
    }
    
    printJson([
        "status": "ok",
        "action": "click",
        "x": x,
        "y": y,
        "button": button,
        "count": count,
        "targetPid": targetPid ?? 0,
        "nonIntrusive": (targetPid ?? 0) > 0
    ])
}

func dispatchTypeText(text: String, targetPid: pid_t? = nil) {
    let utf16Chars = Array(text.utf16)
    
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
        printJson(["error": "Could not create keyboard event"])
        return
    }
    
    down.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
    up.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
    
    if let pid = targetPid, pid > 0 {
        down.postToPid(pid)
        usleep(20000)
        up.postToPid(pid)
    } else {
        down.post(tap: .cghidEventTap)
        usleep(20000)
        up.post(tap: .cghidEventTap)
    }
    
    printJson([
        "status": "ok",
        "action": "type_text",
        "text": text,
        "targetPid": targetPid ?? 0,
        "nonIntrusive": (targetPid ?? 0) > 0
    ])
}

func dispatchScroll(x: Double, y: Double, deltaY: Int32, deltaX: Int32 = 0, targetPid: pid_t? = nil) {
    if let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) {
        scroll.location = CGPoint(x: x, y: y)
        if let pid = targetPid, pid > 0 {
            scroll.postToPid(pid)
        } else {
            scroll.post(tap: .cghidEventTap)
        }
    }
    printJson([
        "status": "ok",
        "action": "scroll",
        "x": x,
        "y": y,
        "deltaY": deltaY,
        "deltaX": deltaX,
        "targetPid": targetPid ?? 0,
        "nonIntrusive": (targetPid ?? 0) > 0
    ])
}

// -------------------------------------------------------------------------
// Virtual Cursor Marker (Draws agent cursor badge onto screenshot)
// -------------------------------------------------------------------------

func markCursor(imagePath: String, x: Double, y: Double, displayWidth: Double = 1800.0) {
    guard let image = NSImage(contentsOfFile: imagePath),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        printJson(["error": "Could not open image"])
        return
    }
    
    let width = cgImage.width
    let height = cgImage.height
    let scale = Double(width) / displayWidth
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        printJson(["error": "Could not create context"])
        return
    }
    
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    let targetX = x * scale
    let targetY = Double(height) - (y * scale)
    let center = CGPoint(x: targetX, y: targetY)
    
    // Outer glowing cyan ring (Virtual Agent Cursor)
    ctx.setLineWidth(max(2.0, 3.0 * scale))
    ctx.setStrokeColor(CGColor(red: 0.05, green: 0.85, blue: 1.0, alpha: 0.95))
    ctx.addArc(center: center, radius: 14.0 * scale, startAngle: 0, endAngle: .pi * 2, clockwise: true)
    ctx.strokePath()
    
    // Inner pulse dot (neon magenta/pink)
    ctx.setFillColor(CGColor(red: 1.0, green: 0.15, blue: 0.45, alpha: 0.95))
    ctx.addArc(center: center, radius: 5.0 * scale, startAngle: 0, endAngle: .pi * 2, clockwise: true)
    ctx.fillPath()
    
    // Crosshair lines
    ctx.setLineWidth(max(1.5, 2.0 * scale))
    ctx.setStrokeColor(CGColor(red: 0.05, green: 0.85, blue: 1.0, alpha: 0.85))
    
    let lineLen = 8.0 * scale
    let lineGap = 16.0 * scale
    
    ctx.move(to: CGPoint(x: targetX - lineGap - lineLen, y: targetY))
    ctx.addLine(to: CGPoint(x: targetX - lineGap, y: targetY))
    ctx.move(to: CGPoint(x: targetX + lineGap, y: targetY))
    ctx.addLine(to: CGPoint(x: targetX + lineGap + lineLen, y: targetY))
    ctx.move(to: CGPoint(x: targetX, y: targetY + lineGap))
    ctx.addLine(to: CGPoint(x: targetX, y: targetY + lineGap + lineLen))
    ctx.move(to: CGPoint(x: targetX, y: targetY - lineGap - lineLen))
    ctx.addLine(to: CGPoint(x: targetX, y: targetY - lineGap))
    ctx.strokePath()
    
    guard let newImage = ctx.makeImage() else {
        printJson(["error": "Could not finalize image"])
        return
    }
    
    let destUrl = URL(fileURLWithPath: imagePath)
    if let dest = CGImageDestinationCreateWithURL(destUrl as CFURL, "public.jpeg" as CFString, 1, nil) {
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImage(dest, newImage, options as CFDictionary)
        CGImageDestinationFinalize(dest)
        printJson(["status": "ok", "action": "mark_cursor", "x": x, "y": y])
    }
}

// -------------------------------------------------------------------------
// Vision OCR and Text Finding Primitives
// -------------------------------------------------------------------------

func recognizeTextInImage(imagePath: String, logicalWidth: Double? = nil) -> [[String: Any]] {
    guard let image = NSImage(contentsOfFile: imagePath),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return []
    }
    
    let pixelWidth = Double(cgImage.width)
    let pixelHeight = Double(cgImage.height)
    
    let scale: Double
    if let lWidth = logicalWidth, lWidth > 0 {
        scale = pixelWidth / lWidth
    } else {
        let screen = NSScreen.main
        scale = Double(screen?.backingScaleFactor ?? 2.0)
    }
    
    var results: [[String: Any]] = []
    
    let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    let request = VNRecognizeTextRequest { (req, err) in
        guard let observations = req.results as? [VNRecognizedTextObservation] else { return }
        
        for obs in observations {
            guard let topCandidate = obs.topCandidates(1).first else { continue }
            let bbox = obs.boundingBox
            
            let rectX = (bbox.origin.x * pixelWidth) / scale
            let rectY = ((1.0 - bbox.origin.y - bbox.height) * pixelHeight) / scale
            let rectW = (bbox.width * pixelWidth) / scale
            let rectH = (bbox.height * pixelHeight) / scale
            let centerX = rectX + (rectW / 2.0)
            let centerY = rectY + (rectH / 2.0)
            
            results.append([
                "text": topCandidate.string,
                "confidence": topCandidate.confidence,
                "bounds": [
                    "x": rectX,
                    "y": rectY,
                    "width": rectW,
                    "height": rectH,
                    "centerX": centerX,
                    "centerY": centerY
                ]
            ])
        }
    }
    
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    
    try? requestHandler.perform([request])
    return results
}

func ocrCommand(imagePath: String, query: String? = nil, logicalWidth: Double? = nil) {
    let allText = recognizeTextInImage(imagePath: imagePath, logicalWidth: logicalWidth)
    
    if let q = query, !q.isEmpty {
        let filtered = allText.filter { item in
            let text = item["text"] as? String ?? ""
            return text.localizedCaseInsensitiveContains(q)
        }
        printJson(["status": "ok", "query": q, "count": filtered.count, "elements": filtered])
    } else {
        printJson(["status": "ok", "count": allText.count, "elements": allText])
    }
}

func findTextInWindow(targetText: String, windowId: Int? = nil, appName: String? = nil) {
    var wid = windowId
    var pid: pid_t = 0
    var windowBounds: [String: Double]? = nil
    
    if wid == nil, let app = appName {
        if let target = findTargetWindowInfo(targetApp: app) {
            wid = target.wid
            pid = target.pid
            windowBounds = target.bounds
        }
    } else if let w = wid {
        let options = CGWindowListOption(arrayLiteral: .optionAll)
        if let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            for win in windowList {
                if (win[kCGWindowNumber as String] as? Int) == w {
                    pid = win[kCGWindowOwnerPID as String] as? pid_t ?? 0
                    let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
                    let width = boundsDict["Width"] as? Double ?? 0
                    let height = boundsDict["Height"] as? Double ?? 0
                    let x = boundsDict["X"] as? Double ?? 0
                    let y = boundsDict["Y"] as? Double ?? 0
                    windowBounds = ["x": x, "y": y, "width": width, "height": height]
                    break
                }
            }
        }
    }
    
    let tmpFile = "/tmp/mcp_ocr_\(Date().timeIntervalSince1970).jpg"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    if let targetWid = wid {
        proc.arguments = ["-x", "-o", "-l", "\(targetWid)", "-t", "jpg", tmpFile]
    } else {
        proc.arguments = ["-x", "-t", "jpg", tmpFile]
    }
    try? proc.run()
    proc.waitUntilExit()
    
    defer {
        try? FileManager.default.removeItem(atPath: tmpFile)
    }
    
    let elements = recognizeTextInImage(imagePath: tmpFile, logicalWidth: windowBounds?["width"])
    
    var matches: [[String: Any]] = []
    for item in elements {
        let text = item["text"] as? String ?? ""
        if text.localizedCaseInsensitiveContains(targetText) {
            var itemCopy = item
            if let bounds = item["bounds"] as? [String: Double], let winB = windowBounds {
                let globalCenterX = (bounds["centerX"] ?? 0) + (winB["x"] ?? 0)
                let globalCenterY = (bounds["centerY"] ?? 0) + (winB["y"] ?? 0)
                itemCopy["globalCoordinates"] = [
                    "x": globalCenterX,
                    "y": globalCenterY
                ]
            }
            matches.append(itemCopy)
        }
    }
    
    if let best = matches.first {
        printJson([
            "status": "ok",
            "found": true,
            "bestMatch": best,
            "allMatches": matches,
            "windowId": wid ?? 0,
            "pid": pid,
            "windowBounds": windowBounds ?? [:]
        ])
    } else {
        printJson([
            "status": "ok",
            "found": false,
            "error": "Text '\(targetText)' not found",
            "windowId": wid ?? 0,
            "pid": pid,
            "availableText": elements.prefix(15).map { $0["text"] ?? "" }
        ])
    }
}

func waitForText(targetText: String, windowId: Int? = nil, appName: String? = nil, timeoutSeconds: Double = 5.0) {
    let start = CFAbsoluteTimeGetCurrent()
    var wid = windowId
    var pid: pid_t = 0
    var windowBounds: [String: Double]? = nil
    
    if wid == nil, let app = appName {
        if let target = findTargetWindowInfo(targetApp: app) {
            wid = target.wid
            pid = target.pid
            windowBounds = target.bounds
        }
    }
    
    while (CFAbsoluteTimeGetCurrent() - start) < timeoutSeconds {
        let tmpFile = "/tmp/mcp_wait_\(Date().timeIntervalSince1970).jpg"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if let targetWid = wid {
            proc.arguments = ["-x", "-o", "-l", "\(targetWid)", "-t", "jpg", tmpFile]
        } else {
            proc.arguments = ["-x", "-t", "jpg", tmpFile]
        }
        try? proc.run()
        proc.waitUntilExit()
        
        let elements = recognizeTextInImage(imagePath: tmpFile, logicalWidth: windowBounds?["width"])
        try? FileManager.default.removeItem(atPath: tmpFile)
        
        for item in elements {
            let text = item["text"] as? String ?? ""
            if text.localizedCaseInsensitiveContains(targetText) {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
                printJson([
                    "status": "ok",
                    "found": true,
                    "match": item,
                    "pid": pid,
                    "windowId": wid ?? 0,
                    "elapsedMs": elapsed
                ])
                return
            }
        }
        usleep(150000)
    }
    
    printJson([
        "status": "ok",
        "found": false,
        "error": "Timed out after \(timeoutSeconds)s waiting for text '\(targetText)'"
    ])
}

// -------------------------------------------------------------------------
// CLI argument parsing
// -------------------------------------------------------------------------

let args = CommandLine.arguments

if args.count < 2 {
    print("Usage: native_helper <command> [args...]")
    exit(1)
}

let command = args[1]

switch command {
case "size":
    getDisplaySize()
case "list_windows":
    let target = args.count >= 3 ? args[2] : nil
    listWindows(targetApp: target)
case "find_window":
    if args.count >= 3 {
        findWindow(targetApp: args[2])
    } else {
        printJson(["error": "Missing target app name"])
        exit(1)
    }
case "get_window_bounds":
    if args.count >= 3, let wid = Int(args[2]) {
        getWindowBounds(windowId: wid)
    } else {
        printJson(["error": "Missing or invalid windowId"])
        exit(1)
    }
case "ocr":
    if args.count >= 3 {
        let path = args[2]
        let query = args.count >= 4 && args[3] != "nil" ? args[3] : nil
        let lWidth = args.count >= 5 ? Double(args[4]) : nil
        ocrCommand(imagePath: path, query: query, logicalWidth: lWidth)
    } else {
        printJson(["error": "Missing image path for ocr"])
        exit(1)
    }
case "find_text":
    if args.count >= 3 {
        let text = args[2]
        let app = args.count >= 4 && args[3] != "nil" ? args[3] : nil
        let wid = args.count >= 5 ? Int(args[4]) : nil
        findTextInWindow(targetText: text, windowId: wid, appName: app)
    } else {
        printJson(["error": "Missing target text"])
        exit(1)
    }
case "wait_for_text":
    if args.count >= 3 {
        let text = args[2]
        let app = args.count >= 4 && args[3] != "nil" ? args[3] : nil
        let wid = args.count >= 5 ? Int(args[4]) : nil
        let timeout = args.count >= 6 ? (Double(args[5]) ?? 5.0) : 5.0
        waitForText(targetText: text, windowId: wid, appName: app, timeoutSeconds: timeout)
    } else {
        printJson(["error": "Missing target text"])
        exit(1)
    }
case "click":
    if args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) {
        let button = args.count >= 5 ? args[4] : "left"
        let count = args.count >= 6 ? (Int(args[5]) ?? 1) : 1
        let pid = args.count >= 7 ? pid_t(args[6]) : nil
        dispatchMouseClick(x: x, y: y, button: button, count: count, targetPid: pid)
    } else {
        printJson(["error": "Invalid arguments for click"])
        exit(1)
    }
case "type_text":
    if args.count >= 3 {
        let text = args[2]
        let pid = args.count >= 4 ? pid_t(args[3]) : nil
        dispatchTypeText(text: text, targetPid: pid)
    } else {
        printJson(["error": "Missing text to type"])
        exit(1)
    }
case "scroll":
    if args.count >= 5, let x = Double(args[2]), let y = Double(args[3]), let dy = Int32(args[4]) {
        let dx = args.count >= 6 ? (Int32(args[5]) ?? 0) : 0
        let pid = args.count >= 7 ? pid_t(args[6]) : nil
        dispatchScroll(x: x, y: y, deltaY: dy, deltaX: dx, targetPid: pid)
    } else {
        printJson(["error": "Invalid arguments for scroll"])
        exit(1)
    }
case "mark_cursor":
    if args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) {
        let path = args[2]
        let dispWidth = args.count >= 6 ? (Double(args[5]) ?? 1800.0) : 1800.0
        markCursor(imagePath: path, x: x, y: y, displayWidth: dispWidth)
    } else {
        printJson(["error": "Invalid arguments for mark_cursor"])
        exit(1)
    }
default:
    printJson(["error": "Unknown command \(command)"])
    exit(1)
}
