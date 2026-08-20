import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import ImageIO
import Vision

@_silgen_name("AXUIElementPostKeyboardEvent")
private func postKeyboardEventToApplication(
    _ application: AXUIElement,
    _ keyCharacter: UInt16,
    _ virtualKey: UInt16,
    _ keyDown: UInt8
) -> AXError

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

func copyAXAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
        return nil
    }
    return value
}

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = copyAXAttribute(element, kAXPositionAttribute as CFString),
          let sizeValue = copyAXAttribute(element, kAXSizeAttribute as CFString),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
        return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
        return nil
    }
    return CGRect(origin: position, size: size)
}

func axRole(_ element: AXUIElement) -> String {
    return copyAXAttribute(element, kAXRoleAttribute as CFString) as? String ?? ""
}

func isEditableAXElement(_ element: AXUIElement) -> Bool {
    let role = axRole(element)
    return role == kAXTextFieldRole as String
        || role == kAXTextAreaRole as String
        || role == "AXSearchField"
        || role == "AXComboBox"
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    return copyAXAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
}

func firstEditableElement(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 40 else { return nil }
    if isEditableAXElement(element) { return element }
    for child in axChildren(element) {
        if let editable = firstEditableElement(in: child, depth: depth + 1) {
            return editable
        }
    }
    return nil
}

func axElement(from value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

func windowMetadata(windowId: Int) -> (pid: pid_t, bounds: CGRect, appName: String, title: String)? {
    let options = CGWindowListOption(arrayLiteral: .optionAll)
    guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }

    for win in windowList where (win[kCGWindowNumber as String] as? Int) == windowId {
        let boundsDict = win[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let bounds = CGRect(
            x: boundsDict["X"] as? Double ?? 0,
            y: boundsDict["Y"] as? Double ?? 0,
            width: boundsDict["Width"] as? Double ?? 0,
            height: boundsDict["Height"] as? Double ?? 0
        )
        return (
            pid: win[kCGWindowOwnerPID as String] as? pid_t ?? 0,
            bounds: bounds,
            appName: win[kCGWindowOwnerName as String] as? String ?? "",
            title: win[kCGWindowName as String] as? String ?? ""
        )
    }
    return nil
}

func matchingAXWindow(pid: pid_t, windowId: Int) -> AXUIElement? {
    guard let metadata = windowMetadata(windowId: windowId), metadata.pid == pid else {
        return nil
    }

    let app = AXUIElementCreateApplication(pid)
    guard let windows = copyAXAttribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
        return nil
    }

    var best: (window: AXUIElement, score: Double)?
    for window in windows {
        guard let frame = axFrame(window) else { continue }
        let distance = abs(frame.origin.x - metadata.bounds.origin.x)
            + abs(frame.origin.y - metadata.bounds.origin.y)
            + abs(frame.size.width - metadata.bounds.size.width)
            + abs(frame.size.height - metadata.bounds.size.height)
        let title = copyAXAttribute(window, kAXTitleAttribute as CFString) as? String ?? ""
        let titlePenalty = !metadata.title.isEmpty && !title.isEmpty && title != metadata.title ? 20.0 : 0.0
        let score = distance + titlePenalty
        if best == nil || score < best!.score {
            best = (window, score)
        }
    }

    guard let best, best.score < 80.0 else { return nil }
    return best.window
}

@discardableResult
func focusAXWindow(pid: pid_t, windowId: Int) -> Bool {
    guard let window = matchingAXWindow(pid: pid, windowId: windowId) else {
        return false
    }

    let app = AXUIElementCreateApplication(pid)
    let focusedWindowResult = AXUIElementSetAttributeValue(
        app,
        kAXFocusedWindowAttribute as CFString,
        window
    )
    let mainResult = AXUIElementSetAttributeValue(
        window,
        kAXMainAttribute as CFString,
        kCFBooleanTrue
    )
    let focusedResult = AXUIElementSetAttributeValue(
        window,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )

    usleep(30000)
    let windowFrame = axFrame(window)
    let currentFocusedElement = axElement(
        from: copyAXAttribute(app, kAXFocusedUIElementAttribute as CFString)
    )
    let currentFocusIsUsable = currentFocusedElement.map { element in
        guard isEditableAXElement(element) else { return false }
        guard let windowFrame, let elementFrame = axFrame(element) else { return true }
        return windowFrame.intersects(elementFrame)
    } ?? false

    var editableFocusResult: AXError?
    if !currentFocusIsUsable, let editable = firstEditableElement(in: window) {
        editableFocusResult = AXUIElementSetAttributeValue(
            editable,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
    }

    return currentFocusIsUsable
        || editableFocusResult == .success
        || focusedWindowResult == .success
        || mainResult == .success
        || focusedResult == .success
}

func axActionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
}

func normalizedAXText(_ value: String) -> String {
    return value
        .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .unicodeScalars
        .filter { !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format }
        .map(String.init)
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
}

func axStringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String {
    guard let value = copyAXAttribute(element, attribute) else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
}

func axAttributeIsSettable(_ element: AXUIElement, _ attribute: CFString) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
}

func axSettableAttributeNames(_ element: AXUIElement) -> [String] {
    var rawNames: CFArray?
    guard AXUIElementCopyAttributeNames(element, &rawNames) == .success,
          let names = rawNames as? [String] else {
        return []
    }
    return names.filter { axAttributeIsSettable(element, $0 as CFString) }
}

func axElementSummary(
    _ element: AXUIElement,
    path: [Int],
    includeValue: Bool = false,
    includeSettableAttributes: Bool = false
) -> [String: Any] {
    let frame = axFrame(element)
    var summary: [String: Any] = [
        "path": path,
        "role": axRole(element),
        "subrole": axStringAttribute(element, kAXSubroleAttribute as CFString),
        "identifier": axStringAttribute(element, kAXIdentifierAttribute as CFString),
        "title": axStringAttribute(element, kAXTitleAttribute as CFString),
        "description": axStringAttribute(element, kAXDescriptionAttribute as CFString),
        "placeholder": axStringAttribute(element, kAXPlaceholderValueAttribute as CFString),
        "help": axStringAttribute(element, kAXHelpAttribute as CFString),
        "valueSettable": axAttributeIsSettable(element, kAXValueAttribute as CFString),
        "actions": axActionNames(element),
        "frame": frame.map {
            ["x": $0.origin.x, "y": $0.origin.y, "width": $0.size.width, "height": $0.size.height]
        } ?? [:]
    ]
    if includeValue {
        let value = axStringAttribute(element, kAXValueAttribute as CFString)
        summary["value"] = String(value.prefix(500))
    }
    if includeSettableAttributes {
        summary["settableAttributes"] = axSettableAttributeNames(element)
    }
    return summary
}

func axSelectorMatches(_ element: AXUIElement, selector: [String: Any]) -> Bool {
    if let role = selector["role"] as? String,
       !role.isEmpty,
       normalizedAXText(axRole(element)) != normalizedAXText(role) {
        return false
    }

    let identifier = axStringAttribute(element, kAXIdentifierAttribute as CFString)
    if let expected = selector["identifier"] as? String,
       !expected.isEmpty,
       normalizedAXText(identifier) != normalizedAXText(expected) {
        return false
    }

    let title = axStringAttribute(element, kAXTitleAttribute as CFString)
    if let expected = selector["title"] as? String,
       !expected.isEmpty,
       normalizedAXText(title) != normalizedAXText(expected) {
        return false
    }

    let description = axStringAttribute(element, kAXDescriptionAttribute as CFString)
    if let expected = selector["description"] as? String,
       !expected.isEmpty,
       normalizedAXText(description) != normalizedAXText(expected) {
        return false
    }

    if let query = selector["query"] as? String, !query.isEmpty {
        let needle = normalizedAXText(query)
        let candidates = [
            identifier,
            title,
            description,
            axStringAttribute(element, kAXPlaceholderValueAttribute as CFString),
            axStringAttribute(element, kAXHelpAttribute as CFString),
            axStringAttribute(element, kAXValueAttribute as CFString)
        ]
        if !candidates.contains(where: { normalizedAXText($0).contains(needle) }) {
            return false
        }
    }

    return true
}

func collectAXElements(
    from root: AXUIElement,
    selector: [String: Any],
    roles: Set<String>,
    maxDepth: Int,
    maxResults: Int
) -> [(element: AXUIElement, path: [Int])] {
    var results: [(element: AXUIElement, path: [Int])] = []

    func visit(_ element: AXUIElement, path: [Int], depth: Int) {
        guard depth <= maxDepth, results.count < maxResults else { return }
        let role = normalizedAXText(axRole(element))
        let roleAllowed = roles.isEmpty || roles.contains(role)
        if roleAllowed && axSelectorMatches(element, selector: selector) {
            results.append((element, path))
        }
        for (index, child) in axChildren(element).enumerated() {
            visit(child, path: path + [index], depth: depth + 1)
            if results.count >= maxResults { return }
        }
    }

    visit(root, path: [], depth: 0)
    return results
}

func parseJSONObject(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        return nil
    }
    return dictionary
}

func parseStringArray(_ raw: String) -> [String]? {
    guard let data = raw.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let values = object as? [String] else {
        return nil
    }
    return values
}

func resolvedAXWindow(pid: pid_t, windowId: Int) -> AXUIElement? {
    guard AXIsProcessTrusted() else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_PERMISSION_REQUIRED",
            "error": "Accessibility permission is required"
        ])
        return nil
    }
    guard let window = matchingAXWindow(pid: pid, windowId: windowId) else {
        printJson([
            "status": "error",
            "code": "TARGET_NOT_FOUND",
            "error": "Could not resolve AX window for windowId \(windowId)"
        ])
        return nil
    }
    return window
}

