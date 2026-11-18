import CUAProtocol
import Foundation

private func eventMilliseconds() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
private func eventEncoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]; return encoder }

/// Stores observed projections, never actionable references or a claim that every UI transition was seen.
final class TargetWindowEvents: @unchecked Sendable {
    let generation = UUID().uuidString
    let target: Target
    let selectors: [CUAProtocol.Selector]
    let includeValues: Bool
    let createdAt: UInt64
    private let startedUnixMs = eventMilliseconds()
    private let lock = NSLock()
    private let source: SemanticObservationHandle
    private let worker: DispatchQueue
    private let now: @Sendable () -> UInt64
    private let onPublish: @Sendable (TargetWindowEvents) -> Void
    private var notificationSource: AXWindowNotifications?
    private var poll: DispatchSourceTimer?
    private var pending = false
    private var closed = false
    private var stale = false
    private var mode: EventMode = .unavailable
    private var coalesced: UInt64 = 0
    private var sequence: UInt64 = 0
    private var samples: UInt64 = 0
    private var lostThrough: UInt64 = 0
    private var bytes = 0
    private var stored: [(TargetEvent, Int)] = []
    private var previous: [EventControl]
    private var previousCoverage: Coverage

    init(handle: SemanticObservationHandle, selectors: [CUAProtocol.Selector], baseline: Observation,
         worker: DispatchQueue, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         onPublish: @escaping @Sendable (TargetWindowEvents) -> Void = { _ in }) {
        target = handle.target; self.selectors = selectors; includeValues = handle.includeValues
        source = handle.eventReadSource(); self.worker = worker; self.now = now; createdAt = now()
        self.onPublish = onPublish
        let projection = Self.project(baseline.elements.map { element in
            AXNodeSnapshot(role: element.role, label: element.label, identifier: element.identifier, bounds: element.bounds,
                enabled: element.enabled ?? false, enabledKnown: element.enabled != nil, value: element.value, subrole: element.subrole)
        }, coverage: baseline.axSelection?.coverage ?? .unavailable)
        previous = projection.controls; previousCoverage = projection.coverage
    }

    func start(context: OperationContext) throws {
        let notifications = try AXWindowNotifications.install(handle: source, context: context) { [weak self] name, time in
            self?.wake(source: .notification, notification: name, observed: time)
        }
        lock.lock()
        guard !closed else { lock.unlock(); notifications?.close(); return }
        notificationSource = notifications
        mode = notifications == nil ? .polling : .notificationsAndPolling
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Notifications are wakeups, not a reliable event log. A bounded safety poll covers silent apps.
        let milliseconds = notifications == nil ? 50 : 500
        timer.schedule(deadline: .now() + .milliseconds(milliseconds), repeating: .milliseconds(milliseconds))
        timer.setEventHandler { [weak self] in self?.wake(source: .poll, notification: nil, observed: eventMilliseconds()) }
        poll = timer; timer.resume(); lock.unlock()
    }

