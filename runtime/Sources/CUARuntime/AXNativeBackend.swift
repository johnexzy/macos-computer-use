import ApplicationServices
import CUAProtocol
import Foundation

public final class NativeAXObject: AXObject, @unchecked Sendable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
}

struct AXScrollbar: Sendable {
    let object: any AXObject
    let position: Double
}

protocol AXScrolling: AXMutating {
    func scrollbar(in area: any AXObject, axis: Axis, context: OperationContext) throws -> AXScrollbar?
    func setScrollPosition(_ position: Double, on scrollbar: any AXObject, context: OperationContext,
                           willDispatch: @Sendable () throws -> Void) throws
}

func readAXActionNames(_ element: AXUIElement, context: OperationContext) throws -> [String] {
    var names: CFArray?
    let result = AXUIElementCopyActionNames(element, &names)
    try checkAXRead(result, context: context, allowMissing: true)
    return result == .success ? (names as? [String] ?? []) : []
}

func boundedAXActionNames(_ actions: [String]) -> [String] {
    let limit = 32
    guard actions.count > limit else { return actions }
    let priority = [
        kAXPressAction as String,
        "AXScrollToVisible",
        kAXConfirmAction as String,
        kAXShowMenuAction as String,
        kAXCancelAction as String,
    ].filter { actions.contains($0) }
    var selected: [String] = []
    for name in priority where !selected.contains(name) { selected.append(name) }
    for name in actions where !selected.contains(name) {
        if selected.count == limit { break }
        selected.append(name)
    }
    return selected
}

private final class BrowserAccessibilityRegistry: @unchecked Sendable {
    static let shared = BrowserAccessibilityRegistry()
    private static let chromiumBrowserBundles: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "org.chromium.Chromium",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "company.thebrowser.dia",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.kagi.kagimacOS",
    ]
    private let lock = NSLock()
    private var preparedPIDs: Set<UInt32> = []

    static func isChromiumBrowser(_ bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return chromiumBrowserBundles.contains(bundleId)
    }

    func alreadyPrepared(_ pid: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return preparedPIDs.contains(pid)
    }

    func markPrepared(_ pid: UInt32) {
        lock.lock(); defer { lock.unlock() }
        if preparedPIDs.count >= 64 { preparedPIDs.removeAll(keepingCapacity: true) }
        preparedPIDs.insert(pid)
    }
}

