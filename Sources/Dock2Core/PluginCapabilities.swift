import Foundation

/// What a plugin may reach ([permissions](product/plugins/permissions.md)), in the order the sheet shows them.
public enum PluginCapability: String, Codable, CodingKeyRepresentable, Sendable, CaseIterable {
    case network
    case localNetwork = "local-network"
    case query
    case clipboardWrite = "clipboard.write"
    case clipboardRead = "clipboard.read"
    case paste, secrets, files, apps, xpc, run
    case nowPlaying = "now-playing"
}

public typealias RunCommand = PluginManifest.Capabilities.Run.Command
public typealias XPCService = PluginManifest.Capabilities.XPC.Service

extension PluginManifest {
    /// `capabilities`: an object keyed by capability, each value what it names and the plugin's reason.
    public struct Capabilities: Codable, Equatable, Sendable {
        /// A capability that names nothing: its reason alone.
        public struct Plain: Codable, Equatable, Sendable {
            public var reason: String?
            public init(reason: String?) { self.reason = reason }
        }

        public struct Network: Codable, Equatable, Sendable {
            /// HTTPS hosts by name; `$setting` for one a setting holds, a self-hosted server; `*` for any.
            public var hosts: [String]
            public var reason: String?
            public init(hosts: [String], reason: String?) { self.hosts = hosts; self.reason = reason }
        }

        public struct LocalNetwork: Codable, Equatable, Sendable {
            /// Plain HTTP to `host:port` on this Mac or the local network, or `$setting`.
            public var hosts: [String]?
            /// HTTP over Unix sockets, by path; `~/` is the home folder.
            public var sockets: [String]?
            public var reason: String?
            public init(hosts: [String]? = nil, sockets: [String]? = nil, reason: String?) {
                self.hosts = hosts
                self.sockets = sockets
                self.reason = reason
            }
        }

        public struct Files: Codable, Equatable, Sendable {
            /// The folder settings whose folders it reaches, as `$setting`.
            public var folders: [String]
            public var write: Bool?
            public var reason: String?
            public init(folders: [String], write: Bool? = nil, reason: String?) {
                self.folders = folders
                self.write = write
                self.reason = reason
            }
        }

        public struct Apps: Codable, Equatable, Sendable {
            /// Links it may open, by scheme.
            public var schemes: [String]?
            /// Apps it may open files in, by bundle identifier.
            public var apps: [String]?
            public var reason: String?

            public init(schemes: [String]? = nil, apps: [String]? = nil, reason: String?) {
                self.schemes = schemes
                self.apps = apps
                self.reason = reason
            }

            /// Apps known to run what they open, refused at install: a file opened in one runs a program, or
            /// installs one. Opening checks each app's own declared types besides (`PluginHost.runsWhatItOpens`).
            public static let runners: Set<String> = [
                "com.apple.terminal", "com.apple.scripteditor2", "com.apple.automator", "com.apple.installer",
                "com.apple.shortcuts", "com.apple.javalauncher", "com.apple.mcx.profilehelper", "com.googlecode.iterm2",
                "com.mitchellh.ghostty", "dev.warp.warp-stable", "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
            ]

            public static func runs(_ app: String) -> Bool { runners.contains(app.lowercased()) }
        }

        public struct XPC: Codable, Equatable, Sendable {
            public struct Service: Codable, Hashable, Sendable {
                /// Its Mach name.
                public var name: String
                /// The team it must be signed by: the name alone proves nothing.
                public var team: String
                /// A daemon's, in the system domain, rather than an agent's in the user's.
                public var daemon: Bool?

                public init(name: String, team: String, daemon: Bool? = nil) {
                    self.name = name
                    self.team = team
                    self.daemon = daemon
                }

                public var isApple: Bool { name.lowercased().hasPrefix("com.apple.") }
            }

            public var services: [Service]
            public var reason: String?

            public init(services: [Service], reason: String?) {
                self.services = services
                self.reason = reason
            }

            public func service(_ name: String) -> Service? { services.first { $0.name == name } }
        }

