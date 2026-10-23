import AppKit
import Dock2Core

/// The system Dock: its preferences, and its process.
public enum SystemDock {
    public static let preferences = PreferenceDomain(Suppression.domain)

    public static func read(_ key: String) -> PlistValue? {
        preferences.read(key)
    }

    /// The tile size the Dock is set to.
    public static var tileSize: Double {
        switch read("tilesize") {
        case .real(let size): size
        case .integer(let size): Double(size)
        default: DockMetrics.defaultTileSize
        }
    }

    /// Quits the Dock. launchd starts it again at once, and it reads its preferences as it starts:
    /// there is no other way to make it notice them. Found in the process table too, since a Dock launchd
    /// has just started — after the last restart — is not yet in LaunchServices' list.
    static func restart() {
        let listed = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").map(\.processIdentifier)
        let docks = Set(listed + processes(running: executable))
        for pid in docks where kill(pid, SIGTERM) != 0 && errno != ESRCH {
            warn("could not quit the Dock (pid \(pid)): \(String(cString: strerror(errno)))")
        }
        if docks.isEmpty { warn("the Dock is not running; it will read the new settings when it starts") }
    }

    static let executable = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"

    /// This user's processes running the executable at `path`.
    static func processes(running path: String) -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.stride + 32)
        let filled = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(max(0, Int(filled)) / MemoryLayout<pid_t>.stride).filter { pid in
            let length = pid > 0 ? proc_pidpath(pid, &buffer, UInt32(buffer.count)) : 0
            return length > 0 && String(decoding: buffer.prefix(Int(length)), as: UTF8.self) == path
        }
    }
}

/// Hides the system Dock — auto-hide with a reveal delay nobody will wait out — and keeps its minimised
/// windows as items of their own, then restarts it, since the Dock reads these keys only as it starts.
public struct SystemDockTakeover: Takeover {
    public let id = TakeoverID.systemDock

    public init() {}

    public func snapshot() -> PlistValue {
        DockOriginal.snapshot(reading: SystemDock.read).plist
    }

    public func completed(_ original: PlistValue) -> PlistValue {
        DockOriginal(original)?.completed(reading: SystemDock.read).plist ?? original
    }

    public func apply() {
        do {
            if try SystemDock.preferences.apply(Suppression.changes) { SystemDock.restart() }
        } catch {
            warn("\(error)")
        }
    }

    public func restore(_ original: PlistValue) -> Bool {
        let keys = DockOriginal(original) ?? {
            warn("the journal's system Dock entry is unreadable; restoring the Dock's defaults for the keys dock2 changed")
            return DockOriginal.recovered(reading: SystemDock.read)
        }()
        do {
            if try SystemDock.preferences.apply(keys.restoration) { SystemDock.restart() }
        } catch {
            warn("\(error)")
            return false
        }
        return keys.keys.allSatisfy { SystemDock.read($0.key) == $0.value }
    }

    public func recovered() -> PlistValue? {
        guard SystemDock.read(Suppression.mark.key) == Suppression.mark.value else { return nil }
        return DockOriginal.recovered(reading: SystemDock.read).plist
    }
}