func inspectAXElements(pid: pid_t, windowId: Int, options: [String: Any]) {
    guard let window = resolvedAXWindow(pid: pid, windowId: windowId) else { return }
    let selector = options["selector"] as? [String: Any] ?? [:]
    let roles = Set((options["roles"] as? [String] ?? []).map(normalizedAXText))
    let maxDepth = min(50, max(1, options["maxDepth"] as? Int ?? 30))
    let maxResults = min(500, max(1, options["maxResults"] as? Int ?? 100))
    let includeValues = options["includeValues"] as? Bool ?? false
    let includeSettableAttributes = options["includeSettableAttributes"] as? Bool ?? false
    let matches = collectAXElements(
        from: window,
        selector: selector,
        roles: roles,
        maxDepth: maxDepth,
        maxResults: maxResults
    )
    printJson([
        "status": "ok",
        "pid": pid,
        "windowId": windowId,
        "elements": matches.map {
            axElementSummary(
                $0.element,
                path: $0.path,
                includeValue: includeValues,
                includeSettableAttributes: includeSettableAttributes
            )
        }
    ])
}

func resolveSelectedAXElement(
    pid: pid_t,
    windowId: Int,
    selector: [String: Any]
) -> (element: AXUIElement, path: [Int])? {
    guard let window = resolvedAXWindow(pid: pid, windowId: windowId) else { return nil }
    let occurrence = max(1, selector["occurrence"] as? Int ?? 1)
    let matches = collectAXElements(
        from: window,
        selector: selector,
        roles: [],
        maxDepth: 40,
        maxResults: occurrence
    )
    guard matches.count >= occurrence else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_ELEMENT_NOT_FOUND",
            "error": "No Accessibility element matched the selector",
            "selector": selector
        ])
        return nil
    }
    return matches[occurrence - 1]
}

func setAXElementValue(pid: pid_t, windowId: Int, selector: [String: Any], value: String) {
    guard let match = resolveSelectedAXElement(pid: pid, windowId: windowId, selector: selector) else {
        return
    }
    guard axAttributeIsSettable(match.element, kAXValueAttribute as CFString) else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_VALUE_NOT_SETTABLE",
            "error": "The matched Accessibility element does not expose a settable value",
            "element": axElementSummary(match.element, path: match.path)
        ])
        return
    }
    let result = AXUIElementSetAttributeValue(
        match.element,
        kAXValueAttribute as CFString,
        value as CFString
    )
    guard result == .success else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_VALUE_FAILED",
            "error": "Setting AXValue failed with code \(result.rawValue)"
        ])
        return
    }
    let resultingValue = axStringAttribute(match.element, kAXValueAttribute as CFString)
    guard resultingValue == value else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_VALUE_UNCONFIRMED",
            "error": "The matched Accessibility element did not retain the requested value"
        ])
        return
    }
    printJson([
        "status": "ok",
        "action": "AXSetValue",
        "verified": true,
        "pid": pid,
        "windowId": windowId,
        "element": axElementSummary(match.element, path: match.path)
    ])
}

func performAXElementAction(
    pid: pid_t,
    windowId: Int,
    selector: [String: Any],
    requestedAction: String
) {
    guard let match = resolveSelectedAXElement(pid: pid, windowId: windowId, selector: selector) else {
        return
    }
    if normalizedAXText(requestedAction) == "focus" {
        let result = AXUIElementSetAttributeValue(
            match.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard result == .success else {
            printJson([
                "status": "error",
                "code": "ACCESSIBILITY_FOCUS_FAILED",
                "error": "Setting AXFocused failed with code \(result.rawValue)"
            ])
            return
        }
        printJson([
            "status": "ok",
            "action": "AXFocus",
            "pid": pid,
            "windowId": windowId,
            "element": axElementSummary(match.element, path: match.path)
        ])
        return
    }
    let actionMap = [
        "press": kAXPressAction as String,
        "confirm": kAXConfirmAction as String,
        "cancel": kAXCancelAction as String,
        "increment": kAXIncrementAction as String,
        "decrement": kAXDecrementAction as String,
        "show_menu": kAXShowMenuAction as String
    ]
    guard let action = actionMap[normalizedAXText(requestedAction)] else {
        printJson([
            "status": "error",
            "code": "UNSUPPORTED_ACCESSIBILITY_ACTION",
            "error": "Unsupported Accessibility action \(requestedAction)"
        ])
        return
    }
    let supported = axActionNames(match.element)
    guard supported.contains(action) else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_ACTION_UNSUPPORTED",
            "error": "The matched element does not support \(action)",
            "element": axElementSummary(match.element, path: match.path)
        ])
        return
    }
    let result = AXUIElementPerformAction(match.element, action as CFString)
    guard result == .success else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_ACTION_FAILED",
            "error": "\(action) failed with code \(result.rawValue)"
        ])
        return
    }
    printJson([
        "status": "ok",
        "action": action,
        "pid": pid,
        "windowId": windowId,
        "element": axElementSummary(match.element, path: match.path)
    ])
}

