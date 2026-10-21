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
    private var timers: [String: [String: DispatchSourceTimer]] = [:]
    private var subscriptions: [String: NowPlaying.Observation] = [:]
    private var concealed: (count: Int, clear: DispatchWorkItem)?
    /// When each instance last heard an event, and its requests not yet answered: what idle is.
    private var lastEvent: [String: Date] = [:]
    private var inFlight: [String: Set<String>] = [:]
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
        let sweep = DispatchSource.makeTimerSource(queue: .main)
        sweep.schedule(deadline: .now() + 60, repeating: 60)
        sweep.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.unloadIdle() } }
        sweep.resume()
        idleSweep = sweep
    }

    /// Unloads each instance with nothing to do — no tile on the dock, no view open, no timer, no
    /// subscription, no request unanswered — that has heard nothing for `idleAfter`. Its storage stays; its
    /// memory goes, and its next event starts it again.
    func unloadIdle(now: Date = Date()) {
        for id in Array(instances.keys) {
            let tiles = store.plugin(id)?.manifest.tiles?.contains { store.tileOn(id, $0.id) } ?? false
            let busy = tiles || delegate?.pluginIsShowing(id) == true || !(timers[id]?.isEmpty ?? true)
                || subscriptions[id] != nil || !(inFlight[id]?.isEmpty ?? true)
            guard !busy, now.timeIntervalSince(lastEvent[id] ?? .distantPast) >= Self.idleAfter else { continue }
            instances.removeValue(forKey: id)?.stop()
        }
    }

    var loaded: Set<String> { Set(instances.keys) }

    // MARK: - Events

    /// An event for a plugin that is on; its instance starts if it has to.
    public func send(_ event: PluginEvent, to id: String) {
        guard store.isEnabled(id), let instance = instance(id) else { return }
        lastEvent[id] = Date()
        if let request = event.request { inFlight[id]?.remove(request) }
        instance.deliver(event, settings: store.settings(for: id))
    }

    private func instance(_ id: String) -> PluginInstance? {
        if let instance = instances[id] { return instance }
        guard let engine, let plugin = store.plugin(id) else { return nil }
        let instance = PluginInstance(plugin: plugin, engine: engine, cache: store.cacheDirectory)
        instance.onEffects = { [weak self] effects, event in
            MainActor.assumeIsolated { self?.perform(effects, from: id, answering: event) }
        }
        instance.onDisabled = { [weak self] reason in
            MainActor.assumeIsolated { self?.disable(id, because: reason) }
        }
        instances[id] = instance
        return instance
    }

    /// Off, by the user or for failing: stopped, its timers and subscriptions ended, its tiles taken off.
    public func stop(_ id: String) {
        instances.removeValue(forKey: id)?.stop()
        inFlight[id] = nil
        lastEvent[id] = nil
        timers.removeValue(forKey: id)?.values.forEach { $0.cancel() }
        subscriptions.removeValue(forKey: id)?.end()
        for tile in store.plugin(id)?.manifest.tiles ?? [] { delegate?.plugin(id, tile: tile.id, set: nil) }
    }

    /// Plugins with tiles on the dock start at once, to draw them.
    public func startTiles() {
        for plugin in store.plugins where store.isEnabled(plugin.id) {
            if plugin.manifest.tiles?.contains(where: { store.tileOn(plugin.id, $0.id) }) == true {
                send(.settings(store.settings(for: plugin.id)), to: plugin.id)
            }
        }
    }

    public func stopAll() {
        for id in instances.keys { stop(id) }
    }

    /// Installed from Settings: an older version that was running stops first, so the new code is what
    /// runs next.
    public func install(_ folder: URL) throws {
        let manifest = try store.inspect(folder)
        stop(manifest.id)
        try store.install(folder)
        startTiles()
    }

    public func remove(_ id: String) throws {
        stop(id)
        try store.remove(id)
    }

    /// `dock2 plugin` installed or removed `id` from a terminal: what ran of it stops — its tiles coming
    /// off while the store still knows them — the store is read again, and tiles start on the new code.
    public func changedElsewhere(_ id: String) {
        stop(id)
        store.reloadFromDisk()
        startTiles()
    }

    private func disable(_ id: String, because reason: String) {
        store.update(id) {
            $0.enabled = false
            $0.disabledBecause = reason
        }
        stop(id)
        delegate?.pluginDisabled(id, because: reason)
    }

    // MARK: - Effects

    /// Granted: declared in the manifest, and approved by the user.
    private func may(_ id: String, _ capability: PluginCapability) -> Bool {
        store.plugin(id)?.manifest.capabilities.contains(capability) == true && store.choices[id]?.granted.contains(capability) == true
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
            if let request = effect.request { inFlight[id, default: []].insert(request) }
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
        case .http(let request, let method, let url, let headers, let body): fetch(request, method, url, headers, body, for: id)
        case .storageGet(let request, let key): send(.storage(request: request, key: key, value: storage(id)[key]), to: id)
        case .storageSet(let key, let value): updateStorage(id) { $0[key] = value }
        case .storageDelete(let key): updateStorage(id) { $0[key] = nil }
        case .secretGet(let request, let key):
            let secrets = secrets(id)
            keychain.async { [weak self] in
                let value = secrets.get(key)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(.secret(request: request, key: key, value: value), to: id) } }
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
        case .open(let url): open(url, for: id)
        case .toast(let text): delegate?.plugin(id, toast: text)
        case .timer(let timer, let ms, let repeats): schedule(timer, ms: ms, repeats: repeats, for: id)
        case .cancelTimer(let timer): timers[id]?.removeValue(forKey: timer)?.cancel()
        case .subscribe(let event):
            guard event == "nowPlaying", subscriptions[id] == nil else { return }
            subscriptions[id] = nowPlaying.observe { [weak self] info in self?.send(.nowPlaying(info), to: id) }
        case .nowPlaying(let command, let seconds): nowPlaying.send(command, seconds: seconds)
        case .derive(let derivation): derive(derivation, for: id)
        }
    }

    /// A view without the chords that are dock2's: the actions stay, on ⌘K.
    private func checked(_ view: ViewNode, from id: String) -> ViewNode {
        let (node, refused) = view.withoutReservedChords()
        warnRefused(refused, from: id)
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

    /// To the hosts the manifest names, over HTTPS — a redirect too; the answer comes back as an event.
    private func fetch(_ request: String, _ method: String, _ url: String, _ headers: [String: String], _ body: Data?, for id: String) {
        guard let plugin = store.plugin(id) else { return }
        guard let target = URL(string: url) else {
            refuse(.http(request: request, method: method, url: url, headers: headers, body: body), from: id, "\(url) is not a URL")
            return
        }
        let allowed = plugin.manifest.allowedHosts(settings: store.settings(for: id))
        guard RedirectGuard.mayReach(target, allowed) else {
            refuse(.http(request: request, method: method, url: url, headers: headers, body: body), from: id, "\(url) is not a host it may reach")
            return
        }
        var call = URLRequest(url: target, timeoutInterval: 30)
        call.httpMethod = method
        call.httpBody = body
        for (name, value) in headers { call.setValue(value, forHTTPHeaderField: name) }
        let task = URLSession.shared.dataTask(with: call) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            var answer: [String: String] = [:]
            for (name, value) in (response as? HTTPURLResponse)?.allHeaderFields ?? [:] {
                if let name = name as? String, let value = value as? String { answer[name] = value }
            }
            let event = PluginEvent.http(request: request, status: status, headers: answer, body: data, error: error?.localizedDescription)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(event, to: id) } }
        }
        task.delegate = RedirectGuard(allowed: allowed)
        task.resume()
    }

    /// Off the main thread: Argon2 takes its memory and its time.
    private func derive(_ derivation: Derivation, for id: String) {
        guard derivation.isReasonable else {
            refuse(.derive(derivation), from: id, "a derivation past what dock2 will spend")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let key = PluginEngine.derive(derivation)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let key {
                        self.send(.derived(request: derivation.request, key: key), to: id)
                    } else {
                        self.send(.error(request: derivation.request, message: "the key could not be derived"), to: id)
                    }
                }
            }
        }
    }

    /// A web page, or a document in its app; never a program — an app, an executable or a script would run
    /// one ([permissions](product/plugins/permissions.md#never)).
    private func open(_ url: String, for id: String) {
        guard let target = URL(string: url) else { return }
        if target.scheme == "https" || target.scheme == "http" || (target.isFileURL && Self.isDocument(target)) {
            NSWorkspace.shared.open(target)
        } else {
            refuse(.open(url: url), from: id, "\(url) is not a page or a document")
        }
    }

    /// Content — text, pictures, documents — by allowlist: Terminal settings, Finder's location files,
    /// workflows, installers and apps are not content; scripts are, and are refused, as are what installs a
    /// profile or runs a shortcut when opened.
    nonisolated static func isDocument(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType, type.conforms(to: .content) else { return false }
        let acting = ["com.apple.mobileconfig", "com.apple.shortcut"].compactMap { UTType($0) }
        guard !type.conforms(to: .script), !type.conforms(to: .executable), !acting.contains(where: { type.conforms(to: $0) }) else { return false }
        return !FileManager.default.isExecutableFile(atPath: url.path)
    }

    // MARK: - Storage and secrets

    private func storageFile(_ id: String) -> JSONFile<[String: String]> {
        JSONFile("storage.json", in: store.dataDirectory.appendingPathComponent(id, isDirectory: true))
    }

    private func storage(_ id: String) -> [String: String] {
        storageFile(id).load() ?? [:]
    }

    private func updateStorage(_ id: String, _ change: (inout [String: String]) -> Void) {
        var values = storage(id)
        change(&values)
        storageFile(id).save(values)
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
        timers[id]?.removeValue(forKey: timer)?.cancel()
        guard (timers[id]?.count ?? 0) < Self.timerLimit else {
            warn("plugin \(id): more than \(Self.timerLimit) timers")
            return
        }
        // A tenth of a second at the least: a plugin is not a busy loop.
        let interval = DispatchTimeInterval.milliseconds(max(ms, 100))
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + interval, repeating: repeats ? interval : .never)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                if !repeats { self?.timers[id]?[timer] = nil }
                self?.send(.timer(id: timer), to: id)
            }
        }
        timers[id, default: [:]][timer] = source
        source.resume()
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

/// A redirect is a request too: followed only where the plugin may reach, else its answer is the redirect
/// itself, status and `Location`, for the plugin to read.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let allowed: [String]

    init(allowed: [String]) {
        self.allowed = allowed
    }

    static func mayReach(_ url: URL, _ allowed: [String]) -> Bool {
        url.scheme == "https" && url.host.map { allowed.contains($0.lowercased()) } == true
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url.map { Self.mayReach($0, allowed) } == true ? request : nil
    }
}
