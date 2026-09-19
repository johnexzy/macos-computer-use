import Foundation

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
        let matchMode = args.count >= 6 ? args[5] : "substring"
        findTextInWindow(targetText: text, windowId: wid, appName: app, matchMode: matchMode)
    } else {
        printJson(["error": "Missing target text"])
        exit(1)
    }
case "match_text":
    if args.count >= 4 {
        let source = args[2]
        let query = args[3]
        let matchMode = args.count >= 5 ? args[4] : "substring"
        let matches = queryRanges(in: source, query: query, matchMode: matchMode)
        printJson([
            "status": "ok",
            "count": matches.count,
            "types": matches.map { $0.type },
            "ranges": matches.map { ["location": $0.range.location, "length": $0.range.length] }
        ])
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Missing arguments for match_text"])
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
case "ax_click":
    if args.count >= 8,
       let x = Double(args[2]),
       let y = Double(args[3]),
       let pid = pid_t(args[6]),
       let wid = Int(args[7]) {
        let button = args[4]
        let count = Int(args[5]) ?? 1
        dispatchAccessibilityClick(
            x: x,
            y: y,
            button: button,
            count: count,
            targetPid: pid,
            windowId: wid
        )
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for ax_click"])
        exit(1)
    }
case "type_text":
    if args.count >= 3 {
        let text = args[2]
        let pid = args.count >= 4 ? pid_t(args[3]) : nil
        let wid = args.count >= 5 ? Int(args[4]) : nil
        dispatchTypeText(text: text, targetPid: pid, windowId: wid)
    } else {
        printJson(["error": "Missing text to type"])
        exit(1)
    }
case "press_key":
    if args.count >= 4,
       let keyCode = UInt16(args[2]),
       let modifiers = parseStringArray(args[3]) {
        dispatchKeyPress(keyCode: keyCode, modifiers: modifiers)
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for press_key"])
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
case "ax_scroll":
    if args.count >= 8,
       let x = Double(args[2]),
       let y = Double(args[3]),
       let dy = Int32(args[4]),
       let pid = pid_t(args[6]),
       let wid = Int(args[7]) {
        let dx = Int32(args[5]) ?? 0
        dispatchAccessibilityScroll(
            x: x,
            y: y,
            deltaY: dy,
            deltaX: dx,
            targetPid: pid,
            windowId: wid
        )
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for ax_scroll"])
        exit(1)
    }
case "ax_inspect":
    if args.count >= 5,
       let pid = pid_t(args[2]),
       let wid = Int(args[3]),
       let options = parseJSONObject(args[4]) {
        inspectAXElements(pid: pid, windowId: wid, options: options)
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for ax_inspect"])
        exit(1)
    }
case "ax_set_value":
    if args.count >= 6,
       let pid = pid_t(args[2]),
       let wid = Int(args[3]),
       let selector = parseJSONObject(args[4]) {
        setAXElementValue(pid: pid, windowId: wid, selector: selector, value: args[5])
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for ax_set_value"])
        exit(1)
    }
case "ax_perform":
    if args.count >= 6,
       let pid = pid_t(args[2]),
       let wid = Int(args[3]),
       let selector = parseJSONObject(args[4]) {
        performAXElementAction(
            pid: pid,
            windowId: wid,
            selector: selector,
            requestedAction: args[5]
        )
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for ax_perform"])
        exit(1)
    }
case "ax_key":
    if args.count >= 6,
       let pid = pid_t(args[2]),
       let wid = Int(args[3]),
       let selector = parseJSONObject(args[4]) {
        postAXKey(
            pid: pid,
            windowId: wid,
            selector: selector,
            requestedKey: args[5]
        )
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for ax_key"])
        exit(1)
    }
case "ax_type":
    if args.count >= 6,
       let pid = pid_t(args[2]),
       let wid = Int(args[3]),
       let selector = parseJSONObject(args[4]) {
        typeTextIntoAXElement(
            pid: pid,
            windowId: wid,
            selector: selector,
            text: args[5]
        )
    } else {
        printJson(["status": "error", "code": "INVALID_ARGUMENTS", "error": "Invalid arguments for ax_type"])
        exit(1)
    }
case "frontmost_app":
    printFrontmostApplication()
case "capabilities":
    printCapabilities()
case "mark_cursor":
    if args.count >= 5, let x = Double(args[3]), let y = Double(args[4]) {
        let path = args[2]
        let dispWidth = args.count >= 6 ? (Double(args[5]) ?? 1800.0) : 1800.0
        markCursor(imagePath: path, x: x, y: y, displayWidth: dispWidth)
    } else {
        printJson(["error": "Invalid arguments for mark_cursor"])
        exit(1)
    }
case "cursor_overlay":
    runCursorOverlay()
default:
    printJson(["error": "Unknown command \(command)"])
    exit(1)
}
