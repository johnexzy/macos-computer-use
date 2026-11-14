import Foundation

public enum Limits {
    public static let version: UInt16 = 1
    public static let maxFrameBytes = 8 * 1024 * 1024
    public static let maxImageBytes = 4 * 1024 * 1024
    public static let maxSteps = 16
    public static let maxElements = 256
    public static let maxTargets = 256
    public static let maxRetainedObservations = 32
    public static let observationTTLMS: UInt32 = 60_000
    public static let maxBudgetMS: UInt32 = 60_000
    public static let maxFeedbackBytes = 2 * 1024 * 1024
}

public struct ContractError: Error, Equatable, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

private struct WireKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private func strict<K: CodingKey & CaseIterable>(_ decoder: Decoder, _ keys: K.Type) throws -> KeyedDecodingContainer<K> {
    let raw = try decoder.container(keyedBy: WireKey.self)
    let allowed = Set(K.allCases.map(\.stringValue))
    guard raw.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw ContractError("unknown field")
    }
    return try decoder.container(keyedBy: keys)
}

private func tagged(_ decoder: Decoder, _ tag: String, _ payload: String) throws -> (String, KeyedDecodingContainer<WireKey>) {
    let container = try decoder.container(keyedBy: WireKey.self)
    guard container.allKeys.count == 2, Set(container.allKeys.map(\.stringValue)) == Set([tag, payload]) else {
        throw ContractError("invalid tagged value fields")
    }
    return (try container.decode(String.self, forKey: WireKey(tag)), container)
}

public enum Delivery: String, Codable, Equatable, Sendable {
    case notDispatched = "not_dispatched"
    case dispatched
    case unknown
}

public enum ExecutionMode: String, Codable, Equatable, Sendable {
    case backgroundRequired
    case foregroundAllowed
}

public enum Verification: String, Codable, Equatable, Sendable {
    case confirmed
    case mismatch
    case unverified
}

public enum DeliveryRoute: String, Codable, Equatable, Sendable {
    case axSetValue, axSelectedText, axPress
}

public enum Coverage: String, Codable, Equatable, Sendable {
    case complete
    case partial
    case unavailable
}

public enum MimeType: String, Codable, Equatable, Sendable {
    case png
    case jpeg
}

public enum CoordinateSpace: String, Codable, Equatable, Sendable {
    case screenPoints
    case windowPoints
    case imagePixels
}

public enum Axis: String, Codable, Equatable, Sendable {
    case vertical
    case horizontal
}

public enum Key: String, Codable, Equatable, Sendable {
    case `return`
    case tab
    case escape
    case backspace
    case left
    case right
    case up
    case down
}

public enum ElementAction: String, Codable, Equatable, Sendable {
    case press
    case setValue
    case typeText
    case key
    case scroll
}

public enum ActionKind: String, Codable, Equatable, Sendable {
    case press
    case setValue
    case typeText
    case key
    case scroll
    case click
}

public enum StopReason: String, Codable, Equatable, Sendable {
    case completed
    case preconditionFailed
    case verificationFailed
    case cancelled
    case deadlineExceeded
    case helperDied
    case targetStale
    case ambiguousTarget
    case unsupported
    case failed
}

public enum ReceiptReason: String, Codable, Equatable, Sendable {
    case alreadySatisfied
    case conditionSatisfied
    case preconditionFailed
    case verificationFailed
    case cancelled
    case deadlineExceeded
    case helperDied
    case targetStale
    case ambiguousTarget
    case unsupported
    case nativeFailed
}

public enum ErrorCode: String, Codable, Equatable, Sendable {
    case invalidRequest
    case unsupportedVersion
    case staleEpoch
    case permissionDenied
    case authorityDenied
    case targetNotFound
    case ambiguousTarget
    case staleObservation
    case staleElement
    case unsupported
    case nativeFailed
    case deadlineExceeded
    case cancelled
    case resourceLimit
}

public enum WaitOutcome: String, Codable, Equatable, Sendable {
    case satisfied
    case timedOut
    case cancelled
}

public enum CancelStatus: String, Codable, Equatable, Sendable {
    case requested
    case notFound
    case alreadyFinished
}

public struct Authority: Codable, Equatable, Sendable {
    public let grantId: String
    public let mode: ExecutionMode
    public init(grantId: String, mode: ExecutionMode) {
        self.grantId = grantId
        self.mode = mode
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case grantId, mode
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        grantId = try c.decode(String.self, forKey: .grantId)
        mode = try c.decode(ExecutionMode.self, forKey: .mode)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(grantId, forKey: .grantId)
        try c.encode(mode, forKey: .mode)
    }
}

public struct HelloRequest: Codable, Equatable, Sendable {
    public let clientName: String
    public let supportedVersions: [UInt16]
    public let authority: Authority
    public init(clientName: String, supportedVersions: [UInt16], authority: Authority) {
        self.clientName = clientName
        self.supportedVersions = supportedVersions
        self.authority = authority
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case clientName, supportedVersions, authority
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        clientName = try c.decode(String.self, forKey: .clientName)
        supportedVersions = try c.decode([UInt16].self, forKey: .supportedVersions)
        authority = try c.decode(Authority.self, forKey: .authority)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientName, forKey: .clientName)
        try c.encode(supportedVersions, forKey: .supportedVersions)
        try c.encode(authority, forKey: .authority)
    }
}

