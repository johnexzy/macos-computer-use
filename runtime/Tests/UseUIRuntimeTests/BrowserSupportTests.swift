import UseUIProtocol
@testable import UseUIRuntime
import Foundation
import XCTest

private final class BrowserNode: AXObject, @unchecked Sendable {
    let id: String
    var pid: UInt32 = 9115
    var role: String
    var title: String?
    var label: String?
    var url: String?
    var bounds: Rect
    var enabled = true
    var enabledKnown = true
    var enabledUnsupported = false
    var valueSettable = false
    var actions: [String] = []
    var children: [BrowserNode] = []
    var complete = true
    weak var parent: BrowserNode?
    weak var owner: BrowserNode?

    init(_ id: String, role: String, title: String? = nil, label: String? = nil, url: String? = nil, bounds: Rect) {
        self.id = id
        self.role = role
        self.title = title
        self.label = label ?? title
        self.url = url
        self.bounds = bounds
    }
}

private final class BrowserBackend: AXReading, AXMutating, WindowCatalog, @unchecked Sendable {
    let app = BrowserNode("app", role: "AXApplication", bounds: Rect(x: 0, y: 0, width: 1, height: 1))
    var appWindows: [BrowserNode] = []
    var records: [Target] = []
    var focused: BrowserNode?
    var prepareReturnsTrue = false
    var delayWebAreaScans = 0
    private let lock = NSLock()
    private var childReads = 0
    var scrollToVisibleCalls = 0
    var delayedWebArea: BrowserNode?

    func prepareBrowserAccessibility(application: any AXObject, bundleId: String?, context: OperationContext) throws -> Bool {
        try context.check()
        return prepareReturnsTrue
    }

    func application(pid: UInt32, context: OperationContext) throws -> any AXObject {
        try context.check()
        return app
    }

    func focusedElement(of application: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check()
        return focused
    }

    func windows(of application: any AXObject, context: OperationContext) throws -> AXChildren {
        try context.check()
        return AXChildren(elements: appWindows, complete: true)
    }

    func children(of element: any AXObject, limit: Int, context: OperationContext) throws -> AXChildren {
        try context.check()
        let node = element as! BrowserNode
        lock.lock()
        if node.role == "AXWindow", let webArea = delayedWebArea {
            childReads += 1
            if childReads > delayWebAreaScans && !node.children.contains(where: { $0 === webArea }) {
                node.children.append(webArea)
            }
        }
        let list = node.children
        lock.unlock()
        return AXChildren(elements: Array(list.prefix(limit)), complete: list.count <= limit)
    }

    func parent(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check()
        return (element as! BrowserNode).parent
    }

    func window(of element: any AXObject, context: OperationContext) throws -> (any AXObject)? {
        try context.check()
        return (element as! BrowserNode).owner
    }

    func ownerPID(of element: any AXObject, context: OperationContext) throws -> UInt32 {
        try context.check()
        return (element as! BrowserNode).pid
    }

    func bounds(of element: any AXObject, context: OperationContext) throws -> Rect? {
        try context.check()
        return (element as! BrowserNode).bounds
    }

    func snapshot(of element: any AXObject, includeValue: Bool, context: OperationContext) throws -> AXNodeSnapshot? {
        try context.check()
        let node = element as! BrowserNode
        return AXNodeSnapshot(
            role: node.role,
            title: node.title,
            label: node.label,
            bounds: node.bounds,
            enabled: node.enabled,
            enabledKnown: node.enabledKnown,
            value: nil,
            valueSettable: node.valueSettable,
            actions: node.actions,
            complete: node.complete,
            enabledUnsupported: node.enabledUnsupported,
            url: node.url
        )
    }

    func same(_ lhs: any AXObject, _ rhs: any AXObject) -> Bool {
        (lhs as! BrowserNode) === (rhs as! BrowserNode)
    }

    func setValue(_ value: String, on object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
    }

    func press(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
    }

    func replaceSelectedText(_ text: String, on object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try willDispatch()
    }

    func scrollToVisible(_ object: any AXObject, context: OperationContext, willDispatch: @Sendable () throws -> Void) throws {
        try context.check()
        try willDispatch()
        lock.lock()
        scrollToVisibleCalls += 1
        lock.unlock()
    }

    func targets(_ request: TargetsRequest, context: OperationContext) throws -> TargetsResult {
        try context.check()
        return TargetsResult(targets: records, truncated: false)
    }

    func window(_ key: TargetKey, context: OperationContext) throws -> Target {
        try context.check()
        guard let target = records.first(where: { $0.key == key }) else {
            throw NativeFailure(.targetNotFound, "missing target")
        }
        return target
    }

