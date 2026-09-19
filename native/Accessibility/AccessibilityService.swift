import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

@_silgen_name("AXUIElementPostKeyboardEvent")
private func postKeyboardEventToApplication(
    _ application: AXUIElement,
    _ keyCharacter: UInt16,
    _ virtualKey: UInt16,
    _ keyDown: UInt8
) -> AXError

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
        "deltaX": deltaX,
        "deltaY": deltaY
    ])
}
