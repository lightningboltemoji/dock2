import Foundation

// What travels between dock2 and a plugin ([runtime](product/plugins/runtime.md)): JSON, every message tagged
// by `type`. The Rust SDK's types (`Plugins/sdk`) are the same shapes from the other side.

/// The interface version this dock2 speaks.
public let pluginAPIVersion = 1

/// What a plugin may reach ([permissions](product/plugins/permissions.md)).
public enum PluginCapability: String, Codable, Sendable, CaseIterable {
    case network, query, secrets, files, paste
    case clipboardWrite = "clipboard.write"
    case clipboardRead = "clipboard.read"
    case nowPlaying = "now-playing"

    /// As the install sheet and Settings say it.
    public func describe(hosts: [String]) -> String {
        switch self {
        case .network: hosts.isEmpty ? "Connects to the internet" : "Connects to \(hosts.joined(separator: ", "))"
        case .query: "Sees what you type in dock2's search"
        case .secrets: "Stores secrets in your Keychain"
        case .files: "Reads files in folders you pick"
        case .paste: "Pastes into other apps"
        case .clipboardWrite: "Copies to the clipboard"
        case .clipboardRead: "Reads your clipboard history"
        case .nowPlaying: "Sees and controls what is playing"
        }
    }
}

/// `manifest.json` ([packaging](product/plugins/packaging.md)).
public struct PluginManifest: Codable, Equatable, Sendable {
    public struct Command: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var subtitle: String?
        public var icon: Icon?
        public var keywords: [String]?
        /// It answers with a view, so dock2 stays up; otherwise running it dismisses.
        public var view: Bool?

        public init(id: String, title: String, subtitle: String? = nil, icon: Icon? = nil, keywords: [String]? = nil, view: Bool? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.keywords = keywords
            self.view = view
        }
    }

    public struct Results: Codable, Equatable, Sendable {
        /// The section's title in search.
        public var title: String
        /// The shortest query it wants.
        public var minimumQuery: Int?
        /// Whether results are on until the user says otherwise.
        public var onByDefault: Bool?
    }

    public struct Tile: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// On the dock until the user takes it off.
        public var onDock: Bool?
    }

    public struct Setting: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case text, secure, toggle, choice, number, folder }
        public var id: String
        public var title: String
        public var kind: Kind
        public var defaultValue: String?
        public var options: [FormNode.Option]?

        enum CodingKeys: String, CodingKey { case id, title, kind, defaultValue = "default", options }
    }

    public var id: String
    public var name: String
    public var description: String?
    public var author: String?
    public var icon: Icon?
    public var version: String
    public var api: Int
    public var module: String
    public var capabilities: [PluginCapability]
    /// The hosts `network` reaches; `$setting` names a setting holding one, for a self-hosted server.
    public var hosts: [String]?
    public var commands: [Command]?
    public var results: Results?
    public var tiles: [Tile]?
    public var settings: [Setting]?

    public enum Problem: LocalizedError, Equatable, Sendable {
        case badID, unsupportedAPI(Int), badVersion, noModule, duplicate(String), comesWithDock2(String)

        public var errorDescription: String? {
            switch self {
            case .badID: "Its id is not reverse-DNS, like com.example.weather."
            case .unsupportedAPI(let api): "It is written for plugin interface \(api); this dock2 speaks \(pluginAPIVersion)."
            case .badVersion: "Its version is not three numbers, like 1.0.0."
            case .noModule: "Its module is missing, or not a .wasm file beside the manifest."
            case .duplicate(let id): "It declares “\(id)” twice."
            case .comesWithDock2(let name): "Its id is \(name)'s, which comes with dock2."
            }
        }
    }

    /// What install refuses: an id that is not reverse-DNS, an interface this dock2 does not speak, a
    /// version that is not semantic, two commands or tiles with one id.
    public func validate() throws {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }) else {
            throw Problem.badID
        }
        guard api == pluginAPIVersion else { throw Problem.unsupportedAPI(api) }
        guard version.split(separator: ".").count == 3, version.split(separator: ".").allSatisfy({ Int($0) != nil }) else {
            throw Problem.badVersion
        }
        guard module.hasSuffix(".wasm"), !module.contains("/") else { throw Problem.noModule }
        for ids in [(commands ?? []).map(\.id), (tiles ?? []).map(\.id), (settings ?? []).map(\.id)] {
            if let repeated = Dictionary(grouping: ids, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                throw Problem.duplicate(repeated)
            }
        }
    }

    /// The hosts `network` may reach, `$setting`s replaced by their values.
    public func allowedHosts(settings values: [String: String]) -> [String] {
        (hosts ?? []).compactMap { host in
            guard host.hasPrefix("$") else { return host.lowercased() }
            return values[String(host.dropFirst())].flatMap { URL(string: $0)?.host ?? $0 }?.lowercased()
        }
    }
}