func postAXKey(
    pid: pid_t,
    windowId: Int,
    selector: [String: Any],
    requestedKey: String
) {
    guard let match = resolveSelectedAXElement(pid: pid, windowId: windowId, selector: selector) else {
        return
    }
    guard isEditableAXElement(match.element) else {
        printJson([
            "status": "error",
            "code": "BACKGROUND_KEY_TARGET_NOT_EDITABLE",
            "error": "Background key delivery requires an editable Accessibility element"
        ])
        return
    }
    let keyMap: [String: CGKeyCode] = [
        "return": 36,
        "enter": 36,
        "escape": 53,
        "esc": 53,
        "tab": 48,
        "space": 49,
        "backspace": 51,
        "up": 126,
        "down": 125,
        "left": 123,
        "right": 124
    ]
    guard let key = keyMap[normalizedAXText(requestedKey)] else {
        printJson([
            "status": "error",
            "code": "UNSUPPORTED_BACKGROUND_KEY",
            "error": "Unsupported background key \(requestedKey)"
        ])
        return
    }

    let focusResult = AXUIElementSetAttributeValue(
        match.element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    guard focusResult == .success else {
        printJson([
            "status": "error",
            "code": "BACKGROUND_KEY_FOCUS_FAILED",
            "error": "Could not focus the target Accessibility element without activation"
        ])
        return
    }

    let beforePid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let characterMap: [String: UInt16] = [
        "return": 13,
        "enter": 13,
        "escape": 27,
        "esc": 27,
        "tab": 9,
        "space": 32,
        "backspace": 8,
        "up": 0,
        "down": 0,
        "left": 0,
        "right": 0
    ]
    let application = AXUIElementCreateApplication(pid)
    let character = characterMap[normalizedAXText(requestedKey)] ?? 0
    let down = postKeyboardEventToApplication(application, character, key, 1)
    usleep(20000)
    let up = postKeyboardEventToApplication(application, character, key, 0)
    usleep(120000)
    let afterPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    guard down == .success, up == .success else {
        printJson([
            "status": "error",
            "code": "BACKGROUND_KEY_DELIVERY_FAILED",
            "error": "Application-targeted key delivery failed with codes \(down.rawValue) and \(up.rawValue)"
        ])
        return
    }
    guard beforePid == pid || afterPid != pid else {
        printJson([
            "status": "error",
            "code": "FOREGROUND_CHANGED",
            "error": "The background key operation activated the target application"
        ])
        return
    }
    printJson([
        "status": "ok",
        "action": "AXPostKeyboardEvent",
        "key": requestedKey,
        "pid": pid,
        "windowId": windowId,
        "foregroundPreserved": beforePid == afterPid
    ])
}

func typeTextIntoAXElement(
    pid: pid_t,
    windowId: Int,
    selector: [String: Any],
    text: String
) {
    guard let match = resolveSelectedAXElement(pid: pid, windowId: windowId, selector: selector) else {
        return
    }
    guard isEditableAXElement(match.element) else {
        printJson([
            "status": "error",
            "code": "BACKGROUND_TYPE_TARGET_NOT_EDITABLE",
            "error": "Background typing requires an editable Accessibility element"
        ])
        return
    }
    let focusResult = AXUIElementSetAttributeValue(
        match.element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    guard focusResult == .success else {
        printJson([
            "status": "error",
            "code": "BACKGROUND_TYPE_FOCUS_FAILED",
            "error": "Could not focus the target Accessibility element without activation"
        ])
        return
    }

    let beforePid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let application = AXUIElementCreateApplication(pid)
    for character in text.utf16 {
        let down = postKeyboardEventToApplication(application, character, 0, 1)
        let up = postKeyboardEventToApplication(application, character, 0, 0)
        guard down == .success, up == .success else {
            printJson([
                "status": "error",
                "code": "BACKGROUND_TYPE_DELIVERY_FAILED",
                "error": "Application-targeted text delivery failed with codes \(down.rawValue) and \(up.rawValue)"
            ])
            return
        }
    }
    usleep(180000)
    let afterPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    guard beforePid == pid || afterPid != pid else {
        printJson([
            "status": "error",
            "code": "FOREGROUND_CHANGED",
            "error": "The background typing operation activated the target application"
        ])
        return
    }
    let resultingValue = axStringAttribute(match.element, kAXValueAttribute as CFString)
    guard resultingValue.contains(text) else {
        printJson([
            "status": "error",
            "code": "BACKGROUND_TYPE_NOT_DELIVERED",
            "error": "The target application did not accept application-targeted text input"
        ])
        return
    }
    printJson([
        "status": "ok",
        "action": "AXPostKeyboardText",
        "pid": pid,
        "windowId": windowId,
        "characters": text.count,
        "foregroundPreserved": beforePid == afterPid
    ])
}

func printFrontmostApplication() {
    guard let application = NSWorkspace.shared.frontmostApplication else {
        printJson(["status": "error", "code": "FRONTMOST_APP_UNAVAILABLE"])
        return
    }
    printJson([
        "status": "ok",
        "pid": application.processIdentifier,
        "appName": application.localizedName ?? "",
        "bundleIdentifier": application.bundleIdentifier ?? ""
    ])
}

func actionableElement(at point: CGPoint, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 40 else { return nil }
    if depth > 0, let frame = axFrame(element), !frame.contains(point) {
        return nil
    }

    for child in axChildren(element).reversed() {
        if let match = actionableElement(at: point, in: child, depth: depth + 1) {
            return match
        }
    }

    let actions = axActionNames(element)
    let role = axRole(element)
    if actions.contains(kAXPressAction as String)
        || role == kAXTextFieldRole as String
        || role == kAXTextAreaRole as String
        || role == "AXSearchField" {
        return element
    }
    return nil
}

func dispatchAccessibilityClick(
    x: Double,
    y: Double,
    button: String,
    count: Int,
    targetPid: pid_t,
    windowId: Int
) {
    guard button == "left" else {
        printJson([
            "status": "error",
            "code": "UNSUPPORTED_TARGETING",
            "error": "Background Accessibility clicks support only the left button"
        ])
        return
    }
    guard AXIsProcessTrusted() else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_PERMISSION_REQUIRED",
            "error": "Accessibility permission is required"
        ])
        return
    }
    guard let window = matchingAXWindow(pid: targetPid, windowId: windowId) else {
        printJson([
            "status": "error",
            "code": "TARGET_NOT_FOUND",
            "error": "Could not resolve AX window for windowId \(windowId)"
        ])
        return
    }
    guard let element = actionableElement(at: CGPoint(x: x, y: y), in: window) else {
        printJson([
            "status": "error",
            "code": "ACTIONABLE_ELEMENT_NOT_FOUND",
            "error": "No actionable Accessibility element exists at (\(x), \(y))"
        ])
        return
    }

    let actions = axActionNames(element)
    let role = axRole(element)
    if actions.contains(kAXPressAction as String) {
        for _ in 0..<max(1, count) {
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result != .success {
                printJson([
                    "status": "error",
                    "code": "ACTION_FAILED",
                    "error": "AXPress failed with code \(result.rawValue)"
                ])
                return
            }
        }
        printJson([
            "status": "ok",
            "method": "accessibility",
            "action": "AXPress",
            "role": role,
            "windowId": windowId,
            "pid": targetPid,
            "x": x,
            "y": y
        ])
        return
    }

    let focusResult = AXUIElementSetAttributeValue(
        element,
        kAXFocusedAttribute as CFString,
        kCFBooleanTrue
    )
    if focusResult == .success {
        printJson([
            "status": "ok",
            "method": "accessibility",
            "action": "AXFocus",
            "role": role,
            "windowId": windowId,
            "pid": targetPid,
            "x": x,
            "y": y
        ])
    } else {
        printJson([
            "status": "error",
            "code": "ACTION_FAILED",
            "error": "AX focus failed with code \(focusResult.rawValue)"
        ])
    }
}

