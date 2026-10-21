import Foundation

/// A system behaviour dock2 changes while it runs, under the name the journal files it by.
public enum TakeoverID: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// The system Dock, hidden by its own auto-hide.
    case systemDock
    /// One entry of the window server's table of system hot keys, switched off.
    case hotKey(Int)
    /// The global `NSFileViewer` default, naming dock2.
    case fileViewer

    public init?(rawValue: String) {
        switch rawValue {
        case "system-dock": self = .systemDock
        case "file-viewer": self = .fileViewer
        default:
            guard rawValue.hasPrefix("hot-key."), let entry = Int(rawValue.dropFirst("hot-key.".count)) else {
                return nil
            }
            self = .hotKey(entry)
        }
    }

    public var rawValue: String {
        switch self {
        case .systemDock: "system-dock"
        case .hotKey(let entry): "hot-key.\(entry)"
        case .fileViewer: "file-viewer"
        }
    }

    public var description: String { rawValue }

    /// Giving back runs in this order: the system Dock last, since giving it back restarts it.
    public static func < (lhs: TakeoverID, rhs: TakeoverID) -> Bool {
        func rank(_ id: TakeoverID) -> Int { id == .systemDock ? 1 : 0 }
        return (rank(lhs), lhs.rawValue) < (rank(rhs), rhs.rawValue)
    }
}

/// The user's own state for every takeover dock2 holds, recorded before dock2 changed it: the only record
/// there is of it (IMPLEMENTATION.md §4).
public struct TakeoverJournal: Sendable, Equatable {
    public var entries: [TakeoverID: PlistValue]
    /// Entries a newer dock2 wrote, under names this one does not know: kept as they are, for that one to
    /// give back.
    public var unknown: [String: PlistValue]

    public init(entries: [TakeoverID: PlistValue] = [:], unknown: [String: PlistValue] = [:]) {
        self.entries = entries
        self.unknown = unknown
    }

    public var isEmpty: Bool { entries.isEmpty && unknown.isEmpty }

    // MARK: - On disk

    private static let version = 2

    /// A property list: `version`, and `takeovers` mapping each takeover's name to its original state.
    public func encoded() throws -> Data {
        var takeovers: [String: Any] = unknown.mapValues(\.object)
        for (id, original) in entries { takeovers[id.rawValue] = original.object }
        let root: [String: Any] = ["version": Self.version, "takeovers": takeovers]
        return try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    /// Reads version 2, and version 1 — the system Dock's keys alone, as the first dock2 wrote them.
    public static func decode(_ data: Data) throws -> TakeoverJournal {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              case .dictionary(let dictionary)? = PlistValue(root) else {
            throw JournalError.unreadable
        }
        switch dictionary["version"] {
        case .integer(1):
            guard let original = DockOriginal(.dictionary(dictionary)) else { throw JournalError.unreadable }
            return TakeoverJournal(entries: [.systemDock: original.plist])
        case .integer(version):
            guard case .dictionary(let takeovers)? = dictionary["takeovers"] else { throw JournalError.unreadable }
            var journal = TakeoverJournal()
            for (name, original) in takeovers {
                if let id = TakeoverID(rawValue: name) { journal.entries[id] = original } else { journal.unknown[name] = original }
            }
            return journal
        default:
            throw JournalError.unreadable
        }
    }

    public enum JournalError: Error, Equatable, CustomStringConvertible {
        case unreadable

        public var description: String { "the journal of dock2's takeovers is unreadable" }
    }
}

/// One write to a preference domain: what giving a setting back, or taking it over, amounts to.
public enum PreferenceChange: Sendable, Equatable {
    case set(String, PlistValue)
    case remove(String)
}

// MARK: - The system Dock

/// How dock2 hides the system Dock: auto-hide, with a reveal delay nobody will wait out.
public enum Suppression {
    /// The preference domain of the Dock.
    public static let domain = "com.apple.dock"

    /// What dock2 writes while it runs: auto-hide on, and a reveal delay of seventeen minutes — not the
    /// 1000 s a common tip has users type, so that it marks dock2's hiding alone.
    public static let overrides: [String: PlistValue] = [
        "autohide": .bool(true),
        "autohide-delay": .real(1000.0625),
    ]

    public static var changes: [PreferenceChange] {
        overrides.keys.sorted().map { .set($0, overrides[$0]!) }
    }

    /// What only dock2 sets: a Dock with this reveal delay was hidden by dock2, whatever its auto-hide says —
    /// which may well be the user's own.
    public static let mark = (key: "autohide-delay", value: overrides["autohide-delay"]!)
}

/// The user's values for the keys `Suppression` overrides, as they were before dock2 touched them.
public struct DockOriginal: Sendable, Equatable {
    /// Every overridden key, mapped to its prior value; nil for a key that was not set.
    public var keys: [String: PlistValue?]

    public init(keys: [String: PlistValue?]) {
        self.keys = keys
    }

    /// The user's values as they are now, from a reader of the Dock's preferences.
    public static func snapshot(reading read: (String) -> PlistValue?) -> DockOriginal {
        var keys: [String: PlistValue?] = [:]
        for key in Suppression.overrides.keys { keys[key] = .some(read(key)) }
        return DockOriginal(keys: keys)
    }

    /// The best guess there is when the journal is lost: a key still holding dock2's own value is taken to
    /// have been unset, which hands it back to the Dock's default.
    public static func recovered(reading read: (String) -> PlistValue?) -> DockOriginal {
        var keys: [String: PlistValue?] = [:]
        for (key, override) in Suppression.overrides {
            let current = read(key)
            keys[key] = .some(current == override ? nil : current)
        }
        return DockOriginal(keys: keys)
    }

    /// What puts the Dock back: each key to its old value, and a key that had none removed rather than
    /// left at a default, so the Dock goes back to deciding for itself.
    public var restoration: [PreferenceChange] {
        keys.keys.sorted().map { key in
            if case .some(.some(let value)) = keys[key] { return .set(key, value) }
            return .remove(key)
        }
    }

    /// `{keys: {<key>: {value: …}}}`, with no `value` for a key that was unset.
    public var plist: PlistValue {
        var entries: [String: PlistValue] = [:]
        for (key, value) in keys { entries[key] = .dictionary(value.map { ["value": $0] } ?? [:]) }
        return .dictionary(["keys": .dictionary(entries)])
    }

    public init?(_ plist: PlistValue) {
        guard case .dictionary(let root) = plist, case .dictionary(let entries)? = root["keys"] else { return nil }
        var keys: [String: PlistValue?] = [:]
        for (key, entry) in entries {
            guard case .dictionary(let fields) = entry else { return nil }
            keys[key] = .some(fields["value"])
        }
        self.keys = keys
    }
}

// MARK: - The others

/// A system hot key's state before dock2 switched it off.
public struct HotKeyOriginal: Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public var plist: PlistValue { .dictionary(["enabled": .bool(enabled)]) }

    public init?(_ plist: PlistValue) {
        guard case .dictionary(let fields) = plist, case .bool(let enabled)? = fields["enabled"] else { return nil }
        self.enabled = enabled
    }
}

/// A preference's value before dock2 wrote its own; nil when it was unset.
public struct DefaultOriginal: Sendable, Equatable {
    public var value: PlistValue?

    public init(value: PlistValue?) {
        self.value = value
    }

    public var plist: PlistValue { .dictionary(value.map { ["value": $0] } ?? [:]) }

    public init?(_ plist: PlistValue) {
        guard case .dictionary(let fields) = plist else { return nil }
        value = fields["value"]
    }
}
