import Foundation

/// A value a setting can hold, as the property-list object the defaults store holds it as.
public protocol SettingValue: Sendable, Equatable {
    init?(propertyList: Any)
    var propertyList: Any { get }
}

/// A setting: its name in dock2's defaults domain, and its value until one is written. Names are plain
/// identifiers, since Key-Value Observing — how a change from `defaults write` arrives — reads a dot as a path.
public struct SettingKey<Value: SettingValue>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, _ defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// Every setting dock2 has ([settings](../../.agents/product/settings.md)).
public enum Settings {
    // MARK: General
    /// The first-launch sequence has been completed.
    public static let onboarded = SettingKey("onboarded", false)
    /// ⌘space is offered at the first launch, never assumed.
    public static let summon = SettingKey("summonShortcut", Shortcut.none)

    // MARK: Files
    /// What the user chose to let dock2 see ([access](../../.agents/product/files/access.md)).
    public static let fileAccess = SettingKey("fileAccess", FileAccessChoice.notAsked)
    /// "Show in Finder" from any app opens Files: the `fileViewer` takeover.
    public static let showInFinderTakeover = SettingKey("showInFinderOpensFiles", true)
    public static let foldersFirst = SettingKey("foldersFirst", true)
    /// ⇧⌘. turns it over, in Files and its search.
    public static let showHiddenFiles = SettingKey("showHiddenFiles", false)
    public static let previewColumn = SettingKey("previewColumn", true)

    // MARK: Clipboard
    /// Search's built-in sources the user switched off, by their sections' titles; a plugin's results are
    /// switched in Plugins.
    public static let searchSourcesOff = SettingKey("searchSourcesOff", [String]())
    /// Folders whose files search leaves out, by path.
    public static let searchExcluded = SettingKey("searchExcludedFolders", [String]())
    /// Folders whose files rank with the home folders', first ([file search](product/search/files.md#ranking)).
    public static let searchFirst = SettingKey("searchFirstFolders", [String]())
    /// The plugins' sections in search, by id; one not named follows, in the order it was installed.
    public static let pluginOrder = SettingKey("pluginResultsOrder", [String]())
    public static let clipboardHistory = SettingKey("clipboardHistory", false)
    public static let clipboardRetentionDays = SettingKey("clipboardRetentionDays", 30)
    /// Apps whose copies are never kept: password managers, and whatever the user adds.
    public static let clipboardIgnored = SettingKey("clipboardIgnoredApps", ClipboardPolicy.ignoredByDefault)
    /// Opens Clipboard History from anywhere.
    public static let clipboardShortcut = SettingKey("clipboardShortcut", Shortcut.none)
    /// ↩ pastes; off, it copies.
    public static let clipboardPastes = SettingKey("clipboardPastes", true)
    /// The system's request for Accessibility has been made, at the first paste.
    public static let askedToPaste = SettingKey("askedToPaste", false)

    // MARK: Dock
    public static let pinned = SettingKey("pinnedApps", [AppRef]())
    public static let tileSize = SettingKey("tileSize", 48.0)
    public static let autohide = SettingKey("autohide", false)
    /// Seconds at the screen's edge before the dock slides in.
    public static let revealDelay = SettingKey("revealDelay", DockMotion.revealDelay)
    /// Seconds after the pointer leaves before the dock slides out.
    public static let hideDelay = SettingKey("hideDelay", DockMotion.hideDelay)
    /// A multiplier on the slide's duration: the system Dock's `autohide-time-modifier`.
    public static let slideTimeModifier = SettingKey("slideTimeModifier", 1.0)
    public static let typeToSearch = SettingKey("typeToSearch", true)
    public static let numberBadges = SettingKey("numberBadges", true)
    public static let bounce = SettingKey("bounceOnLaunch", true)
    public static let showRunning = SettingKey("showRunningApps", true)
    /// Kept for when dock2 supports them; copied from the system Dock at the first launch.
    public static let magnification = SettingKey("magnification", false)
    public static let largeSize = SettingKey("largeSize", 64.0)
    public static let position = SettingKey("position", "bottom")
}

// MARK: - Values

extension Bool: SettingValue {
    public init?(propertyList: Any) {
        guard let number = propertyList as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        self = number.boolValue
    }

    public var propertyList: Any { self as NSNumber }
}

extension Int: SettingValue {
    public init?(propertyList: Any) {
        guard let number = propertyList as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        self = number.intValue
    }

    public var propertyList: Any { self as NSNumber }
}

extension Double: SettingValue {
    public init?(propertyList: Any) {
        guard let number = propertyList as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        self = number.doubleValue
    }

    public var propertyList: Any { self as NSNumber }
}

extension String: SettingValue {
    public init?(propertyList: Any) {
        guard let string = propertyList as? String else { return nil }
        self = string
    }

    public var propertyList: Any { self }
}

extension Array: SettingValue where Element: SettingValue {
    public init?(propertyList: Any) {
        guard let array = propertyList as? [Any] else { return nil }
        let values = array.compactMap(Element.init(propertyList:))
        guard values.count == array.count else { return nil }
        self = values
    }

    public var propertyList: Any { map(\.propertyList) }
}

/// A setting stored as the property list its `Codable` form encodes to, so `defaults read` shows it.
public protocol CodableSetting: SettingValue, Codable {}

extension CodableSetting {
    public init?(propertyList: Any) {
        // A top-level scalar is not a property-list document; wrapping keeps every value encodable.
        guard let data = try? PropertyListSerialization.data(fromPropertyList: ["value": propertyList], format: .binary, options: 0),
              let wrapped = try? PropertyListDecoder().decode([String: Self].self, from: data),
              let value = wrapped["value"] else { return nil }
        self = value
    }

    public var propertyList: Any {
        guard let data = try? PropertyListEncoder().encode(["value": self]),
              let wrapped = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = wrapped["value"] else {
            preconditionFailure("\(Self.self) does not encode as a property list")
        }
        return value
    }
}

/// The file access the user chose; whether macOS granted it is macOS's to say.
public enum FileAccessChoice: String, Sendable, Codable, CodableSetting {
    case notAsked, fullDisk, folders, declined
}

/// A global shortcut: Spotlight's ⌘space taken over, a chord of the user's, or none.
public enum Shortcut: Sendable, Hashable, Codable, CodableSetting {
    case commandSpace
    case chord(KeyChord)
    case none
}

/// A key and its modifiers, as Carbon's hot keys name them: a virtual key code and Carbon modifier bits.
public struct KeyChord: Sendable, Hashable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Carbon's modifier bits.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 13

    /// The space bar's virtual key code.
    public static let space: UInt32 = 49
}