public struct HelloResult: Codable, Equatable, Sendable {
    public let helperVersion: String
    public let selectedVersion: UInt16
    public init(helperVersion: String, selectedVersion: UInt16) {
        self.helperVersion = helperVersion
        self.selectedVersion = selectedVersion
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case helperVersion, selectedVersion
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        helperVersion = try c.decode(String.self, forKey: .helperVersion)
        selectedVersion = try c.decode(UInt16.self, forKey: .selectedVersion)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(helperVersion, forKey: .helperVersion)
        try c.encode(selectedVersion, forKey: .selectedVersion)
    }
}

public struct Empty: Codable, Equatable, Sendable {
    public init() {
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        guard c.allKeys.isEmpty else { throw ContractError("unknown field") }
    }
}

public struct Permissions: Codable, Equatable, Sendable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let inputPosting: Bool
    public init(accessibility: Bool, screenRecording: Bool, inputPosting: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.inputPosting = inputPosting
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case accessibility, screenRecording, inputPosting
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        accessibility = try c.decode(Bool.self, forKey: .accessibility)
        screenRecording = try c.decode(Bool.self, forKey: .screenRecording)
        inputPosting = try c.decode(Bool.self, forKey: .inputPosting)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(accessibility, forKey: .accessibility)
        try c.encode(screenRecording, forKey: .screenRecording)
        try c.encode(inputPosting, forKey: .inputPosting)
    }
}

public struct Capabilities: Codable, Equatable, Sendable {
    public let permissions: Permissions
    public let mode: ExecutionMode
    public let actions: [ActionKind]
    public init(permissions: Permissions, mode: ExecutionMode, actions: [ActionKind]) {
        self.permissions = permissions
        self.mode = mode
        self.actions = actions
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case permissions, mode, actions
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        permissions = try c.decode(Permissions.self, forKey: .permissions)
        mode = try c.decode(ExecutionMode.self, forKey: .mode)
        actions = try c.decode([ActionKind].self, forKey: .actions)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(permissions, forKey: .permissions)
        try c.encode(mode, forKey: .mode)
        try c.encode(actions, forKey: .actions)
    }
}

public struct TargetKey: Codable, Equatable, Sendable {
    public let pid: UInt32
    public let windowId: UInt32
    public init(pid: UInt32, windowId: UInt32) {
        self.pid = pid
        self.windowId = windowId
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pid, windowId
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        pid = try c.decode(UInt32.self, forKey: .pid)
        windowId = try c.decode(UInt32.self, forKey: .windowId)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pid, forKey: .pid)
        try c.encode(windowId, forKey: .windowId)
    }
}

public struct Rect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, width, height
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}

public struct Point: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
    }
}

public struct Target: Codable, Equatable, Sendable {
    public let key: TargetKey
    public let bundleId: String
    public let title: String
    public let bounds: Rect
    public init(key: TargetKey, bundleId: String, title: String, bounds: Rect) {
        self.key = key
        self.bundleId = bundleId
        self.title = title
        self.bounds = bounds
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case key, bundleId, title, bounds
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        key = try c.decode(TargetKey.self, forKey: .key)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        title = try c.decode(String.self, forKey: .title)
        bounds = try c.decode(Rect.self, forKey: .bounds)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(bundleId, forKey: .bundleId)
        try c.encode(title, forKey: .title)
        try c.encode(bounds, forKey: .bounds)
    }
}

public struct TargetsRequest: Codable, Equatable, Sendable {
    public let bundleId: String?
    public init(bundleId: String?) {
        self.bundleId = bundleId
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case bundleId
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleId, forKey: .bundleId)
    }
}

public struct TargetsResult: Codable, Equatable, Sendable {
    public let targets: [Target]
    public let truncated: Bool
    public init(targets: [Target], truncated: Bool) {
        self.targets = targets
        self.truncated = truncated
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case targets, truncated
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        targets = try c.decode([Target].self, forKey: .targets)
        truncated = try c.decode(Bool.self, forKey: .truncated)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(targets, forKey: .targets)
        try c.encode(truncated, forKey: .truncated)
    }
}

public struct CollectionInterval: Codable, Equatable, Sendable {
    public let startedUnixMs: UInt64
    public let finishedUnixMs: UInt64
    public init(startedUnixMs: UInt64, finishedUnixMs: UInt64) {
        self.startedUnixMs = startedUnixMs
        self.finishedUnixMs = finishedUnixMs
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case startedUnixMs, finishedUnixMs
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        startedUnixMs = try c.decode(UInt64.self, forKey: .startedUnixMs)
        finishedUnixMs = try c.decode(UInt64.self, forKey: .finishedUnixMs)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(startedUnixMs, forKey: .startedUnixMs)
        try c.encode(finishedUnixMs, forKey: .finishedUnixMs)
    }
}