        public struct Run: Codable, Equatable, Sendable {
            /// A program, by its absolute path, and its arguments: fixed, or slots the plugin fills.
            public struct Command: Codable, Equatable, Sendable {
                /// One argument the plugin fills as it runs the command, never read by a shell.
                public enum Slot: String, Codable, Sendable, CaseIterable { case text, path, folder }

                public enum Argument: Hashable, Sendable {
                    case fixed(String)
                    case slot(Slot)

                    public init(_ spelling: String) {
                        if spelling.hasPrefix("{"), spelling.hasSuffix("}"), let slot = Slot(rawValue: String(spelling.dropFirst().dropLast())) {
                            self = .slot(slot)
                        } else {
                            self = .fixed(spelling)
                        }
                    }

                    public var spelling: String {
                        switch self {
                        case .fixed(let text): text
                        case .slot(let slot): "{\(slot.rawValue)}"
                        }
                    }
                }

                /// What a command reaches, to compare: an update that changes it asks again.
                public struct Line: Codable, Hashable, Sendable {
                    public var program: String
                    /// nil: any.
                    public var arguments: [String]?
                    public var team: String?
                }

                public var id: String
                public var program: String
                /// nil when it takes any, `"args": "*"`.
                public var arguments: [Argument]?
                /// The team its program must be signed by.
                public var team: String?
                /// In seconds, within dock2's own limit.
                public var timeout: Double?

                public init(id: String, program: String, arguments: [Argument]?, team: String? = nil, timeout: Double? = nil) {
                    self.id = id
                    self.program = program
                    self.arguments = arguments
                    self.team = team
                    self.timeout = timeout
                }

                private enum CodingKeys: String, CodingKey { case id, program, args, team, timeout }

                public init(from decoder: Decoder) throws {
                    let c = try decoder.container(keyedBy: CodingKeys.self)
                    id = try c.decode(String.self, forKey: .id)
                    program = try c.decode(String.self, forKey: .program)
                    team = try c.decodeIfPresent(String.self, forKey: .team)
                    timeout = try c.decodeIfPresent(Double.self, forKey: .timeout)
                    if let any = try? c.decode(String.self, forKey: .args) {
                        guard any == "*" else {
                            throw DecodingError.dataCorruptedError(forKey: .args, in: c, debugDescription: "args are a list, or \"*\" for any")
                        }
                        arguments = nil
                    } else {
                        arguments = try (c.decodeIfPresent([String].self, forKey: .args) ?? []).map(Argument.init)
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var c = encoder.container(keyedBy: CodingKeys.self)
                    try c.encode(id, forKey: .id)
                    try c.encode(program, forKey: .program)
                    if let arguments { try c.encode(arguments.map(\.spelling), forKey: .args) } else { try c.encode("*", forKey: .args) }
                    try c.encodeIfPresent(team, forKey: .team)
                    try c.encodeIfPresent(timeout, forKey: .timeout)
                }

                public var slots: [Slot] {
                    (arguments ?? []).compactMap { if case .slot(let slot) = $0 { slot } else { nil } }
                }

                public var line: Line { Line(program: program, arguments: arguments?.map(\.spelling), team: team) }

                /// As the sheet says it: the program and its arguments, a slot as ‹folder›.
                public var spelled: String {
                    guard let arguments else { return program }
                    return ([program] + arguments.map { argument in
                        switch argument {
                        case .fixed(let text): text.contains(" ") || text.isEmpty ? "'\(text)'" : text
                        case .slot(let slot): "‹\(slot.rawValue)›"
                        }
                    }).joined(separator: " ")
                }
            }

            public var commands: [Command]
            public var reason: String?

            public init(commands: [Command], reason: String?) {
                self.commands = commands
                self.reason = reason
            }

            public func command(_ id: String) -> Command? { commands.first { $0.id == id } }
        }

        public var network: Network?
        public var localNetwork: LocalNetwork?
        public var query: Plain?
        public var clipboardWrite: Plain?
        public var clipboardRead: Plain?
        public var paste: Plain?
        public var secrets: Plain?
        public var files: Files?
        public var apps: Apps?
        public var xpc: XPC?
        public var run: Run?
        public var nowPlaying: Plain?

        public init() {}

