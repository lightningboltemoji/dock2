import Foundation

/// An exclusive `flock` on `Paths.lock`: whoever holds it owns the journal. Close-on-exec, or the guard
/// would inherit it and hold the lock against itself.
public final class InstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close(descriptor) }

    /// The lock, or nil if another process still holds it after `waiting` seconds. The wait covers a
    /// guard that is restoring for a dock2 that just quit, which takes a moment.
    public static func claim(waiting: TimeInterval = 0) -> InstanceLock? {
        do { try Paths.ensureDirectory() } catch {
            warn("cannot create \(Paths.directory.path): \(error.localizedDescription)")
            return nil
        }
        let fd = open(Paths.lock.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            warn("cannot open \(Paths.lock.path): \(String(cString: strerror(errno)))")
            return nil
        }
        let deadline = Date().addingTimeInterval(waiting)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else {
                close(fd)
                return nil
            }
            usleep(50_000)
        }
        ftruncate(fd, 0)
        _ = "\(getpid())\n".withCString { write(fd, $0, strlen($0)) }
        return InstanceLock(descriptor: fd)
    }

    /// The pid written by whoever holds the lock, for telling the user what is in the way.
    public static var holder: pid_t? {
        guard let text = try? String(contentsOf: Paths.lock, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
