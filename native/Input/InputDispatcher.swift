import Foundation
import CoreGraphics
import AppKit

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

func dispatchKeyPress(keyCode: CGKeyCode, modifiers: [String]) {
    var flags = CGEventFlags()
    for modifier in modifiers.map(normalizedAXText) {
        switch modifier {
        case "command", "cmd": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "option", "alt": flags.insert(.maskAlternate)
        case "control", "ctrl": flags.insert(.maskControl)
        default:
            printJson([
                "status": "error",
                "code": "UNSUPPORTED_MODIFIER",
                "error": "Unsupported modifier \(modifier)"
            ])
            return
        }
    }

    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
        printJson([
            "status": "error",
            "code": "ACTION_FAILED",
            "error": "Could not create keyboard events"
        ])
        return
    }
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    usleep(20000)
    up.post(tap: .cghidEventTap)
    printJson([
        "status": "ok",
        "action": "press_key",
        "keyCode": keyCode,
        "modifiers": modifiers,
        "method": "global_core_graphics"
    ])
}

func dispatchTypeText(text: String, targetPid: pid_t? = nil, windowId: Int? = nil) {
    if let pid = targetPid, pid > 0, let wid = windowId {
        guard focusAXWindow(pid: pid, windowId: wid) else {
            printJson([
                "status": "error",
                "code": "WINDOW_TARGETING_UNSUPPORTED",
                "error": "Could not focus AX window for windowId \(wid)"
            ])
            return
        }
        usleep(40000)
    }

    let utf16Chars = Array(text.utf16)
    
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
        printJson([
            "status": "error",
            "code": "ACTION_FAILED",
            "error": "Could not create keyboard event"
        ])
        return
    }
    
    down.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
    up.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
    
    if let pid = targetPid, pid > 0 {
        down.postToPid(pid)
        usleep(20000)
        up.postToPid(pid)
        usleep(120000)
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
        "windowId": windowId ?? 0,
        "method": (targetPid ?? 0) > 0 ? "accessibility_focus_then_process_event" : "global_event",
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