public struct ImageTransform: Codable, Equatable, Sendable {
    public let scaleX: Double
    public let scaleY: Double
    public let offsetX: Double
    public let offsetY: Double
    public let validImageBounds: Rect
    public let coverage: Coverage
    public init(scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double, validImageBounds: Rect, coverage: Coverage) {
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.validImageBounds = validImageBounds
        self.coverage = coverage
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scaleX, scaleY, offsetX, offsetY, validImageBounds, coverage
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        scaleX = try c.decode(Double.self, forKey: .scaleX)
        scaleY = try c.decode(Double.self, forKey: .scaleY)
        offsetX = try c.decode(Double.self, forKey: .offsetX)
        offsetY = try c.decode(Double.self, forKey: .offsetY)
        validImageBounds = try c.decode(Rect.self, forKey: .validImageBounds)
        coverage = try c.decode(Coverage.self, forKey: .coverage)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scaleX, forKey: .scaleX)
        try c.encode(scaleY, forKey: .scaleY)
        try c.encode(offsetX, forKey: .offsetX)
        try c.encode(offsetY, forKey: .offsetY)
        try c.encode(validImageBounds, forKey: .validImageBounds)
        try c.encode(coverage, forKey: .coverage)
    }
}

public struct Screenshot: Codable, Equatable, Sendable {
    public let mimeType: MimeType
    public let widthPx: UInt32
    public let heightPx: UInt32
    public let dataBase64: String
    public let imageToScreen: ImageTransform
    public let collected: CollectionInterval
    public init(mimeType: MimeType, widthPx: UInt32, heightPx: UInt32, dataBase64: String, imageToScreen: ImageTransform, collected: CollectionInterval) {
        self.mimeType = mimeType
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.dataBase64 = dataBase64
        self.imageToScreen = imageToScreen
        self.collected = collected
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mimeType, widthPx, heightPx, dataBase64, imageToScreen, collected
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        mimeType = try c.decode(MimeType.self, forKey: .mimeType)
        widthPx = try c.decode(UInt32.self, forKey: .widthPx)
        heightPx = try c.decode(UInt32.self, forKey: .heightPx)
        dataBase64 = try c.decode(String.self, forKey: .dataBase64)
        imageToScreen = try c.decode(ImageTransform.self, forKey: .imageToScreen)
        collected = try c.decode(CollectionInterval.self, forKey: .collected)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mimeType, forKey: .mimeType)
        try c.encode(widthPx, forKey: .widthPx)
        try c.encode(heightPx, forKey: .heightPx)
        try c.encode(dataBase64, forKey: .dataBase64)
        try c.encode(imageToScreen, forKey: .imageToScreen)
        try c.encode(collected, forKey: .collected)
    }
}

public struct Element: Codable, Equatable, Sendable {
    public let reference: String
    public let role: String
    public let label: String?
    public let value: String?
    public let bounds: Rect
    public let enabled: Bool
    public let actions: [ElementAction]
    public let identifier: String?
    public init(reference: String, role: String, label: String?, value: String?, bounds: Rect, enabled: Bool, actions: [ElementAction], identifier: String? = nil) {
        self.reference = reference
        self.role = role
        self.label = label
        self.value = value
        self.bounds = bounds
        self.enabled = enabled
        self.actions = actions
        self.identifier = identifier
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case reference, role, label, value, bounds, enabled, actions, identifier
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        reference = try c.decode(String.self, forKey: .reference)
        role = try c.decode(String.self, forKey: .role)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        bounds = try c.decode(Rect.self, forKey: .bounds)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        actions = try c.decode([ElementAction].self, forKey: .actions)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(reference, forKey: .reference)
        try c.encode(role, forKey: .role)
        try c.encode(label, forKey: .label)
        try c.encode(value, forKey: .value)
        try c.encode(bounds, forKey: .bounds)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(actions, forKey: .actions)
        try c.encode(identifier, forKey: .identifier)
    }
}

public struct ObserveRequest: Codable, Equatable, Sendable {
    public let target: TargetKey
    public let includeScreenshot: Bool
    public let includeValues: Bool
    public init(target: TargetKey, includeScreenshot: Bool, includeValues: Bool) {
        self.target = target
        self.includeScreenshot = includeScreenshot
        self.includeValues = includeValues
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case target, includeScreenshot, includeValues
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        target = try c.decode(TargetKey.self, forKey: .target)
        includeScreenshot = try c.decode(Bool.self, forKey: .includeScreenshot)
        includeValues = try c.decode(Bool.self, forKey: .includeValues)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        try c.encode(includeScreenshot, forKey: .includeScreenshot)
        try c.encode(includeValues, forKey: .includeValues)
    }
}

