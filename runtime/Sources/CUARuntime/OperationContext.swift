import CUAProtocol
import Foundation

public enum Interruption: Equatable, Sendable { case cancelled, deadlineExceeded }

public struct NativeFailure: Error, Sendable {
    public let code: ErrorCode
    public let message: String
    public init(_ code: ErrorCode, _ message: String) { self.code = code; self.message = message }
}

/// One monotonic budget from frame receipt. Native calls never reset it.
public final class OperationContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public let deadlineNanoseconds: UInt64
    private let now: @Sendable () -> UInt64

    public init(receivedAt: UInt64 = DispatchTime.now().uptimeNanoseconds, budgetMs: UInt32,
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        deadlineNanoseconds = receivedAt + UInt64(budgetMs) * 1_000_000
        self.now = now
    }
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var interruption: Interruption? {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { return .cancelled }
        return now() >= deadlineNanoseconds ? .deadlineExceeded : nil
    }
    public func check() throws {
        if let reason = interruption {
            throw NativeFailure(reason == .cancelled ? .cancelled : .deadlineExceeded, "\(reason)")
        }
    }
    public func nativeTimeoutSeconds(maximum: Double = 0.25) throws -> Float {
        try check()
        let current = now()
        guard current < deadlineNanoseconds else { throw NativeFailure(.deadlineExceeded, "deadlineExceeded") }
        return Float(min(maximum, Double(deadlineNanoseconds - current) / 1_000_000_000))
    }
}
