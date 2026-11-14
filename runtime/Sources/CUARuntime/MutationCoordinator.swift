import Darwin
import Foundation

/// Advisory exclusion for cooperating helpers of the same OS user. Never unlink this inode.
public struct MutationCoordinator: Sendable {
    private let directory: URL?

    public init(directory: URL? = nil) { self.directory = directory }

    public func withOwnership<T>(context: OperationContext, _ operation: () throws -> T) throws -> T {
        try context.check()
        let directory = try directory ?? Self.userDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw NativeFailure(.nativeFailed, "private mutation directory unavailable") }
        defer { Darwin.close(directoryFD) }
        var directoryInfo = stat()
        guard fstat(directoryFD, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_mode & 0o077 == 0 else {
            throw NativeFailure(.nativeFailed, "mutation directory is not private to the current user")
        }
        let descriptor = openat(directoryFD, "mutation.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NativeFailure(.nativeFailed, "mutation lock unavailable") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o077 == 0 else {
            throw NativeFailure(.nativeFailed, "mutation lock is not a private regular file")
        }
        while true {
            try context.check()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw NativeFailure(.nativeFailed, "mutation lock acquisition failed")
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        // Descriptor ownership lasts through the physical operation, even if its logical receipt is interrupted.
        try context.check()
        return try operation()
    }

    private static func userDirectory() throws -> URL {
        // Resolve the OS account, not HOME or a per-host sandbox cache path.
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var bytes = [CChar](repeating: 0, count: 16_384)
        var home: String?
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            let status = getpwuid_r(geteuid(), &account, buffer.baseAddress, buffer.count, &result)
            if status == 0, result != nil, let path = account.pw_dir { home = String(cString: path) }
            return status
        }
        guard status == 0, let home else { throw NativeFailure(.nativeFailed, "current user cache directory unavailable") }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Caches/macos-computer-use", isDirectory: true)
    }
}