        /// The reason it gives for `capability` and what it reaches by it, nil if it does not declare it.
        public func declaration(of capability: PluginCapability) -> (reason: String?, scope: Reach.Scope)? {
            switch capability {
            case .network:
                guard let network else { return nil }
                return (network.reason, .hosts(Set(network.hosts.map { $0.lowercased() })))
            case .localNetwork:
                guard let localNetwork else { return nil }
                return (localNetwork.reason, .local(hosts: Set((localNetwork.hosts ?? []).map { $0.lowercased() }), sockets: Set(localNetwork.sockets ?? [])))
            case .query: return query.map { ($0.reason, .plain) }
            case .clipboardWrite: return clipboardWrite.map { ($0.reason, .plain) }
            case .clipboardRead: return clipboardRead.map { ($0.reason, .plain) }
            case .paste: return paste.map { ($0.reason, .plain) }
            case .secrets: return secrets.map { ($0.reason, .plain) }
            case .files:
                guard let files else { return nil }
                return (files.reason, .folders(Set(files.folders), write: files.write == true))
            case .apps:
                guard let apps else { return nil }
                return (apps.reason, .opens(schemes: Set((apps.schemes ?? []).map { $0.lowercased() }), apps: Set((apps.apps ?? []).map { $0.lowercased() })))
            case .xpc:
                guard let xpc else { return nil }
                return (xpc.reason, .services(Set(xpc.services)))
            case .run:
                guard let run else { return nil }
                return (run.reason, .commands(Set(run.commands.map(\.line))))
            case .nowPlaying: return nowPlaying.map { ($0.reason, .plain) }
            }
        }

        /// What it declares, in the order the sheet shows them.
        public var declared: [PluginCapability] { PluginCapability.allCases.filter(declares) }

        public func declares(_ capability: PluginCapability) -> Bool { declaration(of: capability) != nil }

        public func reason(_ capability: PluginCapability) -> String? { declaration(of: capability)?.reason }

        /// A command that takes any arguments: the escape, off until the user switches it on.
        public var runsAnything: Bool { run?.commands.contains { $0.arguments == nil } ?? false }

        /// One of its commands can do anything the user can.
        public var runsWithFullTrust: Bool { run?.commands.contains(where: isFullTrust) ?? false }

        /// Whether running `command` can do anything the user can: it takes any arguments, or a slot of it
        /// reaches a folder the plugin may also write, so the program may run what the plugin put there.
        public func isFullTrust(_ command: RunCommand) -> Bool {
            command.arguments == nil || (files?.write == true && command.slots.contains { $0 != .text })
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
            init(_ capability: PluginCapability) { stringValue = capability.rawValue }
        }

        public init(from decoder: Decoder) throws {
            if (try? decoder.singleValueContainer().decode([String].self)) != nil { throw Problem.capabilitiesAsList }
            let c = try decoder.container(keyedBy: Key.self)
            if let unknown = c.allKeys.first(where: { PluginCapability(rawValue: $0.stringValue) == nil }) {
                throw Problem.unknownCapability(unknown.stringValue)
            }
            network = try c.decodeIfPresent(Network.self, forKey: Key(.network))
            localNetwork = try c.decodeIfPresent(LocalNetwork.self, forKey: Key(.localNetwork))
            query = try c.decodeIfPresent(Plain.self, forKey: Key(.query))
            clipboardWrite = try c.decodeIfPresent(Plain.self, forKey: Key(.clipboardWrite))
            clipboardRead = try c.decodeIfPresent(Plain.self, forKey: Key(.clipboardRead))
            paste = try c.decodeIfPresent(Plain.self, forKey: Key(.paste))
            secrets = try c.decodeIfPresent(Plain.self, forKey: Key(.secrets))
            files = try c.decodeIfPresent(Files.self, forKey: Key(.files))
            apps = try c.decodeIfPresent(Apps.self, forKey: Key(.apps))
            xpc = try c.decodeIfPresent(XPC.self, forKey: Key(.xpc))
            run = try c.decodeIfPresent(Run.self, forKey: Key(.run))
            nowPlaying = try c.decodeIfPresent(Plain.self, forKey: Key(.nowPlaying))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encodeIfPresent(network, forKey: Key(.network))
            try c.encodeIfPresent(localNetwork, forKey: Key(.localNetwork))
            try c.encodeIfPresent(query, forKey: Key(.query))
            try c.encodeIfPresent(clipboardWrite, forKey: Key(.clipboardWrite))
            try c.encodeIfPresent(clipboardRead, forKey: Key(.clipboardRead))
            try c.encodeIfPresent(paste, forKey: Key(.paste))
            try c.encodeIfPresent(secrets, forKey: Key(.secrets))
            try c.encodeIfPresent(files, forKey: Key(.files))
            try c.encodeIfPresent(apps, forKey: Key(.apps))
            try c.encodeIfPresent(xpc, forKey: Key(.xpc))
            try c.encodeIfPresent(run, forKey: Key(.run))
            try c.encodeIfPresent(nowPlaying, forKey: Key(.nowPlaying))
        }
    }