    func processWindows(pid: UInt32, context: OperationContext) throws -> [Target] {
        try context.check()
        return records.filter { $0.key.pid == pid }
    }
}

private final class BrowserForegroundPlatform: ForegroundPlatform, @unchecked Sendable {
    var pid: UInt32 = 9115
    var focusedWin: (any AXObject)?
    var focusedEl: (any AXObject)?
    var postedKeys: [Key] = []

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
        if case .key(let key) = input { postedKeys.append(key) }
    }
}

private struct DummyCapture: VisualCapturing {
    func capture(target: Target, crop: Rect?, maxDimension: Int, context: OperationContext) throws -> CapturedVisual {
        throw NativeFailure(.unsupported, "unused")
    }
}

final class BrowserSupportTests: XCTestCase {
    func testChromeMultiWindowSuffixAndEllipsisAssociationAndFailClosedAmbiguity() throws {
        let bounds = Rect(x: 0, y: 39, width: 1800, height: 1067)
        let backend = BrowserBackend()
        let t1 = Target(key: TargetKey(pid: 9115, windowId: 135), bundleId: "com.google.Chrome",
                        title: "New Tab", bounds: bounds)
        let t2 = Target(key: TargetKey(pid: 9115, windowId: 1934), bundleId: "com.google.Chrome",
                        title: "MCP analytics • PostHog", bounds: bounds)
        let t3 = Target(key: TargetKey(pid: 9115, windowId: 8938), bundleId: "com.google.Chrome",
                        title: "We need more information to app\u{2026}iversity of Nigeria Nsukka Mail", bounds: bounds)
        backend.records = [t1, t2, t3]

        func makeWindow(_ id: String, axTitle: String, url: String) -> BrowserNode {
            let w = BrowserNode(id, role: "AXWindow", title: axTitle, bounds: bounds)
            let web = BrowserNode("\(id)-web", role: "AXWebArea", title: axTitle, url: url,
                                  bounds: Rect(x: 0, y: 120, width: 1800, height: 980))
            web.actions = ["AXScrollToVisible"]
            web.parent = w; web.owner = w
            w.children = [web]
            return w
        }
        backend.appWindows = [
            makeWindow("w1", axTitle: "New Tab - Google Chrome - Oba", url: "chrome://new-tab-page/"),
            makeWindow("w2", axTitle: "MCP analytics • PostHog - Google Chrome - John", url: "https://eu.posthog.com/"),
            makeWindow("w3", axTitle: "We need more information to approve your Student status - University of Nigeria Nsukka Mail - Google Chrome - oba",
                       url: "https://mail.google.com/mail/u/0/#inbox/1"),
        ]

        let observer = SemanticAXObserver(backend: backend, catalog: backend)
        let obs1 = try observer.observe(params: ObserveRequest(target: t1.key, includeScreenshot: false, includeValues: false), observationId: "o1", context: OperationContext(budgetMs: 2000))
        let obs2 = try observer.observe(params: ObserveRequest(target: t2.key, includeScreenshot: false, includeValues: false), observationId: "o2", context: OperationContext(budgetMs: 2000))
        let obs3 = try observer.observe(params: ObserveRequest(target: t3.key, includeScreenshot: false, includeValues: false), observationId: "o3", context: OperationContext(budgetMs: 2000))

        XCTAssertEqual(obs1.observation.elements.first?.url, "chrome://new-tab-page/")
        XCTAssertEqual(obs2.observation.elements.first?.url, "https://eu.posthog.com/")
        XCTAssertEqual(obs3.observation.elements.first?.url, "https://mail.google.com/mail/u/0/#inbox/1")
        XCTAssertEqual(obs1.observation.elements.first?.actions, [.scrollToVisible])

        // Fail closed when two equal-bounds CG siblings match the same AXWindow title.
        let tCollisionA = Target(key: TargetKey(pid: 9115, windowId: 500), bundleId: "com.google.Chrome", title: "Foo", bounds: bounds)
        let tCollisionB = Target(key: TargetKey(pid: 9115, windowId: 501), bundleId: "com.google.Chrome", title: "Foo - Bar", bounds: bounds)
        backend.records = [tCollisionA, tCollisionB]
        backend.appWindows = [makeWindow("wcol", axTitle: "Foo - Bar - Google Chrome", url: "https://example.com")]
        XCTAssertThrowsError(try observer.observe(params: ObserveRequest(target: tCollisionA.key, includeScreenshot: false, includeValues: false), observationId: "ocol", context: OperationContext(budgetMs: 2000))) { error in
            XCTAssertEqual((error as? NativeFailure)?.code, .ambiguousTarget)
        }

        // Reject degenerate or multi-ellipsis titles.
        XCTAssertFalse(axTitleCompatible(axTitle: "abcd1234", cgTitle: "a\u{2026}4"))
        XCTAssertFalse(axTitleCompatible(axTitle: "prefix middle suffix", cgTitle: "prefix\u{2026}mid\u{2026}suffix"))
    }