public struct Observation: Codable, Equatable, Sendable {
    public let observationId: String
    public let target: TargetKey
    public let collected: CollectionInterval
    public let windowBounds: Rect
    public let accessibility: Coverage
    public let accessibilityCollected: CollectionInterval?
    public let elements: [Element]
    public let screenshot: Screenshot?
    public init(observationId: String, target: TargetKey, collected: CollectionInterval, windowBounds: Rect, accessibility: Coverage, accessibilityCollected: CollectionInterval?, elements: [Element], screenshot: Screenshot?) {
        self.observationId = observationId
        self.target = target
        self.collected = collected
        self.windowBounds = windowBounds
        self.accessibility = accessibility
        self.accessibilityCollected = accessibilityCollected
        self.elements = elements
        self.screenshot = screenshot
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case observationId, target, collected, windowBounds, accessibility, accessibilityCollected, elements, screenshot
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        observationId = try c.decode(String.self, forKey: .observationId)
        target = try c.decode(TargetKey.self, forKey: .target)
        collected = try c.decode(CollectionInterval.self, forKey: .collected)
        windowBounds = try c.decode(Rect.self, forKey: .windowBounds)
        accessibility = try c.decode(Coverage.self, forKey: .accessibility)
        accessibilityCollected = try c.decodeIfPresent(CollectionInterval.self, forKey: .accessibilityCollected)
        elements = try c.decode([Element].self, forKey: .elements)
        screenshot = try c.decodeIfPresent(Screenshot.self, forKey: .screenshot)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observationId, forKey: .observationId)
        try c.encode(target, forKey: .target)
        try c.encode(collected, forKey: .collected)
        try c.encode(windowBounds, forKey: .windowBounds)
        try c.encode(accessibility, forKey: .accessibility)
        try c.encode(accessibilityCollected, forKey: .accessibilityCollected)
        try c.encode(elements, forKey: .elements)
        try c.encode(screenshot, forKey: .screenshot)
    }
}

public struct Selector: Codable, Equatable, Sendable {
    public let role: String
    public let label: String?
    public let identifier: String?
    public init(role: String, label: String?, identifier: String?) {
        self.role = role
        self.label = label
        self.identifier = identifier
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case role, label, identifier
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        role = try c.decode(String.self, forKey: .role)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(label, forKey: .label)
        try c.encode(identifier, forKey: .identifier)
    }
}

public struct ElementCondition: Codable, Equatable, Sendable {
    public let selector: Selector
    public init(selector: Selector) {
        self.selector = selector
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case selector
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        selector = try c.decode(Selector.self, forKey: .selector)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(selector, forKey: .selector)
    }
}

public struct ValueCondition: Codable, Equatable, Sendable {
    public let elementRef: String
    public let value: String
    public init(elementRef: String, value: String) {
        self.elementRef = elementRef
        self.value = value
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef, value
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
        value = try c.decode(String.self, forKey: .value)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
        try c.encode(value, forKey: .value)
    }
}

public struct EnabledCondition: Codable, Equatable, Sendable {
    public let elementRef: String
    public let enabled: Bool
    public init(elementRef: String, enabled: Bool) {
        self.elementRef = elementRef
        self.enabled = enabled
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef, enabled
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
        enabled = try c.decode(Bool.self, forKey: .enabled)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
        try c.encode(enabled, forKey: .enabled)
    }
}

public struct ElementOperation: Codable, Equatable, Sendable {
    public let elementRef: String
    public init(elementRef: String) {
        self.elementRef = elementRef
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
    }
}

public struct SetValueOperation: Codable, Equatable, Sendable {
    public let elementRef: String
    public let value: String
    public init(elementRef: String, value: String) {
        self.elementRef = elementRef
        self.value = value
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef, value
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
        value = try c.decode(String.self, forKey: .value)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
        try c.encode(value, forKey: .value)
    }
}

public struct TypeTextOperation: Codable, Equatable, Sendable {
    public let elementRef: String
    public let text: String
    public init(elementRef: String, text: String) {
        self.elementRef = elementRef
        self.text = text
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef, text
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
        text = try c.decode(String.self, forKey: .text)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
        try c.encode(text, forKey: .text)
    }
}

public struct KeyOperation: Codable, Equatable, Sendable {
    public let elementRef: String
    public let key: Key
    public init(elementRef: String, key: Key) {
        self.elementRef = elementRef
        self.key = key
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef, key
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
        key = try c.decode(Key.self, forKey: .key)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
        try c.encode(key, forKey: .key)
    }
}

public struct ScrollOperation: Codable, Equatable, Sendable {
    public let elementRef: String
    public let axis: Axis
    public let amount: Int32
    public init(elementRef: String, axis: Axis, amount: Int32) {
        self.elementRef = elementRef
        self.axis = axis
        self.amount = amount
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef, axis, amount
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
        axis = try c.decode(Axis.self, forKey: .axis)
        amount = try c.decode(Int32.self, forKey: .amount)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
        try c.encode(axis, forKey: .axis)
        try c.encode(amount, forKey: .amount)
    }
}

public struct ClickOperation: Codable, Equatable, Sendable {
    public let point: Point
    public let space: CoordinateSpace
    public init(point: Point, space: CoordinateSpace) {
        self.point = point
        self.space = space
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case point, space
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        point = try c.decode(Point.self, forKey: .point)
        space = try c.decode(CoordinateSpace.self, forKey: .space)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(point, forKey: .point)
        try c.encode(space, forKey: .space)
    }
}

public enum FeedbackState: String, Codable, Equatable, Sendable {
    case changed, unchanged, invalidated, unavailable
}

public struct WaitOperation: Codable, Equatable, Sendable {
    public let condition: Condition
    public init(condition: Condition) {
        self.condition = condition
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case condition
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        condition = try c.decode(Condition.self, forKey: .condition)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(condition, forKey: .condition)
    }
}

