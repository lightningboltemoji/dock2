import Foundation

/// What another process can ask a running dock2, over its control socket ([control](../../.agents/product/control.md)).
/// Anyone's verbs do what dock2's own shortcut and tiles do; a `debug` one is answered only by a dock2 started
/// with `DOCK2_DEBUG=1`, since it types, presses keys and reads what is shown.
public enum ControlCommand: Sendable, Equatable, Codable {
    /// Takes the keyboard, the field risen over the dock; with `query`, typed into it.
    case summon(query: String?)
    case dismiss
    /// Files, at `folder` if given.
    case files(folder: String?)
    case clipboard
    /// Whether dock2 has the keyboard, and its version.
    case status
    case debug(DebugCommand)

    /// `dock2 <words>`: the verbs a terminal or a script types.
    public static func parse(_ words: [String]) throws -> ControlCommand {
        guard let verb = words.first else { throw ControlError("no verb") }
        let rest = Array(words.dropFirst())
        switch verb {
        case "summon": return .summon(query: rest.isEmpty ? nil : rest.joined(separator: " "))
        case "dismiss" where rest.isEmpty: return .dismiss
        case "files" where rest.count <= 1: return .files(folder: rest.first)
        case "clipboard" where rest.isEmpty: return .clipboard
        case "status" where rest.isEmpty: return .status
        case "debug": return .debug(try DebugCommand.parse(rest))
        default: throw ControlError("\(verb) \(rest.joined(separator: " ")) is not a command")
        }
    }

    public var isDebug: Bool {
        if case .debug = self { true } else { false }
    }
}

public enum DebugCommand: Sendable, Equatable, Codable {
    /// Where everything is and what it shows (`DebugState`).
    case state
    /// Typed into whatever has the keys, through dock2's own event queue as a key press comes.
    case type(String)
    /// A key, or a chord: what a menu, a key equivalent or the field makes of it.
    case press(ControlPress)
    /// Modifiers held down, alone — ⌘ for the number badges — or, empty, let go.
    case hold([ControlModifier])
    /// Holds the dock up, or lets it go.
    case reveal(Bool)

    static func parse(_ words: [String]) throws -> DebugCommand {
        switch (words.first, words.count) {
        case ("state", 1): return .state
        case ("type", 2...): return .type(words.dropFirst().joined(separator: " "))
        case ("key", 2): return .press(try ControlPress(words[1]))
        case ("hold", 2): return .hold(words[1] == "none" ? [] : try ControlModifier.list(words[1]))
        case ("reveal", 2) where ["on", "off"].contains(words[1]): return .reveal(words[1] == "on")
        default: throw ControlError("debug \(words.joined(separator: " ")) is not a command")
        }
    }
}

/// A key with no character of its own to type.
public enum ControlKey: String, Sendable, CaseIterable, Codable {
    case escape, `return`, tab, delete, space, up, down, left, right, home, end, pageup, pagedown
}

public enum ControlModifier: String, Sendable, CaseIterable, Codable, Comparable {
    case control, option, shift, cmd

    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

    /// `cmd+shift`, as words joined by `+`.
    static func list(_ words: String) throws -> [ControlModifier] {
        try words.split(separator: "+").map { word in
            guard let modifier = ControlModifier(word: String(word)) else { throw ControlError("no modifier \(word)") }
            return modifier
        }.sorted()
    }

    init?(word: String) {
        switch word.lowercased() {
        case "cmd", "command", "⌘": self = .cmd
        case "shift", "⇧": self = .shift
        case "option", "opt", "alt", "⌥": self = .option
        case "control", "ctrl", "⌃": self = .control
        default: return nil
        }
    }
}

/// A key and the modifiers held with it: `escape`, `cmd+k`, `shift+cmd+.`, `cmd+1`.
public struct ControlPress: Sendable, Equatable, Codable {
    public enum Key: Sendable, Equatable, Codable {
        case named(ControlKey)
        /// One character, as the key that types it unshifted.
        case character(String)
    }

    public var key: Key
    public var modifiers: [ControlModifier]

    public init(key: Key, modifiers: [ControlModifier] = []) {
        self.key = key
        self.modifiers = modifiers.sorted()
    }

