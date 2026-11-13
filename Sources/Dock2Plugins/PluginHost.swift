import AppKit
import Dock2Core
import Dock2System
import Foundation
import UniformTypeIdentifiers

/// What the host hands to the rest of dock2: views to the panel, results to search, tiles to the dock.
@MainActor
public protocol PluginHostDelegate: AnyObject {
    /// A view to show; `summoning` when it answers something the user did, and so may bring dock2 up.
    func plugin(_ id: String, show view: ViewNode, summoning: Bool)
    /// `answering` names the filter it answers, when it answers one.
    func plugin(_ id: String, update view: ViewNode, answering: Int?)
    func pluginPopView(_ id: String)
    func pluginCloseView(_ id: String)
    func pluginDismiss(_ id: String)
    func plugin(_ id: String, results: [PluginResult], for query: Int)
    /// nil takes the tile off.
    func plugin(_ id: String, tile: String, set node: TileNode?)
    func plugin(_ id: String, toast text: String)
    /// The text is on the clipboard: dock2 lets go, then pastes it into the app in front.
    func pluginPaste(_ id: String)
    func pluginDisabled(_ id: String, because reason: String)
    /// Whether a view of the plugin's is on the stack: a plugin showing one is not idle.
    func pluginIsShowing(_ id: String) -> Bool
}

/// The plugin host ([plugins](design/plugins.md#the-host)): an instance per plugin, started at its first event,
/// and every effect it gives checked against what the user granted, then performed.
@MainActor
public final class PluginHost {
    public let store: PluginStore
    private let engine: PluginEngine?
    private let nowPlaying: NowPlaying
    private var instances: [String: PluginInstance] = [:]
    /// Everything each plugin holds open, under the capability that allowed it.
    let resources = PluginResources()
    let xpc = PluginXPC()
    private var concealed: (count: Int, clear: DispatchWorkItem)?
    /// When each instance last heard an event: with what it holds open, what idle is.
    private var lastEvent: [String: Date] = [:]
    private var idleSweep: DispatchSourceTimer?
    /// The Keychain may block — on a prompt, after a signing change — so secrets are read and written off the
    /// main thread, one after another in the order asked.
    private let keychain = DispatchQueue(label: "zip.tanner.dock2.plugin-secrets", qos: .userInitiated)
    public weak var delegate: PluginHostDelegate?

    /// A copy marked concealed is cleared this long after, if nothing was copied since.
    public static let concealedLifetime: TimeInterval = 30
    static let timerLimit = 32
    /// How long an instance with nothing to do stays loaded ([plugins](product/plugins/README.md#lifecycle)).
    static let idleAfter: TimeInterval = 180