func scrollArea(at point: CGPoint, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    guard depth < 40 else { return nil }
    if depth > 0, let frame = axFrame(element), !frame.contains(point) {
        return nil
    }
    for child in axChildren(element).reversed() {
        if let match = scrollArea(at: point, in: child, depth: depth + 1) {
            return match
        }
    }
    return axRole(element) == kAXScrollAreaRole as String ? element : nil
}

func adjustAXScrollbar(_ scrollArea: AXUIElement, attribute: CFString, delta: Int32) -> Bool {
    guard delta != 0,
          let rawScrollbar = copyAXAttribute(scrollArea, attribute),
          CFGetTypeID(rawScrollbar) == AXUIElementGetTypeID() else {
        return false
    }
    let scrollbar = unsafeBitCast(rawScrollbar, to: AXUIElement.self)
    guard let currentValue = copyAXAttribute(scrollbar, kAXValueAttribute as CFString) as? NSNumber else {
        return false
    }

    let magnitude = min(1.0, max(0.08, Double(abs(delta)) / 1000.0))
    let direction = delta < 0 ? 1.0 : -1.0
    let nextValue = min(1.0, max(0.0, currentValue.doubleValue + (direction * magnitude)))
    return AXUIElementSetAttributeValue(
        scrollbar,
        kAXValueAttribute as CFString,
        NSNumber(value: nextValue)
    ) == .success
}

