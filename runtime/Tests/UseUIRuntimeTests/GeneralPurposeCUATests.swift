import CoreGraphics
import UseUIProtocol
@testable import UseUIRuntime
import Foundation
import XCTest

private final class GPNode: AXObject, @unchecked Sendable {
    let id: String
    var pid: UInt32 = 9115
    var role: String
    var title: String?
    var label: String?
    var identifier: String?
    var subrole: String?
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

    init(_ id: String, role: String, title: String? = nil, label: String? = nil, identifier: String? = nil,
         subrole: String? = nil, value: String? = nil,
         url: String? = nil, bounds: Rect = Rect(x: 10, y: 10, width: 100, height: 24)) {
        self.id = id
        self.role = role
        self.title = title
        self.label = label ?? title
        self.identifier = identifier
        self.subrole = subrole
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
    var invokedMenuWindowIDs: [String] = []
    var setFrames: [Rect] = []
    var windowActions: [WindowActionKind] = []
    var onWindowAction: ((WindowActionKind) -> Void)?

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
        return AXNodeSnapshot(role: node.role, title: node.title, label: node.label, identifier: node.identifier, bounds: node.bounds,
                              enabled: node.enabled, enabledKnown: node.enabledKnown, value: val,
                              valueSettable: node.valueSettable, actions: actions, complete: node.complete, subrole: node.subrole, url: node.url)
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
    func invokeMenu(_ path: [String], on application: any AXObject, window: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
        lock.lock()
        invokedMenuPaths.append(path)
        if let node = window as? GPNode { invokedMenuWindowIDs.append(node.id) }
        lock.unlock()
    }
    func setWindowFrame(_ bounds: Rect, on window: any AXObject, windowId: UInt32, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
        lock.lock(); setFrames.append(bounds); lock.unlock()
    }
    func windowAction(_ action: WindowActionKind, on window: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
        lock.lock(); windowActions.append(action); let hook = onWindowAction; lock.unlock()
        hook?(action)
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
    var activations: [UInt32] = []

    func permissionAvailable() -> Bool { true }
    func visualPermissionAvailable() -> Bool { true }
    func sample() -> ForegroundSample { ForegroundSample(pid: pid, hardwareCounters: [0], inputHeld: false) }
    func watch(expecting pid: UInt32) -> ActivationWatch { ActivationWatch(expecting: pid) }
    func focusedWindow(pid: UInt32, context: OperationContext) throws -> (any AXObject)? { focusedWin }
    func focusedElement(pid: UInt32, context: OperationContext) throws -> (any AXObject)? { focusedEl }
    func activate(pid: UInt32, window: any AXObject, context: OperationContext, willChangeFocus: () throws -> Void) throws {
        try willChangeFocus()
        self.pid = pid
        self.focusedWin = window
        activations.append(pid)
    }
    func hitTest(_ point: Point, in target: SemanticObservationHandle, context: OperationContext) throws -> Bool { true }
    func visualHitTest(_ point: Point, in target: Target, context: OperationContext) throws -> Bool { true }
    func post(_ input: ForegroundInput, willDispatch: () throws -> Void) throws {
        try willDispatch()
        posted.append(input)
    }
}

private final class FakeClipboardManager: ClipboardManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var changeCount: UInt64 = 1
    private var content: String?
    private var types: [String] = []

    func perform(_ request: ClipboardRequest, context: OperationContext) throws -> ClipboardResult {
        try context.check()
        lock.lock(); defer { lock.unlock() }
        switch request.action {
        case .read:
            let bytes = content.map { UInt32($0.utf8.count) }
            return ClipboardResult(changeCount: changeCount, types: types,
                                   text: request.includeText ? content : nil, textBytes: bytes)
        case .write:
            changeCount += 1
            if let text = request.text {
                content = text; types = ["public.utf8-plain-text"]
            } else if request.filePath != nil {
                content = nil; types = ["public.file-url"]
            } else if request.imagePath != nil {
                content = nil; types = ["public.png"]
            }
            let bytes = content.map { UInt32($0.utf8.count) }
            return ClipboardResult(changeCount: changeCount, types: types, text: nil, textBytes: bytes)
        case .clear:
            changeCount += 1
            content = nil; types = []
            return ClipboardResult(changeCount: changeCount, types: [], text: nil, textBytes: nil)
        }
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
        // Chromium advertises AXShowMenu (context menu) + AXScrollToVisible on static text/headings/cells.
        staticText.actions = ["AXScrollToVisible", "AXShowMenu"]
        staticText.parent = web; staticText.owner = win
        let heading = GPNode("hd", role: "AXHeading", title: "Section", bounds: Rect(x: 20, y: 120, width: 200, height: 20))
        heading.actions = ["AXScrollToVisible", "AXShowMenu"]
        heading.parent = web; heading.owner = win
        let submitBtn = GPNode("btn", role: "AXButton", title: "Submit Order", bounds: Rect(x: 20, y: 140, width: 120, height: 32))
        submitBtn.actions = ["AXPress", "AXScrollToVisible", "AXShowMenu"]; submitBtn.parent = web; submitBtn.owner = win
        web.children = [staticText, heading, submitBtn]
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
        XCTAssertFalse(interactiveWeb.observation.elements.contains { $0.role == "AXStaticText" || $0.role == "AXHeading" })
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
                                   axSelectors: [UseUIProtocol.Selector(role: "AXMenuItem", label: nil, identifier: nil, labelContains: "Location")],
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
        XCTAssertEqual(try eval.evaluate(.elementExists(ElementCondition(selector: UseUIProtocol.Selector(role: "AXSearchField", label: nil, identifier: nil, labelContains: "Sear"))), handle: handle, context: ctx).matched, true)

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
        XCTAssertEqual(backend.invokedMenuWindowIDs, ["w"])
    }

    func testChromiumColdStartWaitsForInteractiveActionsToMaterialize() throws {
        let bounds = Rect(x: 0, y: 0, width: 900, height: 600)
        let backend = GPBackend()
        backend.prepareReturnsTrue = true
        let target = Target(key: TargetKey(pid: 9115, windowId: 13), bundleId: "com.google.Chrome", title: "Cold", bounds: bounds)
        backend.records = [target]
        let win = GPNode("w", role: "AXWindow", title: "Cold - Google Chrome", bounds: bounds)
        let web = GPNode("web", role: "AXWebArea", title: "Cold", url: "https://cold.example/", bounds: Rect(x: 0, y: 80, width: 900, height: 520))
        // A writable search field is ready immediately, while buttons/links still wait for AXPress.
        let search = GPNode("search", role: "AXTextField", title: "Search", bounds: Rect(x: 20, y: 90, width: 200, height: 24))
        search.valueSettable = true
        search.parent = web; search.owner = win
        let btn = GPNode("btn", role: "AXButton", title: "Record Check", bounds: Rect(x: 20, y: 120, width: 120, height: 30))
        btn.actions = ["AXScrollToVisible", "AXShowMenu"] // AXPress appears only after 2 probe reads!
        btn.parent = web; btn.owner = win
        web.children = [search, btn]; web.parent = win; web.owner = win
        win.children = [web]
        backend.appWindows = [win]
        backend.delayPressOnNode = btn
        backend.delayPressReads = 2

        let obs = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false),
            observationId: "o-cold", context: OperationContext(budgetMs: 2500))
        let observedBtn = try XCTUnwrap(obs.observation.elements.first { $0.label == "Record Check" })
        XCTAssertTrue(observedBtn.actions.contains(.press), "First observe on cold-started Chromium must settle until AXPress is published even when a writable AXTextField is already present")
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

