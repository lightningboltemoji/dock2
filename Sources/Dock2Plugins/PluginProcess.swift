import Darwin
import Dock2Core
import Dock2System
import Foundation
import Security

/// A program a plugin runs ([commands](product/plugins/permissions.md#commands)): `posix_spawn`, never a shell,
/// answering to macOS for itself, in a process group of its own with `PATH`, `HOME`, `LANG` and `TMPDIR` alone,
/// and no descriptor of dock2's but its pipes. What it prints comes back as it prints it, up to `outputLimit`.
final class PluginProcess: @unchecked Sendable {
    enum Ending: Equatable, Sendable {
        case status(Int)
        case signal(Int)
    }

    let pid: pid_t
    /// What it prints past this is read and dropped, so it never blocks on a full pipe.
    static let outputLimit = 4 << 20

    private let queue = DispatchQueue(label: "zip.tanner.dock2.plugin-process")
    private let onOutput: @MainActor @Sendable (String, Data) -> Void
    // Touched only on `queue`.
    private var readers: [DispatchSourceRead] = []
    private var exit: DispatchSourceProcess?
    private var printed = 0
    private var truncated = false
    private var reaped = false
    private var ending = Ending.status(0)

    private init(pid: pid_t, onOutput: @escaping @MainActor @Sendable (String, Data) -> Void) {
        self.pid = pid
        self.onOutput = onOutput
    }

    /// Spawns `invocation`; `onOutput` hears what it prints and `onExit` how it ended, once its output is read,
    /// both on the main actor. Throws without spawning if its program is not signed by `team`.
    static func spawn(_ invocation: CommandGuard.Invocation, team: String?, stdin: Data?,
                      onOutput: @escaping @MainActor @Sendable (String, Data) -> Void,
                      onExit: @escaping @MainActor @Sendable (Ending, Bool) -> Void) throws -> PluginProcess {
        if let team { try check(invocation.program, signedBy: team) }
        let directory = invocation.directory ?? home
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isFolder), isFolder.boolValue else {
            throw PluginFailure("\(directory) is not a folder")
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        guard Disclaim.apply(&attributes) else {
            throw PluginFailure("this macOS will not let dock2 run a program that answers for itself, so it runs none")
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)

        var opened: [Int32] = []
        func pipe() throws -> (read: Int32, write: Int32) {
            do {
                let ends = try Self.pipe()
                opened += [ends.read, ends.write]
                return ends
            } catch {
                opened.forEach { close($0) }
                throw error
            }
        }
        let output = try pipe(), errors = try pipe(), input = try stdin.map { _ in try pipe() }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let input { posix_spawn_file_actions_adddup2(&actions, input.read, 0) } else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&actions, output.write, 1)
        posix_spawn_file_actions_adddup2(&actions, errors.write, 2)
        posix_spawn_file_actions_addchdir(&actions, directory)

        let argv = ([invocation.program] + invocation.arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, invocation.program, &actions, &attributes, argv, envp)
        for fd in [output.write, errors.write, input?.read].compactMap({ $0 }) { close(fd) }
        guard status == 0 else {
            for fd in [output.read, errors.read, input?.write].compactMap({ $0 }) { close(fd) }
            throw PluginFailure("\(invocation.program): \(String(cString: strerror(status)))")
        }

        let process = PluginProcess(pid: pid, onOutput: onOutput)
        if let input, let stdin { write(stdin, to: input.write) }
        process.queue.async { process.watch(output.read, errors.read, onExit: onExit) }
        return process
    }

    /// Ends it, and anything it started in its group: asked politely, then told after two seconds.
    func terminate() {
        queue.async { [self] in
            guard !reaped else { return }
            kill(-pid, SIGTERM)
            queue.asyncAfter(deadline: .now() + 2) { [self] in if !reaped { kill(-pid, SIGKILL) } }
        }
    }

    // MARK: - On the queue

    private func watch(_ output: Int32, _ errors: Int32, onExit: @escaping @MainActor @Sendable (Ending, Bool) -> Void) {
        let group = DispatchGroup()
        read(output, as: "stdout", group: group)
        read(errors, as: "stderr", group: group)
        group.enter()
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [self] in
            // Still a zombie, so its group id is still its own: what it left running there goes with it.
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            reaped = true
            ending = status & 0x7f == 0 ? .status(Int((status >> 8) & 0xff)) : .signal(Int(status & 0x7f))
            exit.cancel()
            // Something that left the group may hold the pipes: a moment, then they are let go.
            queue.asyncAfter(deadline: .now() + 1) { [self] in readers.forEach { $0.cancel() } }
            group.leave()
        }
        self.exit = exit
        exit.resume()
        group.notify(queue: queue) { [self] in
            let truncated = truncated, ending = ending
            DispatchQueue.main.async { MainActor.assumeIsolated { onExit(ending, truncated) } }
        }
    }

    private func read(_ fd: Int32, as stream: String, group: DispatchGroup) {
        group.enter()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { return }
            guard count > 0 else { return source.cancel() }
            let room = max(0, Self.outputLimit - printed)
            if count > room { truncated = true }
            guard room > 0 else { return }
            let kept = Data(buffer[0..<min(count, room)])
            printed += kept.count
            let onOutput = onOutput
            DispatchQueue.main.async { MainActor.assumeIsolated { onOutput(stream, kept) } }
        }
        source.setCancelHandler {
            close(fd)
            group.leave()
        }
        readers.append(source)
        source.resume()
    }

    // MARK: - Spawning

    private static var home: String {
        LaunchEnvironment.variables["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// dock2's own, for these four alone: a launchd's `PATH` when dock2 was opened as an app.
    static var environment: [String] {
        let launch = LaunchEnvironment.variables
        return ["PATH=\(launch["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")", "HOME=\(home)", "LANG=\(launch["LANG"] ?? "en_US.UTF-8")",
                "TMPDIR=\(launch["TMPDIR"] ?? NSTemporaryDirectory())"]
    }

    private static func pipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { throw PluginFailure("no pipe: \(String(cString: strerror(errno)))") }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// Off the caller's thread, since a program that does not read would block it; a program gone before it
    /// read everything is no signal to dock2.
    private static func write(_ data: Data, to fd: Int32) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async {
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { break }
                    offset += written
                }
            }
            close(fd)
        }
    }

    /// Before each spawn: the program as it is now, signed by `team`.
    static func check(_ program: String, signedBy team: String) throws {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: program) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
        else { throw PluginFailure("\(program) is not signed by \(team)") }
    }
}
