import Dock2TOML
import Foundation

/// A setting: where it is kept, and its value until one is written. Most live in the config file, which a
/// person may keep in a dotfiles repo and share between Macs; a few describe this Mac and stay on it.
public struct SettingKey<Value: Equatable & Sendable>: Sendable {
    /// Its identity: the dotted key it is written under, or its name in this Mac's state.
    public let name: String
    public let defaultValue: Value
    let storage: Storage

    enum Storage: Sendable {
        /// One or more keys of the config file, each carrying part of the value.
        case file([SettingPart<Value>])
        /// This Mac's state (`state.json`), by name.
        case machine(encode: @Sendable (Value) -> String, decode: @Sendable (String) -> Value?)
    }

    /// One key of the config file holding the whole value.
    init(_ path: [String], _ defaultValue: Value, _ codec: SettingCodec<Value>, help: String) {
        self.init(defaultValue, parts: [SettingPart(path, codec, help: help, get: { $0 }, set: { $0 = $1 })])
    }

    /// Several keys of the config file, each holding part of the value.
    init(_ defaultValue: Value, parts: [SettingPart<Value>]) {
        self.name = TOMLDocument.spell(parts[0].path)
        self.defaultValue = defaultValue
        self.storage = .file(parts)
    }

    /// Kept on this Mac, never in the shared file.
    init(machine name: String, _ defaultValue: Value) where Value: LosslessStringConvertible {
        self.name = name
        self.defaultValue = defaultValue
        self.storage = .machine(encode: { $0.description }, decode: { Value($0) })
    }

    init(machine name: String, _ defaultValue: Value) where Value: RawRepresentable, Value.RawValue == String {
        self.name = name
        self.defaultValue = defaultValue
        self.storage = .machine(encode: { $0.rawValue }, decode: { Value(rawValue: $0) })
    }

    /// Whether it is kept on this Mac rather than in the shared file.
    public var isMachine: Bool {
        if case .machine = storage { return true }
        return false
    }

    /// The keys of the config file it is written under.
    public var paths: [[String]] {
        guard case .file(let parts) = storage else { return [] }
        return parts.map(\.path)
    }
}

/// One key of the config file, and the part of a setting's value it carries.
struct SettingPart<Value: Sendable>: Sendable {
    let path: [String]
    let help: String
    let legend: String?
    let read: @Sendable (TOMLValue, inout Value) throws -> Void
    let write: @Sendable (Value) -> TOMLValue

    init<Field>(_ path: [String], _ codec: SettingCodec<Field>, help: String,
                get: @escaping @Sendable (Value) -> Field, set: @escaping @Sendable (inout Value, Field) -> Void) {
        self.path = path
        self.help = help
        self.legend = codec.legend
        self.read = { value, whole in set(&whole, try codec.read(value)) }
        self.write = { codec.write(get($0)) }
    }
}

/// Every setting dock2 has ([settings](../../.agents/product/settings.md)). The config file's tables follow
/// the Settings window's sections; `Settings.all` lists them in order.
public enum Settings {
    // MARK: General
    /// The first-launch sequence has been completed — on any Mac that reads this file.
    public static let onboarded = SettingKey(["general", "onboarded"], false, .toggle,
                                             help: "The first launch is done; a Mac reading this file skips it.")
    /// Applied at every launch: dock2 is a login item exactly while this is on.
    public static let openAtLogin = SettingKey(["general", "open-at-login"], false, .toggle,
                                               help: "Dock2 opens when you log in. Applied at every launch, both ways.")
    /// ⌘space is offered at the first launch, never assumed.
    public static let summon = SettingKey(["general", "summon"], Shortcut.none, .shortcut(takesSpotlight: true),
                                          help: "Summons Dock2 from anywhere.")