    public init(store: PluginStore, nowPlaying: NowPlaying) {
        self.store = store
        self.nowPlaying = nowPlaying
        do {
            engine = try PluginEngine()
        } catch {
            warn("plugins are off: the engine did not start: \(error)")
            engine = nil
        }
        // Read off the main thread at launch: a plugin already running hears them as they come.
        store.onSecureSettings = { [weak self] id in
            guard let self, self.instances[id] != nil else { return }
            self.send(.settings(store.settings(for: id)), to: id)
        }
        // The config file changed what someone chose — by hand, from another Mac, `dock2 plugin`: what ran of
        // each stops, and starts again as the choices now say.
        store.onChoicesChanged = { [weak self] ids in
            guard let self else { return }
            for id in ids { self.stop(id) }
            self.startTiles()
        }
        // A service's news reaches the plugin only while it holds the connection.
        xpc.onEvent = { [weak self] id, event in
            guard let self else { return }
            let service: String, gone: Bool
            switch event {
            case .xpcMessage(let name, _): (service, gone) = (name, false)
            case .xpcClosed(let name, let reason): (service, gone) = (name, reason == "invalid")
            default: return
            }
            let key = PluginResources.Key(.connection, service)
            guard self.resources.holds(key, of: id) else { return }
            if gone { self.resources.release(key, of: id) }
            self.send(event, to: id)
        }
        let sweep = DispatchSource.makeTimerSource(queue: .main)
        sweep.schedule(deadline: .now() + 60, repeating: 60)
        sweep.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.unloadIdle() } }
        sweep.resume()
        idleSweep = sweep
    }

    /// Unloads each instance with nothing to do — no tile on the dock, no view open, nothing held open (a
    /// timer, a subscription, an answer it waits on) — that has heard nothing for `idleAfter`. Its storage
    /// stays; its memory goes, and its next event starts it again.
    func unloadIdle(now: Date = Date()) {
        for id in Array(instances.keys) {
            let tiles = store.plugin(id)?.manifest.tiles?.contains { store.tileOn(id, $0.id) } ?? false
            let busy = tiles || delegate?.pluginIsShowing(id) == true || !resources.isIdle(id)
            guard !busy, now.timeIntervalSince(lastEvent[id] ?? .distantPast) >= Self.idleAfter else { continue }
            instances.removeValue(forKey: id)?.stop()
            storages[id]?.close()
        }
    }

    var loaded: Set<String> { Set(instances.keys) }

    // MARK: - Events

    /// An event for a plugin that is on; its instance starts if it has to.
    public func send(_ event: PluginEvent, to id: String) {
        guard store.isEnabled(id), let instance = instance(id) else { return }
        lastEvent[id] = Date()
        instance.deliver(event, settings: store.settings(for: id), granted: store.granted(id))
    }

    /// An answer to a request the plugin made, if it still waits on it: one ended meanwhile — its capability
    /// revoked, the plugin stopped — is not its news any more.
    private func answer(_ event: PluginEvent, to id: String) {
        guard let request = event.request, resources.release(.init(.request, request), of: id) else { return }
        send(event, to: id)
    }

    /// Waits on an answer to `request`, under the capability that asked for it; `cancel` ends the work.
    private func waitOn(_ request: String, of id: String, under capability: PluginCapability?, cancel: @escaping @MainActor () -> Void = {}) {
        resources.hold(.init(.request, request), of: id, under: capability, end: cancel)
    }

    private func instance(_ id: String) -> PluginInstance? {
        if let instance = instances[id] { return instance }
        guard let engine, let plugin = store.plugin(id) else { return nil }
        let instance = PluginInstance(plugin: plugin, engine: engine, cache: store.cacheDirectory)
        // What an instance answers once it has been stopped — its `stopped`, its last event's — is not acted on.
        instance.onEffects = { [weak self, weak instance] effects, event in
            MainActor.assumeIsolated {
                guard let self, let instance, self.instances[id] === instance else { return }
                self.perform(effects, from: id, answering: event)
            }
        }
        instance.onDisabled = { [weak self] reason in
            MainActor.assumeIsolated { self?.suspend(id, because: reason) }
        }
        instances[id] = instance
        return instance
    }

    /// Off, by the user or for failing: stopped, everything it held open ended, its tiles taken off. What it wrote
    /// is still written, then its storage closes.
    public func stop(_ id: String) {
        instances.removeValue(forKey: id)?.stop()
        lastEvent[id] = nil
        resources.endAll(of: id)
        storages[id]?.close()
        for tile in store.plugin(id)?.manifest.tiles ?? [] { delegate?.plugin(id, tile: tile.id, set: nil) }
    }

    /// Granted or revoked by the person. A revoked capability takes what it held open with it, at once; a
    /// request it was answering is told so.
    public func setGranted(_ id: String, _ capability: PluginCapability, _ on: Bool) {
        choose(id, capability, on) { _ in }
    }

    /// Results are what `query` is for: switching them on grants it, and off revokes it.
    public func setResults(_ id: String, _ on: Bool) {
        choose(id, .query, on) { $0.results = on }
    }

    private func choose(_ id: String, _ capability: PluginCapability, _ on: Bool, also change: (inout PluginChoices) -> Void) {
        let before = store.granted(id)
        store.update(id) { choices in
            change(&choices)
            choices.revoked.removeAll { $0 == capability }
            if !on { choices.revoked.append(capability) }
        }
        if !on {
            for key in resources.end(under: capability, of: id) where key.kind == .request || key.kind == .process {
                send(.error(request: key.name, message: "\(capability.rawValue) was revoked"), to: id)
            }
        }
        // A plugin not running hears it as it starts.
        let after = store.granted(id)
        if after != before, instances[id] != nil { send(.granted(after), to: id) }
    }

    /// Plugins with tiles on the dock start at once, to draw them.
    public func startTiles() {
        for plugin in store.plugins where store.isEnabled(plugin.id) {
            if plugin.manifest.tiles?.contains(where: { store.tileOn(plugin.id, $0.id) }) == true {
                send(.settings(store.settings(for: plugin.id)), to: plugin.id)
            }
        }
    }

    /// dock2 is quitting: what plugins wrote reaches the disk first.
    public func stopAll() {
        for id in instances.keys { stop(id) }
        for storage in storages.values {
            storage.close()
            storage.drain()
        }
    }

    /// Installed from Settings: an older version that was running stops first, so the new code is what
    /// runs next; what the sheet switched off is revoked before it does.
    public func install(_ folder: URL, decisions: [PluginCapability: Bool]) throws {
        let manifest = try store.inspect(folder)
        stop(manifest.id)
        forgetSession(manifest.id)
        try store.install(folder, decisions: decisions)
        startTiles()
    }

    /// A first-party plugin switched on for the first time, its sheet answered.
    public func switchOn(_ id: String, decisions: [PluginCapability: Bool]) {
        store.agree(id, decisions, enabling: true)
        store.resume(id)
        startTiles()
    }

    /// Its storage closed before its data folder goes, the database's `-wal` and `-shm` with it, so none is open.
    public func remove(_ id: String) throws {
        stop(id)
        storages[id]?.drain()
        forgetSession(id)
        try store.remove(id)
    }

    /// `dock2 plugin` installed or removed `id` from a terminal: what ran of it stops — its tiles coming
    /// off while the store still knows them — the store is read again, and tiles start on the new code.
    public func changedElsewhere(_ id: String) {
        stop(id)
        forgetSession(id)
        store.resume(id)
        store.reloadFromDisk()
        startTiles()
    }

    /// Failing over and over: stopped until dock2 quits, it is tried again, or new code is installed. Whether
    /// it is on stays the person's to say.
    private func suspend(_ id: String, because reason: String) {
        store.suspend(id, because: reason)
        stop(id)
        delegate?.pluginDisabled(id, because: reason)
    }

    /// Tried again after failing.
    public func resume(_ id: String) {
        store.resume(id)
        startTiles()
    }

    // MARK: - Effects

    /// Granted: declared in the manifest, and not revoked by the user.
    private func may(_ id: String, _ capability: PluginCapability) -> Bool {
        store.grants(id, capability)
    }

    func perform(_ effects: [PluginEffect], from id: String, answering event: PluginEvent) {
        guard store.isEnabled(id) else { return }
        let acted = userActed(event, from: id)
        for effect in effects {
            if let needed = effect.needs, !may(id, needed) {
                refuse(effect, from: id, "\(needed.rawValue) is not granted")
                continue
            }
            if case .open = effect, acted == nil {
                refuse(effect, from: id, "a URL opens only in answer to something the user did")
                continue
            }
            if let key = effect.secretKey, key.hasPrefix(PluginStore.secureKey("")) {
                refuse(effect, from: id, "secrets named \(PluginStore.secureKey("")) are dock2's: its secure settings")
                continue
            }
            if let acted, let request = effect.request { askedByUser[id, default: [:]][request] = acted }
            perform(effect, from: id, summoning: acted != nil)
        }
    }

    /// Requests made in answer to the user, by plugin and request id, with when the user acted.
    private var askedByUser: [String: [String: Date]] = [:]
    /// How long what the user did stays the cause of the answers to what it asked for.
    static let answerWindow: TimeInterval = 10

    /// The user dismissed dock2 or went to another app: what they did no longer brings dock2 up, or opens
    /// anything, as its answers come.
    public func userMovedOn() {
        askedByUser = [:]
    }

    /// When the user did what `event` answers — an action, or a request one made, lately — or nil.
    private func userActed(_ event: PluginEvent, from id: String) -> Date? {
        let now = Date()
        askedByUser[id] = askedByUser[id]?.filter { now.timeIntervalSince($0.value) < Self.answerWindow }
        if event.isAction { return now }
        guard let request = event.request else { return nil }
        return askedByUser[id]?.removeValue(forKey: request)
    }

    private func refuse(_ effect: PluginEffect, from id: String, _ why: String) {
        warn("plugin \(id): \(why)")
        send(.error(request: effect.request, message: why), to: id)
    }

    private func perform(_ effect: PluginEffect, from id: String, summoning: Bool) {
        switch effect {
        case .showView(let view): delegate?.plugin(id, show: checked(view, from: id), summoning: summoning)
        case .updateView(let view, let answering): delegate?.plugin(id, update: checked(view, from: id), answering: answering)
        case .popView: delegate?.pluginPopView(id)
        case .closeView: delegate?.pluginCloseView(id)
        case .dismiss: delegate?.pluginDismiss(id)
        case .results(let query, let items): delegate?.plugin(id, results: checked(items, from: id), for: query)
        case .setTile(let tile, let node):
            guard store.tileOn(id, tile) else { return }
            delegate?.plugin(id, tile: tile, set: node)
        case .removeTile(let tile): delegate?.plugin(id, tile: tile, set: nil)
        case .setCommands(let shown):
            let declared = store.plugin(id)?.manifest.commands?.map(\.id) ?? []
            let unknown = shown.filter { !declared.contains($0) }
            if !unknown.isEmpty { warn("plugin \(id): no command \(unknown.joined(separator: ", ")) to show") }
            store.showCommands(shown.filter(declared.contains), of: id)
        case .http(let request, let method, let url, let headers, let body, let stream, let socket):
            guard HTTPSyntax.isToken(method), headers.allSatisfy({ HTTPSyntax.isToken($0.key) && HTTPSyntax.isFieldValue($0.value) }) else {
                return refuse(effect, from: id, "its method or a header's name or value is not one HTTP can carry")
            }
            let asked = HTTPAsk(id: request, method: method.uppercased(), url: url, headers: headers, body: body, stream: stream)
            if effect.needs == .localNetwork { fetchLocal(asked, socket: socket, effect, for: id) } else { fetch(asked, effect, for: id) }
        case .webSocketOpen(let socket, let url, let headers, let protocols): openWebSocket(socket, url, headers, protocols, effect, for: id)
        case .webSocketSend(let socket, let text, let data):
            guard let open = webSockets[id]?[socket] else { return refuse(effect, from: id, "no WebSocket \(socket) is open") }
            open.send(text: text, data: data)
        case .webSocketClose(let socket): webSockets[id]?[socket]?.close()
        case .storageGet(let request, let key): onStorage(request, for: id) { .storage(request: request, key: key, value: try $0.read([key]).first?.value) }
        case .storageSet(let key, let value): onStorage(nil, for: id) { try $0.write([.set(key: key, value: value)]); return nil }
        case .storageDelete(let key): onStorage(nil, for: id) { try $0.write([.delete(key: key)]); return nil }
        case .storageRead(let request, let keys): onStorage(request, for: id) { .storageRead(request: request, entries: try $0.read(keys)) }
        case .storageList(let listing):
            onStorage(listing.request, for: id) { storage in
                let (entries, more) = try storage.list(listing)
                return .storageListed(request: listing.request, entries: entries, more: more)
            }
        case .storageWrite(let request, let ops):
            onStorage(request, for: id) { storage in
                try storage.write(ops)
                return request.map { .storageWritten(request: $0) }
            }
        case .secretGet(let request, let key):
            let secrets = secrets(id)
            waitOn(request, of: id, under: .secrets)
            keychain.async { [weak self] in
                let value = secrets.get(key)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.answer(.secret(request: request, key: key, value: value), to: id) } }
            }
        case .secretSet(let key, let value):
            let secrets = secrets(id)
            keychain.async { secrets.set(key, value) }
        case .secretDelete(let key):
            let secrets = secrets(id)
            keychain.async { secrets.set(key, nil) }
        case .copy(let text, let isConcealed): copy(text, concealed: isConcealed)
        case .paste(let text, let isConcealed):
            copy(text, concealed: isConcealed)
            delegate?.pluginPaste(id)
        case .open(let url, let app): open(url, in: app, for: id)
        case .toast(let text): delegate?.plugin(id, toast: text)
        case .timer(let timer, let ms, let repeats): schedule(timer, ms: ms, repeats: repeats, for: id)
        case .cancelTimer(let timer): resources.end(.init(.timer, timer), of: id)
        case .subscribe(let event):
            let key = PluginResources.Key(.subscription, event)
            guard event == "nowPlaying", !resources.holds(key, of: id) else { return }
            // Held before observing: the state now arrives as the observation starts.
            resources.hold(key, of: id, under: .nowPlaying)
            let observation = nowPlaying.observe { [weak self] info in
                guard let self, self.resources.holds(key, of: id) else { return }
                self.send(.nowPlaying(info), to: id)
            }
            resources.hold(key, of: id, under: .nowPlaying) { observation.end() }
        case .nowPlaying(let command, let seconds): nowPlaying.send(command, seconds: seconds)
        case .derive(let derivation): derive(derivation, for: id)
        case .xpcSend(let request, let service, let message): sendXPC(request, service, message, for: id)
        case .run(let request, let command, let values, let arguments, let stdin): run(request, command, values, arguments, stdin, for: id)
        case .cancelRun(let request): running[id]?[request]?.stop()
        case .fileRead(let request, let path, let offset, let length):
            onFiles(effect, request, path, for: id) { resolved in
                let (data, size) = try PluginFiles.read(resolved, offset: offset ?? 0, length: length)
                return .fileRead(request: request, path: resolved, data: data, size: size)
            }
        case .fileList(let request, let path):
            onFiles(effect, request, path, for: id) { resolved in
                let (entries, truncated) = try PluginFiles.list(resolved)
                return .fileListed(request: request, path: resolved, entries: entries, truncated: truncated)
            }
        case .fileStat(let request, let path):
            onFiles(effect, request, path, for: id) { .fileStat(request: request, path: $0, entry: PluginFiles.entry($0)) }
        case .fileWrite(let request, let path, let data, let append):
            onFiles(effect, request, path, writing: true, for: id) { resolved in
                try PluginFiles.write(data, to: resolved, append: append)
                return .fileWritten(request: request, path: resolved)
            }
        case .watch(let watch, let path): self.watch(watch, path, for: id)
        case .unwatch(let watch): resources.end(.init(.watch, watch), of: id)
        }
    }

    /// A view without the chords that are dock2's: the actions stay, on ⌘K.
    private func checked(_ view: ViewNode, from id: String) -> ViewNode {
        let (node, refused) = view.withoutReservedChords()
        warnRefused(refused, from: id)
        if case .list(let list) = node, list.flowHidesChildren { warn("plugin \(id): \(list.id) is a flow, which shows no items under items") }
        return node
    }

    /// Results' actions under the same rule as a view's: search's field keeps its text keys.
    private func checked(_ results: [PluginResult], from id: String) -> [PluginResult] {
        var refused: [String] = []
        let cleaned = results.map { result in
            var result = result
            result.actions = result.actions?.withoutReservedChords(&refused)
            return result
        }
        warnRefused(refused, from: id)
        return cleaned
    }

    private func warnRefused(_ refused: [String], from id: String) {
        if !refused.isEmpty { warn("plugin \(id): \(refused.joined(separator: ", ")) not bound — dock2's own, or not ⌘ or ⌘⇧ with a letter") }
    }

    // MARK: - Network

    /// An `http` effect's request, whichever way it goes.
    private struct HTTPAsk {
        let id: String
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data?
        let stream: Bool
    }

    /// Each plugin's own: no cookie, cache or credential of one plugin's goes with another's requests.
    private var sessions: [String: URLSession] = [:]

    /// New code, or none: what the old kept goes.
    private func forgetSession(_ id: String) {
        sessions.removeValue(forKey: id)?.invalidateAndCancel()
    }

    private func session(for id: String) -> URLSession {
        if let session = sessions[id] { return session }
        let session = URLSession(configuration: .ephemeral)
        sessions[id] = session
        return session
    }

    /// The most WebSockets one plugin holds open.
    static let webSocketLimit = 8
    /// Each plugin's open WebSockets, by id: what `webSocketSend` and `webSocketClose` reach.
    private var webSockets: [String: [String: PluginWebSocket]] = [:]

    /// A part of a streamed answer reaches the plugin only while it waits on its request; the end is the answer.
    private func streamed(_ request: String, for id: String) -> @MainActor @Sendable (PluginEvent) -> Void {
        { [weak self] event in
            guard let self else { return }
            if case .httpPart = event {
                if self.resources.holds(.init(.request, request), of: id) { self.send(event, to: id) }
            } else {
                self.answer(event, to: id)
            }
        }
    }

    /// To the hosts the manifest names, over HTTPS — a redirect too; the answer comes back as an event, whole or
    /// in parts.
    private func fetch(_ asked: HTTPAsk, _ effect: PluginEffect, for id: String) {
        guard let plugin = store.plugin(id) else { return }
        let allowed = plugin.manifest.allowedHosts(settings: store.settings(for: id))
        guard let target = URL(string: asked.url), target.scheme?.lowercased() == "https", RedirectGuard.mayReach(target, allowed) else {
            return refuse(effect, from: id, "\(asked.url) is not a host it may reach over HTTPS")
        }
        var call = URLRequest(url: target, timeoutInterval: 30)
        call.httpMethod = asked.method
        call.httpBody = asked.body
        for (name, value) in asked.headers { call.setValue(value, forHTTPHeaderField: name) }
        let task = session(for: id).dataTask(with: call)
        task.delegate = ResponseReader(request: asked.id, allowed: allowed, stream: asked.stream, deliver: streamed(asked.id, for: id))
        waitOn(asked.id, of: id, under: .network) { task.cancel() }
        task.resume()
    }

    /// Plain HTTP to a `host:port` `local-network` names, on this Mac or the local network, or over a socket it names.
    private func fetchLocal(_ asked: HTTPAsk, socket: String?, _ effect: PluginEffect, for id: String) {
        guard let plugin = store.plugin(id), let local = plugin.manifest.capabilities.localNetwork else { return }
        guard let target = URL(string: asked.url), target.scheme?.lowercased() == "http" else {
            return refuse(effect, from: id, "\(asked.url): local-network speaks plain HTTP, its host naming the socket's server")
        }
        let destination: LocalHTTP.Target
        if let socket {
            let path = Self.expandingHome(socket)
            guard (local.sockets ?? []).map(Self.expandingHome).contains(path) else { return refuse(effect, from: id, "\(socket) is not a socket it names") }
            destination = .socket(path)
        } else {
            let settings = store.settings(for: id)
            let allowed = (local.hosts ?? []).compactMap { host in
                host.hasPrefix("$") ? settings[String(host.dropFirst())].flatMap { HostPort(setting: $0) } : HostPort(host)
            }
            guard let host = target.host, let port = UInt16(exactly: target.port ?? 80), case let address = HostPort(host: host, port: port),
                  allowed.contains(address), address.isLocal else {
                return refuse(effect, from: id, "\(asked.url) is not on a host it may reach")
            }
            destination = .host(address)
        }
        let client = LocalHTTP(destination, .init(id: asked.id, method: asked.method, url: target, headers: asked.headers, body: asked.body, stream: asked.stream),
                               deliver: streamed(asked.id, for: id))
        waitOn(asked.id, of: id, under: .localNetwork) { client.cancel() }
        client.start()
    }

    /// `~/` as the home folder, as a manifest may spell a socket.
    static func expandingHome(_ path: String) -> String {
        path.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst() : path
    }

    /// Over TLS to a host the manifest names, held under `network` until it closes; its news while held.
    private func openWebSocket(_ socket: String, _ url: String, _ headers: [String: String], _ protocols: [String], _ effect: PluginEffect,
                               for id: String) {
        guard let plugin = store.plugin(id) else { return }
        let allowed = plugin.manifest.allowedHosts(settings: store.settings(for: id))
        guard let target = URL(string: url), target.scheme?.lowercased() == "wss", RedirectGuard.mayReach(target, allowed) else {
            return refuse(effect, from: id, "\(url) is not a host it may reach over a secure WebSocket")
        }
        let key = PluginResources.Key(.webSocket, socket)
        guard resources.holds(key, of: id) || resources.keys(.webSocket, of: id).count < Self.webSocketLimit else {
            return refuse(effect, from: id, "it holds \(Self.webSocketLimit) WebSockets open already")
        }
        var call = URLRequest(url: target)
        for (name, value) in headers { call.setValue(value, forHTTPHeaderField: name) }
        if !protocols.isEmpty { call.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol") }
        let open = PluginWebSocket(id: socket, allowed: allowed) { [weak self] source, event in
            guard let self, self.webSockets[id]?[socket] === source, self.resources.holds(key, of: id) else { return }
            if case .webSocketClosed = event {
                self.webSockets[id]?[socket] = nil
                self.resources.release(key, of: id)
            }
            self.send(event, to: id)
        }
        resources.hold(key, of: id, under: .network) { [weak self] in
            open.close()
            if self?.webSockets[id]?[socket] === open { self?.webSockets[id]?[socket] = nil }
        }
        webSockets[id, default: [:]][socket] = open
        open.open(call, in: session(for: id))
    }

    // MARK: - Commands

    /// dock2's limit on how long a command runs, whatever its manifest says.
    static let runLimit: TimeInterval = 60
    /// The most commands one plugin runs at once.
    static let processLimit = 8
    /// The commands each plugin has running, by request: what `cancelRun` and the time limit stop.
    private var running: [String: [String: RunningCommand]] = [:]

    /// A command the manifest declares, its slots filled — a path or a folder inside a folder one of its folder
    /// settings holds — and its program signed by the team it names, checked off the main thread before it
    /// spawns. Held under `run` from the moment it is asked for, so a revoke mid-spawn still ends it.
    private func run(_ request: String, _ name: String, _ values: [String: String], _ arguments: [String]?, _ stdin: Data?, for id: String) {
        let effect = PluginEffect.run(request: request, command: name, values: values, arguments: arguments, stdin: stdin)
        guard let plugin = store.plugin(id), let command = plugin.manifest.capabilities.run?.command(name) else {
            refuse(effect, from: id, "\(name) is not a command it declares")
            return
        }
        let key = PluginResources.Key(.process, request)
        guard resources.holds(key, of: id) || resources.keys(.process, of: id).count < Self.processLimit else {
            return refuse(effect, from: id, "it runs \(Self.processLimit) commands already")
        }
        let settings = store.settings(for: id)
        let folders = (plugin.manifest.settings ?? []).filter { $0.kind == .folder }.compactMap { settings[$0.id] }.filter { !$0.isEmpty }
        let job = RunningCommand()
        resources.hold(key, of: id, under: .run) { [weak self] in
            job.stop()
            if self?.running[id]?[request] === job { self?.running[id]?[request] = nil }
        }
        running[id, default: [:]][request] = job
        let onOutput: @MainActor @Sendable (String, Data) -> Void = { [weak self] stream, data in
            guard let self, self.resources.holds(key, of: id), self.running[id]?[request] === job else { return }
            self.send(.output(request: request, stream: stream, data: data), to: id)
        }
        let onExit: @MainActor @Sendable (PluginProcess.Ending, Bool) -> Void = { [weak self] ending, truncated in
            guard let self, self.running[id]?[request] === job else { return }
            self.running[id]?[request] = nil
            guard self.resources.release(key, of: id) else { return }
            let (status, signal): (Int?, Int?) = switch ending {
            case .status(let status): (status, nil)
            case .signal(let signal): (nil, signal)
            }
            self.send(.exited(request: request, status: status, signal: signal, truncated: truncated, timedOut: job.timedOut), to: id)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = Result {
                let invocation = try CommandGuard.invocation(of: command, values: values, arguments: arguments, folders: PathGuard(folders: folders))
                return try PluginProcess.spawn(invocation, team: command.team, stdin: stdin, onOutput: onOutput, onExit: onExit)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch started {
                    case .success(let process):
                        job.started(process)
                        let limit = min(command.timeout ?? Self.runLimit, Self.runLimit)
                        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { MainActor.assumeIsolated { job.timeOut() } }
                    case .failure(let error):
                        guard self.running[id]?[request] === job else { return }
                        self.running[id]?[request] = nil
                        guard self.resources.release(key, of: id) else { return }
                        self.send(.error(request: request, message: "\(name): \(error.localizedDescription)"), to: id)
                    }
                }
            }
        }
    }

    // MARK: - Files

    /// The most folders one plugin watches at once.
    static let watchLimit = 8
    /// What each plugin watches, by watch id: what a folder setting changing may take away.
    private(set) var watched: [String: [String: String]] = [:]
    /// Reads and writes in the order asked, off the main thread: a folder macOS guards may prompt and wait.
    private let fileQueue = DispatchQueue(label: "zip.tanner.dock2.plugin-files", qos: .userInitiated)

    /// The folders its `files` reaches: those its folder settings named there hold.
    private func grantedFolders(_ id: String) -> [String] {
        let settings = store.settings(for: id)
        return (store.plugin(id)?.manifest.capabilities.files?.folders ?? []).compactMap { settings[String($0.dropFirst())] }.filter { !$0.isEmpty }
    }

    /// `work` on the path as `PathGuard` resolves it inside a granted folder, off the main thread; its event, or
    /// why not, comes back as the answer to `request`.
    private func onFiles(_ effect: PluginEffect, _ request: String, _ path: String, writing: Bool = false, for id: String,
                         _ work: @escaping @Sendable (String) throws -> PluginEvent) {
        if writing, store.plugin(id)?.manifest.capabilities.files?.write != true {
            refuse(effect, from: id, "its files are its to read, not to write")
            return
        }
        let folders = grantedFolders(id), ended = Ended()
        waitOn(request, of: id, under: .files) { ended.set() }
        fileQueue.async { [weak self] in
            // Revoked or stopped while it waited its turn: a write never lands after.
            guard !ended.value else { return }
            let event: PluginEvent
            do { event = try work(try PathGuard(folders: folders).reach(path)) } catch {
                event = .error(request: request, message: "\(path): \(error.localizedDescription)")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.answer(event, to: id) } }
        }
    }

    /// A folder inside a granted one, its changes as `fileChanged`, held under `files` until `unwatch`.
    private func watch(_ watch: String, _ path: String, for id: String) {
        let key = PluginResources.Key(.watch, watch)
        guard resources.holds(key, of: id) || resources.keys(.watch, of: id).count < Self.watchLimit else {
            refuse(.watch(id: watch, path: path), from: id, "it watches \(Self.watchLimit) folders already")
            return
        }
        let folders = grantedFolders(id), pending = Ended()
        // Held while it resolves, so a limit, a revoke or a stop meanwhile counts it.
        resources.hold(key, of: id, under: .files) { pending.set() }
        fileQueue.async { [weak self] in
            let reached = Result { () throws -> String in
                let resolved = try PathGuard(folders: folders).reach(path)
                guard PluginFiles.entry(resolved)?.kind == .folder else { throw PluginFailure("not a folder") }
                return resolved
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !pending.value else { return }
                    switch reached {
                    case .failure(let error):
                        self.resources.release(key, of: id)
                        self.send(.error(request: watch, message: "\(path): \(error.localizedDescription)"), to: id)
                    case .success(let folder):
                        // A folder setting moved meanwhile: what it no longer grants is not watched.
                        guard PathGuard(folders: self.grantedFolders(id)).admits(folder) else {
                            self.resources.release(key, of: id)
                            return
                        }
                        self.startWatching(watch, folder, key: key, for: id)
                    }
                }
            }
        }
    }

    private func startWatching(_ watch: String, _ folder: String, key: PluginResources.Key, for id: String) {
        let watcher = FolderWatcher(paths: [folder], latency: 0.3, files: true) { [weak self] paths in
            guard let self, self.resources.holds(key, of: id) else { return }
            let inside = paths.filter { $0 == folder || $0.hasPrefix(folder + "/") }
            if !inside.isEmpty { self.send(.fileChanged(watch: watch, paths: inside), to: id) }
        }
        resources.hold(key, of: id, under: .files) { [weak self] in
            watcher.stop()
            self?.watched[id]?[watch] = nil
        }
        watched[id, default: [:]][watch] = folder
    }

    /// A setting changed, the plugin hears it; a folder setting changing ends the watches it no longer grants.
    public func setSetting(_ id: String, _ key: String, _ value: String) {
        store.setSetting(id, key, value)
        let folders = PathGuard(folders: grantedFolders(id))
        for (watch, folder) in watched[id] ?? [:] where !folders.admits(folder) {
            resources.end(.init(.watch, watch), of: id)
        }
        send(.settings(store.settings(for: id)), to: id)
    }

    // MARK: - Services

    /// How long a service has to reply before the plugin hears that it did not.
    static let xpcReplyWindow: TimeInterval = 30

    /// To a service the manifest names, as a dictionary, with the plugin's id set over whatever the plugin put
    /// there: the service hears dock2, and is told which plugin speaks.
    private func sendXPC(_ request: String?, _ name: String, _ message: JSONValue, for id: String) {
        let effect = PluginEffect.xpcSend(request: request, service: name, message: message)
        guard let service = store.plugin(id)?.manifest.capabilities.xpc?.service(name) else {
            refuse(effect, from: id, "\(name) is not a service it names")
            return
        }
        guard case .object = message, case .dictionary(var entries)? = try? XPCValue(json: message) else {
            refuse(effect, from: id, "a message to \(name) is a dictionary of values XPC carries")
            return
        }
        entries["dock2.plugin"] = .string(id)
        let connection = PluginResources.Key(.connection, name)
        if !resources.holds(connection, of: id) {
            resources.hold(connection, of: id, under: .xpc) { [weak self] in self?.xpc.close(name, of: id) }
        }
        guard let request else {
            xpc.send(.dictionary(entries), to: service, from: id, reply: nil)
            return
        }
        let late = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resources.release(.init(.request, request), of: id) else { return }
                self.send(.error(request: request, message: "\(name) did not reply in \(Int(Self.xpcReplyWindow)) seconds"), to: id)
            }
        }
        waitOn(request, of: id, under: .xpc) { late.cancel() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.xpcReplyWindow, execute: late)
        xpc.send(.dictionary(entries), to: service, from: id) { [weak self] result in
            late.cancel()
            switch result {
            case .success(let reply): self?.answer(.xpcReply(request: request, service: name, message: reply.json), to: id)
            case .failure(let refusal): self?.answer(.error(request: request, message: refusal.message), to: id)
            }
        }
    }

    /// Off the main thread: Argon2 takes its memory and its time.
    private func derive(_ derivation: Derivation, for id: String) {
        guard derivation.isReasonable else {
            refuse(.derive(derivation), from: id, "a derivation past what dock2 will spend")
            return
        }
        waitOn(derivation.request, of: id, under: nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = PluginEngine.derive(derivation)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let key {
                        self.answer(.derived(request: derivation.request, key: key), to: id)
                    } else {
                        self.answer(.error(request: derivation.request, message: "the key could not be derived"), to: id)
                    }
                }
            }
        }
    }

    /// What opening `url` comes to: a web page or a document; with `apps`, a link of a scheme it names, or a file
    /// in an app it names. Never a program: an app, an executable or a script, nor an app that runs what it opens,
    /// however it is reached ([permissions](product/plugins/permissions.md#never)).
    enum Opening: Equatable {
        case url(URL)
        case file(URL, in: URL)
    }

    nonisolated static func opening(_ url: String, in app: String?, apps: PluginManifest.Capabilities.Apps?,
                                    appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
                                    handler: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) },
                                    runs: (URL) -> Bool = runsWhatItOpens) -> Result<Opening, PluginFailure> {
        func refuse(_ message: String) -> Result<Opening, PluginFailure> { .failure(PluginFailure(message)) }
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased() else { return refuse("\(url) is not a URL") }
        if let app {
            guard (apps?.apps ?? []).contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }), !PluginManifest.Capabilities.Apps.runs(app) else {
                return refuse("\(app) is not an app it names")
            }
            guard let location = appURL(app) else { return refuse("\(app) is not on this Mac") }
            guard !runs(location) else { return refuse("\(app) runs what it opens") }
            guard target.isFileURL, FileManager.default.fileExists(atPath: target.path) else { return refuse("\(url) is not a file") }
            return .success(.file(target, in: location))
        }
        if scheme == "https" || scheme == "http" { return .success(.url(target)) }
        if target.isFileURL {
            guard isDocument(target), let opener = handler(target), !runs(opener) else { return refuse("\(url) is not a document") }
            return .success(.url(target))
        }
        guard (apps?.schemes ?? []).contains(where: { $0.lowercased() == scheme }) else {
            return refuse("\(url) is not a page, a document or a link of a scheme it names")
        }
        guard let opener = handler(target) else { return refuse("nothing on this Mac opens \(scheme): links") }
        guard !runs(opener) else {
            return refuse("\(scheme): links open in \(Bundle(url: opener)?.bundleIdentifier ?? opener.lastPathComponent), which runs what it opens")
        }
        return .success(.url(target))
    }

    /// Whether an app runs what it opens: one known to, or one that says so — a document type in the Shell role,
    /// as Terminal and Ghostty declare, or a program, an app or a script it views rather than edits, as
    /// JavaLauncher does a jar. An editor of scripts runs none by opening one.
    nonisolated static func runsWhatItOpens(_ app: URL) -> Bool {
        let bundle = Bundle(url: app)
        if let id = bundle?.bundleIdentifier, PluginManifest.Capabilities.Apps.runs(id) { return true }
        let running: [UTType] = [.executable, .application, .script]
        for type in bundle?.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? [] {
            let role = type["CFBundleTypeRole"] as? String
            if role == "Shell" { return true }
            guard role != "Editor" else { continue }
            let named = (type["LSItemContentTypes"] as? [String] ?? []).compactMap { UTType($0) }
                + (type["CFBundleTypeExtensions"] as? [String] ?? []).compactMap { UTType(filenameExtension: $0) }
            if named.contains(where: { kind in running.contains { kind.conforms(to: $0) } }) { return true }
        }
        return false
    }

    private func open(_ url: String, in app: String?, for id: String) {
        switch Self.opening(url, in: app, apps: store.plugin(id)?.manifest.capabilities.apps) {
        case .success(.url(let target)): NSWorkspace.shared.open(target)
        case .success(.file(let file, let app)): NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        case .failure(let refusal): refuse(.open(url: url, app: app), from: id, refusal.message)
        }
    }

    /// Content — text, pictures, documents — by allowlist: Terminal settings, Finder's location files,
    /// workflows, installers and apps are not content; scripts are, and are refused, as are what installs a
    /// profile or runs a shortcut when opened.
    nonisolated static func isDocument(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType, type.conforms(to: .content) else { return false }
        let acting = ["com.apple.mobileconfig", "com.apple.configprofile", "com.apple.provisionprofile", "com.apple.shortcut",
                      "com.sun.java-web-start"].compactMap { UTType($0) }
        guard !type.conforms(to: .script), !type.conforms(to: .executable), !acting.contains(where: { type.conforms(to: $0) }) else { return false }
        return !FileManager.default.isExecutableFile(atPath: url.path)
    }

    // MARK: - Storage and secrets

    /// Each plugin's storage while dock2 runs, its queue keeping the order of what was asked across a stop.
    private var storages: [String: PluginStorage] = [:]

    func storage(_ id: String) -> PluginStorage {
        if let storage = storages[id] { return storage }
        let storage = PluginStorage(directory: store.dataDirectory.appendingPathComponent(id, isDirectory: true), label: id)
        storages[id] = storage
        return storage
    }

    /// `work` on the plugin's storage after all it asked before; its event, or why not, comes back as the answer to
    /// `request`. Without a request, only a failure comes back, if the plugin is still running to hear it.
    private func onStorage(_ request: String?, for id: String, _ work: @escaping @Sendable (PluginStorage) throws -> PluginEvent?) {
        if let request { waitOn(request, of: id, under: nil) }
        storage(id).async { [weak self] storage in
            let event: PluginEvent?
            do { event = try work(storage) } catch { event = .error(request: request, message: error.localizedDescription) }
            guard let event else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if request != nil { return self.answer(event, to: id) }
                    if case .error(_, let message) = event { warn("plugin \(id): \(message)") }
                    if self.instances[id] != nil { self.send(event, to: id) }
                }
            }
        }
    }

    private func secrets(_ id: String) -> PluginSecrets {
        PluginSecrets(plugin: id, directory: store.dataDirectory.appendingPathComponent(id, isDirectory: true))
    }

    // MARK: - The clipboard, timers

    private func copy(_ text: String, concealed: Bool) {
        let count = OwnWrite.write { pasteboard in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if concealed { item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
            pasteboard.writeObjects([item])
        }
        self.concealed?.clear.cancel()
        self.concealed = nil
        guard concealed else { return }
        let clear = DispatchWorkItem { [weak self] in
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
            self?.concealed = nil
        }
        self.concealed = (count, clear)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.concealedLifetime, execute: clear)
    }

    private func schedule(_ timer: String, ms: Int, repeats: Bool, for id: String) {
        let key = PluginResources.Key(.timer, timer)
        resources.end(key, of: id)
        guard resources.keys(.timer, of: id).count < Self.timerLimit else {
            warn("plugin \(id): more than \(Self.timerLimit) timers")
            return
        }
        // A tenth of a second at the least: a plugin is not a busy loop.
        let interval = DispatchTimeInterval.milliseconds(max(ms, 100))
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: repeats ? interval : .never)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, repeats ? self.resources.holds(key, of: id) : self.resources.release(key, of: id) else { return }
                self.send(.timer(id: timer), to: id)
            }
        }
        resources.hold(key, of: id, under: nil) { source.cancel() }
        source.resume()
    }
}