/// A plugin's tile on the dock: its live state, drawn at the dock's tile size.
public struct TileNode: Codable, Equatable, Sendable {
    public var image: Icon?
    public var badge: String?
    /// 0 to 1: a ring around the image.
    public var progress: Double?
    /// A few words under the image.
    public var caption: String?
    /// The hover label.
    public var label: String

    public init(image: Icon? = nil, badge: String? = nil, progress: Double? = nil, caption: String? = nil, label: String) {
        self.image = image
        self.badge = badge
        self.progress = progress
        self.caption = caption
        self.label = label
    }
}

/// A result a plugin gives for a query.
public struct PluginResult: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var icon: Icon?
    public var actions: [ActionNode]?

    public init(id: String, title: String, subtitle: String? = nil, icon: Icon? = nil, actions: [ActionNode]? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.actions = actions
    }
}

/// What's playing, as the system reports it.
public struct NowPlayingInfo: Codable, Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var playing: Bool
    public var duration: Double?
    public var elapsed: Double?
    /// When `elapsed` was true, in milliseconds since 1970: it runs on at `playing`'s rate since then.
    public var timestamp: Double?
    /// JPEG or PNG bytes.
    public var artwork: Data?
    public var app: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, playing: Bool, duration: Double? = nil,
                elapsed: Double? = nil, timestamp: Double? = nil, artwork: Data? = nil, app: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.playing = playing
        self.duration = duration
        self.elapsed = elapsed
        self.timestamp = timestamp
        self.artwork = artwork
        self.app = app
    }
}

/// dock2 to a plugin: one at a time, each answered by effects.
public enum PluginEvent: Codable, Equatable, Sendable {
    case started(settings: [String: String])
    case stopped
    case settings([String: String])
    case command(id: String)
    case query(id: Int, text: String)
    /// From a view (`view`), a result (`result`), or a tile (`tile`).
    case action(action: String, item: String?, view: String?, result: String?, tile: String?)
    case submit(view: String, values: [String: String])
    /// A list's field changed, for an owner that filters: `id` grows with each, for its answer to name.
    case filter(view: String, text: String, id: Int)
    case tile(id: String)
    case timer(id: String)
    case http(request: String, status: Int?, headers: [String: String], body: Data?, error: String?)
    case storage(request: String, key: String, value: String?)
    case secret(request: String, key: String, value: String?)
    case nowPlaying(NowPlayingInfo?)
    /// A key derived for the plugin, natively.
    case derived(request: String, key: Data)
    case viewClosed(view: String)
    /// An effect refused: not granted, or failed.
    case error(request: String?, message: String)

    private enum Key: String, CodingKey {
        case type, settings, id, text, action, item, view, result, tile, values, request, status, headers, body, error, key, value, info, message
    }

