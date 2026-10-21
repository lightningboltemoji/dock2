import Dock2Core
import Foundation

/// One of the user's preference domains, read and written through CFPreferences for the current user on
/// any host — the scope the Dock and AppKit read.
public struct PreferenceDomain: Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    /// `.GlobalPreferences`: what every app reads, `NSFileViewer` among it.
    public static let global = PreferenceDomain(kCFPreferencesAnyApplication as String)

    /// A key as the user's defaults hold it right now.
    public func read(_ key: String) -> PlistValue? {
        CFPreferencesAppSynchronize(name as CFString)
        return CFPreferencesCopyAppValue(key as CFString, name as CFString).flatMap { PlistValue($0) }
    }

    /// Writes `changes` and flushes them to cfprefsd, so a process started after this returns reads them.
    /// Returns whether any value changed; throws when cfprefsd did not take them.
    @discardableResult
    public func apply(_ changes: [PreferenceChange]) throws -> Bool {
        let domain = name as CFString
        var changed = false
        for change in changes {
            switch change {
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
        if changed && !CFPreferencesAppSynchronize(domain) { throw Unwritten(domain: name) }
        return changed
    }

    public struct Unwritten: Error, CustomStringConvertible {
        public let domain: String
        public var description: String { "could not write the preferences of \(domain)" }
    }
}
