import Foundation

// What travels between dock2 and a plugin ([runtime](product/plugins/runtime.md)): JSON, every message tagged
// by `type`. The Rust SDK's types (`Plugins/sdk`) are the same shapes from the other side.

/// The interface version this dock2 speaks.
public let pluginAPIVersion = 1

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
        /// Out of Commands until the plugin shows it with `setCommands`.
        public var hidden: Bool?

        public init(id: String, title: String, subtitle: String? = nil, icon: Icon? = nil, keywords: [String]? = nil, view: Bool? = nil,
                    hidden: Bool? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.icon = icon
            self.keywords = keywords
            self.view = view
            self.hidden = hidden
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
    /// Its colour: what its symbols stand on, and its pictures, where they stand among apps', unless a symbol
    /// names its own ([packaging](product/plugins/packaging.md#icons)).
    public var tint: Tint?
    public var version: String
    public var api: Int
    public var module: String
    /// What it may reach, by capability, each with what it names and why it asks.
    public var capabilities: Capabilities
    public var commands: [Command]?
    public var results: Results?
    public var tiles: [Tile]?
    public var settings: [Setting]?

    public enum Problem: LocalizedError, Equatable, Sendable {
        case badID, unsupportedAPI(Int), badVersion, noModule, duplicate(String), comesWithDock2(String), badImage(String)
        case capabilitiesAsList, unknownCapability(String), noReason(PluginCapability), scope(PluginCapability, String), folderDefault(String)

        public var errorDescription: String? {
            switch self {
            case .badID: "Its id is not reverse-DNS, like com.example.weather."
            case .unsupportedAPI(let api): "It is written for plugin interface \(api); this Dock2 speaks \(pluginAPIVersion)."
            case .badVersion: "Its version is not three numbers, like 1.0.0."
            case .noModule: "Its module is missing, or not a .wasm file beside the manifest."
            case .duplicate(let id): "It declares “\(id)” twice."
            case .comesWithDock2(let name): "Its id is \(name)'s, which comes with Dock2."
            case .badImage(let path): "Its image “\(path)” is not a .png file inside its folder."
            case .capabilitiesAsList:
                "Its capabilities are a list. This Dock2 reads them by name, each with what it reaches and why, "
                    + "like \"network\": {\"hosts\": [\"api.example.com\"], \"reason\": \"…\"}."
            case .unknownCapability(let name): "It asks for “\(name)”, which this Dock2 does not know."
            case .noReason(let capability): "It asks for \(capability.rawValue) without saying why: every capability needs its reason."
            case .scope(let capability, let detail): "Its \(capability.rawValue) \(detail)."
            case .folderDefault(let id): "Its folder setting “\(id)” has a default: the folder is yours to pick."
            }
        }
    }

    /// Its own icon and its commands'.
    private var icons: [Icon] { ([icon] + (commands ?? []).map(\.icon)).compactMap { $0 } }

    /// What install refuses: an id that is not reverse-DNS, an interface this dock2 does not speak, a
    /// version that is not semantic, two commands or tiles with one id, an image outside its folder, a
    /// capability without its reason or naming what it cannot reach.
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
        for case .image(let path) in icons {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard path.lowercased().hasSuffix(".png"), !path.hasPrefix("/"), !parts.contains(".."), !parts.contains("") else {
                throw Problem.badImage(path)
            }
        }
        try validateCapabilities()
    }

    /// Each `image` its icons name read into `png` by `read`, given the path as the manifest writes it.
    public func readingImages(_ read: (String) throws -> Data) throws -> PluginManifest {
        func resolve(_ icon: Icon?) throws -> Icon? {
            guard case .image(let path)? = icon else { return icon }
            do { return .png(try read(path)) } catch { throw Problem.badImage(path) }
        }
        var manifest = self
        manifest.icon = try resolve(icon)
        manifest.commands = try commands?.map { command in
            var command = command
            command.icon = try resolve(command.icon)
            return command
        }
        return manifest
    }

    /// The hosts `network` may reach, `$setting`s replaced by their values; `*` stays, for any.
    public func allowedHosts(settings values: [String: String]) -> [String] {
        (capabilities.network?.hosts ?? []).compactMap { host in
            host.hasPrefix("$") ? values[String(host.dropFirst())].flatMap(Self.host(inSetting:)) : host.lowercased()
        }
    }

    /// The host a setting's value names — `https://vault.example.org/`, or `vault.example.org` — if it names one:
    /// never `*`, nor anything else that is not a host name.
    public static func host(inSetting value: String) -> String? {
        let host = (URL(string: value)?.host ?? value).lowercased()
        return isHostName(host) ? host : nil
    }
}

