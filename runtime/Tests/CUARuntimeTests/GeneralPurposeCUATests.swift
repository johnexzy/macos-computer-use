import CoreGraphics
import CUAProtocol
@testable import CUARuntime
import Foundation
import XCTest

private final class GPNode: AXObject, @unchecked Sendable {
    let id: String
    var pid: UInt32 = 9115
    var role: String
    var title: String?
    var label: String?
    var value: String?
    var url: String?
    var bounds: Rect
    var enabled = true
    var enabledKnown = true
    var valueSettable = false
    var actions: [String] = []
    var children: [GPNode] = []
    var complete = true
    weak var parent: GPNode?
    weak var owner: GPNode?

    init(_ id: String, role: String, title: String? = nil, label: String? = nil, value: String? = nil,
         url: String? = nil, bounds: Rect = Rect(x: 10, y: 10, width: 100, height: 24)) {
        self.id = id
        self.role = role
        self.title = title
        self.label = label ?? title
        self.value = value
        self.url = url
        self.bounds = bounds
    }
}

private final class GPBackend: AXReading, AXMutating, WindowCatalog, @unchecked Sendable {
    let app = GPNode("app", role: "AXApplication", bounds: Rect(x: 0, y: 0, width: 1, height: 1))
    var appMenuBar: GPNode?
    var appWindows: [GPNode] = []
    var records: [Target] = []
    var prepareReturnsTrue = false
    var delayPressOnNode: GPNode?
    var delayPressReads = 0
    private let lock = NSLock()
    private var pressCheckReads = 0
    var confirmCalls = 0
    var showMenuCalls = 0
    var cancelCalls = 0
    var invokedMenuPaths: [[String]] = []

    func prepareBrowserAccessibility(application: any AXObject, bundleId: String?, context: OperationContext) throws -> Bool {
        try context.check()
        return prepareReturnsTrue
    }
    func application(pid: UInt32, context: OperationContext) throws -> any AXObject { try context.check(); return app }
    func menuBar(of application: any AXObject, context: OperationContext) throws -> (any AXObject)? { try context.check(); return appMenuBar }
    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren {
        try context.check(); return AXChildren(elements: appWindows, complete: true)
    }
    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren {
        try context.check()
        let node = element as! GPNode
        return AXChildren(elements: Array(node.children.prefix(limit)), complete: node.children.count <= limit)
    }
    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check(); return (element as! GPNode).parent
    }
    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check(); return (element as! GPNode).owner
    }
    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32 {
        try context.check(); return (element as! GPNode).pid
    }
    func bounds(of element: any AXObject, context: OperationContext) throws -> Rect? {
        try context.check(); return (element as! GPNode).bounds
    }
    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot? {
        try context.check()
        let node = element as! GPNode
        lock.lock()
        if let delayed = delayPressOnNode, delayed === node {
            pressCheckReads += 1
            if pressCheckReads > delayPressReads && !node.actions.contains("AXPress") {
                node.actions.append("AXPress")
            }
        }
        let actions = node.actions
        let val = includeValue ? node.value : nil
        lock.unlock()
        return AXNodeSnapshot(role: node.role, title: node.title, label: node.label, bounds: node.bounds,
                              enabled: node.enabled, enabledKnown: node.enabledKnown, value: val,
                              valueSettable: node.valueSettable, actions: actions, complete: node.complete, url: node.url)
    }
    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool { (lhs as! GPNode) === (rhs as! GPNode) }
    func setValue(_ value: String, on object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
    }
    func press(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
    }
    func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
    }
    func confirm(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
        lock.lock(); confirmCalls += 1; lock.unlock()
    }
    func showMenu(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
        lock.lock(); showMenuCalls += 1; lock.unlock()
    }
    func cancel(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
        lock.lock(); cancelCalls += 1; lock.unlock()
    }
    func invokeMenu(_ path: [String], on application: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
        lock.lock(); invokedMenuPaths.append(path); lock.unlock()
    }
    func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult {
        try context.check(); return TargetsResult(targets: records, truncated: false)
    }
    func window(_ key: TargetKey, context: OperationContext) throws -> Target {
        try context.check()
        guard let t = records.first(where: { $0.key == key }) else { throw NativeFailure(.targetNotFound, "missing") }
        return t
    }
    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] {
        try context.check(); return records.filter { $0.key.pid == pid }
    }
}