    func testOversizeUrlIsOmittedAndMarksObservationPartial() throws {
        let bounds = Rect(x: 0, y: 0, width: 800, height: 600)
        let backend = BrowserBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 1), bundleId: "com.google.Chrome", title: "Page", bounds: bounds)
        backend.records = [target]
        let win = BrowserNode("w", role: "AXWindow", title: "Page - Google Chrome", bounds: bounds)
        let link = BrowserNode("l", role: "AXLink", title: "Long", url: "https://example.com/" + String(repeating: "a", count: Limits.maxUrlBytes),
                               bounds: Rect(x: 10, y: 20, width: 100, height: 24))
        link.parent = win; link.owner = win
        win.children = [link]
        backend.appWindows = [win]

        let obs = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false), observationId: "o-url", context: OperationContext(budgetMs: 2000))
        XCTAssertNil(obs.observation.elements.first?.url)
        XCTAssertEqual(obs.observation.accessibility, .partial)
    }

    func testInteractiveFirstBudgetRetainsVisibleControlsOverDenseStaticText() throws {
        let bounds = Rect(x: 0, y: 0, width: 1200, height: 800)
        let backend = BrowserBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 2), bundleId: "com.google.Chrome", title: "Dense", bounds: bounds)
        backend.records = [target]
        let win = BrowserNode("w", role: "AXWindow", title: "Dense - Google Chrome", bounds: bounds)
        let web = BrowserNode("web", role: "AXWebArea", title: "Dense", url: "https://example.com/dense",
                              bounds: Rect(x: 0, y: 80, width: 1200, height: 720))
        web.parent = win; web.owner = win

        var webChildren: [BrowserNode] = []
        for i in 0..<300 {
            let text = BrowserNode("txt-\(i)", role: "AXStaticText", title: "Row \(i)",
                                   bounds: Rect(x: 20, y: Double(100 + (i % 500)), width: 200, height: 16))
            text.parent = web; text.owner = win
            webChildren.append(text)
        }
        for i in 0..<10 {
            let btn = BrowserNode("btn-\(i)", role: "AXButton", title: "Action \(i)",
                                  bounds: Rect(x: 300, y: Double(100 + i * 30), width: 120, height: 24))
            btn.actions = ["AXPress", "AXScrollToVisible"]
            btn.parent = web; btn.owner = win
            webChildren.append(btn)
        }
        for i in 0..<10 {
            let lnk = BrowserNode("lnk-\(i)", role: "AXLink", title: "Link \(i)", url: "https://example.com/\(i)",
                                  bounds: Rect(x: 450, y: Double(100 + i * 30), width: 120, height: 24))
            lnk.actions = ["AXPress", "AXScrollToVisible"]
            lnk.parent = web; lnk.owner = win
            webChildren.append(lnk)
        }
        web.children = webChildren
        win.children = [web]
        backend.appWindows = [win]

        let obs = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false), observationId: "o-dense", context: OperationContext(budgetMs: 2000))
        XCTAssertEqual(obs.observation.accessibility, .partial)
        XCTAssertEqual(obs.observation.elements.count, Limits.maxElements)
        XCTAssertEqual(obs.observation.elements.filter { $0.role == "AXWebArea" }.count, 1)
        XCTAssertEqual(obs.observation.elements.filter { $0.role == "AXButton" }.count, 10)
        XCTAssertEqual(obs.observation.elements.filter { $0.role == "AXLink" }.count, 10)
    }

    func testBrowserAccessibilityPreparationPollsUntilWebAreaMaterializes() throws {
        let bounds = Rect(x: 0, y: 0, width: 800, height: 600)
        let backend = BrowserBackend()
        backend.prepareReturnsTrue = true
        backend.delayWebAreaScans = 2
        let target = Target(key: TargetKey(pid: 9115, windowId: 3), bundleId: "com.google.Chrome", title: "Fresh", bounds: bounds)
        backend.records = [target]
        let win = BrowserNode("w", role: "AXWindow", title: "Fresh - Google Chrome", bounds: bounds)
        let web = BrowserNode("web", role: "AXWebArea", title: "Fresh", url: "https://fresh.example/",
                              bounds: Rect(x: 0, y: 80, width: 800, height: 520))
        web.parent = win; web.owner = win
        backend.delayedWebArea = web
        backend.appWindows = [win]

        let obs = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false), observationId: "o-fresh", context: OperationContext(budgetMs: 2000))
        XCTAssertEqual(obs.observation.elements.first?.role, "AXWebArea")
        XCTAssertEqual(obs.observation.elements.first?.url, "https://fresh.example/")
    }

    func testScrollToVisibleDispatchRefusalAndUrlContainsPredicates() throws {
        let bounds = Rect(x: 0, y: 0, width: 800, height: 600)
        let backend = BrowserBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 4), bundleId: "com.google.Chrome", title: "App", bounds: bounds)
        backend.records = [target]
        let win = BrowserNode("w", role: "AXWindow", title: "App - Google Chrome", bounds: bounds)
        let web = BrowserNode("web", role: "AXWebArea", title: "App", url: "https://app.example.com/dashboard?tab=1",
                              bounds: Rect(x: 0, y: 80, width: 800, height: 520))
        let link = BrowserNode("link", role: "AXLink", title: "Settings", url: "https://app.example.com/settings",
                               bounds: Rect(x: 20, y: 500, width: 120, height: 24))
        link.actions = ["AXScrollToVisible", "AXPress"]
        web.parent = win; web.owner = win
        link.parent = web; link.owner = win
        web.children = [link]
        win.children = [web]
        backend.appWindows = [win]

        let native = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false), observationId: "o-act", context: OperationContext(budgetMs: 2000))
        let webRef = try XCTUnwrap(native.observation.elements.first { $0.role == "AXWebArea" }?.reference)
        let linkRef = try XCTUnwrap(native.observation.elements.first { $0.role == "AXLink" }?.reference)
        let handle = try XCTUnwrap(native.handle as? SemanticObservationHandle)
        let retained = RetainedObservation(observation: native.observation, handle: handle, createdAt: 0)

        // Dispatch scrollToVisible in background.
        let actions = BackgroundActions(now: { 0 }, foreground: { 100 })
        let req = ActRequest(grantId: "g1", observationId: "o-act", target: target.key, steps: [
            ActionStep(actionId: "a1", operation: .scrollToVisible(ElementOperation(elementRef: linkRef)), precondition: nil, expect: nil)
        ])
        let state = ActionExecutionState(act: req)
        let res = actions.act(req, entry: retained, context: OperationContext(budgetMs: 2000), state: state)
        XCTAssertEqual(res.stopReason, .completed)
        XCTAssertEqual(res.steps.first?.delivery, .dispatched)
        XCTAssertEqual(res.steps.first?.route, .axScrollToVisible)
        XCTAssertEqual(backend.scrollToVisibleCalls, 1)

        // Refuse scrollToVisible when unadvertised.
        link.actions = []
        let req2 = ActRequest(grantId: "g1", observationId: "o-act", target: target.key, steps: [
            ActionStep(actionId: "a2", operation: .scrollToVisible(ElementOperation(elementRef: linkRef)), precondition: nil, expect: nil)
        ])
        let res2 = actions.act(req2, entry: retained, context: OperationContext(budgetMs: 2000), state: ActionExecutionState(act: req2))
        XCTAssertEqual(res2.stopReason, .unsupported)
        XCTAssertEqual(backend.scrollToVisibleCalls, 1)

        // Test urlContains predicate (explicit elementRef and window-scoped scan).
        let evaluator = PredicateEvaluator()
        let ctx = OperationContext(budgetMs: 2000)
        XCTAssertEqual(try evaluator.evaluate(.urlContains(UrlCondition(elementRef: webRef, contains: "dashboard")), handle: handle, context: ctx).matched, true)
        XCTAssertEqual(try evaluator.evaluate(.urlContains(UrlCondition(elementRef: webRef, contains: "billing")), handle: handle, context: ctx).matched, false)
        XCTAssertEqual(try evaluator.evaluate(.urlContains(UrlCondition(elementRef: nil, contains: "tab=1")), handle: handle, context: ctx).matched, true)
        XCTAssertEqual(try evaluator.evaluate(.urlContains(UrlCondition(elementRef: nil, contains: "missing")), handle: handle, context: ctx).matched, false)

        // Partial scan without match must return nil (unknown), never false.
        web.complete = false
        XCTAssertNil(try evaluator.evaluate(.urlContains(UrlCondition(elementRef: nil, contains: "missing")), handle: handle, context: ctx).matched)
    }

    func testWindowScopedBrowserShortcutAllowsFocusedDescendantInSameWindow() throws {
        let bounds = Rect(x: 0, y: 0, width: 800, height: 600)
        let backend = BrowserBackend()
        let target = Target(key: TargetKey(pid: 9115, windowId: 5), bundleId: "com.google.Chrome", title: "Browser", bounds: bounds)
        backend.records = [target]
        let win = BrowserNode("w", role: "AXWindow", title: "Browser - Google Chrome", bounds: bounds)
        let web = BrowserNode("web", role: "AXWebArea", title: "Browser", url: "https://example.com",
                              bounds: Rect(x: 0, y: 80, width: 800, height: 520))
        web.enabled = false
        web.enabledKnown = false
        web.enabledUnsupported = true
        let childInput = BrowserNode("inp", role: "AXTextField", title: "Search",
                                     bounds: Rect(x: 20, y: 120, width: 200, height: 24))
        web.parent = win; web.owner = win
        childInput.parent = web; childInput.owner = win
        web.children = [childInput]
        win.children = [web]
        backend.appWindows = [win]

        let native = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: target.key, includeScreenshot: false, includeValues: false), observationId: "o-fg", context: OperationContext(budgetMs: 2000))
        let webRef = try XCTUnwrap(native.observation.elements.first { $0.role == "AXWebArea" }?.reference)
        let handle = try XCTUnwrap(native.handle as? SemanticObservationHandle)
        let retained = RetainedObservation(observation: native.observation, handle: handle, createdAt: 0)

        let platform = BrowserForegroundPlatform()
        platform.focusedWin = win
        platform.focusedEl = childInput
        let actions = BackgroundActions(now: { 0 }, foreground: { 9115 }, foregroundPlatform: platform, coordinateCapture: DummyCapture())
        let req = ActRequest(grantId: "g1", observationId: "o-fg", target: target.key, steps: [
            ActionStep(actionId: "k1", operation: .key(KeyOperation(elementRef: webRef, key: .focusAddressBar)), precondition: nil, expect: nil)
        ], foreground: true)
        let res = actions.act(req, entry: retained, context: OperationContext(budgetMs: 2000), state: ActionExecutionState(act: req))
        XCTAssertEqual(res.stopReason, .completed)
        XCTAssertEqual(platform.postedKeys, [.focusAddressBar])
    }

    func testUrlContainsSurvivesNavigationTitleChangeAndTransientDesync() throws {
        let bounds = Rect(x: 0, y: 0, width: 960, height: 720)
        let backend = BrowserBackend()
        let key = TargetKey(pid: 9115, windowId: 6)
        let initialTarget = Target(key: key, bundleId: "com.google.Chrome", title: "Home", bounds: bounds)
        backend.records = [initialTarget]
        let win = BrowserNode("w", role: "AXWindow", title: "Home - Google Chrome", bounds: bounds)
        let web = BrowserNode("web", role: "AXWebArea", title: "Home", url: "https://shop.example/",
                              bounds: Rect(x: 0, y: 80, width: 960, height: 640))
        web.parent = win; web.owner = win
        win.children = [web]
        backend.appWindows = [win]

        let native = try SemanticAXObserver(backend: backend, catalog: backend).observe(
            params: ObserveRequest(target: key, includeScreenshot: false, includeValues: false), observationId: "o-nav", context: OperationContext(budgetMs: 2000))
        let handle = try XCTUnwrap(native.handle as? SemanticObservationHandle)
        let evaluator = PredicateEvaluator()
        let ctx = OperationContext(budgetMs: 2000)

        // Simulate transient navigation race: AXTitle changed ahead of CGWindowName.
        win.title = "Checkout - Google Chrome"
        web.url = "https://shop.example/checkout"
        XCTAssertThrowsError(try evaluator.evaluate(.urlContains(UrlCondition(elementRef: nil, contains: "/checkout")), handle: handle, context: ctx)) { error in
            XCTAssertTrue(error is AXReadUnavailable)
        }

        // Once CGWindowName converges to the new page title, urlContains succeeds on the same AXWindow.
        backend.records = [Target(key: key, bundleId: "com.google.Chrome", title: "Checkout", bounds: bounds)]
        let eval = try evaluator.evaluate(.urlContains(UrlCondition(elementRef: nil, contains: "/checkout")), handle: handle, context: ctx)
        XCTAssertEqual(eval.matched, true)
    }
}