/// A file or folder as `files` describes it to a plugin.
public struct PluginFileEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, folder, link, other }
    public var name: String
    /// As the file system reaches it.
    public var path: String
    public var kind: Kind
    public var size: Int?
    /// Milliseconds since 1970.
    public var modified: Double?

    public init(name: String, path: String, kind: Kind, size: Int? = nil, modified: Double? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
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
    /// With what it holds: the capabilities it declares that the user has not revoked.
    case started(settings: [String: String], granted: [PluginCapability])
    case stopped
    case settings([String: String])
    /// What it holds changed: the user granted or revoked a capability.
    case granted([PluginCapability])
    case command(id: String)
    case query(id: Int, text: String)
    /// From a view (`view`), a result (`result`), or a tile (`tile`).
    case action(action: String, item: String?, view: String?, result: String?, tile: String?)
    case submit(view: String, values: [String: String])
    /// A list's field changed, for an owner that filters: `id` grows with each, for its answer to name.
    case filter(view: String, text: String, id: Int)
    /// A list's or a grid's scope was chosen, `value` its option's id: `id` counts with the view's filters.
    case scope(view: String, value: String, id: Int)
    case tile(id: String)
    case timer(id: String)
    /// The answer to a request, whole; for one streamed, its end, the body having come in parts.
    case http(request: String, status: Int?, headers: [String: String], body: Data?, error: String?)
    /// Part of a streamed answer: first its status and headers, then its body as it comes.
    case httpPart(request: String, status: Int?, headers: [String: String]?, body: Data?)
    case webSocketOpened(id: String, protocol: String?)
    /// A message, as text or as bytes.
    case webSocketMessage(id: String, text: String?, data: Data?)
    case webSocketClosed(id: String, code: Int, reason: String?)
    case storage(request: String, key: String, value: String?)
    /// Each key a `storageRead` named that holds a value, with it, in the order named: a list, since a dictionary
    /// would take "é" and "e\u{301}", two keys, for one.
    case storageRead(request: String, entries: [StorageEntry])
    /// A page of a `storageList`, in its order; `more` when the range goes on past it.
    case storageListed(request: String, entries: [StorageEntry], more: Bool)
    /// A `storageWrite` with a request id, applied whole.
    case storageWritten(request: String)
    case secret(request: String, key: String, value: String?)
    case nowPlaying(NowPlayingInfo?)
    /// A key derived for the plugin, natively.
    case derived(request: String, key: Data)
    /// With the item it had selected, for a plugin to open it there again.
    case viewClosed(view: String, selected: String?)
    /// A service's answer to a message sent with a request id.
    case xpcReply(request: String, service: String, message: JSONValue)
    /// What a service sent unasked.
    case xpcMessage(service: String, message: JSONValue)
    /// "interrupted": the service went and may come back, so the plugin can send its state again; "invalid":
    /// it is gone, or not signed by the team the manifest names.
    case xpcClosed(service: String, reason: String)
    /// What a command it ran printed, as it printed it: `stdout` or `stderr`.
    case output(request: String, stream: String, data: Data)
    /// A command it ran ended: its status, or the signal that ended it; `truncated` once it printed past what
    /// dock2 carries, `timedOut` if its time ran out.
    case exited(request: String, status: Int?, signal: Int?, truncated: Bool, timedOut: Bool)
    /// A file's bytes from `offset`, and its whole size.
    case fileRead(request: String, path: String, data: Data, size: Int)
    /// A folder's contents, `truncated` past what dock2 lists.
    case fileListed(request: String, path: String, entries: [PluginFileEntry], truncated: Bool)
    /// nil: nothing is there.
    case fileStat(request: String, path: String, entry: PluginFileEntry?)
    case fileWritten(request: String, path: String)
    /// What changed under a folder it watches.
    case fileChanged(watch: String, paths: [String])
    /// An effect refused: not granted, or failed.
    case error(request: String?, message: String)

    private enum Key: String, CodingKey {
        case type, settings, granted, id, text, action, item, view, result, tile, values, request, status, headers, body, error, key, value, info, message
        case service, reason, stream, data, signal, truncated, timedOut, path, size, entries, entry, watch, paths
        case code, selected, more
        case `protocol` = "protocol"
    }

    private enum DerivedKey: String, CodingKey { case key }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .started(let settings, let granted):
            try c.encode("started", forKey: .type); try c.encode(settings, forKey: .settings); try c.encode(granted, forKey: .granted)
        case .stopped: try c.encode("stopped", forKey: .type)
        case .settings(let settings): try c.encode("settings", forKey: .type); try c.encode(settings, forKey: .settings)
        case .granted(let granted): try c.encode("granted", forKey: .type); try c.encode(granted, forKey: .granted)
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
        case .scope(let view, let value, let id):
            try c.encode("scope", forKey: .type); try c.encode(view, forKey: .view); try c.encode(value, forKey: .value); try c.encode(id, forKey: .id)
        case .tile(let id): try c.encode("tile", forKey: .type); try c.encode(id, forKey: .id)
        case .timer(let id): try c.encode("timer", forKey: .type); try c.encode(id, forKey: .id)
        case .http(let request, let status, let headers, let body, let error):
            try c.encode("http", forKey: .type); try c.encode(request, forKey: .request)
            try c.encodeIfPresent(status, forKey: .status); try c.encode(headers, forKey: .headers)
            try c.encodeIfPresent(body, forKey: .body); try c.encodeIfPresent(error, forKey: .error)
        case .httpPart(let request, let status, let headers, let body):
            try c.encode("httpPart", forKey: .type); try c.encode(request, forKey: .request); try c.encodeIfPresent(status, forKey: .status)
            try c.encodeIfPresent(headers, forKey: .headers); try c.encodeIfPresent(body, forKey: .body)
        case .webSocketOpened(let id, let chosen):
            try c.encode("webSocketOpened", forKey: .type); try c.encode(id, forKey: .id); try c.encodeIfPresent(chosen, forKey: .protocol)
        case .webSocketMessage(let id, let text, let data):
            try c.encode("webSocketMessage", forKey: .type); try c.encode(id, forKey: .id); try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(data, forKey: .data)
        case .webSocketClosed(let id, let code, let reason):
            try c.encode("webSocketClosed", forKey: .type); try c.encode(id, forKey: .id); try c.encode(code, forKey: .code)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .storage(let request, let key, let value):
            try c.encode("storage", forKey: .type); try c.encode(request, forKey: .request)
            try c.encode(key, forKey: .key); try c.encodeIfPresent(value, forKey: .value)
        case .storageRead(let request, let entries):
            try c.encode("storageRead", forKey: .type); try c.encode(request, forKey: .request); try c.encode(entries, forKey: .entries)
        case .storageListed(let request, let entries, let more):
            try c.encode("storageListed", forKey: .type); try c.encode(request, forKey: .request); try c.encode(entries, forKey: .entries)
            try c.encode(more, forKey: .more)
        case .storageWritten(let request): try c.encode("storageWritten", forKey: .type); try c.encode(request, forKey: .request)
        case .secret(let request, let key, let value):
            try c.encode("secret", forKey: .type); try c.encode(request, forKey: .request)
            try c.encode(key, forKey: .key); try c.encodeIfPresent(value, forKey: .value)
        case .nowPlaying(let info): try c.encode("nowPlaying", forKey: .type); try c.encodeIfPresent(info, forKey: .info)
        case .derived(let request, let key): try c.encode("derived", forKey: .type); try c.encode(request, forKey: .request); try c.encode(key, forKey: .key)
        case .viewClosed(let view, let selected):
            try c.encode("viewClosed", forKey: .type); try c.encode(view, forKey: .view); try c.encodeIfPresent(selected, forKey: .selected)
        case .xpcReply(let request, let service, let message):
            try c.encode("xpcReply", forKey: .type); try c.encode(request, forKey: .request); try c.encode(service, forKey: .service)
            try c.encode(message, forKey: .message)
        case .xpcMessage(let service, let message):
            try c.encode("xpcMessage", forKey: .type); try c.encode(service, forKey: .service); try c.encode(message, forKey: .message)
        case .xpcClosed(let service, let reason):
            try c.encode("xpcClosed", forKey: .type); try c.encode(service, forKey: .service); try c.encode(reason, forKey: .reason)
        case .output(let request, let stream, let data):
            try c.encode("output", forKey: .type); try c.encode(request, forKey: .request); try c.encode(stream, forKey: .stream)
            try c.encode(data, forKey: .data)
        case .exited(let request, let status, let signal, let truncated, let timedOut):
            try c.encode("exited", forKey: .type); try c.encode(request, forKey: .request); try c.encodeIfPresent(status, forKey: .status)
            try c.encodeIfPresent(signal, forKey: .signal); try c.encode(truncated, forKey: .truncated); try c.encode(timedOut, forKey: .timedOut)
        case .fileRead(let request, let path, let data, let size):
            try c.encode("fileRead", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
            try c.encode(data, forKey: .data); try c.encode(size, forKey: .size)
        case .fileListed(let request, let path, let entries, let truncated):
            try c.encode("fileListed", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
            try c.encode(entries, forKey: .entries); try c.encode(truncated, forKey: .truncated)
        case .fileStat(let request, let path, let entry):
            try c.encode("fileStat", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
            try c.encodeIfPresent(entry, forKey: .entry)
        case .fileWritten(let request, let path):
            try c.encode("fileWritten", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
        case .fileChanged(let watch, let paths):
            try c.encode("fileChanged", forKey: .type); try c.encode(watch, forKey: .watch); try c.encode(paths, forKey: .paths)
        case .error(let request, let message):
            try c.encode("error", forKey: .type); try c.encodeIfPresent(request, forKey: .request); try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        switch try c.decode(String.self, forKey: .type) {
        case "started":
            self = .started(settings: try c.decode([String: String].self, forKey: .settings),
                            granted: try c.decodeIfPresent([PluginCapability].self, forKey: .granted) ?? [])
        case "stopped": self = .stopped
        case "settings": self = .settings(try c.decode([String: String].self, forKey: .settings))
        case "granted": self = .granted(try c.decode([PluginCapability].self, forKey: .granted))
        case "command": self = .command(id: try c.decode(String.self, forKey: .id))
        case "query": self = .query(id: try c.decode(Int.self, forKey: .id), text: try c.decode(String.self, forKey: .text))
        case "action":
            self = .action(action: try c.decode(String.self, forKey: .action), item: try c.decodeIfPresent(String.self, forKey: .item),
                           view: try c.decodeIfPresent(String.self, forKey: .view), result: try c.decodeIfPresent(String.self, forKey: .result),
                           tile: try c.decodeIfPresent(String.self, forKey: .tile))
        case "submit": self = .submit(view: try c.decode(String.self, forKey: .view), values: try c.decode([String: String].self, forKey: .values))
        case "filter": self = .filter(view: try c.decode(String.self, forKey: .view), text: try c.decode(String.self, forKey: .text),
                                      id: try c.decodeIfPresent(Int.self, forKey: .id) ?? 0)
        case "scope": self = .scope(view: try c.decode(String.self, forKey: .view), value: try c.decode(String.self, forKey: .value),
                                    id: try c.decodeIfPresent(Int.self, forKey: .id) ?? 0)
        case "tile": self = .tile(id: try c.decode(String.self, forKey: .id))
        case "timer": self = .timer(id: try c.decode(String.self, forKey: .id))
        case "http":
            self = .http(request: try c.decode(String.self, forKey: .request), status: try c.decodeIfPresent(Int.self, forKey: .status),
                         headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                         body: try c.decodeIfPresent(Data.self, forKey: .body), error: try c.decodeIfPresent(String.self, forKey: .error))
        case "httpPart":
            self = .httpPart(request: try c.decode(String.self, forKey: .request), status: try c.decodeIfPresent(Int.self, forKey: .status),
                             headers: try c.decodeIfPresent([String: String].self, forKey: .headers), body: try c.decodeIfPresent(Data.self, forKey: .body))
        case "webSocketOpened": self = .webSocketOpened(id: try c.decode(String.self, forKey: .id), protocol: try c.decodeIfPresent(String.self, forKey: .protocol))
        case "webSocketMessage":
            self = .webSocketMessage(id: try c.decode(String.self, forKey: .id), text: try c.decodeIfPresent(String.self, forKey: .text),
                                     data: try c.decodeIfPresent(Data.self, forKey: .data))
        case "webSocketClosed":
            self = .webSocketClosed(id: try c.decode(String.self, forKey: .id), code: try c.decode(Int.self, forKey: .code),
                                    reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "storage":
            self = .storage(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key),
                            value: try c.decodeIfPresent(String.self, forKey: .value))
        case "storageRead":
            self = .storageRead(request: try c.decode(String.self, forKey: .request), entries: try c.decode([StorageEntry].self, forKey: .entries))
        case "storageListed":
            self = .storageListed(request: try c.decode(String.self, forKey: .request), entries: try c.decode([StorageEntry].self, forKey: .entries),
                                  more: try c.decodeIfPresent(Bool.self, forKey: .more) ?? false)
        case "storageWritten": self = .storageWritten(request: try c.decode(String.self, forKey: .request))
        case "secret":
            self = .secret(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key),
                           value: try c.decodeIfPresent(String.self, forKey: .value))
        case "nowPlaying": self = .nowPlaying(try c.decodeIfPresent(NowPlayingInfo.self, forKey: .info))
        case "derived": self = .derived(request: try c.decode(String.self, forKey: .request), key: try c.decode(Data.self, forKey: .key))
        case "viewClosed": self = .viewClosed(view: try c.decode(String.self, forKey: .view), selected: try c.decodeIfPresent(String.self, forKey: .selected))
        case "xpcReply":
            self = .xpcReply(request: try c.decode(String.self, forKey: .request), service: try c.decode(String.self, forKey: .service),
                             message: try c.decode(JSONValue.self, forKey: .message))
        case "xpcMessage": self = .xpcMessage(service: try c.decode(String.self, forKey: .service), message: try c.decode(JSONValue.self, forKey: .message))
        case "xpcClosed": self = .xpcClosed(service: try c.decode(String.self, forKey: .service), reason: try c.decode(String.self, forKey: .reason))
        case "fileRead":
            self = .fileRead(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path),
                             data: try c.decode(Data.self, forKey: .data), size: try c.decode(Int.self, forKey: .size))
        case "fileListed":
            self = .fileListed(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path),
                               entries: try c.decode([PluginFileEntry].self, forKey: .entries), truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false)
        case "fileStat":
            self = .fileStat(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path),
                             entry: try c.decodeIfPresent(PluginFileEntry.self, forKey: .entry))
        case "fileWritten": self = .fileWritten(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path))
        case "fileChanged": self = .fileChanged(watch: try c.decode(String.self, forKey: .watch), paths: try c.decode([String].self, forKey: .paths))
        case "output":
            self = .output(request: try c.decode(String.self, forKey: .request), stream: try c.decode(String.self, forKey: .stream),
                           data: try c.decode(Data.self, forKey: .data))
        case "exited":
            self = .exited(request: try c.decode(String.self, forKey: .request), status: try c.decodeIfPresent(Int.self, forKey: .status),
                           signal: try c.decodeIfPresent(Int.self, forKey: .signal), truncated: try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false,
                           timedOut: try c.decodeIfPresent(Bool.self, forKey: .timedOut) ?? false)
        case "error": self = .error(request: try c.decodeIfPresent(String.self, forKey: .request), message: try c.decode(String.self, forKey: .message))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "no event \(other)")
        }
    }

    /// An interactive event — something the user is waiting on — or background work, for its budget.
    public var isInteractive: Bool {
        switch self {
        case .command, .query, .action, .submit, .filter, .scope, .tile: true
        default: false
        }
    }

    /// Something the user did — not typing, which a plugin hears as it goes, nor a scope chosen, which narrows a view.
    /// Only an answer to one may open a URL ([permissions](product/plugins/permissions.md#capabilities)).
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
        case .storageRead(let request, _), .storageListed(let request, _, _), .storageWritten(let request): request
        case .xpcReply(let request, _, _), .exited(let request, _, _, _, _): request
        case .fileRead(let request, _, _, _), .fileListed(let request, _, _, _), .fileStat(let request, _, _), .fileWritten(let request, _): request
        case .error(let request, _): request
        default: nil
        }
    }
}

