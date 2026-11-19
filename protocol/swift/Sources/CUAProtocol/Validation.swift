import Foundation

private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw ContractError(message) }
}
private func identifier(_ value: String) throws {
    try require(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 128, "invalid identifier")
}
private func validTarget(_ target: TargetKey) throws {
    try require(target.pid > 0 && target.windowId > 0, "target IDs must be positive")
}
private func validRect(_ rect: Rect) throws {
    try require([rect.x, rect.y, rect.width, rect.height].allSatisfy(\.isFinite)
                && rect.width > 0 && rect.height > 0 && (rect.x + rect.width).isFinite
                && (rect.y + rect.height).isFinite, "invalid rectangle")
}
private func unique(_ values: [String]) throws {
    var seen = Set<String>()
    for value in values {
        try identifier(value)
        try require(seen.insert(value).inserted, "duplicate identifier")
    }
}
private func validInterval(_ interval: CollectionInterval) throws {
    try require(interval.startedUnixMs <= interval.finishedUnixMs
                && interval.finishedUnixMs <= 9_007_199_254_740_991, "invalid collection interval")
}
private func channelInterval(_ channel: CollectionInterval, within total: CollectionInterval) throws {
    try validInterval(channel)
    try require(channel.startedUnixMs >= total.startedUnixMs && channel.finishedUnixMs <= total.finishedUnixMs,
                "channel interval outside observation")
}
private func expectation(_ step: ActionStep, _ receipt: StepReceipt, settled: Bool, foreground: Bool) throws {
    if let route = receipt.route {
        switch (step.operation, route) {
        case (.setValue, .axSetValue), (.typeText, .axSelectedText), (.press, .axPress), (.scroll, .axScroll),
             (.key, .foregroundKey), (.click, .foregroundClick): break
        default: throw ContractError("receipt route does not match operation")
        }
        try require(foreground == (route == .foregroundKey || route == .foregroundClick),
                    "receipt route does not match requested foreground mode")
    }
    var required: [Condition] = []
    if case .waitFor(let wait) = step.operation {
        try require(receipt.delivery == .notDispatched && receipt.route == nil, "wait cannot dispatch input")
        required.append(wait.condition)
        if settled || receipt.reason == .alreadySatisfied || receipt.reason == .conditionSatisfied {
            try require(receipt.reason == .alreadySatisfied || receipt.reason == .conditionSatisfied,
                        "settled wait requires a successful wait reason")
            try require(receipt.evidence.contains { $0.condition == wait.condition && $0.matched && $0.collected != nil },
                        "settled wait requires timed condition evidence")
        }
    } else {
        try require(receipt.reason != .conditionSatisfied, "conditionSatisfied requires a wait operation")
    }
    if case .setValue(let value) = step.operation {
        required.append(.valueEquals(ValueCondition(elementRef: value.elementRef, value: value.value)))
    }
    if let expected = step.expect {
        if !required.contains(expected) { required.append(expected) }
    }
    if !required.isEmpty {
        func matches(_ condition: Condition, _ matched: Bool) -> Bool {
            receipt.evidence.contains { $0.condition == condition && $0.matched == matched }
        }
        switch receipt.verification {
        case .confirmed: try require(required.allSatisfy { matches($0, true) }, "confirmation does not match requested expectation")
        case .mismatch: try require(required.contains { matches($0, false) }, "mismatch does not match requested expectation")
        case .unverified: try require(!settled, "settled step has unverified required expectation")
        }
    } else {
        try require(receipt.reason != .alreadySatisfied, "alreadySatisfied requires an expectation")
    }
}

extension Condition {
    func validate() throws {
        switch self {
        case .elementExists(let value), .elementAbsent(let value): try identifier(value.selector.role)
        case .valueEquals(let value): try identifier(value.elementRef)
        case .enabled(let value): try identifier(value.elementRef)
        case .windowAbsent: break
        }
    }
}

extension CheckEvidence {
    func validate() throws {
        try identifier(observationId)
        try condition.validate()
        if let collected { try validInterval(collected) }
    }
}