public struct FeedbackRequest: Codable, Equatable, Sendable {
    public let elementRefs: [String]
    public let includeValues: Bool
    public init(elementRefs: [String], includeValues: Bool) {
        self.elementRefs = elementRefs
        self.includeValues = includeValues
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRefs, includeValues
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRefs = try c.decode([String].self, forKey: .elementRefs)
        includeValues = try c.decode(Bool.self, forKey: .includeValues)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRefs, forKey: .elementRefs)
        try c.encode(includeValues, forKey: .includeValues)
    }
}

public struct ControlFeedback: Codable, Equatable, Sendable {
    public let elementRef: String
    public let state: FeedbackState
    public let element: Element?
    public init(elementRef: String, state: FeedbackState, element: Element? = nil) {
        self.elementRef = elementRef
        self.state = state
        self.element = element
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case elementRef, state, element
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        elementRef = try c.decode(String.self, forKey: .elementRef)
        state = try c.decode(FeedbackState.self, forKey: .state)
        element = try c.decodeIfPresent(Element.self, forKey: .element)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(elementRef, forKey: .elementRef)
        try c.encode(state, forKey: .state)
        try c.encode(element, forKey: .element)
    }
}

public struct ObservationFeedback: Codable, Equatable, Sendable {
    public let baseObservationId: String
    public let collected: CollectionInterval
    public let controls: [ControlFeedback]
    public let invalidated: Bool
    public let truncated: Bool
    public init(baseObservationId: String, collected: CollectionInterval, controls: [ControlFeedback], invalidated: Bool, truncated: Bool) {
        self.baseObservationId = baseObservationId
        self.collected = collected
        self.controls = controls
        self.invalidated = invalidated
        self.truncated = truncated
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case baseObservationId, collected, controls, invalidated, truncated
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        baseObservationId = try c.decode(String.self, forKey: .baseObservationId)
        collected = try c.decode(CollectionInterval.self, forKey: .collected)
        controls = try c.decode([ControlFeedback].self, forKey: .controls)
        invalidated = try c.decode(Bool.self, forKey: .invalidated)
        truncated = try c.decode(Bool.self, forKey: .truncated)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseObservationId, forKey: .baseObservationId)
        try c.encode(collected, forKey: .collected)
        try c.encode(controls, forKey: .controls)
        try c.encode(invalidated, forKey: .invalidated)
        try c.encode(truncated, forKey: .truncated)
    }
}

public struct ActionStep: Codable, Equatable, Sendable {
    public let actionId: String
    public let operation: Operation
    public let precondition: Condition?
    public let expect: Condition?
    public init(actionId: String, operation: Operation, precondition: Condition?, expect: Condition?) {
        self.actionId = actionId
        self.operation = operation
        self.precondition = precondition
        self.expect = expect
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case actionId, operation, precondition, expect
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        actionId = try c.decode(String.self, forKey: .actionId)
        operation = try c.decode(Operation.self, forKey: .operation)
        precondition = try c.decodeIfPresent(Condition.self, forKey: .precondition)
        expect = try c.decodeIfPresent(Condition.self, forKey: .expect)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actionId, forKey: .actionId)
        try c.encode(operation, forKey: .operation)
        try c.encode(precondition, forKey: .precondition)
        try c.encode(expect, forKey: .expect)
    }
}

public struct ActRequest: Codable, Equatable, Sendable {
    public let grantId: String
    public let observationId: String
    public let target: TargetKey
    public let steps: [ActionStep]
    public let feedback: FeedbackRequest?
    public init(grantId: String, observationId: String, target: TargetKey, steps: [ActionStep], feedback: FeedbackRequest? = nil) {
        self.grantId = grantId
        self.observationId = observationId
        self.target = target
        self.steps = steps
        self.feedback = feedback
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case grantId, observationId, target, steps
        case feedback
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        grantId = try c.decode(String.self, forKey: .grantId)
        observationId = try c.decode(String.self, forKey: .observationId)
        target = try c.decode(TargetKey.self, forKey: .target)
        steps = try c.decode([ActionStep].self, forKey: .steps)
        feedback = try c.decodeIfPresent(FeedbackRequest.self, forKey: .feedback)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(grantId, forKey: .grantId)
        try c.encode(observationId, forKey: .observationId)
        try c.encode(target, forKey: .target)
        try c.encode(steps, forKey: .steps)
        try c.encode(feedback, forKey: .feedback)
    }
}

public struct CheckEvidence: Codable, Equatable, Sendable {
    public let observationId: String
    public let condition: Condition
    public let matched: Bool
    public let collected: CollectionInterval?
    public init(observationId: String, condition: Condition, matched: Bool, collected: CollectionInterval? = nil) {
        self.observationId = observationId
        self.condition = condition
        self.matched = matched
        self.collected = collected
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case observationId, condition, matched
        case collected
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        observationId = try c.decode(String.self, forKey: .observationId)
        condition = try c.decode(Condition.self, forKey: .condition)
        matched = try c.decode(Bool.self, forKey: .matched)
        collected = try c.decodeIfPresent(CollectionInterval.self, forKey: .collected)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observationId, forKey: .observationId)
        try c.encode(condition, forKey: .condition)
        try c.encode(matched, forKey: .matched)
        try c.encode(collected, forKey: .collected)
    }
}

