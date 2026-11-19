import AppKit
import CUAProtocol
import CUARuntime
import Darwin
import Foundation

final class RuntimeProcess: @unchecked Sendable {
    private let visualFeedback: Bool
    private var session: RuntimeSession!
    private var output: OutputPump!
    private var signals: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var exitCode: Int32 = 0
    private var stopped = false

    init(visualFeedback: Bool) {
        self.visualFeedback = visualFeedback
    }

    func start() {
        signal(SIGPIPE, SIG_IGN)
        output = OutputPump(write: { try FileHandle.standardOutput.write(contentsOf: $0) },
                            onFailure: { [weak self] in self?.session.shutdown() })
        session = RuntimeSession(visualFeedback: visualFeedback, emit: { [weak self] response in
            guard let self else { return }
            do { try self.output.send(response) }
            catch { self.diagnostic("output_failure"); self.session.shutdown() }
        }, emitProgress: { [weak self] progress in
            guard let self else { throw NativeFailure(.nativeFailed, "runtime output unavailable") }
            return try self.output.sendProgress(progress)
        }, didShutdown: { [weak self] in self?.finish() })
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.session.shutdown() }
            source.resume()
            signals.append(source)
        }
    }
    func startReading() {
        DispatchQueue.global(qos: .userInitiated).async { self.readInput() }
    }
    private func readInput() {
        var framer = LineFramer()
        do {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                if count == 0 { break }
                let bytes = Data(buffer.prefix(count))
                for line in try framer.append(bytes) {
                    let receivedAt = DispatchTime.now().uptimeNanoseconds
                    guard case .request(let request) = try Frame.decodeLine(line) else {
                        throw ContractError("stdin accepts request frames only")
                    }
                    session.receive(request, receivedAt: receivedAt, frameBytes: line.count)
                }
            }
            try framer.finish()
        } catch {
            lock.lock(); exitCode = 64; lock.unlock()
            diagnostic("invalid_input")
        }
        session.shutdown()
    }
    private func finish() {
        output.finish { self.stop() }
        // A peer that stops reading stdout cannot prevent process cleanup on EOF/SIGTERM.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { self.stop() }
    }
    private func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        if visualFeedback {
            DispatchQueue.main.async {
                let app = NSApplication.shared
                app.stop(nil)
                // Wake AppKit's next-event loop without posting any system input.
                if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    app.postEvent(wake, atStart: true)
                }
            }
        } else {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetMain()) }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
    func result() -> Int32 { lock.lock(); defer { lock.unlock() }; return exitCode }
    func shouldRun() -> Bool { lock.lock(); defer { lock.unlock() }; return !stopped }
    private func diagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data(("cua-runtime: " + message + "\n").utf8))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let feedbackRequested = ProcessInfo.processInfo.environment["CUA_VISUAL_FEEDBACK"] == "1"
    let visualFeedback = feedbackRequested && app.setActivationPolicy(.accessory)
    if !visualFeedback { app.setActivationPolicy(.prohibited) }
    let process = RuntimeProcess(visualFeedback: visualFeedback)
    process.start()
    if process.shouldRun() {
        process.startReading()
        if visualFeedback { app.run() }
        else { CFRunLoopRun() }
    }
    exit(process.result())
}