/// A plugin to dock2: what to do, in answer to an event.
public enum PluginEffect: Codable, Equatable, Sendable {
    case showView(ViewNode)
    /// `answering` names the filter or scope it answers: an answer to an older one than the view has shown is dropped.
    case updateView(ViewNode, answering: Int?)
    case popView
    case closeView
    /// dock2 lets go: after a copy, say, as its own actions do.
    case dismiss
    case results(query: Int, items: [PluginResult])
    case setTile(id: String, tile: TileNode)
    case removeTile(id: String)
    /// Which of its commands Commands lists, until it says otherwise: its state's, as signed in or not.
    case setCommands(shown: [String])
    /// HTTPS to a host `network` names; plain HTTP to a `host:port`, or over a `socket`, `local-network` names.
    /// Streamed, its answer comes in `httpPart`s before its end.
    case http(request: String, method: String, url: String, headers: [String: String], body: Data?, stream: Bool = false, socket: String? = nil)
    case storageGet(request: String, key: String)
    case storageSet(key: String, value: String)
    case storageDelete(key: String)
    /// Several keys' values at once, as `storageRead`.
    case storageRead(request: String, keys: [String])
    /// A page of the keys under a prefix, in their order, as `storageListed`.
    case storageList(StorageListing)
    /// Steps applied in order as one transaction, all or none; with a request id, `storageWritten` says it is done.
    case storageWrite(request: String?, ops: [StorageOp])
    case secretGet(request: String, key: String)
    case secretSet(key: String, value: String)
    case secretDelete(key: String)
    case copy(text: String, concealed: Bool)
    /// Concealed as a copy is: clipboard history skips it, and it is cleared after a while.
    case paste(text: String, concealed: Bool)
    /// A web page or a document; with `apps`, a link of a scheme it names, or a file in an app it names.
    case open(url: String, app: String? = nil)
    case toast(text: String)
    case timer(id: String, ms: Int, repeats: Bool)
    case cancelTimer(id: String)
    case subscribe(event: String)
    case nowPlaying(command: String, seconds: Double?)
    /// A key from a password, natively: PBKDF2 and Argon2 are slow by design, past a call's budget.
    case derive(Derivation)
    /// A dictionary to a service the manifest names; with a request id, its reply comes back as `xpcReply`.
    case xpcSend(request: String?, service: String, message: JSONValue)
    /// A command the manifest declares, its slots' values by name — or, for one that takes any, `arguments`;
    /// what it prints comes back as `output`, then `exited`.
    case run(request: String, command: String, values: [String: String], arguments: [String]?, stdin: Data?)
    /// Ends a command it ran, as its time running out would.
    case cancelRun(request: String)
    /// Up to `length` bytes from `offset`, within dock2's limit for one read.
    case fileRead(request: String, path: String, offset: Int?, length: Int?)
    case fileList(request: String, path: String)
    case fileStat(request: String, path: String)
    /// The whole file, replaced at once; or `append`ed to. Folders it lacks are made.
    case fileWrite(request: String, path: String, data: Data, append: Bool)
    /// A WebSocket to a host `network` names, open until it closes or `webSocketClose`.
    case webSocketOpen(id: String, url: String, headers: [String: String], protocols: [String])
    /// Text, or bytes.
    case webSocketSend(id: String, text: String?, data: Data?)
    case webSocketClose(id: String)
    /// Its changes as they happen, as `fileChanged` under `id`, until `unwatch`.
    case watch(id: String, path: String)
    case unwatch(id: String)