    // MARK: Dock
    public static let dockStyle = SettingKey(["dock", "style"], DockStyle.glass, .word,
                                             help: "Liquid Glass, or the shelf of Mac OS X 10.6.")
    public static let tileSize = SettingKey(["dock", "tile-size"], 48.0, .number(DockMetrics.tileSizes, unit: "points"),
                                            help: "How large the tiles are.")
    public static let autohide = SettingKey(["dock", "autohide"], false, .toggle,
                                            help: "The dock hides until the pointer reaches the screen's edge.")
    /// Seconds at the screen's edge before the dock slides in.
    public static let revealDelay = SettingKey(["dock", "reveal-delay"], DockMotion.revealDelay, .number(atLeast: 0, unit: "seconds"),
                                               help: "How long the pointer rests at the edge before the dock slides in.")
    /// Seconds after the pointer leaves before the dock slides out.
    public static let hideDelay = SettingKey(["dock", "hide-delay"], DockMotion.hideDelay, .number(atLeast: 0, unit: "seconds"),
                                             help: "How long after the pointer leaves the dock slides out.")
    /// A multiplier on the slide's duration: the system Dock's `autohide-time-modifier`.
    public static let slideTimeModifier = SettingKey(["dock", "slide-time-modifier"], 1.0, .number(atLeast: 0, unit: nil),
                                                     help: "A multiplier on the slide's duration; 0 is no slide.")
    public static let typeToSearch = SettingKey(["dock", "type-to-search"], true, .toggle,
                                                help: "Typing while the dock is revealed searches.")
    public static let numberBadges = SettingKey(["dock", "number-badges"], true, .toggle,
                                                help: "Holding ⌘ numbers the first nine tiles.")
    public static let bounce = SettingKey(["dock", "bounce-on-launch"], true, .toggle,
                                          help: "An app's tile bounces while it opens.")
    public static let showRunning = SettingKey(["dock", "show-running-apps"], true, .toggle,
                                               help: "Running apps that are not pinned have tiles too.")
    /// A minimised window goes into its app's tile rather than a tile of its own: the system Dock's
    /// `minimize-to-application`, which dock2 holds off in the hidden Dock while it runs.
    public static let minimizeToApp = SettingKey(["dock", "minimize-into-app-icon"], false, .toggle,
                                                 help: "A minimised window goes into its app's tile rather than a tile of its own.")
    public static let pinned = SettingKey(["dock", "pinned"], [AppRef](), .apps,
                                          help: "The apps kept in the dock, left to right. An app not installed on this Mac is skipped.")

    // MARK: Search
    /// What the search field is while nothing is typed ([panel](../../.agents/product/panel.md#the-fields-form)).
    public static let fieldForm = SettingKey(["search", "field-form"], FieldForm.drop, .word,
                                             help: "What the search field is while nothing is typed.")
    /// Search's built-in sources the user switched off, by their sections' titles; a plugin's results are
    /// switched in Plugins.
    public static let searchSourcesOff = SettingKey(["search", "sources-off"], [String](), .strings,
                                                    help: "Search's own sections switched off, by title.")
    /// Folders whose files rank with the home folders', first ([file search](product/search/files.md#ranking)).
    public static let searchFirst = SettingKey(["search", "first-folders"], [String](), .paths,
                                               help: "Folders whose files rank first, with the home folders'.")
    /// Folders whose files search leaves out, by path.
    public static let searchExcluded = SettingKey(["search", "excluded-folders"], [String](), .paths,
                                                  help: "Folders whose files search leaves out.")
    /// The plugins' sections in search, by id; one not named follows, in the order it was installed.
    public static let pluginOrder = SettingKey(["search", "plugin-order"], [String](), .strings,
                                               help: "The plugins' sections in search, by plugin id; one not named follows, in the order it was installed.")

