import Darwin
import Foundation

/// `dock2 --guard <pid>`: a second process that restores the system Dock when dock2 exits without doing
/// so itself — a crash, SIGKILL. In its own session, so a terminal's Ctrl-C reaches dock2 alone.
public enum Guard {
    public static let flag = "--guard"

    /// The descriptor the guard reports readiness on: one byte, once it is watching.
    private static let readyDescriptor: Int32 = 3

    /// Starts a guard for this process and waits until it is watching. Returns its pid, or nil if it
    /// could not be started — dock2 then runs unguarded, and says so.
    public static func spawn() -> pid_t? {
        guard let executable = Bundle.main.executableURL?.path else { return nil }
        var pipeEnds: [Int32] = [0, 0]
        guard pipe(&pipeEnds) == 0 else { return nil }
        defer { close(pipeEnds[0]) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] { posix_spawn_file_actions_addinherit_np(&actions, fd) }
        posix_spawn_file_actions_adddup2(&actions, pipeEnds[1], readyDescriptor)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Nothing else of dock2's crosses over: in particular not the instance lock's descriptor.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let arguments = [executable, flag, String(getpid())]
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
        close(pipeEnds[1])
        guard status == 0 else {
            warn("could not start the guard: \(String(cString: strerror(status)))")
            return nil
        }

        var poller = pollfd(fd: pipeEnds[0], events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        guard poll(&poller, 1, 2000) == 1, read(pipeEnds[0], &byte, 1) == 1 else {
            warn("the guard did not report in; continuing without it")
            return pid
        }
        return pid
    }

    /// The guard's whole life. Never returns.
    public static func run(parent: pid_t) -> Never {
        // Only dock2's exit ends this; a logout's SIGTERM is answered by dock2 restoring, after which
        // the journal is gone and this has nothing left to do.
        for number in [SIGINT, SIGHUP, SIGTERM, SIGPIPE] { signal(number, SIG_IGN) }
        programName = "dock2 guard"

        let queue = kqueue()
        var change = kevent(ident: UInt(parent), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        // ESRCH: dock2 died before this got here. Restore at once.
        let watching = kevent(queue, &change, 1, nil, 0, nil) == 0
        var byte: UInt8 = 1
        _ = write(readyDescriptor, &byte, 1)
        close(readyDescriptor)

        if watching {
            var event = kevent()
            while kevent(queue, nil, 0, &event, 1, nil) == -1 && errno == EINTR {}
        }

        // A new dock2 may already hold the lock, and with it the journal: then there is nothing to do.
        guard let lock = InstanceLock.claim(waiting: 0) else { exit(0) }
        if Suppressor.isSuppressed {
            warn("dock2 (pid \(parent)) exited without restoring the system Dock; restoring it")
            Suppressor.restore()
        }
        withExtendedLifetime(lock) { exit(0) }
    }
}