public struct MacOSAXBackend: AXReading, AXScrolling {
    public init() {}
    public func prepareBrowserAccessibility(application: any AXObject, bundleId: String?, context: OperationContext) throws -> Bool {
        try context.check()
        guard BrowserAccessibilityRegistry.isChromiumBrowser(bundleId) else { return false }
        let pid = try ownerPID(of: application, context: context)
        if BrowserAccessibilityRegistry.shared.alreadyPrepared(pid) { return false }
        let app = try prepared(application, context: context)
        var current: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &current)
        if readResult == .success, let flag = current as? NSNumber, flag.boolValue {
            BrowserAccessibilityRegistry.shared.markPrepared(pid)
            return false
        }
        let setResult = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        // Chromium's BrowserCrApplication enables full web accessibility on AXEnhancedUserInterface
        // and may return .success or .notImplemented/.attributeUnsupported.
        switch setResult {
        case .success, .notImplemented, .attributeUnsupported:
            BrowserAccessibilityRegistry.shared.markPrepared(pid)
            return true
        default:
            try checkAXRead(setResult, context: context, allowMissing: true)
            return false
        }
    }
    public func application(pid: UInt32, context: OperationContext) throws -> any AXObject {
        try context.check()
        guard AXIsProcessTrusted() else { throw NativeFailure(.permissionDenied, "Accessibility permission is unavailable") }
        let object = NativeAXObject(AXUIElementCreateApplication(pid_t(pid)))
        _ = try prepared(object, context: context)
        return object
    }
    public func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren {
        try list(application, attribute: kAXWindowsAttribute as CFString, limit: 256, missingIsEmpty: false, context: context)
    }
    public func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren {
        try list(element, attribute: kAXChildrenAttribute as CFString, limit: limit, missingIsEmpty: true, context: context)
    }
    public func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try objectAttribute(element, kAXParentAttribute as CFString, context: context)
    }
    public func focusedElement(of application: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try objectAttribute(application, kAXFocusedUIElementAttribute as CFString, context: context)
    }
    public func menuBar(of application: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try objectAttribute(application, kAXMenuBarAttribute as CFString, context: context)
    }
    public func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try objectAttribute(element, kAXWindowAttribute as CFString, context: context)
    }
    public func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32 {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(try prepared(element, context: context), &pid)
        try checkAXRead(result, context: context)
        guard pid > 0 else { throw NativeFailure(.staleElement, "AX process identity unavailable") }
        return UInt32(pid)
    }
    public func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool {
        guard let lhs = lhs as? NativeAXObject, let rhs = rhs as? NativeAXObject else { return false }
        return CFEqual(lhs.element, rhs.element)
    }
    func scrollbar(in area: any AXObject, axis: Axis, context: OperationContext) throws -> AXScrollbar? {
        let name = axis == .vertical ? kAXVerticalScrollBarAttribute : kAXHorizontalScrollBarAttribute
        let value = kAXValueAttribute as CFString
        guard let bar = try objectAttribute(area, name as CFString, context: context),
              try string(bar, kAXRoleAttribute as CFString, context: context) == kAXScrollBarRole as String,
              try isSettable(bar, value, context: context),
              let raw = try attribute(bar, value, context: context), CFGetTypeID(raw) == CFNumberGetTypeID(),
              let number = raw as? NSNumber, (0...1).contains(number.doubleValue) else { return nil }
        return AXScrollbar(object: bar, position: number.doubleValue)
    }
    func setScrollPosition(_ position: Double, on scrollbar: any AXObject, context: OperationContext,
                           willDispatch: @Sendable () throws -> Void) throws {
        let bar = try prepared(scrollbar, context: context)
        try willDispatch()
        guard AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: position)) == .success else {
            throw NativeFailure(.nativeFailed, "AX scrollbar setter returned an error")
        }
    }
    public func identity(of element: any AXObject, context: OperationContext) throws -> AXElementIdentity? {
        guard let role = try string(element, kAXRoleAttribute as CFString, context: context) else { return nil }
        return AXElementIdentity(role: role, identifier: try string(element, kAXIdentifierAttribute as CFString, context: context),
            subrole: try string(element, kAXSubroleAttribute as CFString, context: context))
    }
    public func bounds(of element: any AXObject, context: OperationContext) throws -> Rect? {
        var raw: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        let result = AXUIElementCopyMultipleAttributeValues(try prepared(element, context: context), attributes, [], &raw)
        try checkAXRead(result, context: context, allowMissing: true)
        guard result == .success, let values = raw as? [CFTypeRef], values.count == 2 else { return nil }
        return decodeBounds(position: values[0], size: values[1], allowClippedZeroAxis: true)
    }

    public func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot? {
        guard let role = try string(element, kAXRoleAttribute as CFString, context: context) else { return nil }
        let isMenuRole = role == "AXMenuItem" || role == "AXMenuBarItem" || role == "AXMenu" || role == "AXMenuBar"
        let position = try attribute(element, kAXPositionAttribute as CFString, context: context)
        let size = try attribute(element, kAXSizeAttribute as CFString, context: context)
        let actions = try readAXActionNames(prepared(element, context: context), context: context)
        let allowClippedZeroAxis = role != "AXWindow" && (actions.contains("AXScrollToVisible") || isMenuRole)
        let bounds: Rect
        if let position, let size, let decoded = decodeBounds(position: position, size: size, allowClippedZeroAxis: allowClippedZeroAxis) {
            bounds = decoded
        } else if isMenuRole {
            // Closed macOS menu items can omit AXPosition/AXSize while remaining inspectable.
            bounds = Rect(x: 0, y: 0, width: 1, height: 1)
        } else {
            return nil
        }
        let title = try string(element, kAXTitleAttribute as CFString, context: context)
        var descriptionValue: CFTypeRef?
        let descriptionResult = AXUIElementCopyAttributeValue(try prepared(element, context: context),
            kAXDescriptionAttribute as CFString, &descriptionValue)
        let description = try decodeAXDescription(descriptionResult, value: descriptionValue, context: context)
        let rawIdentifier = try string(element, kAXIdentifierAttribute as CFString, context: context)
        let subrole = try string(element, kAXSubroleAttribute as CFString, context: context)
        var enabledValue: CFTypeRef?
        let enabledResult = AXUIElementCopyAttributeValue(try prepared(element, context: context),
            kAXEnabledAttribute as CFString, &enabledValue)
        let enabled = try decodeAXEnabled(enabledResult, value: enabledValue, context: context)
        let value = includeValue ? try string(element, kAXValueAttribute as CFString, context: context) : nil
        let settable = try isSettable(element, kAXValueAttribute as CFString, context: context)
        let textSettable = try isSettable(element, kAXSelectedTextAttribute as CFString, context: context)
        var range: AXTextRange?
        if textSettable,
           let raw = try attribute(element, kAXSelectedTextRangeAttribute as CFString, context: context),
           CFGetTypeID(raw) == AXValueGetTypeID() {
            var selected = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &selected), selected.location >= 0, selected.length >= 0 {
                range = AXTextRange(location: selected.location, length: selected.length)
            }
        }
        let rawUrl = (role == "AXWebArea" || role == "AXLink") ? try urlString(element, context: context) : nil
        let boundedUrl = rawUrl.flatMap { !$0.isEmpty && $0.utf8.count <= Limits.maxUrlBytes ? $0 : nil }
        let rawLabel = [title, description.value].compactMap { $0 }.first { !$0.isEmpty }
        let label = rawLabel.flatMap { $0.utf8.count <= 1024 ? $0 : nil }
        let boundedValue = value.flatMap { $0.utf8.count <= 65_536 ? $0 : nil }
        return AXNodeSnapshot(role: role, title: title, label: label, identifier: rawIdentifier,
            bounds: bounds,
            enabled: enabled.value ?? false, enabledKnown: enabled.value != nil, value: boundedValue,
            valueSettable: settable, selectedTextSettable: textSettable, selectedRange: range,
            actions: boundedAXActionNames(actions),
            complete: description.complete && enabled.completeForTraversal && rawLabel == label
                && (rawIdentifier?.utf8.count ?? 0) <= 1024 && (subrole?.utf8.count ?? 0) <= 1024
                && rawUrl == boundedUrl && value == boundedValue && actions.count <= 32,
            subrole: subrole, enabledUnsupported: enabled.unsupported, url: boundedUrl)
    }

    private func decodeBounds(position: CFTypeRef, size: CFTypeRef, allowClippedZeroAxis: Bool = false) -> Rect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              [point.x, point.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite) else { return nil }
        if allowClippedZeroAxis {
            guard dimensions.width >= 0, dimensions.height >= 0 else { return nil }
            // Chromium clips off-screen scrollable web elements to 0 on the clipped axis; clamp
            // to 1pt so they stay representable, remain classified as clipped, and can receive AXScrollToVisible.
            return Rect(x: point.x, y: point.y, width: max(1, dimensions.width), height: max(1, dimensions.height))
        }
        guard dimensions.width > 0, dimensions.height > 0 else { return nil }
        return Rect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }

    private func prepared(_ object: any AXObject, context: OperationContext) throws -> AXUIElement {
        guard let native = object as? NativeAXObject else { throw NativeFailure(.nativeFailed, "incompatible native AX object") }
        let result = AXUIElementSetMessagingTimeout(native.element, try context.nativeTimeoutSeconds())
        try checkAXRead(result, context: context)
        return native.element
    }
    private func attribute(_ object: any AXObject, _ name: CFString, context: OperationContext) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(try prepared(object, context: context), name, &value)
        try checkAXRead(result, context: context, allowMissing: true)
        return result == .success ? value : nil
    }
    private func string(_ object: any AXObject, _ name: CFString, context: OperationContext) throws -> String? {
        guard let value = try attribute(object, name, context: context) else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    private func urlString(_ object: any AXObject, context: OperationContext) throws -> String? {
        guard let value = try attribute(object, kAXURLAttribute as CFString, context: context) else { return nil }
        if let url = value as? URL { return url.absoluteString.isEmpty ? nil : url.absoluteString }
        if let string = value as? String { return string.isEmpty ? nil : string }
        return nil
    }
    private func objectAttribute(_ object: any AXObject, _ name: CFString, context: OperationContext) throws -> (any AXObject)? {
        guard let value = try attribute(object, name, context: context), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return NativeAXObject(unsafeDowncast(value, to: AXUIElement.self))
    }
    private func isSettable(_ object: any AXObject, _ name: CFString, context: OperationContext) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(try prepared(object, context: context), name, &settable)
        try checkAXRead(result, context: context, allowMissing: true)
        return result == .success && settable.boolValue
    }
    private func list(_ object: any AXObject, attribute: CFString, limit: Int, missingIsEmpty: Bool, context: OperationContext) throws -> AXChildren {
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(try prepared(object, context: context), attribute, &count)
        try checkAXRead(result, context: context, allowMissing: true)
        guard result == .success else { return AXChildren(elements: [], complete: missingIsEmpty) }
        if count == 0 { return AXChildren(elements: []) }
        let take = min(count, limit)
        if take == 0 { return AXChildren(elements: [], complete: false) }
        var values: CFArray?
        let copied = AXUIElementCopyAttributeValues(try prepared(object, context: context), attribute, 0, take, &values)
        try checkAXRead(copied, context: context)
        guard let elements = values as? [AXUIElement] else { return AXChildren(elements: [], complete: false) }
        return AXChildren(elements: elements.map(NativeAXObject.init), complete: elements.count == count)
    }
}