    private enum DerivedKey: String, CodingKey { case key }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .started(let settings): try c.encode("started", forKey: .type); try c.encode(settings, forKey: .settings)
        case .stopped: try c.encode("stopped", forKey: .type)
        case .settings(let settings): try c.encode("settings", forKey: .type); try c.encode(settings, forKey: .settings)
        case .command(let id): try c.encode("command", forKey: .type); try c.encode(id, forKey: .id)
        case .query(let id, let text):
            try c.encode("query", forKey: .type); try c.encode(id, forKey: .id); try c.encode(text, forKey: .text)
        case .action(let action, let item, let view, let result, let tile):
            try c.encode("action", forKey: .type); try c.encode(action, forKey: .action)
            try c.encodeIfPresent(item, forKey: .item); try c.encodeIfPresent(view, forKey: .view)
            try c.encodeIfPresent(result, forKey: .result); try c.encodeIfPresent(tile, forKey: .tile)
        case .submit(let view, let values):
            try c.encode("submit", forKey: .type); try c.encode(view, forKey: .view); try c.encode(values, forKey: .values)
        case .filter(let view, let text, let id):
            try c.encode("filter", forKey: .type); try c.encode(view, forKey: .view); try c.encode(text, forKey: .text); try c.encode(id, forKey: .id)
        case .tile(let id): try c.encode("tile", forKey: .type); try c.encode(id, forKey: .id)
        case .timer(let id): try c.encode("timer", forKey: .type); try c.encode(id, forKey: .id)
        case .http(let request, let status, let headers, let body, let error):
            try c.encode("http", forKey: .type); try c.encode(request, forKey: .request)
            try c.encodeIfPresent(status, forKey: .status); try c.encode(headers, forKey: .headers)
            try c.encodeIfPresent(body, forKey: .body); try c.encodeIfPresent(error, forKey: .error)
        case .storage(let request, let key, let value):
            try c.encode("storage", forKey: .type); try c.encode(request, forKey: .request)
            try c.encode(key, forKey: .key); try c.encodeIfPresent(value, forKey: .value)
        case .secret(let request, let key, let value):
            try c.encode("secret", forKey: .type); try c.encode(request, forKey: .request)
            try c.encode(key, forKey: .key); try c.encodeIfPresent(value, forKey: .value)
        case .nowPlaying(let info): try c.encode("nowPlaying", forKey: .type); try c.encodeIfPresent(info, forKey: .info)
        case .derived(let request, let key): try c.encode("derived", forKey: .type); try c.encode(request, forKey: .request); try c.encode(key, forKey: .key)
        case .viewClosed(let view): try c.encode("viewClosed", forKey: .type); try c.encode(view, forKey: .view)
        case .error(let request, let message):
            try c.encode("error", forKey: .type); try c.encodeIfPresent(request, forKey: .request); try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "started": self = .started(settings: try c.decode([String: String].self, forKey: .settings))
        case "stopped": self = .stopped
        case "settings": self = .settings(try c.decode([String: String].self, forKey: .settings))
        case "command": self = .command(id: try c.decode(String.self, forKey: .id))
        case "query": self = .query(id: try c.decode(Int.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "action":
            self = .action(action: try c.decode(String.self, forKey: .action), item: try c.decodeIfPresent(String.self, forKey: .item),
                           view: try c.decodeIfPresent(String.self, forKey: .view), result: try c.decodeIfPresent(String.self, forKey: .result),
                           tile: try c.decodeIfPresent(String.self, forKey: .tile))
        case "submit": self = .submit(view: try c.decode(String.self, forKey: .view), values: try c.decode([String: String].self, forKey: .values))
        case "filter": self = .filter(view: try c.decode(String.self, forKey: .view), text: try c.decode(String.self, forKey: .text),
                                      id: try c.decodeIfPresent(Int.self, forKey: .id) ?? 0)
        case "tile": self = .tile(id: try c.decode(String.self, forKey: .id))
        case "timer": self = .timer(id: try c.decode(String.self, forKey: .id))
        case "http":
            self = .http(request: try c.decode(String.self, forKey: .request), status: try c.decodeIfPresent(Int.self, forKey: .status),
                         headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                         body: try c.decodeIfPresent(Data.self, forKey: .body), error: try c.decodeIfPresent(String.self, forKey: .error))
        case "storage":
            self = .storage(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key),
                            value: try c.decodeIfPresent(String.self, forKey: .value))
        case "secret":
            self = .secret(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key),
                           value: try c.decodeIfPresent(String.self, forKey: .value))
        case "nowPlaying": self = .nowPlaying(try c.decodeIfPresent(NowPlayingInfo.self, forKey: .info))
        case "derived": self = .derived(request: try c.decode(String.self, forKey: .request), key: try c.decode(Data.self, forKey: .key))
        case "viewClosed": self = .viewClosed(view: try c.decode(String.self, forKey: .view))
        case "error": self = .error(request: try c.decodeIfPresent(String.self, forKey: .request), message: try c.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "no event \(other)")
        }
    }

    /// An interactive event — something the user is waiting on — or background work, for its budget.
    public var isInteractive: Bool {
        switch self {
        case .command, .query, .action, .submit, .filter, .tile: true
        default: false
        }
    }

    /// Something the user did — not typing, which a plugin hears as it goes. Only an answer to one may open
    /// a URL ([permissions](product/plugins/permissions.md#capabilities)).
    public var isAction: Bool {
        switch self {
        case .command, .action, .submit, .tile: true
        default: false
        }
    }

    /// The request an answer answers.
    public var request: String? {
        switch self {
        case .http(let request, _, _, _, _), .storage(let request, _, _), .secret(let request, _, _), .derived(let request, _): request
        case .error(let request, _): request
        default: nil
        }
    }
}

