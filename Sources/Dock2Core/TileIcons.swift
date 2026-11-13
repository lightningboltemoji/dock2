import Dock2TOML
import Foundation

/// Which tile an icon of the user's is for: the Files tile, or an app wherever dock2 shows it as one.
public enum TileIconKey: Hashable, Sendable {
    case files
    case app(AppRef)

    /// As `[icons]` keys it: `files`, else an app as `pinned` lists one — which no app's key can be.
    public init?(key: String) {
        if key == "files" {
            self = .files
        } else if let app = AppRef(written: key) {
            self = .app(app)
        } else {
            return nil
        }
    }

    public var key: String {
        switch self {
        case .files: "files"
        case .app(let app): app.written
        }
    }
}

/// What a tile wears in place of its own icon ([icons](../../.agents/product/icons.md)).
public enum TileIcon: Hashable, Sendable {
    /// An Icon Composer icon, compiled: a catalog's path as `[icons]` writes it, and which of its icons — nil
    /// for its only one.
    case file(path: String, name: String?)
    case picture(PictureIcon)
    /// Another app's own icon: Finder's, for the Files tile.
    case app(AppRef)
}

/// `[icons]`: the icons the user gave tiles, each by the tile it is for
/// ([icons](../../.agents/product/icons.md#the-file)).
public struct TileIcons: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let key: TileIconKey
        public let icon: TileIcon
        /// Where the file says it: what a diagnostic about the file it names points at.
        public let line: Int

        public init(key: TileIconKey, icon: TileIcon, line: Int) {
            self.key = key
            self.icon = icon
            self.line = line
        }
    }

    /// In the file's order.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public static let none = TileIcons(entries: [])

    public subscript(key: TileIconKey) -> TileIcon? {
        entries.first { $0.key == key }?.icon
    }

    /// The `[icons]` key, spelled as a diagnostic names it.
    public static func spell(_ key: TileIconKey) -> String {
        TOMLDocument.spell(Settings.iconsTable + [key.key])
    }

    // MARK: Reading

    /// What `table` — `[icons]` — says. An entry whose shape it can't read is left out, its tile wearing its
    /// own icon, and is a diagnostic on its line; whether a file it names is there, and an icon, is System's.
    public static func read(_ table: TOMLTable?) -> (TileIcons, [SettingsDiagnostic]) {
        guard var table else { return (.none, []) }
        var entries: [Entry] = []
        var problems: [SettingsDiagnostic] = []
        let names = (table.names(under: []).map { ($0, table.value(at: [$0])?.line ?? 0) }
            + table.tableNames(under: []).map { ($0, table.table(at: [$0])?.line ?? 0) }).sorted { $0.1 < $1.1 }
        for (name, line) in names {
            var refusals: [String] = []
            let icon: TileIcon?
            if let value = table.take([name]) {
                icon = file(value, refusals: &refusals)
            } else if var entry = table.takeTable([name]) {
                icon = entry.value(at: ["picture"]) != nil ? picture(&entry, refusals: &refusals)
                    : entry.value(at: ["app"]) != nil ? app(&entry, refusals: &refusals) : file(&entry, refusals: &refusals)
                refusals += entry.leftovers.map { "has '\($0.key)', which an icon doesn't: it is \(shapes)" }
            } else {
                continue
            }
            let key = TileIconKey(key: name)
            if key == nil { refusals.append("names no app") }
            if let key, let first = entries.first(where: { $0.key == key }) {
                refusals.append("is the same app as line \(first.line)")
            }
            problems += refusals.map { SettingsDiagnostic(line: line, message: "'\(TOMLDocument.spell(Settings.iconsTable + [name]))' \($0)") }
            if let key, let icon, refusals.isEmpty { entries.append(Entry(key: key, icon: icon, line: line)) }
        }
        problems += table.leftovers.map { leftover in
            SettingsDiagnostic(line: leftover.line, message: "'\(TOMLDocument.spell(Settings.iconsTable)).\(leftover.key)' must be a file in quotes or a table")
        }
        return (TileIcons(entries: entries), problems)
    }

    /// `"icons/safari.car"`: a catalog of one icon.
    private static func file(_ value: TOMLValue, refusals: inout [String]) -> TileIcon? {
        guard let path = value.asString else {
            refusals.append("must be a file in quotes, or a table — \(shapes) — not \(value.kindName)")
            return nil
        }
        guard !path.isEmpty else {
            refusals.append("names no file")
            return nil
        }
        return .file(path: path, name: nil)
    }

    /// `{ file = "icons/pack.car", name = "ghostty" }`: one icon of a pack.
    private static func file(_ entry: inout TOMLTable, refusals: inout [String]) -> TileIcon? {
        let named = entry.take(["name"])
        guard let written = entry.take(["file"]) else {
            refusals.append("must give a file, a picture or an app")
            return nil
        }
        let path = written.asString
        if path == nil { refusals.append("has a file that must be in quotes, not \(written.kindName)") }
        if path == "" { refusals.append("names no file") }
        var name: String?
        if let written = named {
            name = written.asString
            if name == nil { refusals.append("has a name that must be in quotes, not \(written.kindName)") }
            if name == "" { refusals.append("has an empty name") }
        }
        guard let path, !path.isEmpty, refusals.isEmpty else { return nil }
        return .file(path: path, name: name)
    }

    /// The tables an entry can be.
    private static let shapes = "{ file, name }, { picture, color, filled } or { app }"

    /// `{ app = "com.apple.finder" }`: another app's own icon.
    private static func app(_ entry: inout TOMLTable, refusals: inout [String]) -> TileIcon? {
        guard let written = entry.take(["app"]) else { return nil }
        guard let app = written.asString.flatMap(AppRef.init(written:)) else {
            refusals.append("has an app that must be a bundle identifier or a path in quotes, not \(written.asString == "" ? "an empty one" : written.kindName)")
            return nil
        }
        return .app(app)
    }

    /// `{ picture = "pear", color = "#34C759", filled = false }`: violet and filled unless it says.
    private static func picture(_ entry: inout TOMLTable, refusals: inout [String]) -> TileIcon? {
        var icon = PictureIcon(picture: .blossom)
        if let written = entry.take(["picture"]) {
            if let match = CairoPicture.allCases.first(where: { written.asString == SettingCodec<CairoPicture>.kebab($0.rawValue) }) {
                icon.picture = match
            } else {
                refusals.append("has a picture that must be one of Cairo's pictures, not \(written.asString.map { "\"\($0)\"" } ?? written.kindName)")
            }
        }
        if let written = entry.take(["color"]) {
            do {
                icon.color = try SettingCodec<IconColor>.color.read(written)
            } catch {
                refusals.append("has a color that \((error as? SettingProblem)?.message ?? "\(error)")")
            }
        }
        if let written = entry.take(["filled"]) {
            if let filled = written.asBool { icon.filled = filled } else { refusals.append("has filled, which must be true or false, not \(written.kindName)") }
        }
        return refusals.isEmpty ? .picture(icon) : nil
    }

    // MARK: Writing

    /// The edit that gives `key` `icon`, or with nil gives it its own icon back by taking its line out.
    public static func edit(_ key: TileIconKey, _ icon: TileIcon?) -> SettingsEdit {
        SettingsEdit(Settings.iconsTable + [key.key], icon.map(value))
    }

    /// An icon as `[icons]` writes it: a string for a catalog of one, a table otherwise, saying only what is not
    /// a picture's default.
    static func value(_ icon: TileIcon) -> TOMLValue {
        switch icon {
        case .file(let path, nil):
            return .string(path)
        case .file(let path, let name?):
            return .table([("file", .string(path)), ("name", .string(name))])
        case .picture(let icon):
            var pairs: [(key: String, value: TOMLValue)] = [("picture", .string(SettingCodec<CairoPicture>.kebab(icon.picture.rawValue)))]
            let color = SettingCodec<IconColor>.color.write(icon.color)
            if color.spelled != SettingCodec<IconColor>.color.write(.violet).spelled { pairs.append(("color", color)) }
            if !icon.filled { pairs.append(("filled", .bool(false))) }
            return .table(pairs)
        case .app(let app):
            return .table([("app", .string(app.written))])
        }
    }

    // MARK: Paths

    /// A catalog's path as written, on disk: relative to `folder` — the settings file's — unless it starts at
    /// home or the root.
    public static func resolve(_ path: String, against folder: String) -> String {
        if path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") { return HomePath.expand(path) }
        return ((folder as NSString).appendingPathComponent(path) as NSString).standardizingPath
    }
}
