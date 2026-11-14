import CUAProtocol
import Foundation

/// One bounded output queue; a slow peer cannot grow response memory indefinitely.
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
    public func send(_ response: Response) throws {
        let data = try Frame.response(response).encodeLine()
        lock.lock()
        guard !failed, !finishing, frames < 32, data.count <= Limits.maxFrameBytes - bytes else {
            lock.unlock(); throw NativeFailure(.nativeFailed, "stdout closed or bounded response queue full")
        }
        frames += 1; bytes += data.count
        lock.unlock()
        queue.async {
            do { try self.write(data) }
            catch {
                self.lock.lock(); self.failed = true; self.lock.unlock()
                self.onFailure()
            }
            self.lock.lock(); self.frames -= 1; self.bytes -= data.count; self.lock.unlock()
        }
    }
    public func finish(_ completion: @escaping @Sendable () -> Void) {
        lock.lock(); finishing = true; lock.unlock()
        queue.async(execute: completion)
    }
}