func dispatchAccessibilityScroll(
    x: Double,
    y: Double,
    deltaY: Int32,
    deltaX: Int32,
    targetPid: pid_t,
    windowId: Int
) {
    guard AXIsProcessTrusted() else {
        printJson([
            "status": "error",
            "code": "ACCESSIBILITY_PERMISSION_REQUIRED",
            "error": "Accessibility permission is required"
        ])
        return
    }
    guard let window = matchingAXWindow(pid: targetPid, windowId: windowId),
          let area = scrollArea(at: CGPoint(x: x, y: y), in: window) else {
        printJson([
            "status": "error",
            "code": "SCROLL_AREA_NOT_FOUND",
            "error": "No Accessibility scroll area exists at (\(x), \(y))"
        ])
        return
    }

    let verticalChanged = adjustAXScrollbar(area, attribute: kAXVerticalScrollBarAttribute as CFString, delta: deltaY)
    let horizontalChanged = adjustAXScrollbar(area, attribute: kAXHorizontalScrollBarAttribute as CFString, delta: deltaX)
    guard verticalChanged || horizontalChanged else {
        printJson([
            "status": "error",
            "code": "ACTION_NO_EFFECT",
            "error": "The target scroll area did not expose a settable scrollbar"
        ])
        return
    }

    printJson([
        "status": "ok",
        "method": "accessibility",
        "action": "AXSetScrollbarValue",
        "windowId": windowId,
        "pid": targetPid,
        "x": x,
        "y": y,
        "deltaY": deltaY,
        "deltaX": deltaX
    ])
}

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

// -------------------------------------------------------------------------
// Agent Cursor (Live click-through overlay and matching screenshot marker)
// -------------------------------------------------------------------------

enum AgentCursorFeedback {
    case idle
    case click
    case scroll
    case error
}