extension ObservationFeedback {
    func validate() throws {
        try identifier(baseObservationId)
        try validInterval(collected)
        try require(controls.count <= Limits.maxElements, "too many feedback controls")
        try unique(controls.map(\.elementRef))
        for control in controls {
            try require((control.state == .changed) == (control.element != nil), "only changed feedback carries an element")
            if let element = control.element {
                try require(element.reference == control.elementRef, "feedback must preserve the base reference")
                try identifier(element.role)
                try validRect(element.bounds)
                try require((element.label?.utf8.count ?? 0) <= 1024 && (element.identifier?.utf8.count ?? 0) <= 1024
                            && (element.subrole?.utf8.count ?? 0) <= 1024
                            && (element.value?.utf8.count ?? 0) <= 65_536, "feedback projection exceeds string limit")
            }
        }
        try require(!invalidated || controls.allSatisfy { $0.state == .invalidated }, "invalidated binding cannot carry live feedback")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try require(try encoder.encode(self).count <= Limits.maxFeedbackBytes, "feedback exceeds payload limit")
    }
}

private func correlateFeedback(_ request: ActRequest, _ result: ActResult) throws {
    guard let feedback = result.feedback else {
        return
    }
    guard let requested = request.feedback else { throw ContractError("unrequested feedback") }
    try require(feedback.baseObservationId == request.observationId, "feedback base observation mismatch")
    let refs = Set(requested.elementRefs)
    try require(feedback.controls.allSatisfy { refs.contains($0.elementRef) }, "feedback contains an unrequested reference")
    try require(feedback.truncated || feedback.controls.count == requested.elementRefs.count, "feedback omitted requested references")
    try require(requested.includeValues || feedback.controls.allSatisfy { $0.element?.value == nil }, "feedback includes unrequested values")
}

extension ImageTransform {
    public func toScreen(_ point: Point) throws -> Point {
        let r = validImageBounds
        try validRect(r)
        try require([scaleX, scaleY, offsetX, offsetY].allSatisfy(\.isFinite)
                    && scaleX > 0 && scaleY > 0, "invalid image transform")
        try require(coverage != .unavailable && point.x.isFinite && point.y.isFinite
                    && point.x >= r.x && point.y >= r.y && point.x < r.x + r.width
                    && point.y < r.y + r.height, "point outside valid image transform")
        let mapped = Point(x: point.x * scaleX + offsetX, y: point.y * scaleY + offsetY)
        try require(mapped.x.isFinite && mapped.y.isFinite, "mapped point overflow")
        return mapped
    }
}

