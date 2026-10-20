import AppKit
import Dock2Core

/// The system Dock: its preferences, and its process.
public enum SystemDock {
    private static var domain: CFString { Suppression.domain as CFString }

    /// One of the Dock's preferences, as the user's defaults hold it right now.
    public static func read(_ key: String) -> PlistValue? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key as CFString, domain).flatMap { PlistValue($0) }
    }

    /// The tile size the Dock is set to, which dock2 mirrors.
    public static var tileSize: Double {
        switch read("tilesize") {
        case .real(let size): return size
        case .integer(let size): return Double(size)
        default: return DockMetrics.defaultTileSize
        }
    }

    /// Writes `steps` and flushes them to `cfprefsd`, so a Dock started after this returns reads them.
    /// Returns whether any value changed, which is whether the Dock needs a restart to see them.
    @discardableResult
    static func apply(_ steps: [SuppressionJournal.Step]) -> Bool {
        var changed = false
        for step in steps {
            switch step {
            case .set(let key, let value):
                guard read(key) != value else { continue }
                // cfprefsd skips a write that CFEqual calls equal, and 95 equals 95.0: clearing the key
                // first makes the type stick too.
                CFPreferencesSetAppValue(key as CFString, nil, domain)
                CFPreferencesSetAppValue(key as CFString, value.object as CFPropertyList, domain)
                changed = true
            case .remove(let key):
                guard read(key) != nil else { continue }
                CFPreferencesSetAppValue(key as CFString, nil, domain)
                changed = true
            }
        }
        if changed && !CFPreferencesAppSynchronize(domain) {
            warn("could not write the Dock's preferences")
        }
        return changed
    }

    /// Quits the Dock. launchd starts it again at once, and it reads its preferences as it starts:
    /// there is no other way to make it notice them.
    static func restart() {
        let docks = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
        for dock in docks { kill(dock.processIdentifier, SIGTERM) }
        if docks.isEmpty { warn("the Dock is not running; it will read the new settings when it starts") }
    }
}