    /// What a plugin reaches: each capability with its scope, as values to compare. An update asks again for
    /// what its reach has beyond the one agreed to; a reason alone changing asks nothing.
    public struct Reach: Codable, Equatable, Sendable {
        public enum Scope: Codable, Equatable, Sendable {
            case plain
            case hosts(Set<String>)
            case local(hosts: Set<String>, sockets: Set<String>)
            case folders(Set<String>, write: Bool)
            case opens(schemes: Set<String>, apps: Set<String>)
            case services(Set<XPCService>)
            case commands(Set<RunCommand.Line>)

            /// Everything it reaches, `agreed` reached already.
            public func isWithin(_ agreed: Scope) -> Bool {
                switch (self, agreed) {
                case (.plain, .plain): true
                case (.hosts(let new), .hosts(let old)): old.contains("*") || new.isSubset(of: old)
                case (.local(let hosts, let sockets), .local(let oldHosts, let oldSockets)): hosts.isSubset(of: oldHosts) && sockets.isSubset(of: oldSockets)
                case (.folders(let folders, let write), .folders(let old, let wrote)): folders.isSubset(of: old) && (!write || wrote)
                case (.opens(let schemes, let apps), .opens(let oldSchemes, let oldApps)): schemes.isSubset(of: oldSchemes) && apps.isSubset(of: oldApps)
                case (.services(let new), .services(let old)): new.isSubset(of: old)
                case (.commands(let new), .commands(let old)): new.isSubset(of: old)
                default: false
                }
            }
        }

        public var scopes: [PluginCapability: Scope]

        public init(scopes: [PluginCapability: Scope]) {
            self.scopes = scopes
        }

        /// What it reaches beyond `agreed`, in the sheet's order: a capability added, or one reaching further —
        /// a host, a socket, a folder, writing, a scheme, an app, a service or a command added, or a command's
        /// arguments changed. Everything, when nothing was agreed.
        public func beyond(_ agreed: Reach?) -> [PluginCapability] {
            PluginCapability.allCases.filter { capability in
                guard let scope = scopes[capability] else { return false }
                guard let old = agreed?.scopes[capability] else { return true }
                return !scope.isWithin(old)
            }
        }
    }