    public init(_ spec: String) throws {
        // The key is last; a `+` key is the one after the last separator.
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if spec.hasSuffix("++") || spec == "+" { parts = Array(parts.dropLast(2)) + ["+"] }
        guard let last = parts.last, !last.isEmpty else { throw ControlError("no key in \(spec)") }
        let modifiers = try parts.dropLast().map { word in
            guard let modifier = ControlModifier(word: word) else { throw ControlError("no modifier \(word) in \(spec)") }
            return modifier
        }
        if let named = ControlKey(rawValue: last.lowercased()) {
            self.init(key: .named(named), modifiers: modifiers)
        } else if last.count == 1 {
            self.init(key: .character(last.lowercased()), modifiers: modifiers)
        } else {
            throw ControlError("no key \(last); a character, or one of \(ControlKey.allCases.map(\.rawValue).joined(separator: ", "))")
        }
    }
}

/// Where a pointer command goes, by what is there rather than by coordinates: a tile, a row, the field, the
/// screen's bottom edge under the dock (where auto-hide reveals it), out of the way, or a point.
public enum PointerTarget: Sendable, Equatable {
    /// By name, as its label says it, or by place along the dock from 1.
    case tile(String)
    /// From the field up, from 1: the top hit is 1.
    case row(Int)
    case field
    case platter
    case edge
    case away
    case point(Double, Double)

    public init(_ word: String) throws {
        let parts = word.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("tile", 2): self = .tile(parts[1])
        case ("row", 2):
            guard let index = Int(parts[1]), index > 0 else { throw ControlError("row takes a number from 1") }
            self = .row(index)
        case ("field", 1): self = .field
        case ("platter", 1): self = .platter
        case ("edge", 1): self = .edge
        case ("away", 1): self = .away
        default:
            let xy = word.split(separator: ",").compactMap { Double($0) }
            guard xy.count == 2 else {
                throw ControlError("no target \(word); tile:<name|n>, row:<n>, field, platter, edge, away, or x,y")
            }
            self = .point(xy[0], xy[1])
        }
    }

    /// The point to aim at in `state`, or nil when it is not showing.
    public func point(in state: DebugState) -> (x: Double, y: Double)? {
        let centre = { (rect: DebugState.Rect) in (x: rect.x + rect.width / 2, y: rect.y + rect.height / 2) }
        switch self {
        case .tile(let name):
            let tiles = state.dock.tiles
            let tile = Int(name).flatMap { tiles.indices.contains($0 - 1) ? tiles[$0 - 1] : nil }
                ?? tiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
            return state.dock.shown ? tile.map { centre($0.frame) } : nil
        case .row(let index):
            guard state.panel.rows.indices.contains(index - 1), let frame = state.panel.rows[index - 1].frame else { return nil }
            return centre(frame)
        case .field: return state.panel.field.map(centre)
        case .platter: return state.dock.shown ? state.dock.platter.map(centre) : nil
        case .edge:
            // The last row of points: auto-hide's edge is the screen's bottom pixel.
            let x = state.dock.platter.map { $0.x + $0.width / 2 } ?? state.display.x + state.display.width / 2
            return (x, state.display.y + state.display.height)
        case .away: return (state.display.x + state.display.width / 2, state.display.y + state.display.height * 0.3)
        case .point(let x, let y): return (x, y)
        }
    }
}

/// A command that is not one, or a message that is not dock2's.
public struct ControlError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum ControlReply: Sendable, Equatable, Codable {
    /// Done, or for one that moves something, begun.
    case ok
    /// A read's answer, a JSON document.
    case json(String)
    case failed(String)
}

/// The socket's framing: one request and one reply, each a line of JSON carrying the version first, so a
/// peer from another build is told so rather than failing to decode.
public enum ControlWire {
    public static let version = 1
    public static let socketEnvironmentKey = "DOCK2_SOCKET"
    /// `sockaddr_un.sun_path` holds 104 bytes with the NUL.
    public static let maxPathBytes = 103
    public static let maxLineBytes = 1 << 20