    // MARK: Clipboard
    public static let clipboardHistory = SettingKey(["clipboard", "history"], false, .toggle,
                                                    help: "Dock2 keeps what you copy.")
    public static let clipboardRetentionDays = SettingKey(["clipboard", "retention-days"], 30, .integer(atLeast: 1, unit: "days"),
                                                          help: "How long a copy is kept.")
    /// Apps whose copies are never kept: password managers, and whatever the user adds.
    public static let clipboardIgnored = SettingKey(["clipboard", "ignored-apps"], ClipboardPolicy.ignoredByDefault, .strings,
                                                    help: "Apps whose copies are never kept, by bundle identifier.")
    /// Opens Clipboard History from anywhere.
    public static let clipboardShortcut = SettingKey(["clipboard", "shortcut"], Shortcut.none, .shortcut(takesSpotlight: false),
                                                     help: "Opens Clipboard History from anywhere.")
    /// ↩ pastes; off, it copies.
    public static let clipboardPastes = SettingKey(["clipboard", "paste-on-return"], true, .toggle,
                                                   help: "↩ on an entry pastes it; off, it copies it.")
    /// The system's request for Accessibility has been made, at the first paste.
    public static let askedToPaste = SettingKey(machine: "askedToPaste", false)

    // MARK: Plugins
    /// `plugins.json`, where plugin choices were kept before the config file, has been carried into it here.
    public static let pluginChoicesImported = SettingKey(machine: "pluginChoicesImported", false)

    // MARK: Files
    /// What the user chose to let dock2 see ([access](../../.agents/product/files/access.md)); macOS's grant
    /// is per Mac, so the choice is too.
    public static let fileAccess = SettingKey(machine: "fileAccess", FileAccessChoice.notAsked)
    /// "Show in Finder" from any app opens Files: the `fileViewer` takeover.
    public static let showInFinderTakeover = SettingKey(["files", "show-in-finder-opens-files"], true, .toggle,
                                                        help: "\"Show in Finder\", from any app, opens Files instead.")
    public static let foldersFirst = SettingKey(["files", "folders-first"], true, .toggle,
                                                help: "Folders sort before files.")
    /// ⇧⌘. turns it over, in Files and its search.
    public static let showHiddenFiles = SettingKey(["files", "show-hidden"], false, .toggle,
                                                   help: "Hidden files show in Files and its search; ⇧⌘. turns it over.")
    public static let previewColumn = SettingKey(["files", "preview-column"], true, .toggle,
                                                 help: "Files previews the selection in a column of its own.")
    /// The Finder tile's icon: Finder's own, or one of Cairo's pictures on a colour.
    public static let finderIcon = SettingKey(FinderIcon(), parts: [
        SettingPart(["files", "icon"], .picture, help: "The icon Files wears in the dock.",
                    get: { $0.picture }, set: { $0.picture = $1 }),
        SettingPart(["files", "icon-color"], .color, help: "The colour behind the icon's picture.",
                    get: { $0.color }, set: { $0.color = $1 }),
        SettingPart(["files", "icon-filled"], .toggle, help: "The picture's ink black and its paper white, rather than its ink white.",
                    get: { $0.filled }, set: { $0.filled = $1 }),
    ])
}

// MARK: - Values

/// The file access the user chose; whether macOS granted it is macOS's to say.
public enum FileAccessChoice: String, Sendable, Codable {
    case notAsked, fullDisk, folders, declined
}

/// A global shortcut: Spotlight's ⌘space taken over, a chord of the user's, or none.
public enum Shortcut: Sendable, Hashable, Codable {
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

    /// A stored chord may mark ⌃ with bit 13, Carbon's right shift, which macOS never reports; it reads as ⌃.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        let stored = try container.decode(UInt32.self, forKey: .modifiers)
        modifiers = stored & Self.storedControl == 0 ? stored : stored & ~Self.storedControl | Self.control
    }

    /// Carbon's modifier bits.
    public static let command: UInt32 = 1 << 8
    public static let shift: UInt32 = 1 << 9
    public static let option: UInt32 = 1 << 11
    public static let control: UInt32 = 1 << 12
    private static let storedControl: UInt32 = 1 << 13

    /// The space bar's virtual key code.
    public static let space: UInt32 = 49
}
