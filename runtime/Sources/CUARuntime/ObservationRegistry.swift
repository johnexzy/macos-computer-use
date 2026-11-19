import CUAProtocol
import Foundation

public protocol RetainedNativeHandle: AnyObject, Sendable {
    func didPublishObservation()
}
public extension RetainedNativeHandle { func didPublishObservation() {} }

public struct RetainedObservation: Sendable {
    public let observation: Observation
    public let handle: (any RetainedNativeHandle)?
    let createdAt: UInt64
}

/// Epoch-local ownership, insertion-order eviction, and non-refreshing TTL.
public final class ObservationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let epoch: String
    private let now: @Sendable () -> UInt64
    private var entries: [String: RetainedObservation] = [:]
    private var order: [String] = []
    private var valid = true

    public init(epoch: String, now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.epoch = epoch; self.now = now
    }
    public func insert(_ observation: Observation, handle: (any RetainedNativeHandle)?) throws {
        lock.lock(); defer { lock.unlock() }
        guard valid else { throw NativeFailure(.staleEpoch, "session is closed") }
        pruneLocked()
        if entries[observation.observationId] != nil { order.removeAll { $0 == observation.observationId } }
        while order.count >= Limits.maxRetainedObservations {
            entries.removeValue(forKey: order.removeFirst())
        }
        entries[observation.observationId] = RetainedObservation(observation: observation, handle: handle, createdAt: now())
        order.append(observation.observationId)
        handle?.didPublishObservation()
    }
    public func lookup(_ id: String, epoch: String, target: TargetKey) throws -> RetainedObservation {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
        guard epoch == self.epoch, let entry = entries[id], entry.observation.target == target else {
            throw NativeFailure(.staleObservation, "observation is expired, unknown, or belongs to another target/session")
        }
        return entry
    }
    public func prune() { lock.lock(); pruneLocked(); lock.unlock() }
    public func removeAll() { lock.lock(); entries.removeAll(); order.removeAll(); lock.unlock() }
    public func invalidate() {
        lock.lock(); valid = false; entries.removeAll(); order.removeAll(); lock.unlock()
    }
    public var count: Int { lock.lock(); defer { lock.unlock() }; pruneLocked(); return entries.count }
    private func pruneLocked() {
        let current = now()
        let lifetime = UInt64(Limits.observationTTLMS) * 1_000_000
        order.removeAll { id in
            guard let entry = entries[id] else { return true }
            if current - entry.createdAt >= lifetime { entries.removeValue(forKey: id); return true }
            return false
        }
    }
}