    /// The override, else the per-user temporary folder, else `/tmp` under the user's name.
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  user: String = NSUserName()) -> String {
        if let path = environment[socketEnvironmentKey], !path.isEmpty { return path }
        if let folder = environment["TMPDIR"], !folder.isEmpty {
            let path = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("dock2.sock").path
            if path.utf8.count <= maxPathBytes { return path }
        }
        return "/tmp/dock2-\(user).sock"
    }

    public struct Request: Codable, Equatable, Sendable {
        public var version = ControlWire.version
        public var command: ControlCommand
        public init(_ command: ControlCommand) { self.command = command }
    }

    public struct Reply: Codable, Equatable, Sendable {
        public var version = ControlWire.version
        public var reply: ControlReply
        public init(_ reply: ControlReply) { self.reply = reply }
    }

    private struct Probe: Decodable { let version: Int }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    /// The message, or why not: another build's version is named rather than misread.
    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        guard let probe = try? JSONDecoder().decode(Probe.self, from: line) else {
            throw ControlError("not a dock2 control message")
        }
        guard probe.version == version else {
            throw ControlError("dock2 speaks control version \(probe.version) and this one \(version): run the same build")
        }
        return try JSONDecoder().decode(type, from: line)
    }
}

/// What `dock2 debug state` prints. Frames are in screen points from the top left of the main display, as
/// `screencapture -R` and a posted event take them.
public struct DebugState: Codable, Equatable, Sendable {
    public struct Rect: Codable, Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            (self.x, self.y, self.width, self.height) = (x, y, width, height)
        }
    }

    public struct Dock: Codable, Equatable, Sendable {
        public var shown: Bool
        public var platter: Rect?
        /// Left to right, separators left out.
        public var tiles: [Tile]
        public init(shown: Bool, platter: Rect?, tiles: [Tile] = []) { (self.shown, self.platter, self.tiles) = (shown, platter, tiles) }
    }

    public struct Tile: Codable, Equatable, Sendable {
        /// As its label says it.
        public var name: String
        /// finder, app, temporary, plugin or window.
        public var kind: String
        public var running: Bool
        public var ringed: Bool
        /// The app's badge as the system Dock spells it; absent for none.
        public var badge: String?
        public var frame: Rect
        public init(name: String, kind: String, running: Bool, ringed: Bool, badge: String? = nil, frame: Rect) {
            (self.name, self.kind, self.running, self.ringed, self.badge, self.frame) = (name, kind, running, ringed, badge, frame)
        }
    }

    public struct Panel: Codable, Equatable, Sendable {
        public var shown: Bool
        /// The form showing (`FieldForm`), and whether it rests.
        public var form: String
        public var resting: Bool
        public var field: Rect?
        /// The glass as the panel wants it: the field, and what grew from it.
        public var body: Rect?
        /// The most the panel can grow to at its width: where to record a pour that grows.
        public var reach: Rect?
        /// The view or Files over the search, by title.
        public var screen: String?
        public var text: String
        public var rows: [Row]
        public init(shown: Bool, form: String, resting: Bool, field: Rect?, body: Rect?, reach: Rect?, screen: String?,
                    text: String, rows: [Row]) {
            (self.shown, self.form, self.resting, self.field, self.body, self.reach) = (shown, form, resting, field, body, reach)
            (self.screen, self.text, self.rows) = (screen, text, rows)
        }
    }

    public struct Row: Codable, Equatable, Sendable {
        public var title: String
        public var subtitle: String?
        public var selected: Bool
        /// Absent while scrolled out of the panel.
        public var frame: Rect?
        public init(title: String, subtitle: String?, selected: Bool, frame: Rect? = nil) {
            (self.title, self.subtitle, self.selected, self.frame) = (title, subtitle, selected, frame)
        }
    }

    public var pid: Int32
    public var version: String
    /// The interaction's phase: resting, revealed or engaged.
    public var phase: String
    public var hasKeyboard: Bool
    public var dock: Dock
    public var panel: Panel
    /// The display dock2 is on.
    public var display: Rect
    public var scale: Double

    public init(pid: Int32, version: String, phase: String, hasKeyboard: Bool, dock: Dock, panel: Panel, display: Rect,
                scale: Double) {
        (self.pid, self.version, self.phase, self.hasKeyboard) = (pid, version, phase, hasKeyboard)
        (self.dock, self.panel, self.display, self.scale) = (dock, panel, display, scale)
    }
}