private final class GPForegroundPlatform: ForegroundPlatform, @unchecked Sendable {
    var pid: UInt32 = 9115
    var focusedWin: (any AXObject)?
    var focusedEl: (any AXObject)?
    var posted: [ForegroundInput] = []

    func permissionAvailable() -> Bool { true }
    func visualPermissionAvailable() -> Bool { true }
    func sample() -> ForegroundSample { ForegroundSample(pid: pid, hardwareCounters: [0], inputHeld: false) }
    func watch(expecting pid: UInt32) -> ActivationWatch { ActivationWatch(expecting: pid) }
    func focusedWindow(pid: UInt32, context: OperationContext) throws -> (any AXObject)? { focusedWin }
    func focusedElement(pid: UInt32, context: OperationContext) throws -> (any AXObject)? { focusedEl }
    func activate(pid: UInt32, window: any AXObject, context: OperationContext, willChangeFocus: () throws -> Void) throws {
        try willChangeFocus()
    }
    func hitTest(_ point: Point, in target: SemanticObservationHandle, context: OperationContext) throws -> Bool { true }
    func visualHitTest(_ point: Point, in target: Target, context: OperationContext) throws -> Bool { true }
    func post(_ input: ForegroundInput, willDispatch: () throws -> Void) throws {
        try willDispatch()
        posted.append(input)
    }
}

private struct SolidVisualCapture: VisualCapturing {
    let image: CGImage
    let frame: VisualFrame
    func capture(target: Target, crop: Rect?, maxDimension: Int, context: OperationContext) throws -> CapturedVisual {
        CapturedVisual(image: image, frame: frame, collected: CollectionInterval(startedUnixMs: 1, finishedUnixMs: 2))
    }
}

private final class FakeOpener: AppOpening, @unchecked Sendable {
    let lock = NSLock()
    var lastRequest: OpenRequest?
    var resultToReturn: OpenResult
    init(_ result: OpenResult) { resultToReturn = result }
    func open(_ request: OpenRequest, catalog: any WindowCatalog, context: OperationContext) throws -> OpenResult {
        try context.check()
        lock.lock(); lastRequest = request; lock.unlock()
        return resultToReturn
    }
}

private final class TestCollector: @unchecked Sendable {
    let lock = NSLock()
    var responses: [Response] = []
    let changed = DispatchSemaphore(value: 0)
    func append(_ value: Response) { lock.lock(); responses.append(value); lock.unlock(); changed.signal() }
    func response(_ id: String) throws -> Response {
        let deadline = DispatchTime.now() + 2
        while true {
            lock.lock(); let found = responses.first(where: { $0.id == id }); lock.unlock()
            if let found { return found }
            guard changed.wait(timeout: deadline) == .success else { throw ContractError("timed out waiting for \(id)") }
        }
    }
}