    func testObserveQueryRespectsValuePrivacyAndRolelessSelectorMatchesAcrossRoles() throws {
        let bounds = Rect(x: 0, y: 0, width: 1000, height: 700)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 20), bundleId: "com.google.Chrome", title: "Shop", bounds: bounds)
        backend.records = [target]

        let win = GPNode("w", role: "AXWindow", title: "Shop", bounds: bounds)
        let btn = GPNode("b", role: "AXButton", title: "Proceed to Checkout", identifier: "btn-checkout", bounds: Rect(x: 20, y: 100, width: 140, height: 32))
        btn.actions = ["AXPress"]; btn.parent = win; btn.owner = win
        let link = GPNode("l", role: "AXLink", title: "Express Checkout", url: "https://shop.example/pay", bounds: Rect(x: 20, y: 150, width: 140, height: 24))
        link.actions = ["AXPress"]; link.parent = win; link.owner = win
        let secret = GPNode("s", role: "AXTextField", title: "Coupon", value: "SECRET-VIP-CODE", bounds: Rect(x: 20, y: 200, width: 200, height: 28))
        secret.valueSettable = true; secret.parent = win; secret.owner = win
        win.children = [btn, link, secret]
        backend.appWindows = [win]

        let observer = SemanticAXObserver(backend: backend, catalog: backend)
        let ctx = OperationContext(budgetMs: 2000)

        // Case-insensitive query matches label, URL, and identifier; marks accessibility partial.
        let byQuery = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false, query: "CHECKOUT"),
            observationId: "o-q1", context: ctx)
        XCTAssertEqual(byQuery.observation.accessibility, .partial)
        XCTAssertEqual(Set(byQuery.observation.elements.compactMap(\.label)), ["Proceed to Checkout", "Express Checkout"])

        // Query matches URL even when label doesn't contain it.
        let byUrl = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false, query: "/pay"),
            observationId: "o-q2", context: ctx)
        XCTAssertEqual(byUrl.observation.elements.compactMap(\.label), ["Express Checkout"])

        // Privacy: query must NOT match element value when includeValues is false!
        let hiddenSecret = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false, query: "SECRET-VIP"),
            observationId: "o-q3", context: ctx)
        XCTAssertTrue(hiddenSecret.observation.elements.isEmpty)

        // With includeValues: true, query matches value too.
        let visibleSecret = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: true, query: "SECRET-VIP"),
            observationId: "o-q4", context: ctx)
        XCTAssertEqual(visibleSecret.observation.elements.compactMap(\.label), ["Coupon"])

        // Role-optional Selector matches BOTH AXButton and AXLink without specifying role.
        let roleless = try observer.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false,
                                   axSelectors: [UseUIProtocol.Selector(role: nil, label: nil, identifier: nil, labelContains: "Checkout")]),
            observationId: "o-rl", context: ctx)
        XCTAssertEqual(Set(roleless.observation.elements.map(\.role)), ["AXButton", "AXLink"])
        XCTAssertEqual(roleless.observation.axSelection?.ambiguous, true)
    }

    func testUnifiedTargetsDiscoveryIncludesOffscreenAppsAndDisplays() throws {
        @Sendable func makeRecord(id: UInt32, title: String, x: Double, y: Double) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: UInt32(42),
                kCGWindowNumber as String: id,
                kCGWindowLayer as String: 0,
                kCGWindowName as String: title,
                kCGWindowOwnerName as String: "Notes",
                kCGWindowBounds as String: ["X": x, "Y": y, "Width": 800.0, "Height": 600.0],
            ]
        }
        let gen = ProcessGeneration(startAbstime: 10, executableUUID: UUID())
        let catalog = MacOSWindowCatalog(
            windowRecords: { [makeRecord(id: 101, title: "Visible Window", x: 0, y: 25)] },
            processOwners: { _ in [42: WindowProcessOwner(generation: gen, bundleId: "com.apple.Notes")] },
            allWindowRecords: { [
                makeRecord(id: 101, title: "Visible Window", x: 0, y: 25),
                makeRecord(id: 102, title: "Minimized Window", x: 10, y: 30),
            ] },
            apps: { [
                AppInfo(pid: 42, bundleId: "com.apple.Notes", name: "Notes", running: true, active: true, hidden: false),
                AppInfo(pid: nil, bundleId: "com.apple.Safari", name: "Safari", running: false, active: false, hidden: false),
            ] },
            displays: { [
                DisplayInfo(displayId: 1, bounds: Rect(x: 0, y: 0, width: 1440, height: 900), scaleFactor: 2.0, isPrimary: true),
            ] }
        )
        let ctx = OperationContext(budgetMs: 2000)

        // Default request omits onScreen, apps, displays.
        let basic = try catalog.targets(TargetsRequest(), context: ctx)
        XCTAssertEqual(basic.targets.count, 1)
        XCTAssertNil(basic.targets[0].onScreen)
        XCTAssertNil(basic.apps)
        XCTAssertNil(basic.displays)

        // Full discovery includes offscreen with onScreen flags, apps, and displays.
        let full = try catalog.targets(TargetsRequest(includeOffscreen: true, includeApps: true, includeDisplays: true), context: ctx)
        XCTAssertEqual(full.targets.count, 2)
        XCTAssertEqual(full.targets.first(where: { $0.key.windowId == 101 })?.onScreen, true)
        XCTAssertEqual(full.targets.first(where: { $0.key.windowId == 102 })?.onScreen, false)
        XCTAssertEqual(full.apps?.count, 2)
        XCTAssertEqual(full.displays?.first?.isPrimary, true)

        // Filtering by bundleId also filters apps list.
        let filtered = try catalog.targets(TargetsRequest(bundleId: "com.apple.Safari", includeApps: true), context: ctx)
        XCTAssertTrue(filtered.targets.isEmpty)
        XCTAssertEqual(filtered.apps?.map(\.name), ["Safari"])
    }

    func testBackgroundWindowFrameAndWindowActionCloseWithWindowAbsentExpectation() throws {
        let bounds = Rect(x: 0, y: 0, width: 800, height: 600)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 21), bundleId: "com.example.App", title: "Doc", bounds: bounds)
        backend.records = [target]
        let win = GPNode("w", role: "AXWindow", title: "Doc", bounds: bounds)
        let btn = GPNode("b", role: "AXButton", title: "Save", bounds: Rect(x: 20, y: 40, width: 80, height: 24))
        btn.actions = ["AXPress"]; btn.parent = win; btn.owner = win
        win.children = [btn]
        backend.appWindows = [win]

        let ctx = OperationContext(budgetMs: 2000)
        let native = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false),
            observationId: "o-win", context: ctx)
        let retained = RetainedObservation(observation: native.observation, handle: native.handle, createdAt: 0)

        final class FlagBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
            func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
        }
        let windowClosed = FlagBox()
        backend.onWindowAction = { action in
            if action == .close { windowClosed.set(true) }
        }
        let actions = BackgroundActions(
            predicates: PredicateEvaluator(windowPresent: { _, _ in !windowClosed.get() }),
            now: { 0 }, foreground: { 100 })
        let nextBounds = Rect(x: 120, y: 80, width: 960, height: 640)
        let req = ActRequest(grantId: "g", observationId: "o-win", target: target.key, steps: [
            ActionStep(actionId: "f1", operation: .setWindowFrame(SetWindowFrameOperation(bounds: nextBounds)), precondition: nil, expect: nil),
            ActionStep(actionId: "w1", operation: .windowAction(WindowActionOperation(action: .minimize)), precondition: nil, expect: nil),
            ActionStep(actionId: "w2", operation: .windowAction(WindowActionOperation(action: .close)),
                       precondition: nil, expect: .windowAbsent(Empty())),
        ])
        let res = actions.act(req, entry: retained, context: ctx, state: ActionExecutionState(act: req), progress: { _, _ in })
        XCTAssertEqual(res.stopReason, .completed)
        XCTAssertEqual(res.steps.map(\.route), [.axWindowFrame, .axWindowAction, .axWindowAction])
        XCTAssertEqual(res.steps[2].verification, .confirmed)
        XCTAssertEqual(backend.setFrames, [nextBounds])
        XCTAssertEqual(backend.windowActions, [.minimize, .close])
    }

    func testForegroundScrollWheelAndPersistentFocusWindowSkipRestore() throws {
        let bounds = Rect(x: 0, y: 0, width: 400, height: 300)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 22), bundleId: "com.google.Chrome", title: "Canvas", bounds: bounds)
        backend.records = [target]
        let win = GPNode("w", role: "AXWindow", title: "Canvas", bounds: bounds)
        let web = GPNode("web", role: "AXWebArea", title: "Canvas", bounds: bounds)
        web.parent = win; web.owner = win
        win.children = [web]
        backend.appWindows = [win]

        let img = makeSolidImage(width: 400, height: 300)
        let identity = ImageTransform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0, validImageBounds: bounds, coverage: .complete)
        let frame = VisualFrame(widthPx: 400, heightPx: 300, captureWindowBounds: bounds, captureScreenBounds: bounds,
                                imageToScreen: identity, imageToWindow: identity)
        let capture = SolidVisualCapture(image: img, frame: frame)
        let system = MacOSSystem(backend: backend, catalog: backend, visual: capture, isAXTrusted: { true })
        let ctx = OperationContext(budgetMs: 2500)
        let native = try system.observe(
            params: ObserveRequest(target: target.key, includeScreenshot: true, includeValues: false),
            observationId: "o-fg2", context: ctx)
        let retained = RetainedObservation(observation: native.observation, handle: native.handle, createdAt: 0)

        let priorWin = GPNode("prior", role: "AXWindow", title: "Terminal", bounds: bounds)
        let platform = GPForegroundPlatform()
        platform.pid = 777 // Different app starts in foreground!
        platform.focusedWin = priorWin
        platform.focusedEl = web

        let actions = BackgroundActions(now: { 0 }, foreground: { 777 }, foregroundPlatform: platform, coordinateCapture: capture)
        let req = ActRequest(grantId: "g", observationId: "o-fg2", target: target.key, steps: [
            ActionStep(actionId: "focus", operation: .focusWindow(Empty()), precondition: nil, expect: nil),
            ActionStep(actionId: "wheel", operation: .scrollWheel(ScrollWheelOperation(point: Point(x: 100, y: 120), space: .windowPoints, deltaX: 10, deltaY: 240)),
                       precondition: nil, expect: nil),
        ], foreground: true)
        let res = actions.act(req, entry: retained, context: ctx, state: ActionExecutionState(act: req), progress: { _, _ in })
        XCTAssertEqual(res.stopReason, .completed)
        XCTAssertEqual(res.steps.map(\.route), [.foregroundFocus, .foregroundScrollWheel])
        XCTAssertEqual(res.foreground?.activationRequested, true)
        XCTAssertEqual(res.foreground?.restoration, .notNeeded, "focusWindow must persist focus without restoring prior app")
        XCTAssertEqual(platform.activations, [9115], "prior app 777 must not be re-activated after focusWindow")
        XCTAssertEqual(platform.pid, 9115)
        XCTAssertEqual(platform.posted, [.focusWindow, .scrollWheel(point: Point(x: 100, y: 120), deltaX: 10, deltaY: 240)])
    }

    func testOcrContainsWaitOnVisualOnlyWindowAndClipboardPrivacyInSession() throws {
        let bounds = Rect(x: 0, y: 0, width: 400, height: 300)
        let gen = ProcessGeneration(startAbstime: 99, executableUUID: UUID())
        let catalog = MacOSWindowCatalog(
            windowRecords: { [[
                kCGWindowOwnerPID as String: UInt32(9115),
                kCGWindowNumber as String: UInt32(23),
                kCGWindowLayer as String: 0,
                kCGWindowName as String: "GameCanvas",
                kCGWindowOwnerName as String: "CanvasApp",
                kCGWindowBounds as String: ["X": 0.0, "Y": 0.0, "Width": 400.0, "Height": 300.0],
            ]] },
            processOwners: { _ in [9115: WindowProcessOwner(generation: gen, bundleId: nil)] }
        )
        let backend = GPBackend() // No AX windows -> falls back to VisualObservationHandle!
        let img = makeSolidImage(width: 400, height: 300)
        let identity = ImageTransform(scaleX: 1, scaleY: 1, offsetX: 0, offsetY: 0, validImageBounds: bounds, coverage: .complete)
        let frame = VisualFrame(widthPx: 400, heightPx: 300, captureWindowBounds: bounds, captureScreenBounds: bounds,
                                imageToScreen: identity, imageToWindow: identity)
        let capture = SolidVisualCapture(image: img, frame: frame)
        let clipboard = FakeClipboardManager()
        let system = MacOSSystem(backend: backend, catalog: catalog, visual: capture,
                                 clipboardManager: clipboard, isAXTrusted: { false })
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
        }
        let ocrReads = CounterBox()
        let predicates = PredicateEvaluator(
            windowPresent: { _, _ in true },
            visual: capture,
            ocr: { _, query, _ in
                let count = ocrReads.next()
                let now = UInt64(Date().timeIntervalSince1970 * 1000)
                let interval = CollectionInterval(startedUnixMs: now, finishedUnixMs: now)
                if count >= 2, query == "PAY NOW" {
                    return OcrEvidence(status: .complete, collected: interval,
                                       matches: [OcrMatch(text: "PAY NOW", imageBounds: Rect(x: 10, y: 10, width: 80, height: 20))])
                }
                return OcrEvidence(status: .complete, collected: interval, matches: [])
            }
        )
        let actions = BackgroundActions(predicates: predicates)
        let values = TestCollector()
        let session = RuntimeSession(system: system, epoch: "e2", actions: actions, emit: values.append)
        defer { session.shutdown() }

        func send(_ id: String, _ body: RequestBody, epoch: String? = "e2") throws -> Response {
            let req = Request(version: 1, id: id, epoch: epoch, budgetMs: 3000, body: body)
            session.receive(req, frameBytes: try Frame.request(req).encodeLine().count)
            return try values.response(id)
        }

        _ = try send("h", .hello(HelloRequest(clientName: "t", supportedVersions: [1],
                                              authority: Authority(grantId: "g2", mode: .backgroundRequired))), epoch: nil)

        // Clipboard write, metadata-only read (no text), opt-in read (with text), and clear.
        let writeRes = try send("cb1", .clipboard(ClipboardRequest(grantId: "g2", action: .write, text: "secret token")))
        guard case .clipboard(let written) = writeRes.body else { return XCTFail("expected clipboard write result") }
        XCTAssertNil(written.text)
        XCTAssertEqual(written.textBytes, 12)
        XCTAssertEqual(written.types, ["public.utf8-plain-text"])

        let metaRes = try send("cb2", .clipboard(ClipboardRequest(grantId: "g2", action: .read, includeText: false)))
        guard case .clipboard(let meta) = metaRes.body else { return XCTFail("expected clipboard read result") }
        XCTAssertNil(meta.text)
        XCTAssertEqual(meta.textBytes, 12)

        let fullRes = try send("cb3", .clipboard(ClipboardRequest(grantId: "g2", action: .read, includeText: true)))
        guard case .clipboard(let full) = fullRes.body else { return XCTFail("expected clipboard full read") }
        XCTAssertEqual(full.text, "secret token")

        let clearRes = try send("cb4", .clipboard(ClipboardRequest(grantId: "g2", action: .clear)))
        guard case .clipboard(let cleared) = clearRes.body else { return XCTFail("expected clipboard clear") }
        XCTAssertTrue(cleared.types.isEmpty)
        XCTAssertNil(cleared.text)

        // Visual-only observation (no AX) -> waitFor(ocrContains) succeeds on 2nd poll!
        let targetKey = TargetKey(pid: 9115, windowId: 23)
        let obsRes = try send("obs", .observe(ObserveRequest(target: targetKey, includeScreenshot: true, includeValues: false)))
        guard case .observe(let obs) = obsRes.body else { return XCTFail("expected visual observation") }
        XCTAssertEqual(obs.accessibility, .unavailable)

        let waitRes = try send("w-ocr", .waitFor(WaitRequest(observationId: obs.observationId, target: targetKey,
                                                             condition: .ocrContains(OcrCondition(contains: "PAY NOW")))))
        guard case .waitFor(let waited) = waitRes.body else { return XCTFail("expected wait result") }
        XCTAssertEqual(waited.outcome, .satisfied)
        XCTAssertEqual(waited.alreadySatisfied, false)
        XCTAssertEqual(waited.evidence?.matched, true)
        XCTAssertNotNil(waited.observation)
    }

    func testActObserveAfterAndOpenObserveRegisterLiveShortRefObservations() throws {
        let bounds = Rect(x: 0, y: 0, width: 900, height: 600)
        let backend = GPBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 30), bundleId: "com.google.Chrome", title: "Directory", bounds: bounds)
        backend.records = [target]

        let win = GPNode("w", role: "AXWindow", title: "Directory", bounds: bounds)
        let web = GPNode("web", role: "AXWebArea", title: "Directory", url: "https://startuplist.africa/startups", bounds: bounds)
        let btn = GPNode("btn", role: "AXLink", title: "OPay", url: "https://startuplist.africa/startups/opay",
                         bounds: Rect(x: 20, y: 100, width: 120, height: 24))
        btn.actions = ["AXPress"]
        btn.parent = web; btn.owner = win
        web.children = [btn]; web.parent = win; web.owner = win
        win.children = [web]
        backend.appWindows = [win]

        let opener = FakeOpener(OpenResult(pid: 9115, bundleId: "com.google.Chrome", activated: false, targets: [target]))
        let system = MacOSSystem(backend: backend, catalog: backend, visual: ScreenWindowCapture(),
                                 opener: opener, isAXTrusted: { true })
        let values = TestCollector()
        let session = RuntimeSession(system: system, epoch: "ep-fast", emit: values.append)
        defer { session.shutdown() }

        func send(_ id: String, _ body: RequestBody, epoch: String? = "ep-fast") throws -> Response {
            let req = Request(version: 1, id: id, epoch: epoch, budgetMs: 3000, body: body)
            session.receive(req, frameBytes: try Frame.request(req).encodeLine().count)
            return try values.response(id)
        }

        _ = try send("h", .hello(HelloRequest(clientName: "t", supportedVersions: [1],
                                              authority: Authority(grantId: "g-fast", mode: .backgroundRequired))), epoch: nil)

        // 1. open(..., observe:) returns and registers an initial observation with short refs (obs-1, eN.M).
        let openRes = try send("op", .open(OpenRequest(grantId: "g-fast", bundleId: "com.google.Chrome",
                                                       url: "https://startuplist.africa/startups",
                                                       observe: ObserveAfter(scope: .webArea, interactiveOnly: true))))
        guard case .open(let opened) = openRes.body else { return XCTFail("expected open result") }
        let initialObs = try XCTUnwrap(opened.observation)
        XCTAssertTrue(initialObs.observationId.hasPrefix("obs-"))
        let linkEl = try XCTUnwrap(initialObs.elements.first { $0.label == "OPay" })
        XCTAssertTrue(linkEl.reference.hasPrefix("e"), "Expected compact ref, got \(linkEl.reference)")
        XCTAssertLessThan(linkEl.reference.count, 12)

        // 2. act(..., observeAfter:) uses the observation registered by open() AND returns a newly registered observation!
        let actRes = try send("a1", .act(ActRequest(
            grantId: "g-fast",
            observationId: initialObs.observationId,
            target: target.key,
            steps: [ActionStep(actionId: "click-opay", operation: .press(ElementOperation(elementRef: linkEl.reference)),
                               precondition: nil, expect: nil)],
            observeAfter: ObserveAfter(scope: .webArea, interactiveOnly: true)
        )))
        guard case .act(let acted) = actRes.body else { return XCTFail("expected act result") }
        XCTAssertEqual(acted.stopReason, .completed)
        let afterObs = try XCTUnwrap(acted.observation)
        XCTAssertNotEqual(afterObs.observationId, initialObs.observationId)
        let afterLink = try XCTUnwrap(afterObs.elements.first { $0.label == "OPay" })
        XCTAssertNotEqual(afterLink.reference, linkEl.reference, "Disjoint short refs across observations")

        // 3. Follow-up act immediately succeeds using the observationId & ref from observeAfter!
        let actRes2 = try send("a2", .act(ActRequest(
            grantId: "g-fast",
            observationId: afterObs.observationId,
            target: target.key,
            steps: [ActionStep(actionId: "click-again", operation: .press(ElementOperation(elementRef: afterLink.reference)),
                               precondition: nil, expect: nil)]
        )))
        guard case .act(let acted2) = actRes2.body else { return XCTFail("expected second act result") }
        XCTAssertEqual(acted2.stopReason, .completed)
    }

    func testAXSheetTargetAssociatesWithParentWindowSheetAndResolvesControls() throws {
        let winBounds = Rect(x: 0, y: 39, width: 1400, height: 900)
        let sheetBounds = Rect(x: 260, y: 114, width: 880, height: 600)
        let backend = GPBackend()
        let parentTarget = Target(key: TargetKey(pid: 9115, windowId: 40), bundleId: "com.google.Chrome", title: "Extensions", bounds: winBounds)
        let sheetTarget = Target(key: TargetKey(pid: 9115, windowId: 41), bundleId: "com.google.Chrome", title: "Open", bounds: sheetBounds)
        backend.records = [parentTarget, sheetTarget]

        let win = GPNode("w", role: "AXWindow", title: "Extensions", bounds: winBounds)
        let sheet = GPNode("sheet", role: "AXSheet", title: "open", bounds: sheetBounds)
        let selectBtn = GPNode("ok", role: "AXButton", title: "Select", identifier: "OKButton",
                               bounds: Rect(x: 1020, y: 670, width: 90, height: 28))
        selectBtn.actions = ["AXPress"]
        selectBtn.parent = sheet; selectBtn.owner = win // AppKit AXWindow of a sheet child points to parent window!
        sheet.children = [selectBtn]; sheet.parent = win; sheet.owner = win
        win.children = [sheet]
        backend.appWindows = [win]

        let observer = SemanticAXObserver(backend: backend, catalog: backend)
        let obs = try observer.observe(
            params: ObserveRequest(target: sheetTarget.key, includeScreenshot: false, includeValues: false),
            observationId: "obs-sheet", context: OperationContext(budgetMs: 2000))
        let foundSelect = try XCTUnwrap(obs.observation.elements.first { $0.label == "Select" })
        XCTAssertTrue(foundSelect.actions.contains(.press))
        let handle = try XCTUnwrap(obs.handle as? SemanticObservationHandle)
        let resolved = try handle.resolve(foundSelect.reference, context: OperationContext(budgetMs: 2000))
        XCTAssertTrue(backend.same(resolved.object, selectBtn))
    }
}