/// A plugin to dock2: what to do, in answer to an event.
public enum PluginEffect: Codable, Equatable, Sendable {
    case showView(ViewNode)
    /// `answering` names the filter it answers: an answer to an older text than the view has shown is dropped.
    case updateView(ViewNode, answering: Int?)
    case popView
    case closeView
    /// dock2 lets go: after a copy, say, as its own actions do.
    case dismiss
    case results(query: Int, items: [PluginResult])
    case setTile(id: String, tile: TileNode)
    case removeTile(id: String)
    case http(request: String, method: String, url: String, headers: [String: String], body: Data?)
    case storageGet(request: String, key: String)
    case storageSet(key: String, value: String)
    case storageDelete(key: String)
    case secretGet(request: String, key: String)
    case secretSet(key: String, value: String)
    case secretDelete(key: String)
    case copy(text: String, concealed: Bool)
    /// Concealed as a copy is: clipboard history skips it, and it is cleared after a while.
    case paste(text: String, concealed: Bool)
    case open(url: String)
    case toast(text: String)
    case timer(id: String, ms: Int, repeats: Bool)
    case cancelTimer(id: String)
    case subscribe(event: String)
    case nowPlaying(command: String, seconds: Double?)
    /// A key from a password, natively: PBKDF2 and Argon2 are slow by design, past a call's budget.
    case derive(Derivation)