public struct StepReceipt: Codable, Equatable, Sendable {
    public let actionId: String
    public let delivery: Delivery
    public let verification: Verification
    public let reason: ReceiptReason?
    public let evidence: [CheckEvidence]
    public let route: DeliveryRoute?
    public init(actionId: String, delivery: Delivery, verification: Verification, reason: ReceiptReason?, evidence: [CheckEvidence], route: DeliveryRoute? = nil) {
        self.actionId = actionId
        self.delivery = delivery
        self.verification = verification
        self.reason = reason
        self.evidence = evidence
        self.route = route
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case actionId, delivery, verification, reason, evidence, route
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        actionId = try c.decode(String.self, forKey: .actionId)
        delivery = try c.decode(Delivery.self, forKey: .delivery)
        verification = try c.decode(Verification.self, forKey: .verification)
        reason = try c.decodeIfPresent(ReceiptReason.self, forKey: .reason)
        evidence = try c.decode([CheckEvidence].self, forKey: .evidence)
        route = try c.decodeIfPresent(DeliveryRoute.self, forKey: .route)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actionId, forKey: .actionId)
        try c.encode(delivery, forKey: .delivery)
        try c.encode(verification, forKey: .verification)
        try c.encode(reason, forKey: .reason)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(route, forKey: .route)
    }
}

public struct ActResult: Codable, Equatable, Sendable {
    public let observationId: String
    public let steps: [StepReceipt]
    public let remainingSteps: UInt16
    public let stopReason: StopReason
    public let feedback: ObservationFeedback?
    public init(observationId: String, steps: [StepReceipt], remainingSteps: UInt16, stopReason: StopReason, feedback: ObservationFeedback? = nil) {
        self.observationId = observationId
        self.steps = steps
        self.remainingSteps = remainingSteps
        self.stopReason = stopReason
        self.feedback = feedback
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case observationId, steps, remainingSteps, stopReason
        case feedback
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        observationId = try c.decode(String.self, forKey: .observationId)
        steps = try c.decode([StepReceipt].self, forKey: .steps)
        remainingSteps = try c.decode(UInt16.self, forKey: .remainingSteps)
        stopReason = try c.decode(StopReason.self, forKey: .stopReason)
        feedback = try c.decodeIfPresent(ObservationFeedback.self, forKey: .feedback)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observationId, forKey: .observationId)
        try c.encode(steps, forKey: .steps)
        try c.encode(remainingSteps, forKey: .remainingSteps)
        try c.encode(stopReason, forKey: .stopReason)
        try c.encode(feedback, forKey: .feedback)
    }
}

public struct WaitRequest: Codable, Equatable, Sendable {
    public let observationId: String
    public let target: TargetKey
    public let condition: Condition
    public init(observationId: String, target: TargetKey, condition: Condition) {
        self.observationId = observationId
        self.target = target
        self.condition = condition
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case observationId, target, condition
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        observationId = try c.decode(String.self, forKey: .observationId)
        target = try c.decode(TargetKey.self, forKey: .target)
        condition = try c.decode(Condition.self, forKey: .condition)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observationId, forKey: .observationId)
        try c.encode(target, forKey: .target)
        try c.encode(condition, forKey: .condition)
    }
}

public struct WaitResult: Codable, Equatable, Sendable {
    public let outcome: WaitOutcome
    public let alreadySatisfied: Bool
    public let observation: Observation?
    public let evidence: CheckEvidence?
    public init(outcome: WaitOutcome, alreadySatisfied: Bool, observation: Observation?, evidence: CheckEvidence? = nil) {
        self.outcome = outcome
        self.alreadySatisfied = alreadySatisfied
        self.observation = observation
        self.evidence = evidence
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case outcome, alreadySatisfied, observation
        case evidence
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        outcome = try c.decode(WaitOutcome.self, forKey: .outcome)
        alreadySatisfied = try c.decode(Bool.self, forKey: .alreadySatisfied)
        observation = try c.decodeIfPresent(Observation.self, forKey: .observation)
        evidence = try c.decodeIfPresent(CheckEvidence.self, forKey: .evidence)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(alreadySatisfied, forKey: .alreadySatisfied)
        try c.encode(observation, forKey: .observation)
        try c.encode(evidence, forKey: .evidence)
    }
}

public struct CancelRequest: Codable, Equatable, Sendable {
    public let requestId: String
    public init(requestId: String) {
        self.requestId = requestId
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requestId
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
    }
}

public struct CancelResult: Codable, Equatable, Sendable {
    public let requestId: String
    public let status: CancelStatus
    public init(requestId: String, status: CancelStatus) {
        self.requestId = requestId
        self.status = status
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requestId, status
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        requestId = try c.decode(String.self, forKey: .requestId)
        status = try c.decode(CancelStatus.self, forKey: .status)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(status, forKey: .status)
    }
}

