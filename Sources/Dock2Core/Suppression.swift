import Foundation

/// How dock2 hides the system Dock: auto-hide, with a reveal delay nobody will wait out. The keys' old
/// values go to `SuppressionJournal` first, and it is the only record of them (IMPLEMENTATION.md §4).
public enum Suppression {
    /// The preference domain of the Dock.
    public static let domain = "com.apple.dock"

    /// What dock2 writes while it runs: auto-hide on, and a reveal delay of seventeen minutes.
    public static let overrides: [String: PlistValue] = [
        "autohide": .bool(true),
        "autohide-delay": .real(1000),
    ]
}

/// The user's own values for the keys dock2 overrides, as they were before it touched them.
public struct SuppressionJournal: Sendable, Equatable {
    /// Every key dock2 overrides, mapped to its prior value; nil for a key that was not set.
    public var originals: [String: PlistValue?]

    public init(originals: [String: PlistValue?]) {
        self.originals = originals
    }

    /// The journal for the system as it is now, from a reader of the Dock's preferences.
    public static func snapshot(reading read: (String) -> PlistValue?) -> SuppressionJournal {
        var originals: [String: PlistValue?] = [:]
        for key in Suppression.overrides.keys { originals[key] = .some(read(key)) }
        return SuppressionJournal(originals: originals)
    }

    /// The best journal there is when the real one is lost: a key still holding dock2's own value is
    /// taken to have been unset, which hands it back to the Dock's default.
    public static func recovered(reading read: (String) -> PlistValue?) -> SuppressionJournal {
        var originals: [String: PlistValue?] = [:]
        for (key, override) in Suppression.overrides {
            let current = read(key)
            originals[key] = .some(current == override ? nil : current)
        }
        return SuppressionJournal(originals: originals)
    }

    public enum Step: Sendable, Equatable {
        case set(String, PlistValue)
        case remove(String)
    }

    /// What puts the Dock back: each key to its old value, and a key that had none removed rather than
    /// left at a default, so the Dock goes back to deciding for itself.
    public var restoration: [Step] {
        originals.keys.sorted().map { key in
            if case .some(.some(let value)) = originals[key] { return .set(key, value) }
            return .remove(key)
        }
    }

    // MARK: - On disk

    private static let version = 1

    /// A property list: `version`, and `keys` mapping each key to a dictionary that has a `value` entry
    /// exactly when the key was set.
    public func encoded() throws -> Data {
        var keys: [String: Any] = [:]
        for (key, value) in originals {
            keys[key] = value.map { ["value": $0.object] } ?? [String: Any]()
        }
        let root: [String: Any] = ["version": Self.version, "keys": keys]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    public static func decode(_ data: Data) throws -> SuppressionJournal {
        let root = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = root as? [String: Any], dictionary["version"] as? Int == version,
              let keys = dictionary["keys"] as? [String: [String: Any]] else {
            throw JournalError.unreadable
        }
        var originals: [String: PlistValue?] = [:]
        for (key, entry) in keys {
            if let raw = entry["value"] {
                guard let value = PlistValue(raw) else { throw JournalError.unreadable }
                originals[key] = .some(value)
            } else {
                originals[key] = .some(nil)
            }
        }
        return SuppressionJournal(originals: originals)
    }

    public enum JournalError: Error, CustomStringConvertible {
        case unreadable
        public var description: String { "the journal of the system Dock's settings is unreadable" }
    }
}
