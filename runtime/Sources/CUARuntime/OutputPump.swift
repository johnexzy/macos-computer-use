import CUAProtocol
import Foundation

/// Completion of one whole JSONL write, not merely admission to the output queue.
public final class OutputTicket: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Void, NativeFailure>?

    init() {}
    func resolve(_ result: Result<Void, NativeFailure>) {
        condition.lock(); defer { condition.unlock() }
        guard self.result == nil else { return }
        self.result = result; condition.broadcast()
    }
    public func wait(context: OperationContext) throws {
        while true {
            try context.check()
            condition.lock()
            if let result {
                condition.unlock()
                try context.check()
                return try result.get()
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.005))
            condition.unlock()
        }
    }
}

/// One bounded ordered queue. Native work may await a write without blocking session control/timers.
public final class OutputPump: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "cua.runtime.stdout")
    private let write: @Sendable (Data) throws -> Void
    private let onFailure: @Sendable () -> Void
    private var bytes = 0
    private var frames = 0
    private var failed = false
    private var finishing = false

    public init(write: @escaping @Sendable (Data) throws -> Void, onFailure: @escaping @Sendable () -> Void) {
        self.write = write; self.onFailure = onFailure
    }
    public func send(_ response: Response) throws { _ = try enqueue(.response(response)) }
    public func sendProgress(_ progress: CUAProtocol.Progress) throws -> OutputTicket { try enqueue(.progress(progress)) }

    private func enqueue(_ frame: Frame) throws -> OutputTicket {
        let data = try frame.encodeLine()
        let ticket = OutputTicket()
        lock.lock()
        guard !failed, !finishing, frames < 32, data.count <= Limits.maxFrameBytes - bytes else {
            lock.unlock(); throw NativeFailure(.nativeFailed, "stdout closed or bounded response queue full")
        }
        frames += 1; bytes += data.count
        queue.async {
            self.lock.lock(); let alreadyFailed = self.failed; self.lock.unlock()
            if alreadyFailed {
                ticket.resolve(.failure(NativeFailure(.nativeFailed, "stdout write failed")))
            } else {
                do { try self.write(data); ticket.resolve(.success(())) }
                catch {
                    self.lock.lock(); self.failed = true; self.lock.unlock()
                    ticket.resolve(.failure(NativeFailure(.nativeFailed, "stdout write failed")))
                    self.onFailure()
                }
            }
            self.lock.lock(); self.frames -= 1; self.bytes -= data.count; self.lock.unlock()
        }
        lock.unlock()
        return ticket
    }
    public func finish(_ completion: @escaping @Sendable () -> Void) {
        lock.lock(); finishing = true
        queue.async(execute: completion)
        lock.unlock()
    }
}