public struct Failure: Codable, Equatable, Sendable {
    public let code: ErrorCode
    public let message: String
    public init(code: ErrorCode, message: String) {
        self.code = code
        self.message = message
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case code, message
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        code = try c.decode(ErrorCode.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        try c.encode(message, forKey: .message)
    }
}

public struct Request: Codable, Equatable, Sendable {
    public let version: UInt16
    public let id: String
    public let epoch: String?
    public let budgetMs: UInt32
    public let body: RequestBody
    public init(version: UInt16, id: String, epoch: String?, budgetMs: UInt32, body: RequestBody) {
        self.version = version
        self.id = id
        self.epoch = epoch
        self.budgetMs = budgetMs
        self.body = body
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, epoch, budgetMs, body
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        version = try c.decode(UInt16.self, forKey: .version)
        id = try c.decode(String.self, forKey: .id)
        epoch = try c.decodeIfPresent(String.self, forKey: .epoch)
        budgetMs = try c.decode(UInt32.self, forKey: .budgetMs)
        body = try c.decode(RequestBody.self, forKey: .body)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(budgetMs, forKey: .budgetMs)
        try c.encode(body, forKey: .body)
    }
}

public struct Response: Codable, Equatable, Sendable {
    public let version: UInt16
    public let id: String
    public let epoch: String
    public let body: ResponseBody
    public init(version: UInt16, id: String, epoch: String, body: ResponseBody) {
        self.version = version
        self.id = id
        self.epoch = epoch
        self.body = body
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, epoch, body
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        version = try c.decode(UInt16.self, forKey: .version)
        id = try c.decode(String.self, forKey: .id)
        epoch = try c.decode(String.self, forKey: .epoch)
        body = try c.decode(ResponseBody.self, forKey: .body)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(body, forKey: .body)
    }
}

public struct Progress: Codable, Equatable, Sendable {
    public let version: UInt16
    public let id: String
    public let epoch: String
    public let observationId: String
    public let steps: [StepReceipt]
    public init(version: UInt16, id: String, epoch: String, observationId: String, steps: [StepReceipt]) {
        self.version = version
        self.id = id
        self.epoch = epoch
        self.observationId = observationId
        self.steps = steps
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, id, epoch, observationId, steps
    }
    public init(from decoder: Decoder) throws {
        let c = try strict(decoder, CodingKeys.self)
        version = try c.decode(UInt16.self, forKey: .version)
        id = try c.decode(String.self, forKey: .id)
        epoch = try c.decode(String.self, forKey: .epoch)
        observationId = try c.decode(String.self, forKey: .observationId)
        steps = try c.decode([StepReceipt].self, forKey: .steps)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(epoch, forKey: .epoch)
        try c.encode(observationId, forKey: .observationId)
        try c.encode(steps, forKey: .steps)
    }
}

public enum Condition: Codable, Equatable, Sendable {
    case elementExists(ElementCondition)
    case elementAbsent(ElementCondition)
    case valueEquals(ValueCondition)
    case enabled(EnabledCondition)
    case windowAbsent(Empty)
    public init(from decoder: Decoder) throws {
        let (tag, c) = try tagged(decoder, "kind", "params")
        switch tag {
        case "elementExists": self = .elementExists(try c.decode(ElementCondition.self, forKey: WireKey("params")))
        case "elementAbsent": self = .elementAbsent(try c.decode(ElementCondition.self, forKey: WireKey("params")))
        case "valueEquals": self = .valueEquals(try c.decode(ValueCondition.self, forKey: WireKey("params")))
        case "enabled": self = .enabled(try c.decode(EnabledCondition.self, forKey: WireKey("params")))
        case "windowAbsent": self = .windowAbsent(try c.decode(Empty.self, forKey: WireKey("params")))
        default: throw ContractError("unknown tagged variant")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .elementExists(let value):
            try c.encode("elementExists", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .elementAbsent(let value):
            try c.encode("elementAbsent", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .valueEquals(let value):
            try c.encode("valueEquals", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .enabled(let value):
            try c.encode("enabled", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .windowAbsent(let value):
            try c.encode("windowAbsent", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        }
    }
}

public enum Operation: Codable, Equatable, Sendable {
    case press(ElementOperation)
    case setValue(SetValueOperation)
    case typeText(TypeTextOperation)
    case key(KeyOperation)
    case scroll(ScrollOperation)
    case click(ClickOperation)
    case waitFor(WaitOperation)
    public init(from decoder: Decoder) throws {
        let (tag, c) = try tagged(decoder, "kind", "params")
        switch tag {
        case "press": self = .press(try c.decode(ElementOperation.self, forKey: WireKey("params")))
        case "setValue": self = .setValue(try c.decode(SetValueOperation.self, forKey: WireKey("params")))
        case "typeText": self = .typeText(try c.decode(TypeTextOperation.self, forKey: WireKey("params")))
        case "key": self = .key(try c.decode(KeyOperation.self, forKey: WireKey("params")))
        case "scroll": self = .scroll(try c.decode(ScrollOperation.self, forKey: WireKey("params")))
        case "click": self = .click(try c.decode(ClickOperation.self, forKey: WireKey("params")))
        case "waitFor": self = .waitFor(try c.decode(WaitOperation.self, forKey: WireKey("params")))
        default: throw ContractError("unknown tagged variant")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .press(let value):
            try c.encode("press", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .setValue(let value):
            try c.encode("setValue", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .typeText(let value):
            try c.encode("typeText", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .key(let value):
            try c.encode("key", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .scroll(let value):
            try c.encode("scroll", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .click(let value):
            try c.encode("click", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        case .waitFor(let value):
            try c.encode("waitFor", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("params"))
        }
    }
}

public enum RequestBody: Codable, Equatable, Sendable {
    case hello(HelloRequest)
    case capabilities(Empty)
    case targets(TargetsRequest)
    case observe(ObserveRequest)
    case act(ActRequest)
    case waitFor(WaitRequest)
    case cancel(CancelRequest)
    public init(from decoder: Decoder) throws {
        let (tag, c) = try tagged(decoder, "method", "params")
        switch tag {
        case "hello": self = .hello(try c.decode(HelloRequest.self, forKey: WireKey("params")))
        case "capabilities": self = .capabilities(try c.decode(Empty.self, forKey: WireKey("params")))
        case "targets": self = .targets(try c.decode(TargetsRequest.self, forKey: WireKey("params")))
        case "observe": self = .observe(try c.decode(ObserveRequest.self, forKey: WireKey("params")))
        case "act": self = .act(try c.decode(ActRequest.self, forKey: WireKey("params")))
        case "waitFor": self = .waitFor(try c.decode(WaitRequest.self, forKey: WireKey("params")))
        case "cancel": self = .cancel(try c.decode(CancelRequest.self, forKey: WireKey("params")))
        default: throw ContractError("unknown tagged variant")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .hello(let value):
            try c.encode("hello", forKey: WireKey("method"))
            try c.encode(value, forKey: WireKey("params"))
        case .capabilities(let value):
            try c.encode("capabilities", forKey: WireKey("method"))
            try c.encode(value, forKey: WireKey("params"))
        case .targets(let value):
            try c.encode("targets", forKey: WireKey("method"))
            try c.encode(value, forKey: WireKey("params"))
        case .observe(let value):
            try c.encode("observe", forKey: WireKey("method"))
            try c.encode(value, forKey: WireKey("params"))
        case .act(let value):
            try c.encode("act", forKey: WireKey("method"))
            try c.encode(value, forKey: WireKey("params"))
        case .waitFor(let value):
            try c.encode("waitFor", forKey: WireKey("method"))
            try c.encode(value, forKey: WireKey("params"))
        case .cancel(let value):
            try c.encode("cancel", forKey: WireKey("method"))
            try c.encode(value, forKey: WireKey("params"))
        }
    }
}

public enum ResponseBody: Codable, Equatable, Sendable {
    case hello(HelloResult)
    case capabilities(Capabilities)
    case targets(TargetsResult)
    case observe(Observation)
    case act(ActResult)
    case waitFor(WaitResult)
    case cancel(CancelResult)
    case error(Failure)
    public init(from decoder: Decoder) throws {
        let (tag, c) = try tagged(decoder, "result", "data")
        switch tag {
        case "hello": self = .hello(try c.decode(HelloResult.self, forKey: WireKey("data")))
        case "capabilities": self = .capabilities(try c.decode(Capabilities.self, forKey: WireKey("data")))
        case "targets": self = .targets(try c.decode(TargetsResult.self, forKey: WireKey("data")))
        case "observe": self = .observe(try c.decode(Observation.self, forKey: WireKey("data")))
        case "act": self = .act(try c.decode(ActResult.self, forKey: WireKey("data")))
        case "waitFor": self = .waitFor(try c.decode(WaitResult.self, forKey: WireKey("data")))
        case "cancel": self = .cancel(try c.decode(CancelResult.self, forKey: WireKey("data")))
        case "error": self = .error(try c.decode(Failure.self, forKey: WireKey("data")))
        default: throw ContractError("unknown tagged variant")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .hello(let value):
            try c.encode("hello", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        case .capabilities(let value):
            try c.encode("capabilities", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        case .targets(let value):
            try c.encode("targets", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        case .observe(let value):
            try c.encode("observe", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        case .act(let value):
            try c.encode("act", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        case .waitFor(let value):
            try c.encode("waitFor", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        case .cancel(let value):
            try c.encode("cancel", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        case .error(let value):
            try c.encode("error", forKey: WireKey("result"))
            try c.encode(value, forKey: WireKey("data"))
        }
    }
}

public enum Frame: Codable, Equatable, Sendable {
    case request(Request)
    case response(Response)
    case progress(Progress)
    public init(from decoder: Decoder) throws {
        let (tag, c) = try tagged(decoder, "kind", "message")
        switch tag {
        case "request": self = .request(try c.decode(Request.self, forKey: WireKey("message")))
        case "response": self = .response(try c.decode(Response.self, forKey: WireKey("message")))
        case "progress": self = .progress(try c.decode(Progress.self, forKey: WireKey("message")))
        default: throw ContractError("unknown tagged variant")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: WireKey.self)
        switch self {
        case .request(let value):
            try c.encode("request", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("message"))
        case .response(let value):
            try c.encode("response", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("message"))
        case .progress(let value):
            try c.encode("progress", forKey: WireKey("kind"))
            try c.encode(value, forKey: WireKey("message"))
        }
    }
}