func drawAgentCursor(
    context: CGContext,
    tip: CGPoint,
    scale: CGFloat = 1.0,
    feedback: AgentCursorFeedback = .idle,
    feedbackProgress: CGFloat = 0.0
) {
    context.saveGState()
    context.setLineJoin(.round)
    context.setLineCap(.round)

    let arrow = CGMutablePath()
    arrow.move(to: tip)
    arrow.addLine(to: CGPoint(x: tip.x, y: tip.y - (34 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (9 * scale), y: tip.y - (25 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (16 * scale), y: tip.y - (42 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (24 * scale), y: tip.y - (38 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (16 * scale), y: tip.y - (22 * scale)))
    arrow.addLine(to: CGPoint(x: tip.x + (31 * scale), y: tip.y - (22 * scale)))
    arrow.closeSubpath()

    context.setShadow(
        offset: CGSize(width: 0, height: -2 * scale),
        blur: 4 * scale,
        color: CGColor(gray: 0, alpha: 0.28)
    )
    context.addPath(arrow)
    context.setFillColor(CGColor(red: 0.98, green: 0.99, blue: 1.0, alpha: 1.0))
    context.setStrokeColor(CGColor(red: 0.04, green: 0.07, blue: 0.14, alpha: 1.0))
    context.setLineWidth(2.6 * scale)
    context.drawPath(using: .fillStroke)
    context.setShadow(offset: .zero, blur: 0, color: nil)

    let badgeCenter = CGPoint(x: tip.x + (30 * scale), y: tip.y - (37 * scale))
    let badgeRadius = 9.5 * scale
    let badgeRect = CGRect(
        x: badgeCenter.x - badgeRadius,
        y: badgeCenter.y - badgeRadius,
        width: badgeRadius * 2,
        height: badgeRadius * 2
    )
    let badgeColor = feedback == .error
        ? CGColor(red: 0.95, green: 0.20, blue: 0.25, alpha: 1.0)
        : CGColor(red: 0.10, green: 0.55, blue: 1.0, alpha: 1.0)
    context.setFillColor(badgeColor)
    context.fillEllipse(in: badgeRect)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    context.setLineWidth(1.5 * scale)
    context.strokeEllipse(in: badgeRect)

    let spark = CGMutablePath()
    spark.move(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y + (5 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x + (1.7 * scale), y: badgeCenter.y + (1.7 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x + (5 * scale), y: badgeCenter.y))
    spark.addLine(to: CGPoint(x: badgeCenter.x + (1.7 * scale), y: badgeCenter.y - (1.7 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y - (5 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x - (1.7 * scale), y: badgeCenter.y - (1.7 * scale)))
    spark.addLine(to: CGPoint(x: badgeCenter.x - (5 * scale), y: badgeCenter.y))
    spark.addLine(to: CGPoint(x: badgeCenter.x - (1.7 * scale), y: badgeCenter.y + (1.7 * scale)))
    spark.closeSubpath()
    context.addPath(spark)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()

    if feedback == .click || feedback == .error {
        let progress = min(1, max(0, feedbackProgress))
        let radius = (12 + (14 * progress)) * scale
        context.setStrokeColor(
            feedback == .error
                ? CGColor(red: 1.0, green: 0.18, blue: 0.22, alpha: 1.0 - progress)
                : CGColor(red: 0.10, green: 0.65, blue: 1.0, alpha: 1.0 - progress)
        )
        context.setLineWidth(2.5 * scale)
        context.strokeEllipse(
            in: CGRect(
                x: tip.x - radius,
                y: tip.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
    } else if feedback == .scroll {
        context.setStrokeColor(CGColor(red: 0.10, green: 0.65, blue: 1.0, alpha: 0.95))
        context.setLineWidth(2.5 * scale)
        for offset in [CGFloat(-5), CGFloat(5)] {
            let chevron = CGMutablePath()
            let centerY = tip.y - (45 * scale) + (offset * scale)
            chevron.move(to: CGPoint(x: tip.x + (43 * scale), y: centerY + (3 * scale)))
            chevron.addLine(to: CGPoint(x: tip.x + (47 * scale), y: centerY - (1 * scale)))
            chevron.addLine(to: CGPoint(x: tip.x + (51 * scale), y: centerY + (3 * scale)))
            context.addPath(chevron)
            context.strokePath()
        }
    }

    context.restoreGState()
}

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
    
    drawAgentCursor(context: ctx, tip: center, scale: scale)
    
    guard let newImage = ctx.makeImage() else {
        printJson(["error": "Could not finalize image"])
        return
    }
    
    let destUrl = URL(fileURLWithPath: imagePath)
    let isPNG = destUrl.pathExtension.lowercased() == "png"
    let destinationType = isPNG ? "public.png" : "public.jpeg"
    if let dest = CGImageDestinationCreateWithURL(destUrl as CFURL, destinationType as CFString, 1, nil) {
        let options: [CFString: Any] = isPNG
            ? [:]
            : [kCGImageDestinationLossyCompressionQuality: 0.88]
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

func normalizedText(_ text: String) -> String {
    return text.folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
    )
}

func isWordCodeUnit(_ value: unichar) -> Bool {
    guard let scalar = UnicodeScalar(value) else { return false }
    return CharacterSet.alphanumerics.contains(scalar) || value == 95
}

func queryRanges(in text: String, query: String, matchMode: String) -> [(range: NSRange, type: String, rank: Int)] {
    let source = text as NSString
    let queryLength = (query as NSString).length
    guard queryLength > 0 else { return [] }

    var results: [(range: NSRange, type: String, rank: Int)] = []
    var searchRange = NSRange(location: 0, length: source.length)
    while searchRange.length >= queryLength {
        let found = source.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: searchRange
        )
        if found.location == NSNotFound { break }

        let isExact = found.location == 0
            && found.length == source.length
            && normalizedText(text) == normalizedText(query)
        let beforeIsWord = found.location > 0 && isWordCodeUnit(source.character(at: found.location - 1))
        let afterIndex = found.location + found.length
        let afterIsWord = afterIndex < source.length && isWordCodeUnit(source.character(at: afterIndex))
        let isWord = !beforeIsWord && !afterIsWord
        let isPrefix = found.location == 0

        let matchType: String
        let rank: Int
        if isExact {
            matchType = "exact"
            rank = 4
        } else if isWord {
            matchType = "word"
            rank = 3
        } else if isPrefix {
            matchType = "prefix"
            rank = 2
        } else {
            matchType = "substring"
            rank = 1
        }

        let accepted: Bool
        switch matchMode {
        case "exact":
            accepted = isExact
        case "word":
            accepted = isExact || isWord
        case "prefix":
            accepted = isExact || isPrefix
        default:
            accepted = true
        }
        if accepted {
            results.append((found, matchType, rank))
        }

        let nextLocation = found.location + max(1, found.length)
        if nextLocation >= source.length { break }
        searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
    }
    return results
}

func findTextInWindow(
    targetText: String,
    windowId: Int? = nil,
    appName: String? = nil,
    matchMode: String = "substring"
) {
    var wid = windowId
    var pid: pid_t = 0
    var windowBounds: [String: Double]? = nil
    
    if let w = wid {
        guard let metadata = windowMetadata(windowId: w) else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "Window ID \(w) not found"
            ])
            return
        }
        if let app = appName,
           !metadata.appName.localizedCaseInsensitiveContains(app),
           !metadata.title.localizedCaseInsensitiveContains(app) {
            printJson([
                "status": "error",
                "code": "TARGET_MISMATCH",
                "error": "Window ID \(w) does not belong to \(app)"
            ])
            return
        }
        pid = metadata.pid
        windowBounds = [
            "x": metadata.bounds.origin.x,
            "y": metadata.bounds.origin.y,
            "width": metadata.bounds.size.width,
            "height": metadata.bounds.size.height
        ]
    } else if let app = appName {
        if let target = findTargetWindowInfo(targetApp: app) {
            wid = target.wid
            pid = target.pid
            windowBounds = target.bounds
        } else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "No window found matching \(app)"
            ])
            return
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
    do {
        try proc.run()
    } catch {
        printJson(["status": "error", "code": "CAPTURE_FAILED", "error": error.localizedDescription])
        return
    }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: tmpFile) else {
        printJson([
            "status": "error",
            "code": "CAPTURE_FAILED",
            "error": "screencapture exited with status \(proc.terminationStatus)"
        ])
        return
    }
    
    defer {
        try? FileManager.default.removeItem(atPath: tmpFile)
    }
    
    let elements = recognizeTextInImage(imagePath: tmpFile, logicalWidth: windowBounds?["width"])
    
    var matches: [[String: Any]] = []
    for item in elements {
        let text = item["text"] as? String ?? ""
        let ranges = queryRanges(in: text, query: targetText, matchMode: matchMode)
        for queryMatch in ranges {
            var itemCopy = item
            if let lineBounds = item["bounds"] as? [String: Double] {
                let sourceLength = max(1, (text as NSString).length)
                let startFraction = Double(queryMatch.range.location) / Double(sourceLength)
                let widthFraction = Double(queryMatch.range.length) / Double(sourceLength)
                let matchX = (lineBounds["x"] ?? 0) + ((lineBounds["width"] ?? 0) * startFraction)
                let matchWidth = (lineBounds["width"] ?? 0) * widthFraction
                let matchBounds: [String: Double] = [
                    "x": matchX,
                    "y": lineBounds["y"] ?? 0,
                    "width": matchWidth,
                    "height": lineBounds["height"] ?? 0,
                    "centerX": matchX + (matchWidth / 2.0),
                    "centerY": lineBounds["centerY"] ?? 0
                ]
                itemCopy["lineBounds"] = lineBounds
                itemCopy["bounds"] = matchBounds
                itemCopy["matchedText"] = (text as NSString).substring(with: queryMatch.range)
                itemCopy["matchType"] = queryMatch.type
                itemCopy["matchRank"] = queryMatch.rank
                itemCopy["querySimilarity"] = min(1.0, Double(queryMatch.range.length) / Double(sourceLength))

                if let winB = windowBounds {
                    let globalCenterX = (matchBounds["centerX"] ?? 0) + (winB["x"] ?? 0)
                    let globalCenterY = (matchBounds["centerY"] ?? 0) + (winB["y"] ?? 0)
                    itemCopy["globalCoordinates"] = [
                        "x": globalCenterX,
                        "y": globalCenterY
                    ]
                }
            }
            if windowBounds == nil,
               let bounds = itemCopy["bounds"] as? [String: Double] {
                itemCopy["globalCoordinates"] = [
                    "x": bounds["centerX"] ?? 0,
                    "y": bounds["centerY"] ?? 0
                ]
            }
            matches.append(itemCopy)
        }
    }

    matches.sort { lhs, rhs in
        let lhsRank = lhs["matchRank"] as? Int ?? 0
        let rhsRank = rhs["matchRank"] as? Int ?? 0
        if lhsRank != rhsRank { return lhsRank > rhsRank }
        return (lhs["confidence"] as? Float ?? 0) > (rhs["confidence"] as? Float ?? 0)
    }
    
    if let best = matches.first {
        printJson([
            "status": "ok",
            "found": true,
            "bestMatch": best,
            "allMatches": matches,
            "windowId": wid ?? 0,
            "pid": pid,
            "matchMode": matchMode,
            "windowBounds": windowBounds ?? [:]
        ])
    } else {
        printJson([
            "status": "ok",
            "found": false,
            "error": "Text '\(targetText)' not found",
            "windowId": wid ?? 0,
            "pid": pid,
            "matchMode": matchMode,
            "availableText": elements.prefix(15).map { $0["text"] ?? "" }
        ])
    }
}

func waitForText(targetText: String, windowId: Int? = nil, appName: String? = nil, timeoutSeconds: Double = 5.0) {
    let start = CFAbsoluteTimeGetCurrent()
    var wid = windowId
    var pid: pid_t = 0
    var windowBounds: [String: Double]? = nil
    
    if let w = wid {
        guard let metadata = windowMetadata(windowId: w) else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "Window ID \(w) not found"
            ])
            return
        }
        if let app = appName,
           !metadata.appName.localizedCaseInsensitiveContains(app),
           !metadata.title.localizedCaseInsensitiveContains(app) {
            printJson([
                "status": "error",
                "code": "TARGET_MISMATCH",
                "error": "Window ID \(w) does not belong to \(app)"
            ])
            return
        }
        pid = metadata.pid
        windowBounds = [
            "x": metadata.bounds.origin.x,
            "y": metadata.bounds.origin.y,
            "width": metadata.bounds.size.width,
            "height": metadata.bounds.size.height
        ]
    } else if let app = appName {
        if let target = findTargetWindowInfo(targetApp: app) {
            wid = target.wid
            pid = target.pid
            windowBounds = target.bounds
        } else {
            printJson([
                "status": "error",
                "code": "TARGET_NOT_FOUND",
                "error": "No window found matching \(app)"
            ])
            return
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
        do {
            try proc.run()
        } catch {
            printJson(["status": "error", "code": "CAPTURE_FAILED", "error": error.localizedDescription])
            return
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: tmpFile) else {
            printJson([
                "status": "error",
                "code": "CAPTURE_FAILED",
                "error": "screencapture exited with status \(proc.terminationStatus)"
            ])
            return
        }
        
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
