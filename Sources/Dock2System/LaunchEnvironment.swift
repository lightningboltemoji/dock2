import Darwin
import Foundation

/// The environment dock2 was started with, which is dock2's alone. LaunchServices gives an app it opens its
/// caller's environment over the session's, so with dock2's set aside an app it opens starts as one the Dock
/// opens, whether dock2 was started by launchd or from a terminal.
public enum LaunchEnvironment {
    /// Every variable dock2 was started with: the `DOCK2_*` switches, and `TMPDIR` for the control socket.
    public static let variables = ProcessInfo.processInfo.environment

    /// Empties the process's environment, keeping it in `variables`. Once, before any other thread runs.
    public static func setAside() {
        for name in variables.keys { unsetenv(name) }
    }
}