    private enum Key: String, CodingKey {
        case type, view, query, items, id, tile, request, method, url, headers, body, key, value, text, concealed, ms
        case repeats = "repeat", event, command, seconds, answering, shown, service, message, values, args, stdin
        case path, offset, length, data, append, socket, app, protocols, stream, keys, ops
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
        case "setCommands": self = .setCommands(shown: try c.decode([String].self, forKey: .shown))
        case "http":
            let method: String = try c.decodeIfPresent(String.self, forKey: .method) ?? "GET"
            let headers: [String: String] = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            let stream: Bool = try c.decodeIfPresent(Bool.self, forKey: .stream) ?? false
            self = .http(request: try c.decode(String.self, forKey: .request), method: method, url: try c.decode(String.self, forKey: .url),
                         headers: headers, body: try c.decodeIfPresent(Data.self, forKey: .body), stream: stream,
                         socket: try c.decodeIfPresent(String.self, forKey: .socket))
        case "storageGet": self = .storageGet(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key))
        case "storageSet": self = .storageSet(key: try c.decode(String.self, forKey: .key), value: try c.decode(String.self, forKey: .value))
        case "storageDelete": self = .storageDelete(key: try c.decode(String.self, forKey: .key))
        case "storageRead": self = .storageRead(request: try c.decode(String.self, forKey: .request), keys: try c.decode([String].self, forKey: .keys))
        case "storageList": self = .storageList(try StorageListing(from: decoder))
        case "storageWrite":
            self = .storageWrite(request: try c.decodeIfPresent(String.self, forKey: .request), ops: try c.decode([StorageOp].self, forKey: .ops))
        case "secretGet": self = .secretGet(request: try c.decode(String.self, forKey: .request), key: try c.decode(String.self, forKey: .key))
        case "secretSet": self = .secretSet(key: try c.decode(String.self, forKey: .key), value: try c.decode(String.self, forKey: .value))
        case "secretDelete": self = .secretDelete(key: try c.decode(String.self, forKey: .key))
        case "copy": self = .copy(text: try c.decode(String.self, forKey: .text), concealed: try c.decodeIfPresent(Bool.self, forKey: .concealed) ?? false)
        case "paste": self = .paste(text: try c.decode(String.self, forKey: .text), concealed: try c.decodeIfPresent(Bool.self, forKey: .concealed) ?? false)
        case "open": self = .open(url: try c.decode(String.self, forKey: .url), app: try c.decodeIfPresent(String.self, forKey: .app))
        case "toast": self = .toast(text: try c.decode(String.self, forKey: .text))
        case "timer":
            self = .timer(id: try c.decode(String.self, forKey: .id), ms: try c.decode(Int.self, forKey: .ms),
                          repeats: try c.decodeIfPresent(Bool.self, forKey: .repeats) ?? false)
        case "cancelTimer": self = .cancelTimer(id: try c.decode(String.self, forKey: .id))
        case "subscribe": self = .subscribe(event: try c.decode(String.self, forKey: .event))
        case "nowPlaying": self = .nowPlaying(command: try c.decode(String.self, forKey: .command), seconds: try c.decodeIfPresent(Double.self, forKey: .seconds))
        case "derive": self = .derive(try Derivation(from: decoder))
        case "xpcSend":
            self = .xpcSend(request: try c.decodeIfPresent(String.self, forKey: .request), service: try c.decode(String.self, forKey: .service),
                            message: try c.decode(JSONValue.self, forKey: .message))
        case "run":
            self = .run(request: try c.decode(String.self, forKey: .request), command: try c.decode(String.self, forKey: .command),
                        values: try c.decodeIfPresent([String: String].self, forKey: .values) ?? [:],
                        arguments: try c.decodeIfPresent([String].self, forKey: .args), stdin: try c.decodeIfPresent(Data.self, forKey: .stdin))
        case "cancelRun": self = .cancelRun(request: try c.decode(String.self, forKey: .request))
        case "fileRead":
            self = .fileRead(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path),
                             offset: try c.decodeIfPresent(Int.self, forKey: .offset), length: try c.decodeIfPresent(Int.self, forKey: .length))
        case "fileList": self = .fileList(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path))
        case "fileStat": self = .fileStat(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path))
        case "fileWrite":
            self = .fileWrite(request: try c.decode(String.self, forKey: .request), path: try c.decode(String.self, forKey: .path),
                              data: try c.decode(Data.self, forKey: .data), append: try c.decodeIfPresent(Bool.self, forKey: .append) ?? false)
        case "webSocketOpen":
            self = .webSocketOpen(id: try c.decode(String.self, forKey: .id), url: try c.decode(String.self, forKey: .url),
                                  headers: try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:],
                                  protocols: try c.decodeIfPresent([String].self, forKey: .protocols) ?? [])
        case "webSocketSend":
            self = .webSocketSend(id: try c.decode(String.self, forKey: .id), text: try c.decodeIfPresent(String.self, forKey: .text),
                                  data: try c.decodeIfPresent(Data.self, forKey: .data))
        case "webSocketClose": self = .webSocketClose(id: try c.decode(String.self, forKey: .id))
        case "watch": self = .watch(id: try c.decode(String.self, forKey: .id), path: try c.decode(String.self, forKey: .path))
        case "unwatch": self = .unwatch(id: try c.decode(String.self, forKey: .id))
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
        case .setCommands(let shown): try c.encode("setCommands", forKey: .type); try c.encode(shown, forKey: .shown)
        case .http(let request, let method, let url, let headers, let body, let stream, let socket):
            try c.encode("http", forKey: .type); try c.encode(request, forKey: .request); try c.encode(method, forKey: .method)
            try c.encode(url, forKey: .url); try c.encode(headers, forKey: .headers); try c.encodeIfPresent(body, forKey: .body)
            if stream { try c.encode(stream, forKey: .stream) }
            try c.encodeIfPresent(socket, forKey: .socket)
        case .storageGet(let request, let key): try c.encode("storageGet", forKey: .type); try c.encode(request, forKey: .request); try c.encode(key, forKey: .key)
        case .storageSet(let key, let value): try c.encode("storageSet", forKey: .type); try c.encode(key, forKey: .key); try c.encode(value, forKey: .value)
        case .storageDelete(let key): try c.encode("storageDelete", forKey: .type); try c.encode(key, forKey: .key)
        case .storageRead(let request, let keys): try c.encode("storageRead", forKey: .type); try c.encode(request, forKey: .request); try c.encode(keys, forKey: .keys)
        case .storageList(let listing): try c.encode("storageList", forKey: .type); try listing.encode(to: encoder)
        case .storageWrite(let request, let ops):
            try c.encode("storageWrite", forKey: .type); try c.encodeIfPresent(request, forKey: .request); try c.encode(ops, forKey: .ops)
        case .secretGet(let request, let key): try c.encode("secretGet", forKey: .type); try c.encode(request, forKey: .request); try c.encode(key, forKey: .key)
        case .secretSet(let key, let value): try c.encode("secretSet", forKey: .type); try c.encode(key, forKey: .key); try c.encode(value, forKey: .value)
        case .secretDelete(let key): try c.encode("secretDelete", forKey: .type); try c.encode(key, forKey: .key)
        case .copy(let text, let concealed): try c.encode("copy", forKey: .type); try c.encode(text, forKey: .text); try c.encode(concealed, forKey: .concealed)
        case .paste(let text, let concealed): try c.encode("paste", forKey: .type); try c.encode(text, forKey: .text); try c.encode(concealed, forKey: .concealed)
        case .open(let url, let app): try c.encode("open", forKey: .type); try c.encode(url, forKey: .url); try c.encodeIfPresent(app, forKey: .app)
        case .toast(let text): try c.encode("toast", forKey: .type); try c.encode(text, forKey: .text)
        case .timer(let id, let ms, let repeats):
            try c.encode("timer", forKey: .type); try c.encode(id, forKey: .id); try c.encode(ms, forKey: .ms); try c.encode(repeats, forKey: .repeats)
        case .cancelTimer(let id): try c.encode("cancelTimer", forKey: .type); try c.encode(id, forKey: .id)
        case .subscribe(let event): try c.encode("subscribe", forKey: .type); try c.encode(event, forKey: .event)
        case .nowPlaying(let command, let seconds):
            try c.encode("nowPlaying", forKey: .type); try c.encode(command, forKey: .command); try c.encodeIfPresent(seconds, forKey: .seconds)
        case .derive(let derivation): try c.encode("derive", forKey: .type); try derivation.encode(to: encoder)
        case .xpcSend(let request, let service, let message):
            try c.encode("xpcSend", forKey: .type); try c.encodeIfPresent(request, forKey: .request); try c.encode(service, forKey: .service)
            try c.encode(message, forKey: .message)
        case .run(let request, let command, let values, let arguments, let stdin):
            try c.encode("run", forKey: .type); try c.encode(request, forKey: .request); try c.encode(command, forKey: .command)
            try c.encode(values, forKey: .values); try c.encodeIfPresent(arguments, forKey: .args); try c.encodeIfPresent(stdin, forKey: .stdin)
        case .cancelRun(let request): try c.encode("cancelRun", forKey: .type); try c.encode(request, forKey: .request)
        case .fileRead(let request, let path, let offset, let length):
            try c.encode("fileRead", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
            try c.encodeIfPresent(offset, forKey: .offset); try c.encodeIfPresent(length, forKey: .length)
        case .fileList(let request, let path): try c.encode("fileList", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
        case .fileStat(let request, let path): try c.encode("fileStat", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
        case .fileWrite(let request, let path, let data, let append):
            try c.encode("fileWrite", forKey: .type); try c.encode(request, forKey: .request); try c.encode(path, forKey: .path)
            try c.encode(data, forKey: .data); try c.encode(append, forKey: .append)
        case .webSocketOpen(let id, let url, let headers, let protocols):
            try c.encode("webSocketOpen", forKey: .type); try c.encode(id, forKey: .id); try c.encode(url, forKey: .url)
            try c.encode(headers, forKey: .headers); try c.encode(protocols, forKey: .protocols)
        case .webSocketSend(let id, let text, let data):
            try c.encode("webSocketSend", forKey: .type); try c.encode(id, forKey: .id); try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(data, forKey: .data)
        case .webSocketClose(let id): try c.encode("webSocketClose", forKey: .type); try c.encode(id, forKey: .id)
        case .watch(let id, let path): try c.encode("watch", forKey: .type); try c.encode(id, forKey: .id); try c.encode(path, forKey: .path)
        case .unwatch(let id): try c.encode("unwatch", forKey: .type); try c.encode(id, forKey: .id)
        }
    }

    /// The capability an effect needs, if any. No `default`: an effect is added with its decision.
    public var needs: PluginCapability? {
        switch self {
        case .showView, .updateView, .popView, .closeView, .dismiss, .setTile, .removeTile, .setCommands: nil
        case .storageGet, .storageSet, .storageDelete, .storageRead, .storageList, .storageWrite, .toast, .timer, .cancelTimer, .derive: nil
        case .open(let url, let app): app != nil || !Self.alwaysOpens(url) ? .apps : nil
        case .results: .query
        case .http(_, _, let url, _, _, _, let socket): socket != nil || url.lowercased().hasPrefix("http:") ? .localNetwork : .network
        case .webSocketOpen, .webSocketSend: .network
        case .webSocketClose: nil
        case .secretGet, .secretSet, .secretDelete: .secrets
        case .copy: .clipboardWrite
        case .paste: .paste
        case .subscribe, .nowPlaying: .nowPlaying
        case .xpcSend: .xpc
        case .run: .run
        case .cancelRun, .unwatch: nil
        case .fileRead, .fileList, .fileStat, .fileWrite, .watch: .files
        }
    }

    /// What opens without `apps`: a web page, or a document.
    static func alwaysOpens(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased() else { return true }
        return ["http", "https", "file"].contains(scheme)
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
        case .http(let request, _, _, _, _, _, _), .storageGet(let request, _), .storageRead(let request, _), .secretGet(let request, _): request
        case .storageList(let listing): listing.request
        case .storageWrite(let request, _): request
        case .derive(let derivation): derivation.request
        case .xpcSend(let request, _, _): request
        case .run(let request, _, _, _, _): request
        case .fileRead(let request, _, _, _), .fileList(let request, _), .fileStat(let request, _), .fileWrite(let request, _, _, _): request
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

/// What a `storageList` asks for: the keys under `prefix`, every key for "", in the order of their UTF-8 bytes or its
/// reverse, from past `after`, a page at a time.
public struct StorageListing: Codable, Equatable, Sendable {
    public var request: String
    public var prefix: String
    /// The last key of the page before: the listing goes on past it, in its direction.
    public var after: String?
    /// At most dock2's page, which is also what none asks for.
    public var limit: Int?
    public var reverse: Bool
    public var keysOnly: Bool

    public init(request: String, prefix: String = "", after: String? = nil, limit: Int? = nil, reverse: Bool = false, keysOnly: Bool = false) {
        self.request = request
        self.prefix = prefix
        self.after = after
        self.limit = limit
        self.reverse = reverse
        self.keysOnly = keysOnly
    }

    private enum Key: String, CodingKey { case request, prefix, after, limit, reverse, keysOnly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        self.init(request: try c.decode(String.self, forKey: .request), prefix: try c.decodeIfPresent(String.self, forKey: .prefix) ?? "",
                  after: try c.decodeIfPresent(String.self, forKey: .after), limit: try c.decodeIfPresent(Int.self, forKey: .limit),
                  reverse: try c.decodeIfPresent(Bool.self, forKey: .reverse) ?? false, keysOnly: try c.decodeIfPresent(Bool.self, forKey: .keysOnly) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(request, forKey: .request); try c.encode(prefix, forKey: .prefix)
        try c.encodeIfPresent(after, forKey: .after); try c.encodeIfPresent(limit, forKey: .limit)
        if reverse { try c.encode(reverse, forKey: .reverse) }
        if keysOnly { try c.encode(keysOnly, forKey: .keysOnly) }
    }
}

/// A key, and its value unless only keys were asked for.
public struct StorageEntry: Codable, Equatable, Sendable {
    public var key: String
    public var value: String?

    public init(key: String, value: String? = nil) {
        self.key = key
        self.value = value
    }
}

/// A step of a `storageWrite`. As JSON, one key naming which, as an icon's does: `{"set": "item/1", "value": "…"}`,
/// `{"delete": "item/1"}`, or `{"deletePrefix": "item/"}`, which deletes every key under it, and every key for "".
public enum StorageOp: Codable, Equatable, Sendable {
    case set(key: String, value: String)
    case delete(key: String)
    case deletePrefix(String)

    private enum Key: String, CodingKey { case set, value, delete, deletePrefix }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        if let key = try c.decodeIfPresent(String.self, forKey: .set) { self = .set(key: key, value: try c.decode(String.self, forKey: .value)) }
        else if let key = try c.decodeIfPresent(String.self, forKey: .delete) { self = .delete(key: key) }
        else if let prefix = try c.decodeIfPresent(String.self, forKey: .deletePrefix) { self = .deletePrefix(prefix) }
        else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a step names set, delete or deletePrefix")) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        switch self {
        case .set(let key, let value): try c.encode(key, forKey: .set); try c.encode(value, forKey: .value)
        case .delete(let key): try c.encode(key, forKey: .delete)
        case .deletePrefix(let prefix): try c.encode(prefix, forKey: .deletePrefix)
        }
    }
}