private func makeSolidImage(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

final class GeneralPurposeCUATests: XCTestCase {
    func testWebAreaScopeAndInteractiveOnlyFilterSkipBrowserChrome() throws {
        let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 10), bundleId: "com.google.Chrome", title: "App", bounds: bounds)
        backend.records = [target]

        let win = GPNode("w", role: "AXWindow", title: "App - Google Chrome", bounds: bounds)
        let tab1 = GPNode("tab1", role: "AXTabButton", title: "Noise Tab 1", bounds: Rect(x: 10, y: 10, width: 120, height: 24))
        tab1.parent = win; tab1.owner = win
        let toolbarBtn = GPNode("tb", role: "AXButton", title: "Back", bounds: Rect(x: 10, y: 40, width: 30, height: 24))
        toolbarBtn.actions = ["AXPress"]; toolbarBtn.parent = win; toolbarBtn.owner = win

        let web = GPNode("web", role: "AXWebArea", title: "App", url: "https://app.example/", bounds: Rect(x: 0, y: 80, width: 1200, height: 720))
        web.parent = win; web.owner = win
        let staticText = GPNode("txt", role: "AXStaticText", title: "Welcome heading", value: "Welcome heading", bounds: Rect(x: 20, y: 100, width: 200, height: 20))
        staticText.parent = web; staticText.owner = win
        let submitBtn = GPNode("btn", role: "AXButton", title: "Submit Order", bounds: Rect(x: 20, y: 140, width: 120, height: 32))
        submitBtn.actions = ["AXPress"]; submitBtn.parent = web; submitBtn.owner = win
        web.children = [staticText, submitBtn]
        win.children = [tab1, toolbarBtn, web]
        backend.appWindows = [win]

        let observer = SemanticAXObserver(backend: backend, catalog: backend)
        let webOnly = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false, scope: .webArea),
            observationId: "o-web", context: OperationContext(budgetMs: 2000))
        XCTAssertEqual(webOnly.observation.accessibility, .partial)
        XCTAssertFalse(webOnly.observation.elements.contains { $0.label == "Noise Tab 1" || $0.label == "Back" })
        XCTAssertTrue(webOnly.observation.elements.contains { $0.label == "Welcome heading" })
        XCTAssertTrue(webOnly.observation.elements.contains { $0.label == "Submit Order" })

        let interactiveWeb = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false, scope: .webArea, interactiveOnly: true),
            observationId: "o-web-int", context: OperationContext(budgetMs: 2000))
        XCTAssertEqual(interactiveWeb.observation.accessibility, .partial)
        XCTAssertFalse(interactiveWeb.observation.elements.contains { $0.role == "AXStaticText" })
        XCTAssertTrue(interactiveWeb.observation.elements.contains { $0.label == "Submit Order" })
    }

    func testMenuBarScopeAndLabelContainsSelectors() throws {
        let bounds = Rect(x: 0, y: 0, width: 900, height: 600)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 11), bundleId: "com.google.Chrome", title: "Home", bounds: bounds)
        backend.records = [target]
        let win = GPNode("w", role: "AXWindow", title: "Home - Google Chrome", bounds: bounds)
        backend.appWindows = [win]

        let mb = GPNode("mb", role: "AXMenuBar")
        let fileTop = GPNode("file", role: "AXMenuBarItem", title: "File")
        let fileMenu = GPNode("fileMenu", role: "AXMenu")
        let newTab = GPNode("newTab", role: "AXMenuItem", title: "New Tab")
        let openLoc = GPNode("openLoc", role: "AXMenuItem", title: "Open Location…")
        fileMenu.children = [newTab, openLoc]
        fileTop.children = [fileMenu]
        mb.children = [fileTop]
        backend.appMenuBar = mb

        let observer = SemanticAXObserver(backend: backend, catalog: backend)
        let allMenus = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false, scope: .menuBar),
            observationId: "o-mb", context: OperationContext(budgetMs: 2000))
        XCTAssertEqual(allMenus.observation.accessibility, .partial)
        XCTAssertEqual(allMenus.observation.elements.compactMap(\.label), ["File > New Tab", "File > Open Location…"])

        let filtered = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false,
                                   axSelectors: [CUAProtocol.Selector(role: "AXMenuItem", label: nil, identifier: nil, labelContains: "Location")],
                                   scope: .menuBar),
            observationId: "o-mb-sel", context: OperationContext(budgetMs: 2000))
        XCTAssertEqual(filtered.observation.elements.count, 1)
        XCTAssertEqual(filtered.observation.elements.first?.label, "File > Open Location…")
    }

    func testConfirmShowMenuCancelInvokeMenuAndValueContainsPredicate() throws {
        let bounds = Rect(x: 0, y: 0, width: 900, height: 600)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 12), bundleId: "com.example.App", title: "Form", bounds: bounds)
        backend.records = [target]

        let win = GPNode("w", role: "AXWindow", title: "Form", bounds: bounds)
        let field = GPNode("f", role: "AXSearchField", title: "Search", value: "Nigeria startups", bounds: Rect(x: 20, y: 50, width: 220, height: 28))
        field.valueSettable = true
        field.actions = ["AXConfirm", "AXCancel", "AXShowMenu"]
        field.parent = win; field.owner = win
        win.children = [field]
        backend.appWindows = [win]

        let native = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: true),
            observationId: "o-bg", context: OperationContext(budgetMs: 2000))
        let el = try XCTUnwrap(native.observation.elements.first)
        XCTAssertTrue(el.actions.contains(.confirm))
        XCTAssertTrue(el.actions.contains(.showMenu))
        XCTAssertTrue(el.actions.contains(.cancel))

        let handle = try XCTUnwrap(native.handle as? SemanticObservationHandle)
        let retained = RetainedObservation(observation: native.observation, handle: handle, createdAt: 0)

        // PredicateEvaluator: valueContains + selector labelContains
        let eval = PredicateEvaluator()
        let ctx = OperationContext(budgetMs: 2000)
        XCTAssertEqual(try eval.evaluate(.valueContains(ValueContainsCondition(elementRef: el.reference, contains: "Nigeria")), handle: handle, context: ctx).matched, true)
        XCTAssertEqual(try eval.evaluate(.valueContains(ValueContainsCondition(elementRef: el.reference, contains: "Kenya")), handle: handle, context: ctx).matched, false)
        XCTAssertEqual(try eval.evaluate(.elementExists(ElementCondition(selector: CUAProtocol.Selector(role: "AXSearchField", label: nil, identifier: nil, labelContains: "Sear"))), handle: handle, context: ctx).matched, true)

        let actions = BackgroundActions(now: { 0 }, foreground: { 100 })
        let req = ActRequest(grantId: "g", observationId: "o-bg", target: target.key, steps: [
            ActionStep(actionId: "c1", operation: .confirm(ElementOperation(elementRef: el.reference)), precondition: nil, expect: nil),
            ActionStep(actionId: "m1", operation: .showMenu(ElementOperation(elementRef: el.reference)), precondition: nil, expect: nil),
            ActionStep(actionId: "x1", operation: .cancel(ElementOperation(elementRef: el.reference)), precondition: nil, expect: nil),
            ActionStep(actionId: "menu1", operation: .invokeMenu(InvokeMenuOperation(path: ["File", "New Tab"])), precondition: nil, expect: nil),
        ])
        let res = actions.act(req, entry: retained, context: ctx, state: ActionExecutionState(act: req), progress: { _, _ in })
        XCTAssertEqual(res.stopReason, .completed)
        XCTAssertEqual(res.steps.map(\.route), [.axConfirm, .axShowMenu, .axCancel, .axMenu])
        XCTAssertEqual(backend.confirmCalls, 1)
        XCTAssertEqual(backend.showMenuCalls, 1)
        XCTAssertEqual(backend.cancelCalls, 1)
        XCTAssertEqual(backend.invokedMenuPaths, [["File", "New Tab"]])
    }

    func testChromiumColdStartWaitsForInteractiveActionsToMaterialize() throws {
        let bounds = Rect(x: 0, y: 0, width: 900, height: 600)
        let backend = GPBackend()
        backend.prepareReturnsTrue = true
        let target = Target(key: TargetKey(pid: 9115, windowId: 13), bundleId: "com.google.Chrome", title: "Cold", bounds: bounds)
        backend.records = [target]
        let win = GPNode("w", role: "AXWindow", title: "Cold - Google Chrome", bounds: bounds)
        let web = GPNode("web", role: "AXWebArea", title: "Cold", url: "https://cold.example/", bounds: Rect(x: 0, y: 80, width: 900, height: 520))
        let btn = GPNode("btn", role: "AXButton", title: "Record Check", bounds: Rect(x: 20, y: 120, width: 120, height: 30))
        btn.actions = ["AXScrollToVisible"] // AXPress appears only after 2 probe reads!
        btn.parent = web; btn.owner = win
        web.children = [btn]; web.parent = win; web.owner = win
        win.children = [web]
        backend.appWindows = [win]
        backend.delayPressOnNode = btn
        backend.delayPressReads = 2

        let obs = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false),
            observationId: "o-cold", context: OperationContext(budgetMs: 2500))
        let observedBtn = try XCTUnwrap(obs.observation.elements.first { $0.label == "Record Check" })
        XCTAssertTrue(observedBtn.actions.contains(.press), "First observe on cold-started Chromium must settle until AXPress is published")
    }

    func testForegroundPointerDragHotkeyAndTypeKeysDispatch() throws {
        let bounds = Rect(x: 0, y: 0, width: 400, height: 300)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 14), bundleId: "com.google.Chrome", title: "FG", bounds: bounds)
        backend.records = [target]
        let win = GPNode("w", role: "AXWindow", title: "FG - Google Chrome", bounds: bounds)
        let web = GPNode("web", role: "AXWebArea", title: "FG", url: "https://fg.example/", bounds: bounds)
        web.parent = win; web.owner = win
        win.children = [web]
        backend.appWindows = [win]

        let img = makeSolidImage(width: 400, height: 300)
        let identity = ImageTransform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0,
                                      validImageBounds: bounds, coverage: .complete)
        let frame = VisualFrame(widthPx: 400, heightPx: 300, captureWindowBounds: bounds, captureScreenBounds: bounds,
                                imageToScreen: identity, imageToWindow: identity)
        let capture = SolidVisualCapture(image: img, frame: frame)
        let system = MacOSSystem(backend: backend, catalog: backend, visual: capture, isAXTrusted: { true })
        let native = try system.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: true, includeValues: false),
            observationId: "o-fg", context: OperationContext(budgetMs: 2000))
        let retained = RetainedObservation(observation: native.observation, handle: native.handle, createdAt: 0)

        let platform = GPForegroundPlatform()
        platform.focusedWin = win
        platform.focusedEl = web
        let actions = BackgroundActions(now: { 0 }, foreground: { 9115 }, foregroundPlatform: platform, coordinateCapture: capture)
        let req = ActRequest(grantId: "g", observationId: "o-fg", target: target.key, steps: [
            ActionStep(actionId: "h", operation: .hover(ClickOperation(point: Point(x: 60, y: 60), space: .windowPoints)), precondition: nil, expect: nil),
            ActionStep(actionId: "dc", operation: .doubleClick(ClickOperation(point: Point(x: 60, y: 60), space: .windowPoints)), precondition: nil, expect: nil),
            ActionStep(actionId: "rc", operation: .rightClick(ClickOperation(point: Point(x: 60, y: 60), space: .windowPoints)), precondition: nil, expect: nil),
            ActionStep(actionId: "dr", operation: .drag(DragOperation(from: Point(x: 60, y: 60), to: Point(x: 200, y: 150), space: .windowPoints, steps: 5)), precondition: nil, expect: nil),
            ActionStep(actionId: "hk", operation: .hotkey(HotkeyOperation(key: "l", modifiers: [.command])), precondition: nil, expect: nil),
            ActionStep(actionId: "tk", operation: .typeKeys(TypeKeysOperation(text: "https://example.com\n")), precondition: nil, expect: nil),
        ], foreground: true)
        let res = actions.act(req, entry: retained, context: OperationContext(budgetMs: 2500), state: ActionExecutionState(act: req), progress: { _, _ in })
        XCTAssertEqual(res.stopReason, .completed)
        XCTAssertEqual(res.steps.map(\.route), [
            .foregroundHover, .foregroundDoubleClick, .foregroundRightClick, .foregroundDrag, .foregroundHotkey, .foregroundTypeKeys
        ])
        XCTAssertEqual(platform.posted, [
            .hover(Point(x: 60, y: 60)),
            .doubleClick(Point(x: 60, y: 60)),
            .rightClick(Point(x: 60, y: 60)),
            .drag(from: Point(x: 60, y: 60), to: Point(x: 200, y: 150), steps: 5),
            .hotkey(key: "l", modifiers: [.command]),
            .typeKeys("https://example.com\n"),
        ])

        // Every valid hotkey name must have a Carbon virtual key code mapping.
        for name in ["a", "z", "0", "9", "minus", "equal", "leftBracket", "rightBracket", "backslash", "semicolon",
                     "quote", "comma", "period", "slash", "grave", "space", "return", "tab", "escape", "backspace",
                     "delete", "left", "right", "up", "down", "home", "end", "pageUp", "pageDown", "f1", "f12"] {
            XCTAssertTrue(isValidHotkeyName(name), name)
            XCTAssertNotNil(NativeForegroundPlatform.virtualKeyCode(for: name), name)
        }
    }

    func testRuntimeSessionOpenAndWaitForIncludeValues() throws {
        let bounds = Rect(x: 0, y: 0, width: 800, height: 600)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 15), bundleId: "com.google.Chrome", title: "Ready", bounds: bounds)
        backend.records = [target]
        let win = GPNode("w", role: "AXWindow", title: "Ready - Google Chrome", bounds: bounds)
        let web = GPNode("web", role: "AXWebArea", title: "Ready", url: "https://example.com/done", bounds: Rect(x: 0, y: 80, width: 800, height: 520))
        let status = GPNode("st", role: "AXStaticText", title: "Status", value: "DONE:42", bounds: Rect(x: 20, y: 120, width: 120, height: 20))
        status.parent = web; status.owner = win
        web.children = [status]; web.parent = win; web.owner = win
        win.children = [web]
        backend.appWindows = [win]

        let opener = FakeOpener(OpenResult(pid: 9115, bundleId: "com.google.Chrome", activated: false, targets: [target]))
        let img = makeSolidImage(width: 800, height: 600)
        let identity = ImageTransform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0, validImageBounds: bounds, coverage: .complete)
        let system = MacOSSystem(backend: backend, catalog: backend,
                                 visual: SolidVisualCapture(image: img, frame: VisualFrame(widthPx: 800, heightPx: 600,
                                     captureWindowBounds: bounds, captureScreenBounds: bounds, imageToScreen: identity, imageToWindow: identity)),
                                 opener: opener, isAXTrusted: { true })
        let values = TestCollector()
        let session = RuntimeSession(system: system, epoch: "e1", emit: values.append)
        defer { session.shutdown() }

        func send(_ id: String, _ body: RequestBody, epoch: String? = "e1") throws -> Response {
            let req = Request(version: 1, id: id, epoch: epoch, budgetMs: 2000, body: body)
            session.receive(req, frameBytes: try Frame.request(req).encodeLine().count)
            return try values.response(id)
        }

        _ = try send("h", .hello(HelloRequest(clientName: "t", supportedVersions: [1],
                                              authority: Authority(grantId: "g1", mode: .backgroundRequired))), epoch: nil)

        // Background open succeeds; activate: true is denied under backgroundRequired.
        let openBg = try send("o1", .open(OpenRequest(grantId: "g1", bundleId: "com.google.Chrome", url: "https://example.com/done")))
        guard case .open(let opened) = openBg.body else { return XCTFail("expected open result") }
        XCTAssertEqual(opened.pid, 9115)
        XCTAssertEqual(opened.targets.count, 1)
        XCTAssertFalse(opened.activated)

        let openFgDenied = try send("o2", .open(OpenRequest(grantId: "g1", bundleId: "com.google.Chrome", activate: true)))
        guard case .error(let err) = openFgDenied.body else { return XCTFail("expected authority error") }
        XCTAssertEqual(err.code, .authorityDenied)

        // Observe then waitFor with includeValues: true and scope: .webArea returns live value directly.
        let obsRes = try send("obs", .observe(ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false)))
        guard case .observe(let obs) = obsRes.body else { return XCTFail("expected observation") }
        let waitRes = try send("w1", .waitFor(WaitRequest(observationId: obs.observationId, target: target.key,
                                                          condition: .urlContains(UrlCondition(contains: "/done")),
                                                          includeValues: true, scope: .webArea)))
        guard case .waitFor(let waited) = waitRes.body, let waitedObs = waited.observation else {
            return XCTFail("expected satisfied wait observation")
        }
        XCTAssertEqual(waited.outcome, .satisfied)
        XCTAssertEqual(waitedObs.accessibility, .partial)
        XCTAssertTrue(waitedObs.elements.contains { $0.value == "DONE:42" })
    }
}