    private enum Key: String, CodingKey {
        case type, view, query, items, id, tile, request, method, url, headers, body, key, value, text, concealed, ms
        case repeats = "repeat", event, command, seconds, answering
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "showView": self = .showView(try c.decode(ViewNode.self, forKey: .view))
        case "updateView": self = .updateView(try c.decode(ViewNode.self, forKey: .view), answering: try c.decodeIfPresent(Int.self, forKey: .answering))
        case "popView": self = .popView
        case "closeView": self = .closeView
        case "dismiss": self = .dismiss
        case "results": self = .results(query: try c.decode(Int.self, forKey: .query), items: try c.decode([PluginResult].self, forKey: .items))
        case "setTile": self = .setTile(id: try c.decode(String.self, forKey: .id), tile: try c.decode(TileNode.self, forKey: .tile))
        case "removeTile": self = .removeTile(id: try c.decode(String.self, forKey: .id))
        case "http":
            self = .http(request: try c.decode(String.self, forKey: .request), method: try c.decodeIfPresent(String.self, forKey: .method) ?? "GET",
                         url: try c.decode(String.self, forKey: .url), headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                         body: try c.decodeIfPresent(Data.self, forKey: .body))
        case "storageGet": self = .storageGet(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key))
        case "storageSet": self = .storageSet(key: try c.decode(String.self, forKey: .key), value: try c.decode(String.self, forKey: .value))
        case "storageDelete": self = .storageDelete(key: try c.decode(String.self, forKey: .key))
        case "secretGet": self = .secretGet(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key))
        case "secretSet": self = .secretSet(key: try c.decode(String.self, forKey: .key), value: try c.decode(String.self, forKey: .value))
        case "secretDelete": self = .secretDelete(key: try c.decode(String.self, forKey: .key))
        case "copy": self = .copy(text: try c.decode(String.self, forKey: .text), concealed: try c.decodeIfPresent(Bool.self, forKey: .concealed) ?? false)
        case "paste": self = .paste(text: try c.decode(String.self, forKey: .text), concealed: try c.decodeIfPresent(Bool.self, forKey: .concealed) ?? false)
        case "open": self = .open(url: try c.decode(String.self, forKey: .url))
        case "toast": self = .toast(text: try c.decode(String.self, forKey: .text))
        case "timer":
            self = .timer(id: try c.decode(String.self, forKey: .id), ms: try c.decode(Int.self, forKey: .ms),
                          repeats: try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? false)
        case "cancelTimer": self = .cancelTimer(id: try c.decode(String.self, forKey: .id))
        case "subscribe": self = .subscribe(event: try c.decode(String.self, forKey: .event))
        case "nowPlaying": self = .nowPlaying(command: try c.decode(String.self, forKey: .command), seconds: try c.decodeIfPresent(Double.self, forKey: .seconds))
        case "derive": self = .derive(try Derivation(from: decoder))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "no effect \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .showView(let view): try c.encode("showView", forKey: .type); try c.encode(view, forKey: .view)
        case .updateView(let view, let answering):
            try c.encode("updateView", forKey: .type); try c.encode(view, forKey: .view); try c.encodeIfPresent(answering, forKey: .answering)
        case .popView: try c.encode("popView", forKey: .type)
        case .closeView: try c.encode("closeView", forKey: .type)
        case .dismiss: try c.encode("dismiss", forKey: .type)
        case .results(let query, let items): try c.encode("results", forKey: .type); try c.encode(query, forKey: .query); try c.encode(items, forKey: .items)
        case .setTile(let id, let tile): try c.encode("setTile", forKey: .type); try c.encode(id, forKey: .id); try c.encode(tile, forKey: .tile)
        case .removeTile(let id): try c.encode("removeTile", forKey: .type); try c.encode(id, forKey: .id)
        case .http(let request, let method, let url, let headers, let body):
            try c.encode("http", forKey: .type); try c.encode(request, forKey: .request); try c.encode(method, forKey: .method)
            try c.encode(url, forKey: .url); try c.encode(headers, forKey: .headers); try c.encodeIfPresent(body, forKey: .body)
        case .storageGet(let request, let key): try c.encode("storageGet", forKey: .type); try c.encode(request, forKey: .request); try c.encode(key, forKey: .key)
        case .storageSet(let key, let value): try c.encode("storageSet", forKey: .type); try c.encode(key, forKey: .key); try c.encode(value, forKey: .value)
        case .storageDelete(let key): try c.encode("storageDelete", forKey: .type); try c.encode(key, forKey: .key)
        case .secretGet(let request, let key): try c.encode("secretGet", forKey: .type); try c.encode(request, forKey: .request); try c.encode(key, forKey: .key)
        case .secretSet(let key, let value): try c.encode("secretSet", forKey: .type); try c.encode(key, forKey: .key); try c.encode(value, forKey: .value)
        case .secretDelete(let key): try c.encode("secretDelete", forKey: .type); try c.encode(key, forKey: .key)
        case .copy(let text, let concealed): try c.encode("copy", forKey: .type); try c.encode(text, forKey: .text); try c.encode(concealed, forKey: .concealed)
        case .paste(let text, let concealed): try c.encode("paste", forKey: .type); try c.encode(text, forKey: .text); try c.encode(concealed, forKey: .concealed)
        case .open(let url): try c.encode("open", forKey: .type); try c.encode(url, forKey: .url)
        case .toast(let text): try c.encode("toast", forKey: .type); try c.encode(text, forKey: .text)
        case .timer(let id, let ms, let repeats):
            try c.encode("timer", forKey: .type); try c.encode(id, forKey: .id); try c.encode(ms, forKey: .ms); try c.encode(repeats, forKey: .repeats)
        case .cancelTimer(let id): try c.encode("cancelTimer", forKey: .type); try c.encode(id, forKey: .id)
        case .subscribe(let event): try c.encode("subscribe", forKey: .type); try c.encode(event, forKey: .event)
        case .nowPlaying(let command, let seconds):
            try c.encode("nowPlaying", forKey: .type); try c.encode(command, forKey: .command); try c.encodeIfPresent(seconds, forKey: .seconds)
        case .derive(let derivation): try c.encode("derive", forKey: .type); try derivation.encode(to: encoder)
        }
    }

    /// The capability an effect needs, if any.
    public var needs: PluginCapability? {
        switch self {
        case .results: .query
        case .http: .network
        case .secretGet, .secretSet, .secretDelete: .secrets
        case .copy: .clipboardWrite
        case .paste: .paste
        case .subscribe, .nowPlaying: .nowPlaying
        default: nil
        }
    }

    /// The key of a secret it reads or writes.
    public var secretKey: String? {
        switch self {
        case .secretGet(_, let key), .secretSet(let key, _), .secretDelete(let key): key
        default: nil
        }
    }

    /// The request id an answer — or a refusal — goes back under.
    public var request: String? {
        switch self {
        case .http(let request, _, _, _, _), .storageGet(let request, _), .secretGet(let request, _): request
        case .derive(let derivation): derivation.request
        default: nil
        }
    }
}

/// A key to derive from a password, for a plugin.
public struct Derivation: Codable, Equatable, Sendable {
    public enum Function: String, Codable, Sendable {
        case pbkdf2 = "pbkdf2-sha256"
        case argon2id
    }

    public var request: String
    public var function: Function
    public var password: String
    public var salt: Data
    public var iterations: Int
    /// Argon2id's, in KiB.
    public var memory: Int?
    public var parallelism: Int?
    public var length: Int

    public init(request: String, function: Function, password: String, salt: Data, iterations: Int, memory: Int? = nil,
                parallelism: Int? = nil, length: Int = 32) {
        self.request = request
        self.function = function
        self.password = password
        self.salt = salt
        self.iterations = iterations
        self.memory = memory
        self.parallelism = parallelism
        self.length = length
    }

    /// What the host will spend on one: up to ten million PBKDF2 rounds, a GiB and sixteen lanes of Argon2.
    public var isReasonable: Bool {
        guard (16...64).contains(length), iterations > 0 else { return false }
        switch function {
        case .pbkdf2: return iterations <= 10_000_000
        case .argon2id: return iterations <= 64 && (8...1_048_576).contains(memory ?? 0) && (1...16).contains(parallelism ?? 0)
        }
    }
}
