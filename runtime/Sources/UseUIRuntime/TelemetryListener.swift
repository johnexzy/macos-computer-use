import Darwin
import Foundation

/// Structured telemetry frame pushed from `useui` Rust host to `useui-runtime` over a
/// user-private (`0600`) Unix domain socket verified with `LOCAL_PEERCRED`.
struct HostTelemetryEvent: Decodable, Sendable {
    let source: String
    let phase: String
    let label: String
    let detail: String?
    let tsUnixMs: UInt64
}

/// Event-driven Unix domain socket listener that receives browser/host activity updates
/// with zero polling and zero changes to the v1 AX wire protocol.
final class TelemetryListener: @unchecked Sendable {
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.johnoba.useui.telemetry", qos: .utility)
    private let onEvent: @Sendable (HostTelemetryEvent) -> Void
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let expectedUID = geteuid()

    init(socketPath: String, onEvent: @escaping @Sendable (HostTelemetryEvent) -> Void) {
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [weak self] in
            self?.openAndListen()
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            if listenFD >= 0 {
                Darwin.close(listenFD)
                listenFD = -1
            }
            unlink(socketPath)
        }
    }

    private func openAndListen() {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(socketPath)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < maxLen else {
            Darwin.close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for i in 0..<bytes.count {
                raw[i] = bytes[i]
            }
            raw[bytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            return
        }
        chmod(socketPath, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            unlink(socketPath)
            return
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainConnections()
        }
        source.resume()
        acceptSource = source
    }

    private func drainConnections() {
        guard listenFD >= 0 else { return }
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 { break }
            defer { Darwin.close(clientFD) }

            // Verify peer UID via LOCAL_PEERCRED (getpeereid) before reading a byte.
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == expectedUID else {
                continue
            }

            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while data.count < 32_768 {
                let n = Darwin.read(clientFD, &buf, buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
                if buf.prefix(n).contains(UInt8(ascii: "\n")) { break }
            }
            for line in data.split(separator: UInt8(ascii: "\n")) {
                if let event = try? JSONDecoder().decode(HostTelemetryEvent.self, from: Data(line)) {
                    onEvent(event)
                }
            }
        }
    }
}