    var active: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && now() - createdAt < UInt64(Limits.observationTTLMS) * 1_000_000
    }
    func publish() { onPublish(self) }
    func sameScope(_ handle: SemanticObservationHandle, selectors: [CUAProtocol.Selector]) -> Bool {
        active && self.selectors == selectors && includeValues == handle.includeValues && target == handle.target &&
            source.backend.same(source.retainedWindow, handle.retainedWindow)
    }
    func wake(source cause: EventSource, notification: String?, observed: UInt64) {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if now() - createdAt >= UInt64(Limits.observationTTLMS) * 1_000_000 { lock.unlock(); stop(); return }
        guard !pending else { coalesced += 1; lock.unlock(); return }
        pending = true; lock.unlock()
        worker.async { [weak self] in self?.sample(source: cause, notification: notification, observed: observed) }
    }

    private func sample(source cause: EventSource, notification: String?, observed: UInt64) {
        let start = eventMilliseconds()
        var coverage: Coverage = .unavailable
        var controls: [EventControl] = []
        var invalidated = false
        do {
            let scan = try source.scan(selectors: selectors, includeValues: includeValues, context: OperationContext(budgetMs: 75))
            let projection = Self.project(scan.nodes.map(\.snapshot), coverage: scan.complete ? .complete : .partial)
            coverage = projection.coverage; controls = projection.controls
        } catch let failure as NativeFailure {
            invalidated = [.staleObservation, .staleElement, .targetNotFound, .ambiguousTarget].contains(failure.code)
        } catch {}
        lock.lock(); defer { lock.unlock() }
        pending = false
        guard !closed else { return }
        samples += 1
        if invalidated { stale = true; closed = true; mode = .unavailable; poll?.cancel(); notificationSource?.close(); return }
        guard controls != previous || coverage != previousCoverage else { return }
        previous = controls; previousCoverage = coverage; sequence += 1
        let event = TargetEvent(sequence: sequence, source: cause, notification: notification, observedUnixMs: observed,
            collected: CollectionInterval(startedUnixMs: start, finishedUnixMs: max(start, observed, eventMilliseconds())),
            coverage: coverage, controls: controls)
        guard let size = try? eventEncoder().encode(event).count, size <= Limits.maxTargetEventBytes - 2048 else {
            // The sequence advances even when a single event cannot be retained, making the gap visible.
            lostThrough = sequence; return
        }
        stored.append((event, size)); bytes += size
        while stored.count > Limits.maxTargetEvents || bytes > Limits.maxTargetEventBytes - 2048 {
            let removed = stored.removeFirst(); bytes -= removed.1; lostThrough = max(lostThrough, removed.0.sequence)
        }
    }

    func history(after cursor: EventCursor?, includeValues: Bool, context: OperationContext) throws -> EventHistory {
        try context.check()
        let started = eventMilliseconds()
        lock.lock(); defer { lock.unlock() }
        let changed = cursor != nil && cursor?.generation != generation
        if let cursor, !changed, cursor.sequence > sequence { throw NativeFailure(.invalidRequest, "event cursor is ahead of retained history") }
        let first = stored.first?.0.sequence
        let requested = !changed ? cursor?.sequence ?? 0 : 0
        let overrun = requested < lostThrough || (first.map { requested < $0 - 1 } ?? (sequence > requested))
        let events = stored.map(\.0).filter { $0.sequence > requested }.map { event in
            TargetEvent(sequence: event.sequence, source: event.source, notification: event.notification,
                observedUnixMs: event.observedUnixMs, collected: event.collected, coverage: event.coverage,
                controls: event.controls.map { control in
                    EventControl(role: control.role, identifier: control.identifier, label: control.label,
                        value: includeValues ? control.value : nil, enabled: control.enabled, bounds: control.bounds, subrole: control.subrole)
                })
        }
        return EventHistory(cursor: EventCursor(generation: generation, sequence: sequence), oldestSequence: first,
            startedUnixMs: startedUnixMs, collected: CollectionInterval(startedUnixMs: started, finishedUnixMs: max(started, eventMilliseconds())),
            stale: stale || changed || now() - createdAt >= UInt64(Limits.observationTTLMS) * 1_000_000,
            overrun: overrun, mode: mode, coalescedWakes: coalesced, sampleCount: samples, events: events)
    }
    func stop() {
        lock.lock(); closed = true; stale = true; mode = .unavailable; lock.unlock()
        poll?.cancel(); notificationSource?.close()
    }
    deinit { poll?.cancel(); notificationSource?.close() }

    private static func project(_ snapshots: [AXNodeSnapshot], coverage: Coverage) -> (controls: [EventControl], coverage: Coverage) {
        var complete = coverage
        let controls = snapshots.prefix(Limits.maxEventControls).map { snapshot in
            func bounded(_ value: String?, limit: Int) -> String? {
                guard let value else { return nil }
                if value.utf8.count > limit { complete = .partial; return nil }
                return value
            }
            return EventControl(role: snapshot.role, identifier: bounded(snapshot.identifier, limit: 1024),
                label: bounded(snapshot.label, limit: 1024), value: bounded(snapshot.value, limit: Limits.maxEventValueBytes),
                enabled: snapshot.enabledKnown ? snapshot.enabled : nil, bounds: snapshot.bounds,
                subrole: bounded(snapshot.subrole, limit: 1024))
        }
        if snapshots.count > Limits.maxEventControls { complete = .partial }
        return (controls, complete)
    }
}

private final class WeakEventTracker {
    weak var value: TargetWindowEvents?
    init(_ value: TargetWindowEvents) { self.value = value }
}

/// Weak entries keep ownership with published observations; cancelled late reads cannot leave active trackers.
final class TargetEventRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var worker = DispatchQueue(label: "cua.runtime.events", qos: .utility)
    private var entries: [String: WeakEventTracker] = [:]
    private var order: [String] = []
    private var closed = false

    /// A runtime session supplies its serial native queue before admitting any observations.
    /// AX messaging timeouts on retained objects must not race action guards or mutation calls.
    func configure(worker: DispatchQueue) {
        lock.lock(); defer { lock.unlock() }
        precondition(entries.isEmpty, "event worker must be configured before collection")
        self.worker = worker
    }

    func track(handle: SemanticObservationHandle, observation: Observation, selectors: [CUAProtocol.Selector], context: OperationContext) throws -> TargetWindowEvents {
        try context.check()
        let key = "\(handle.target.key.pid):\(handle.target.key.windowId)"
        lock.lock()
        guard !closed else { lock.unlock(); throw NativeFailure(.staleEpoch, "observation tracking session is closed") }
        if let existing = entries[key]?.value, existing.sameScope(handle, selectors: selectors) { lock.unlock(); return existing }
        let eventWorker = worker
        lock.unlock()
        let tracker = TargetWindowEvents(handle: handle, selectors: selectors, baseline: observation, worker: eventWorker, onPublish: { [weak self] tracker in
            self?.publish(tracker)
        })
        try tracker.start(context: context)
        try context.check()
        return tracker
    }
    private func publish(_ tracker: TargetWindowEvents) {
        let key = "\(tracker.target.key.pid):\(tracker.target.key.windowId)"
        lock.lock()
        guard !closed else { lock.unlock(); tracker.stop(); return }
        if entries[key]?.value === tracker { lock.unlock(); return }
        let previous = entries.removeValue(forKey: key)?.value
        entries = entries.filter { $0.value.value != nil }
        order.removeAll { $0 == key || entries[$0]?.value == nil }
        let evicted = order.count >= 4 ? entries.removeValue(forKey: order.removeFirst())?.value : nil
        entries[key] = WeakEventTracker(tracker); order.append(key); lock.unlock()
        previous?.stop(); evicted?.stop()
    }
    func shutdown() {
        lock.lock(); closed = true; let live = entries.values.compactMap(\.value); entries.removeAll(); order.removeAll(); lock.unlock()
        for tracker in live { tracker.stop() }
    }
}