extension Screenshot {
    func validate() throws {
        try validInterval(collected)
        try require(widthPx > 0 && heightPx > 0, "image dimensions must be positive")
        let t = imageToScreen
        try validRect(t.validImageBounds)
        try require([t.scaleX, t.scaleY, t.offsetX, t.offsetY].allSatisfy(\.isFinite)
                    && t.scaleX > 0 && t.scaleY > 0 && t.coverage != .unavailable, "invalid image transform")
        let r = t.validImageBounds
        try require(r.x >= 0 && r.y >= 0 && r.x + r.width <= Double(widthPx)
                    && r.y + r.height <= Double(heightPx), "transform domain outside image")
        try require([r.x * t.scaleX + t.offsetX, (r.x + r.width) * t.scaleX + t.offsetX,
                     r.y * t.scaleY + t.offsetY, (r.y + r.height) * t.scaleY + t.offsetY].allSatisfy(\.isFinite),
                    "mapped rectangle overflow")
        if t.coverage == .complete {
            try require(r.x == 0 && r.y == 0 && r.width == Double(widthPx)
                        && r.height == Double(heightPx), "complete transform must cover image")
        }
        try require(!dataBase64.isEmpty && dataBase64.utf8.count <= ((Limits.maxImageBytes + 2) / 3) * 4,
                    "image exceeds payload limit")
        guard let bytes = Data(base64Encoded: dataBase64) else { throw ContractError("invalid image base64") }
        try require(bytes.base64EncodedString() == dataBase64, "noncanonical image base64")
        try require(!bytes.isEmpty && bytes.count <= Limits.maxImageBytes, "image exceeds payload limit")
    }
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 0.000_001 }
private func sameRect(_ a: Rect, _ b: Rect) -> Bool {
    near(a.x, b.x) && near(a.y, b.y) && near(a.width, b.width) && near(a.height, b.height)
}
private func inside(_ a: Rect, _ b: Rect) -> Bool {
    a.x >= b.x - 0.000_001 && a.y >= b.y - 0.000_001 &&
        a.x + a.width <= b.x + b.width + 0.000_001 && a.y + a.height <= b.y + b.height + 0.000_001
}
extension ObserveRequest {
    func validate() throws {
        try validTarget(target)
        if let selectors = axSelectors { try validateSelectors(selectors) }
        if let history = eventHistory {
            try require(axSelectors != nil, "event history requires explicit AX selectors")
            if let cursor = history.cursor {
                try identifier(cursor.generation)
                try require(cursor.sequence <= 9_007_199_254_740_991, "event cursor exceeds safe integer range")
            }
        }
        if let query = ocrQuery {
            try require(includeOcr && !query.isEmpty && query.utf8.count <= Limits.maxOcrQueryBytes, "invalid OCR query")
        }
        if let crop = cropWindow {
            try validRect(crop)
            try require((includeScreenshot || includeOcr) && crop.x >= 0 && crop.y >= 0, "invalid window crop")
        }
        if let size = maxImageDimensionPx {
            try require((includeScreenshot || includeOcr) && (64...2048).contains(size), "invalid image dimension limit")
        }
    }
}
private func validateSelectors(_ selectors: [Selector]) throws {
    try require(!selectors.isEmpty && selectors.count <= Limits.maxAxSelectors, "invalid AX selector count")
    for (index, selector) in selectors.enumerated() {
        try identifier(selector.role)
        try require((selector.label?.utf8.count ?? 0) <= 1024 && (selector.identifier?.utf8.count ?? 0) <= 1024,
                    "AX selector exceeds string limit")
        try require(!selectors.prefix(index).contains(selector), "duplicate AX selector")
    }
}
private func selectorMatches(_ element: Element, _ selector: Selector) -> Bool {
    element.role == selector.role && (selector.label == nil || selector.label == element.label) &&
        (selector.identifier == nil || selector.identifier == element.identifier)
}
private func historicalMatches(_ control: EventControl, _ selector: Selector) -> Bool {
    control.role == selector.role && (selector.label == nil || selector.label == control.label) &&
        (selector.identifier == nil || selector.identifier == control.identifier)
}
extension EventHistory {
    func validate() throws {
        try identifier(cursor.generation)
        try require(cursor.sequence <= 9_007_199_254_740_991 && coalescedWakes <= 9_007_199_254_740_991 && sampleCount <= 9_007_199_254_740_991,
                    "event counters exceed safe integer range")
        try validInterval(collected)
        try require(startedUnixMs <= collected.finishedUnixMs, "event history starts after collection")
        try require(events.count <= Limits.maxTargetEvents, "too many target events")
        if let oldestSequence { try require(oldestSequence > 0 && oldestSequence <= cursor.sequence, "invalid oldest event sequence") }
        var previous: UInt64 = 0
        for event in events {
            try require(event.sequence > previous && event.sequence <= cursor.sequence, "unordered target events")
            previous = event.sequence
            try validInterval(event.collected)
            try require(event.observedUnixMs <= event.collected.finishedUnixMs && event.collected.finishedUnixMs <= collected.finishedUnixMs,
                        "invalid historical event interval")
            try require((event.source == .notification) == (event.notification != nil), "event source lacks notification provenance")
            if let notification = event.notification { try identifier(notification) }
            try require(event.controls.count <= Limits.maxEventControls, "too many historical controls")
            try require(event.coverage != .unavailable || event.controls.isEmpty, "unavailable historical event has controls")
            for control in event.controls {
                try identifier(control.role); try validRect(control.bounds)
                try require((control.identifier?.utf8.count ?? 0) <= 1024 && (control.label?.utf8.count ?? 0) <= 1024 &&
                            (control.subrole?.utf8.count ?? 0) <= 1024 &&
                            (control.value?.utf8.count ?? 0) <= Limits.maxEventValueBytes, "historical control exceeds string limit")
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        try require(try encoder.encode(self).count <= Limits.maxTargetEventBytes, "event history exceeds payload limit")
    }
}
extension VisualFrame {
    func validate() throws {
        try validRect(captureWindowBounds); try validRect(captureScreenBounds)
        try require(widthPx > 0 && heightPx > 0 && inside(captureScreenBounds, captureWindowBounds), "invalid visual capture bounds")
        let domain = Rect(x: 0, y: 0, width: Double(widthPx), height: Double(heightPx))
        for transform in [imageToScreen, imageToWindow] {
            try require(transform.coverage == .complete && sameRect(transform.validImageBounds, domain), "visual frame mapping must cover returned image")
            _ = try transform.toScreen(Point(x: 0, y: 0))
        }
        let mapped = Rect(x: imageToScreen.offsetX, y: imageToScreen.offsetY,
                          width: domain.width * imageToScreen.scaleX, height: domain.height * imageToScreen.scaleY)
        try require(sameRect(mapped, captureScreenBounds), "image mapping disagrees with capture bounds")
        try require(near(imageToWindow.scaleX, imageToScreen.scaleX) && near(imageToWindow.scaleY, imageToScreen.scaleY) &&
                    near(imageToWindow.offsetX, imageToScreen.offsetX - captureWindowBounds.x) &&
                    near(imageToWindow.offsetY, imageToScreen.offsetY - captureWindowBounds.y), "window and desktop mappings disagree")
    }
}
extension OcrEvidence {
    func validate() throws {
        if let time = collected { try validInterval(time) }
        try require(matches.count <= Limits.maxOcrMatches, "too many OCR matches")
        switch status {
        case .complete, .partial: try require(collected != nil, "available OCR requires collection interval")
        case .failed: try require(collected != nil && matches.isEmpty, "failed OCR requires interval and no matches")
        case .unavailable: try require(matches.isEmpty, "unavailable OCR cannot include matches")
        }
        for match in matches {
            try require(!match.text.isEmpty && match.text.utf8.count <= Limits.maxOcrTextBytes, "invalid OCR text")
            try validRect(match.imageBounds)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try require(try encoder.encode(self).count <= Limits.maxOcrBytes, "OCR exceeds payload limit")
    }
}
extension Observation {
    func validate() throws {
        try identifier(observationId)
        try validTarget(target)
        try validRect(windowBounds)
        try validInterval(collected)
        try require(accessibility == .unavailable || accessibilityCollected != nil,
                    "available accessibility requires collection interval")
        if let ax = accessibilityCollected { try channelInterval(ax, within: collected) }
        try require(elements.count <= Limits.maxElements, "too many elements")
        try unique(elements.map(\.reference))
        try require(accessibility != .unavailable || elements.isEmpty, "unavailable accessibility cannot include elements")
        for element in elements {
            try identifier(element.role)
            try validRect(element.bounds)
            try require((element.subrole?.utf8.count ?? 0) <= 1024, "element subrole exceeds string limit")
        }
        if let selection = axSelection {
            try validateSelectors(selection.selectors)
            try require(accessibility != .complete && selection.visitedNodes <= 1024, "selected AX scope cannot imply a complete window")
            try require(elements.allSatisfy { element in selection.selectors.contains { selectorMatches(element, $0) } }, "selected AX result is outside its query")
            let duplicates = selection.selectors.contains { selector in elements.filter { selectorMatches($0, selector) }.count > 1 }
            try require(!duplicates || selection.ambiguous, "selected AX result hides ambiguity")
            if selection.coverage == .complete { try require(selection.ambiguous == duplicates, "inconsistent selected AX ambiguity") }
            if selection.coverage == .unavailable { try require(elements.isEmpty && !selection.ambiguous, "unavailable AX selection has results") }
        }
        if let events {
            try events.validate()
            try channelInterval(events.collected, within: collected)
            try require(axSelection != nil, "event history lacks query provenance")
        }
        try screenshot?.validate()
        if let screenshot { try channelInterval(screenshot.collected, within: collected) }
        if let visual {
            try channelInterval(visual.collected, within: collected)
            let captured = visual.captureStatus == .captured
            try require(captured == (visual.frame != nil), "capture status and visual frame disagree")
            if let frame = visual.frame {
                try frame.validate()
                if accessibility != .unavailable {
                    try require(visual.geometryMatchesAX == sameRect(frame.captureWindowBounds, windowBounds), "missing or inconsistent AX geometry agreement")
                } else { try require(visual.geometryMatchesAX == nil, "unavailable AX cannot establish geometry agreement") }
                if let image = screenshot {
                    try require(image.widthPx == frame.widthPx && image.heightPx == frame.heightPx &&
                                image.imageToScreen == frame.imageToScreen && image.collected == visual.collected,
                                "screenshot and visual provenance disagree")
                }
                if let ocr = visual.ocr {
                    let domain = Rect(x: 0, y: 0, width: Double(frame.widthPx), height: Double(frame.heightPx))
                    try require(ocr.matches.allSatisfy { inside($0.imageBounds, domain) }, "OCR bounds outside returned image")
                }
            } else {
                try require(screenshot == nil, "failed capture cannot include screenshot")
                try require(visual.geometryMatchesAX == nil || (visual.captureStatus == .geometryChanged &&
                            visual.geometryMatchesAX == false && accessibility != .unavailable), "failed capture has unsupported geometry agreement")
            }
            if let ocr = visual.ocr {
                try ocr.validate()
                if let time = ocr.collected {
                    try channelInterval(time, within: collected)
                    try require(time.startedUnixMs >= visual.collected.finishedUnixMs, "OCR precedes capture completion")
                }
                try require(captured || ocr.status == .unavailable, "OCR requires a captured frame")
            }
        }
    }
}

extension ActRequest {
    func validate() throws {
        try identifier(grantId)
        try identifier(observationId)
        try validTarget(target)
        try require(!steps.isEmpty && steps.count <= Limits.maxSteps, "invalid action count")
        try unique(steps.map(\.actionId))
        if foreground {
            try require(steps.allSatisfy {
                switch $0.operation { case .key, .click, .waitFor: true; default: false }
            } && steps.contains {
                switch $0.operation { case .key, .click: true; default: false }
            }, "foreground sequences require a key or click and may include waits")
        }
        for step in steps {
            switch step.operation {
            case .press(let value): try identifier(value.elementRef)
            case .setValue(let value): try identifier(value.elementRef)
            case .typeText(let value):
                try identifier(value.elementRef)
                try require(!value.text.isEmpty, "empty typing")
            case .key(let value): try identifier(value.elementRef)
            case .scroll(let value):
                try identifier(value.elementRef)
                try require(value.amount != 0 && (-1000...1000).contains(value.amount), "invalid scroll amount")
            case .click(let value):
                try require(value.point.x.isFinite && value.point.y.isFinite, "invalid point")
            case .waitFor(let value):
                try value.condition.validate()
                try require(step.precondition == nil && step.expect == nil, "wait steps cannot carry guards or expectations")
            }
            try step.precondition?.validate()
            try step.expect?.validate()
        }
        if let feedback {
            try require(feedback.elementRefs.count <= Limits.maxElements, "too many feedback references")
            try unique(feedback.elementRefs)
        }
    }
}

extension ActResult {
    func validate() throws {
        try identifier(observationId)
        try require(!steps.isEmpty && steps.count + Int(remainingSteps) <= Limits.maxSteps, "invalid receipt prefix")
        try unique(steps.map(\.actionId))
        for (index, step) in steps.enumerated() {
            for evidence in step.evidence {
                try evidence.validate()
            }
            switch step.verification {
            case .confirmed:
                try require(!step.evidence.isEmpty && step.evidence.allSatisfy(\.matched), "confirmation needs evidence")
            case .mismatch:
                try require(step.evidence.contains(where: { !$0.matched }), "mismatch needs evidence")
            case .unverified: break
            }
            if step.reason == .alreadySatisfied || step.reason == .conditionSatisfied {
                try require(step.delivery == .notDispatched && step.verification == .confirmed,
                            "alreadySatisfied requires confirmed evidence without dispatch")
            }
            if step.delivery == .notDispatched && step.reason != .alreadySatisfied && step.reason != .conditionSatisfied {
                try require(index + 1 == steps.count && step.reason != nil && stopReason != .completed,
                            "rejected step must stop sequence")
            }
            if let reason = step.reason, reason != .alreadySatisfied && reason != .conditionSatisfied {
                let expected: StopReason
                switch reason {
                case .preconditionFailed: expected = .preconditionFailed
                case .verificationFailed: expected = .verificationFailed
                case .cancelled: expected = .cancelled
                case .deadlineExceeded: expected = .deadlineExceeded
                case .helperDied: expected = .helperDied
                case .targetStale: expected = .targetStale
                case .ambiguousTarget: expected = .ambiguousTarget
                case .unsupported: expected = .unsupported
                case .nativeFailed: expected = .failed
                case .alreadySatisfied, .conditionSatisfied: expected = .completed
                }
                try require(index + 1 == steps.count && stopReason == expected,
                            "failed step must be terminal with matching stop reason")
            }
            if step.delivery == .unknown {
                try require(index + 1 == steps.count && stopReason != .completed, "unknown dispatch must stop sequence")
            }
            if step.verification == .mismatch {
                try require(index + 1 == steps.count && stopReason != .completed,
                            "verification mismatch must stop sequence")
            }
        }
        if stopReason == .completed {
            try require(remainingSteps == 0 && steps.allSatisfy {
                $0.delivery == .dispatched || $0.reason == .alreadySatisfied || $0.reason == .conditionSatisfied
            }, "completed sequence cannot include rejected steps")
        }
        try feedback?.validate()
    }
}

extension Frame {
    public func validate() throws {
        switch self {
        case .progress(let progress):
            try require(progress.version == Limits.version, "unsupported envelope version")
            try identifier(progress.id)
            try identifier(progress.epoch)
            try ActResult(observationId: progress.observationId, steps: progress.steps,
                          remainingSteps: 0, stopReason: .completed).validate()
        case .request(let request):
            try require(request.version == Limits.version, "unsupported envelope version")
            try identifier(request.id)
            try require(request.budgetMs > 0 && request.budgetMs <= Limits.maxBudgetMS, "invalid deadline budget")
            if case .hello(let hello) = request.body {
                try require(request.epoch == nil, "hello must not reuse an epoch")
                try identifier(hello.clientName)
                try identifier(hello.authority.grantId)
                try require(hello.supportedVersions.contains(Limits.version), "no compatible protocol version")
            } else {
                guard let epoch = request.epoch else { throw ContractError("epoch required") }
                try identifier(epoch)
            }
            switch request.body {
            case .observe(let value): try value.validate()
            case .act(let value): try value.validate()
            case .waitFor(let value):
                try identifier(value.observationId)
                try validTarget(value.target)
                try value.condition.validate()
            case .cancel(let value):
                try identifier(value.requestId)
                try require(value.requestId != request.id, "cancel cannot target itself")
            default: break
            }
        case .response(let response):
            try require(response.version == Limits.version, "unsupported envelope version")
            try identifier(response.id)
            try identifier(response.epoch)
            switch response.body {
            case .hello(let value):
                try identifier(value.helperVersion)
                try require(value.selectedVersion == Limits.version, "unsupported selected version")
            case .targets(let value):
                try require(value.targets.count <= Limits.maxTargets, "too many targets")
                for target in value.targets {
                    try validTarget(target.key)
                    if let bundleId = target.bundleId { try identifier(bundleId) }
                    if let ownerName = target.ownerName {
                        try require(!ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && ownerName.utf8.count <= 1024, "invalid target owner name")
                    }
                    try validRect(target.bounds)
                }
            case .observe(let value): try value.validate()
            case .act(let value): try value.validate()
            case .waitFor(let value):
                try require(!value.alreadySatisfied || value.outcome == .satisfied, "invalid alreadySatisfied wait")
                try value.evidence?.validate()
                let closed = value.evidence.map { if case .windowAbsent = $0.condition { return $0.matched && $0.collected != nil }; return false } ?? false
                try require(value.outcome != .satisfied || value.observation != nil || closed, "satisfied wait needs observation or timed window-absence evidence")
                try value.observation?.validate()
            case .cancel(let value): try identifier(value.requestId)
            case .error(let value): try require(!value.message.isEmpty, "empty error message")
            case .capabilities: break
            }
        }
    }

    public static func decodeLine(_ bytes: Data) throws -> Frame {
        try require(bytes.count <= Limits.maxFrameBytes, "frame exceeds limit")
        let content = bytes.last == 10 ? bytes.dropLast() : bytes[...]
        try require(content.count < Limits.maxFrameBytes, "frame exceeds limit")
        try require(!content.contains(10) && !content.contains(13), "one JSON object per line required")
        let frame = try JSONDecoder().decode(Frame.self, from: Data(content))
        try frame.validate()
        return frame
    }

    public func encodeLine() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(10)
        try require(data.count <= Limits.maxFrameBytes, "frame exceeds limit")
        return data
    }
}

extension Progress {
    public func validateFor(_ request: Request, expectedEpoch: String) throws {
        try Frame.request(request).validate()
        try Frame.progress(self).validate()
        try require(id == request.id && epoch == expectedEpoch && request.epoch == expectedEpoch,
                    "progress correlation mismatch")
        guard case .act(let act) = request.body else { throw ContractError("progress requires act request") }
        try require(observationId == act.observationId, "progress observation provenance mismatch")
        try require(steps.count <= act.steps.count && zip(steps, act.steps).allSatisfy { $0.actionId == $1.actionId },
                    "progress does not match requested action prefix")
        for (receipt, step) in zip(steps, act.steps) { try expectation(step, receipt, settled: true, foreground: act.foreground) }
    }
}

extension Response {
    public func validateFor(_ request: Request, expectedEpoch: String) throws {
        try Frame.request(request).validate()
        try Frame.response(self).validate()
        try require(id == request.id, "response request ID mismatch")
        try require(epoch == expectedEpoch, "response helper epoch mismatch")
        if case .hello = request.body {} else {
            try require(request.epoch == expectedEpoch, "pending request epoch mismatch")
        }
        switch (request.body, body) {
        case (_, .error), (.hello, .hello), (.capabilities, .capabilities), (.targets, .targets): break
        case (.observe(let request), .observe(let observation)):
            try require(request.target == observation.target, "observation target mismatch")
            try require(request.includeValues || observation.elements.allSatisfy { $0.value == nil },
                        "observation includes unrequested values")
            try require(request.axSelectors == observation.axSelection?.selectors, "AX selection does not match request")
            try require((request.eventHistory != nil) == (observation.events != nil), "event history inclusion does not match request")
            if let history = observation.events {
                try require(request.includeValues || history.events.allSatisfy { $0.controls.allSatisfy { $0.value == nil } }, "event history includes unrequested values")
                try require(history.events.allSatisfy { event in event.controls.allSatisfy { control in
                    request.axSelectors?.contains { historicalMatches(control, $0) } == true
                } }, "event history contains controls outside the query")
                if let cursor = request.eventHistory?.cursor {
                    if cursor.generation != history.cursor.generation { try require(history.stale, "history generation changed without a stale marker") }
                    else {
                        try require(history.cursor.sequence >= cursor.sequence && history.events.allSatisfy { $0.sequence > cursor.sequence }, "event cursor replay or regression")
                        if let oldest = history.oldestSequence, cursor.sequence < oldest - 1 { try require(history.overrun, "history hides an event-buffer overrun") }
                    }
                }
            }
            try require(request.includeScreenshot || observation.screenshot == nil,
                        "observation includes unrequested image")
            try require(request.includeScreenshot || request.includeOcr || observation.visual == nil, "observation includes unrequested visual evidence")
            try require(!(request.includeOcr || request.cropWindow != nil || request.maxImageDimensionPx != nil) || observation.visual != nil,
                        "requested visual evidence is missing")
            if let visual = observation.visual {
                try require(request.includeOcr == (visual.ocr != nil), "OCR inclusion does not match request")
                if let frame = visual.frame {
                    try require(!request.includeScreenshot || observation.screenshot != nil, "requested bitmap is missing")
                    if let limit = request.maxImageDimensionPx {
                        try require(max(frame.widthPx, frame.heightPx) <= limit, "image exceeds requested dimensions")
                    }
                    let expected: Rect
                    if let crop = request.cropWindow {
                        expected = Rect(x: frame.captureWindowBounds.x + crop.x, y: frame.captureWindowBounds.y + crop.y,
                                        width: crop.width, height: crop.height)
                    } else { expected = frame.captureWindowBounds }
                    let actual = frame.captureScreenBounds
                    let matches: Bool
                    if request.cropWindow != nil {
                        matches = inside(actual, expected) &&
                            abs(actual.x - expected.x) <= frame.imageToScreen.scaleX + 0.000_001 &&
                            abs(actual.y - expected.y) <= frame.imageToScreen.scaleY + 0.000_001 &&
                            abs((actual.x + actual.width) - (expected.x + expected.width)) <= frame.imageToScreen.scaleX + 0.000_001 &&
                            abs((actual.y + actual.height) - (expected.y + expected.height)) <= frame.imageToScreen.scaleY + 0.000_001
                    } else { matches = sameRect(expected, actual) }
                    try require(matches, "capture does not match requested window crop")
                }
            }
        case (.act(let request), .act(let result)):
            try require(result.observationId == request.observationId, "act observation provenance mismatch")
            try require(result.steps.count + Int(result.remainingSteps) == request.steps.count,
                        "receipt prefix does not account for requested steps")
            try require(zip(result.steps, request.steps).allSatisfy { $0.actionId == $1.actionId },
                        "receipt does not match requested action prefix")
            for (index, pair) in zip(result.steps, request.steps).enumerated() {
                try expectation(pair.1, pair.0, settled: result.stopReason == .completed || index + 1 < result.steps.count, foreground: request.foreground)
            }
            try require(request.foreground || result.foreground == nil, "unrequested foreground evidence")
            try correlateFeedback(request, result)
        case (.waitFor(let request), .waitFor(let result)):
            if let evidence = result.evidence {
                try require(evidence.condition == request.condition, "wait evidence condition mismatch")
                try require(result.outcome != .satisfied || evidence.matched, "satisfied wait has negative evidence")
            }
            if result.outcome == .satisfied {
                if case .windowAbsent = request.condition {
                    try require(result.observation == nil && result.evidence?.matched == true && result.evidence?.collected != nil,
                                "window absence requires timed evidence without a new observation")
                } else {
                    try require(result.observation != nil, "satisfied element wait requires an observation")
                }
            }
            if let observation = result.observation {
                try require(request.target == observation.target, "wait observation target mismatch")
                try require(observation.elements.allSatisfy { $0.value == nil }, "wait observation includes private values")
            }
        case (.cancel(let request), .cancel(let result)):
            try require(request.requestId == result.requestId, "cancel target mismatch")
        default: throw ContractError("response method mismatch")
        }
    }
}

/// Created from the trusted host handshake, never from public tool arguments.
public struct SessionContext: Sendable {
    public let epoch: String
    public let authority: Authority
    public init(epoch: String, authority: Authority) { self.epoch = epoch; self.authority = authority }
    public func authorize(_ request: Request) throws {
        try Frame.request(request).validate()
        if case .hello = request.body { throw ContractError("session already initialized") }
        try require(request.epoch == epoch, "stale helper epoch")
        if case .act(let act) = request.body {
            try require(act.grantId == authority.grantId, "unknown host authority grant")
            try require(!act.foreground || authority.mode == .foregroundAllowed, "operator foreground authority is required")
        }
    }
}
