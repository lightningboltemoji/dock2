import Darwin

/// A child that answers to macOS for itself ([commands](product/plugins/permissions.md#commands)). Spawned
/// plainly, a program is held responsible to the app at the top of its parents, so it would carry dock2's
/// Accessibility, Full Disk Access and Screen Recording. Private API, looked up by name: without it, nothing runs.
enum Disclaim {
    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, CBool) -> Int32
    private typealias Responsible = @convention(c) (pid_t) -> pid_t

    private static let setDisclaim: SetDisclaim? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: SetDisclaim.self) }

    static var isAvailable: Bool { setDisclaim != nil }

    /// Marks the attributes so the child is its own responsible process; false if that cannot be done.
    static func apply(_ attributes: inout posix_spawnattr_t?) -> Bool {
        guard let setDisclaim else { return false }
        return setDisclaim(&attributes, true) == 0
    }

    /// Which process macOS holds `pid` responsible to: for tests.
    static func responsible(for pid: pid_t) -> pid_t? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: Responsible.self)(pid) }
    }
}
