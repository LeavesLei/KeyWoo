import Foundation
import Darwin

/// A per-user process lease. Never unlink the file: replacing its inode would
/// allow another process to acquire a different lock while this one is held.
final class ProcessInstanceLock {
    enum Failure: Error, LocalizedError {
        case operation(String, Int32)
        case unsafeFile

        var errorDescription: String? {
            switch self {
            case let .operation(name, code): return "\(name): \(String(cString: strerror(code)))"
            case .unsafeFile: return "The instance lock must be a private, user-owned regular file."
            }
        }
    }

    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// nil means another process holds the lease; other failures must not be
    /// treated as permission to start a second audio engine.
    static func acquire(at url: URL) throws -> ProcessInstanceLock? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw Failure.operation("open instance lock", errno) }
        var keepOpen = false
        defer { if !keepOpen { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Failure.operation("inspect instance lock", errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw Failure.unsafeFile }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { return nil }
            throw Failure.operation("acquire instance lock", code)
        }
        guard ftruncate(descriptor, 0) == 0 else { throw Failure.operation("write lock owner", errno) }
        let owner = Array("\(getpid())\n".utf8)
        try owner.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure.operation("write lock owner", errno) }
                offset += written
            }
        }
        keepOpen = true
        return ProcessInstanceLock(descriptor: descriptor)
    }

    /// The PID is only a hint for activation; callers must also verify the
    /// running application's bundle identifier. It can be empty during startup.
    static func ownerProcessIdentifier(at url: URL) -> pid_t? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_nlink == 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count > 0,
              let pid = pid_t(String(decoding: bytes.prefix(count), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