/// Set once, from the main actor, when what was asked for ended; read on the queue doing the work.
final class Ended: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    var value: Bool { lock.withLock { ended } }

    func set() { lock.withLock { ended = true } }
}

/// A command a plugin asked to run, from the moment it asked: stopping it before it has spawned stops it as
/// it does.
@MainActor
final class RunningCommand {
    private var process: PluginProcess?
    private var stopping = false
    private(set) var timedOut = false

    func started(_ process: PluginProcess) {
        self.process = process
        if stopping { process.terminate() }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    func timeOut() {
        guard !stopping, process != nil else { return }
        timedOut = true
        stop()
    }
}

/// A plugin's secrets: Keychain items under dock2's service and its id inside the bundle; outside it, a
/// file only the user can read, since the Keychain would ask every rebuilt build.
struct PluginSecrets {
    let plugin: String
    let directory: URL

    private var inBundle: Bool { Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier }
    private var service: String { "\(Dock2Identity.bundleIdentifier).plugin.\(plugin)" }
    private var file: URL { directory.appendingPathComponent("secrets.json") }

    func get(_ key: String) -> String? {
        if inBundle {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: key, kSecReturnData as String: true]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return fileValues()[key]
    }

    func set(_ key: String, _ value: String?) {
        if inBundle {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
            SecItemDelete(query as CFDictionary)
            guard let value else { return }
            var add = query
            add[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(add as CFDictionary, nil)
            return
        }
        var values = fileValues()
        values[key] = value
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func clear() {
        if inBundle {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
        try? FileManager.default.removeItem(at: file)
    }

    private func fileValues() -> [String: String] {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
}