    /// A `$setting` is reached with its default: an update that changes the default reaches somewhere else.
    public var reach: Reach {
        func named(_ entries: Set<String>) -> Set<String> {
            Set(entries.map { entry in
                guard entry.hasPrefix("$"), let value = settings?.first(where: { $0.id == String(entry.dropFirst()) })?.defaultValue else { return entry }
                return "\(entry)=\(value)"
            })
        }
        return Reach(scopes: Dictionary(uniqueKeysWithValues: capabilities.declared.compactMap { capability in
            capabilities.declaration(of: capability).map { declaration in
                let scope: Reach.Scope = switch declaration.scope {
                case .hosts(let hosts): .hosts(named(hosts))
                case .local(let hosts, let sockets): .local(hosts: named(hosts), sockets: sockets)
                default: declaration.scope
                }
                return (capability, scope)
            }
        }))
    }
}

// MARK: - In plain words

extension PluginManifest {
    /// What dock2 says a capability lets the plugin do: a line for each thing it names, in plain words — what
    /// dock2 enforces, never what the plugin claims. `settings` are its values, for what a `$setting` holds.
    public func lines(_ capability: PluginCapability, settings values: [String: String], appName: (String) -> String? = { _ in nil }) -> [String] {
        func setting(_ reference: String) -> (title: String, value: String?) {
            let id = String(reference.dropFirst())
            let title = settings?.first { $0.id == id }?.title ?? id
            return (title, values[id].flatMap { $0.isEmpty ? nil : $0 })
        }
        func list(_ items: [String]) -> String {
            items.count < 2 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
        switch capability {
        case .network:
            let hosts = capabilities.network?.hosts ?? []
            if hosts.contains("*") { return ["Connects to any website"] }
            let named = hosts.map { host in
                guard host.hasPrefix("$") else { return host.lowercased() }
                let (title, value) = setting(host)
                return value.flatMap(Self.host(inSetting:)) ?? "the server you set in \(title)"
            }
            return ["Connects to \(list(named))"]
        case .localNetwork:
            let local = capabilities.localNetwork
            let hosts = (local?.hosts ?? []).map { host in
                guard host.hasPrefix("$") else { return host.lowercased() }
                let (title, value) = setting(host)
                return value.flatMap { HostPort(setting: $0)?.spelled } ?? "the address you set in \(title)"
            }
            return (hosts.isEmpty ? [] : ["Connects to \(list(hosts))"])
                + (local?.sockets ?? []).map { "Connects to the socket \($0)" }
        case .query: return ["Sees what you type in Dock2's search"]
        case .clipboardWrite: return ["Copies to the clipboard"]
        case .clipboardRead: return ["Reads your clipboard history"]
        case .paste: return ["Pastes into other apps"]
        case .secrets: return ["Stores secrets in your Keychain"]
        case .files:
            let files = capabilities.files
            let verb = files?.write == true ? "Reads and writes files in" : "Reads files in"
            return (files?.folders ?? []).map { folder in
                let (title, value) = setting(folder)
                return "\(verb) \(value.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "the folder you pick for \(title)")"
            }
        case .apps:
            let apps = capabilities.apps
            let schemes = (apps?.schemes ?? []).map { "\($0.lowercased()):" }
            return (schemes.isEmpty ? [] : ["Opens \(list(schemes)) links"]) + (apps?.apps ?? []).map { "Opens files in \(appName($0) ?? $0)" }
        case .xpc:
            return (capabilities.xpc?.services ?? []).map { service in
                "Talks to \(service.daemon == true ? "the daemon " : "")\(service.name), signed by \(service.team)"
            }
        case .run:
            return (capabilities.run?.commands ?? []).map { command in
                let signed = command.team.map { ", signed by \($0)" } ?? ""
                guard capabilities.isFullTrust(command) else { return "Runs \(command.spelled)\(signed)" }
                let what = command.arguments == nil ? "\(command.program) with any arguments" : command.spelled
                return "Runs \(what)\(signed) — it can do anything you can"
            }
        case .nowPlaying: return ["Sees and controls what is playing"]
        }
    }
}

// MARK: - What install refuses

extension PluginManifest {
    /// Every capability with its reason, naming only what it can reach; a folder setting without a default,
    /// since the folder is the user's to pick.
    func validateCapabilities() throws {
        if let folder = (settings ?? []).first(where: { $0.kind == .folder && $0.defaultValue != nil }) {
            throw Problem.folderDefault(folder.id)
        }
        for capability in capabilities.declared where (capabilities.reason(capability) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw Problem.noReason(capability)
        }
        func refuse(_ capability: PluginCapability, _ detail: String) -> Problem { .scope(capability, detail) }
        /// `$setting`, naming one of its settings of those kinds.
        func names(_ reference: String, _ kinds: Set<Setting.Kind>) -> Bool {
            reference.hasPrefix("$") && (settings ?? []).contains { $0.id == String(reference.dropFirst()) && kinds.contains($0.kind) }
        }
        if let network = capabilities.network {
            guard !network.hosts.isEmpty else { throw refuse(.network, "names no host") }
            for host in network.hosts where host != "*" && !names(host, [.text, .choice]) && !Self.isHostName(host) {
                throw refuse(.network, "names “\(host)”, which is neither a host name, like api.example.com, nor one of its text settings")
            }
        }
        if let local = capabilities.localNetwork {
            guard !(local.hosts ?? []).isEmpty || !(local.sockets ?? []).isEmpty else { throw refuse(.localNetwork, "names no host or socket") }
            for host in local.hosts ?? [] where !names(host, [.text, .choice]) && HostPort(host)?.isLocal != true {
                throw refuse(.localNetwork, "names “\(host)”, which is not a host and port on this Mac or the local network, like localhost:11434")
            }
            for socket in local.sockets ?? [] where !(socket.hasPrefix("/") || socket.hasPrefix("~/")) || socket.split(separator: "/").contains("..") {
                throw refuse(.localNetwork, "names the socket “\(socket)”, which is not an absolute path")
            }
        }
        if let files = capabilities.files {
            guard !files.folders.isEmpty else { throw refuse(.files, "names no folder setting") }
            for folder in files.folders where !names(folder, [.folder]) {
                throw refuse(.files, "names “\(folder)”, which is not one of its folder settings, like $notes")
            }
        }
        if let apps = capabilities.apps {
            guard !(apps.schemes ?? []).isEmpty || !(apps.apps ?? []).isEmpty else { throw refuse(.apps, "names no scheme or app") }
            for scheme in apps.schemes ?? [] where !Self.isScheme(scheme) || ["http", "https", "file"].contains(scheme.lowercased()) {
                throw refuse(.apps, "names the scheme “\(scheme)”, which is not one it may ask for")
            }
            for app in apps.apps ?? [] {
                guard app.split(separator: ".").count >= 2 else { throw refuse(.apps, "names “\(app)”, which is not a bundle identifier, like dev.zed.Zed") }
                guard !Capabilities.Apps.runs(app) else { throw refuse(.apps, "names \(app), which runs what it opens") }
            }
        }
        if let xpc = capabilities.xpc {
            guard !xpc.services.isEmpty else { throw refuse(.xpc, "names no service") }
            if let repeated = Dictionary(grouping: xpc.services.map(\.name), by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                throw Problem.duplicate(repeated)
            }
            for service in xpc.services {
                guard !service.name.isEmpty, !service.isApple else { throw refuse(.xpc, "names “\(service.name)”: Apple's services are never a plugin's") }
                guard Self.isTeam(service.team) else { throw refuse(.xpc, "names “\(service.team)” as \(service.name)'s team, which is not a team identifier like ABCDE12345") }
            }
        }
        if let run = capabilities.run {
            guard !run.commands.isEmpty else { throw refuse(.run, "declares no command") }
            if let repeated = Dictionary(grouping: run.commands.map(\.id), by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                throw Problem.duplicate(repeated)
            }
            let folders = (settings ?? []).contains { $0.kind == .folder }
            for command in run.commands {
                let parts = command.program.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
                guard command.program.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
                    throw refuse(.run, "runs “\(command.program)”, which is not a program's absolute path")
                }
                for case .fixed(let text) in command.arguments ?? [] where text.hasPrefix("{") && text.hasSuffix("}") {
                    throw refuse(.run, "gives \(command.id) the argument “\(text)”, which is no slot: {text}, {path} or {folder}")
                }
                if let repeated = Dictionary(grouping: command.slots, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
                    throw refuse(.run, "uses {\(repeated.rawValue)} twice in \(command.id)")
                }
                if !folders, let slot = command.slots.first(where: { $0 != .text }) {
                    throw refuse(.run, "gives \(command.id) a {\(slot.rawValue)}, but it has no folder setting for it to lie inside")
                }
                if let team = command.team, !Self.isTeam(team) {
                    throw refuse(.run, "names “\(team)” as \(command.id)'s team, which is not a team identifier like ABCDE12345")
                }
                if let timeout = command.timeout, !(timeout > 0) {
                    throw refuse(.run, "gives \(command.id) a timeout that is not a number of seconds")
                }
            }
        }
    }

    static func isHostName(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
        }
    }

    static func isScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+.-".contains($0)) }
    }

    static func isTeam(_ team: String) -> Bool {
        team.count == 10 && team.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }
}
