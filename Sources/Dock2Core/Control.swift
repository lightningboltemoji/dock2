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
    /// Typed into whatever has the keys, through the window as a key press is.
    case type(String)
    case key(ControlKey)
    /// Holds the dock up, or lets it go.
    case reveal(Bool)

    static func parse(_ words: [String]) throws -> DebugCommand {
        switch (words.first, words.count) {
        case ("state", 1): return .state
        case ("type", 2...): return .type(words.dropFirst().joined(separator: " "))
        case ("key", 2):
            guard let key = ControlKey(rawValue: words[1]) else {
                throw ControlError("no key \(words[1]); one of \(ControlKey.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return .key(key)
        case ("reveal", 2) where ["on", "off"].contains(words[1]): return .reveal(words[1] == "on")
        default: throw ControlError("debug \(words.joined(separator: " ")) is not a command")
        }
    }
}

/// A key with no character of its own to type.
public enum ControlKey: String, Sendable, CaseIterable, Codable {
    case escape, `return`, tab, delete, up, down, left, right, home, end
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
        public init(shown: Bool, platter: Rect?) { (self.shown, self.platter) = (shown, platter) }
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
        public init(title: String, subtitle: String?, selected: Bool) {
            (self.title, self.subtitle, self.selected) = (title, subtitle, selected)
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
