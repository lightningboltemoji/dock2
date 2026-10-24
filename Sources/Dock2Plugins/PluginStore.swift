import Dock2Core
import Dock2System
import Dock2TOML
import Foundation
import Observation

/// An installed plugin: its folder, its manifest, and whether it ships with dock2.
public struct InstalledPlugin: Sendable, Equatable {
    public let folder: URL
    public let manifest: PluginManifest
    public let isFirstParty: Bool

    public var id: String { manifest.id }
    public var module: URL { folder.appendingPathComponent(manifest.module) }
}

extension [InstalledPlugin] {
    /// The order search shows their sections in: as `order` names them, then the rest as installed.
    public func ordered(by order: [String]) -> [InstalledPlugin] {
        enumerated().sorted { (order.firstIndex(of: $0.element.id) ?? order.count + $0.offset)
            < (order.firstIndex(of: $1.element.id) ?? order.count + $1.offset) }.map(\.element)
    }
}

/// A plugin's choices as `plugins.json` kept them, for the one import.
struct LegacyPluginChoices: Codable {
    var enabled: Bool
    var granted: [PluginCapability]
    var results: Bool?
    var tiles: [String: Bool]?
    var settings: [String: String]?
    /// Why dock2 switched it off, if it did — not the person's choice, so not carried as one.
    var disabledBecause: String?
    /// What its manifest declared when the person last agreed to it.
    var declared: [PluginCapability]?

    func choices(for plugin: InstalledPlugin) -> PluginChoices {
        let agreed = declared ?? plugin.manifest.capabilities
        let secure = Set((plugin.manifest.settings ?? []).filter { $0.kind == .secure }.map(\.id))
        return PluginChoices(enabled: enabled || disabledBecause != nil, revoked: agreed.filter { !granted.contains($0) }, results: results,
                             tiles: tiles ?? [:], settings: (settings ?? [:]).filter { !secure.contains($0.key) })
    }
}

/// The plugins on this Mac ([packaging](product/plugins/packaging.md)): first-party ones from dock2's own
/// resources, the user's from `Plugins/<id>/`. The choices made about each are the config file's, so they
/// follow the person between Macs; the code, the storage and the secrets stay on this one.
@MainActor
@Observable
public final class PluginStore {
    public private(set) var plugins: [InstalledPlugin] = []
    /// Plugins stopped for failing, and why: until dock2 quits, the plugin is tried again or new code installed.
    /// Never written down — the person's choice stays theirs.
    public private(set) var suspended: [String: String] = [:]
    @ObservationIgnored public let settings: SettingsStore
    private let firstParty: URL?
    private let installed: URL
    /// Data, storage and secrets live per plugin under here.
    public let dataDirectory: URL
    /// Each plugin's module compiled, by its hash (`PluginInstance`).
    public let cacheDirectory: URL
    /// A plugin installed, removed, switched or changed: search's sources follow.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Plugins whose choices the config file changed under dock2 — an editor, another Mac, `dock2 plugin`.
    @ObservationIgnored public var onChoicesChanged: (([String]) -> Void)?
    /// The choices each plugin was last known to have, so a change the file brings is told from dock2's own.
    @ObservationIgnored private var known: [String: PluginChoices] = [:]
    @ObservationIgnored private var observation: SettingsObservation?
    /// Secure settings as read from the plugins' secrets, so an event does not wait on the Keychain.
    private var secureValues: [String: [String: String]] = [:]
    /// The commands each plugin last said Commands lists (`setCommands`), kept in its data folder.
    private var shownCommands: [String: [String]] = [:]
    /// Secret reads and writes, in order and off the main thread: the Keychain may block on a prompt.
    @ObservationIgnored private let keychain = DispatchQueue(label: "zip.tanner.dock2.plugin-settings", qos: .userInitiated)
    /// A plugin's secure settings arrived from its secrets: a running plugin hears them.
    @ObservationIgnored public var onSecureSettings: ((String) -> Void)?

    public init(settings: SettingsStore, firstParty: URL? = PluginStore.bundledPlugins, directory: URL = Paths.directory) {
        self.settings = settings
        self.firstParty = firstParty
        installed = directory.appendingPathComponent("Plugins", isDirectory: true)
        dataDirectory = directory.appendingPathComponent("PluginData", isDirectory: true)
        cacheDirectory = directory.appendingPathComponent("PluginCache", isDirectory: true)
        reload()
        importLegacyChoices(from: directory)
        observation = settings.observeTables { [weak self] in self?.choicesChangedInFile() }
    }

    /// `plugins.json`, where the choices were kept before the config file: carried in once on each Mac, for
    /// each installed plugin the file says nothing about yet — so choices another Mac wrote win. Left in place.
    private func importLegacyChoices(from directory: URL) {
        guard !settings[Settings.pluginChoicesImported], settings.unreadable == nil else { return }
        defer { settings[Settings.pluginChoicesImported] = true }
        let file = JSONFile<[String: LegacyPluginChoices]>("plugins.json", in: directory)
        guard FileManager.default.fileExists(atPath: file.url.path), let legacy = file.load() else { return }
        for plugin in plugins where settings.table(at: PluginChoices.path(plugin.id)) == nil {
            guard let old = legacy[plugin.id] else { continue }
            let defaults = PluginChoices.defaults(plugin)
            settings.write(old.choices(for: plugin).edits(from: defaults, for: plugin), describing: plugin.id)
        }
        // Written before the flag is, so a process that ends now hasn't marked an import it never made.
        settings.flush()
        known = Dictionary(uniqueKeysWithValues: plugins.compactMap { plugin in choices(plugin.id).map { (plugin.id, $0) } })
    }

    /// Everything read again: another dock2 process — `dock2 plugin` — installed or removed one.
    public func reloadFromDisk() {
        settings.reload()
        secureValues = [:]
        reload()
    }

    /// Inside the bundle, `Resources/Plugins`; run from `.build`, what `make plugins` put beside it.
    public static var bundledPlugins: URL? {
        if Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier { return Bundle.main.resourceURL?.appendingPathComponent("Plugins") }
        return Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("plugins")
    }

    public func reload() {
        var found: [InstalledPlugin] = []
        for (root, firstParty) in [(firstParty, true), (installed, false)] {
            guard let root, let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for folder in folders.sorted(by: { $0.path < $1.path }) {
                do {
                    let manifest = try Self.manifest(in: folder)
                    guard !found.contains(where: { $0.id == manifest.id }) else { continue }
                    found.append(InstalledPlugin(folder: folder, manifest: manifest, isFirstParty: firstParty))
                } catch {
                    warn("plugin at \(folder.lastPathComponent) not loaded: \(error.localizedDescription)")
                }
            }
        }
        plugins = found
        known = Dictionary(uniqueKeysWithValues: found.compactMap { plugin in choices(plugin.id).map { (plugin.id, $0) } })
        shownCommands = Dictionary(uniqueKeysWithValues: found.compactMap { plugin in commandsFile(plugin.id).load().map { (plugin.id, $0) } })
        for plugin in found where secureValues[plugin.id] == nil { readSecure(plugin) }
        onChange?()
    }

    /// What the person chose about an installed plugin: the config file's table for it, over its defaults.
    public func choices(_ id: String) -> PluginChoices? {
        guard let plugin = plugin(id) else { return nil }
        return PluginChoices.read(settings.table(at: PluginChoices.path(id)), for: plugin).0
    }

    /// What the config file says about the installed plugins that they can't use.
    public var diagnostics: [SettingsDiagnostic] {
        plugins.flatMap { PluginChoices.read(settings.table(at: PluginChoices.path($0.id)), for: $0).1 }
    }

    private func choicesChangedInFile() {
        var changed: [String] = []
        for plugin in plugins {
            let now = choices(plugin.id)
            if known[plugin.id] != now {
                known[plugin.id] = now
                changed.append(plugin.id)
            }
        }
        guard !changed.isEmpty else { return }
        onChoicesChanged?(changed)
        onChange?()
    }

    /// Reads a plugin's secure settings on the secrets' queue, once; one written in the clear in the config
    /// file moves into its secrets first, and out of the file.
    private func readSecure(_ plugin: InstalledPlugin) {
        let keys = (plugin.manifest.settings ?? []).filter { $0.kind == .secure }.map(\.id)
        guard !keys.isEmpty else { return }
        let id = plugin.id
        secureValues[id] = [:]
        var plain: [String: String] = [:]
        for key in keys {
            guard let value = settings.table(at: PluginChoices.path(id, "settings"))?.value(at: [key])?.asString else { continue }
            plain[key] = value
        }
        if !plain.isEmpty {
            warn("moved \(plain.keys.sorted().joined(separator: ", ")) of \(id) out of \(settings.file.url.path) into its secrets")
            settings.write(plain.keys.sorted().map { SettingsEdit(PluginChoices.path(id, "settings", $0), nil) }, describing: id)
        }
        let secrets = secrets(id), moving = plain
        keychain.async { [weak self] in
            for (key, value) in moving { secrets.set(Self.secureKey(key), value) }
            let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in secrets.get(Self.secureKey(key)).map { (key, $0) } })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A value set meanwhile is newer than what was read.
                    self.secureValues[id] = values.merging(self.secureValues[id] ?? [:]) { _, set in set }
                    self.onSecureSettings?(id)
                }
            }
        }
    }

    /// Waits for every secret read and write asked so far: for tests.
    func drainSecrets() {
        keychain.sync {}
    }

    nonisolated static func manifest(in folder: URL) throws -> PluginManifest {
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        try manifest.validate()
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(manifest.module).path) else {
            throw PluginManifest.Problem.noModule
        }
        return manifest
    }

    public func plugin(_ id: String) -> InstalledPlugin? {
        plugins.first { $0.id == id }
    }

    /// Whether it runs: switched on by the person, and not stopped for failing.
    public func isEnabled(_ id: String) -> Bool {
        suspended[id] == nil && choices(id)?.enabled == true
    }

    /// Whether it may use `capability`: declared in its manifest, and not revoked.
    public func grants(_ id: String, _ capability: PluginCapability) -> Bool {
        guard let plugin = plugin(id) else { return false }
        return choices(id)?.grants(capability, in: plugin.manifest) == true
    }

    public func update(_ id: String, _ change: (inout PluginChoices) -> Void) {
        guard let plugin = plugin(id), let old = choices(id) else { return }
        var new = old
        change(&new)
        guard new != old else { return }
        known[id] = new
        settings.write(new.edits(from: old, for: plugin), describing: id)
        onChange?()
    }

    /// Stopped for failing, until dock2 quits, it is tried again, or new code is installed.
    public func suspend(_ id: String, because reason: String) {
        suspended[id] = reason
        onChange?()
    }

    public func resume(_ id: String) {
        guard suspended.removeValue(forKey: id) != nil else { return }
        onChange?()
    }

    /// The manifest read and validated, before the user is asked: what `install` would grant.
    public func inspect(_ folder: URL) throws -> PluginManifest {
        let manifest = try Self.manifest(in: folder)
        if let bundled = plugin(manifest.id), bundled.isFirstParty {
            throw PluginManifest.Problem.comesWithDock2(bundled.manifest.name)
        }
        return manifest
    }

    /// Copies a folder in — the caller asked the user first. What the config file already says about the
    /// plugin applies: an update, or the same plugin installed on another Mac, keeps the person's choices.
    @discardableResult
    public func install(_ folder: URL) throws -> InstalledPlugin {
        let manifest = try inspect(folder)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let target = installed.appendingPathComponent(manifest.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: folder, to: target)
        suspended[manifest.id] = nil
        reload()
        return InstalledPlugin(folder: target, manifest: manifest, isFirstParty: false)
    }

    /// Removes its code, its storage, its secrets and its compiled modules. Its choices stay in the config
    /// file: taking them out would put a copy still installed on another Mac back on its defaults, which grant
    /// everything it declares. A first-party plugin stays: it can only be switched off.
    public func remove(_ id: String) throws {
        guard let plugin = plugin(id), !plugin.isFirstParty else { return }
        try FileManager.default.removeItem(at: plugin.folder)
        let secrets = secrets(id)
        keychain.async { secrets.clear() }
        secureValues[id] = nil
        suspended[id] = nil
        try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(id))
        Self.removeCompiled(of: id, in: cacheDirectory)
        reload()
    }

    /// `<id>-<hash>.cwasm`: a plugin's compiled modules but `keeping`, as a new build replaces the last.
    nonisolated static func removeCompiled(of id: String, in cache: URL, keeping: URL? = nil) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
        for name in names where name.hasPrefix("\(id)-") && name.hasSuffix(".cwasm") && name.count == id.count + 1 + PluginInstance.hashLength + 6
            && name != keeping?.lastPathComponent {
            try? FileManager.default.removeItem(at: cache.appendingPathComponent(name))
        }
    }

    /// Told to a running dock2 when `dock2 plugin` installed or removed a plugin, its id under `pluginKey`.
    nonisolated public static let changedNotification = Notification.Name("\(Dock2Identity.bundleIdentifier).plugins-changed")
    nonisolated public static let pluginKey = "plugin"

    public static func announceChange(_ id: String) {
        DistributedNotificationCenter.default().postNotificationName(changedNotification, object: nil, userInfo: [pluginKey: id],
                                                                     deliverImmediately: true)
    }

    /// Each setting's value: the user's, else the manifest's default.
    public func settings(for id: String) -> [String: String] {
        guard let plugin = plugin(id) else { return [:] }
        let chosen = choices(id)?.settings ?? [:]
        var values: [String: String] = [:]
        for setting in plugin.manifest.settings ?? [] {
            values[setting.id] = (setting.kind == .secure ? secureValues[id]?[setting.id] : chosen[setting.id]) ?? setting.defaultValue
        }
        return values
    }

    /// A setting changed: a secure one into the plugin's secrets, never the config file
    /// ([settings](product/settings.md#plugin-settings)); any other into its choices.
    public func setSetting(_ id: String, _ key: String, _ value: String) {
        guard plugin(id)?.manifest.settings?.first(where: { $0.id == key })?.kind == .secure else {
            update(id) { $0.settings[key] = value }
            return
        }
        secureValues[id, default: [:]][key] = value
        let secrets = secrets(id)
        keychain.async { secrets.set(Self.secureKey(key), value) }
        onChange?()
    }

    private func secrets(_ id: String) -> PluginSecrets {
        PluginSecrets(plugin: id, directory: dataDirectory.appendingPathComponent(id, isDirectory: true))
    }

    /// Kept beside what the plugin stores itself, under a prefix it cannot write: its own keys are its to name.
    nonisolated static func secureKey(_ setting: String) -> String { "dock2.setting.\(setting)" }

    public func resultsOn(_ id: String) -> Bool {
        guard let plugin = plugin(id), plugin.manifest.results != nil, isEnabled(id), grants(id, .query) else { return false }
        return choices(id)?.results ?? plugin.manifest.results?.onByDefault ?? false
    }

    /// The commands Commands lists: those the plugin last showed, or, before it has said, those not hidden.
    public func commands(of id: String) -> [PluginManifest.Command] {
        let declared = plugin(id)?.manifest.commands ?? []
        guard let shown = shownCommands[id] else { return declared.filter { $0.hidden != true } }
        return declared.filter { shown.contains($0.id) }
    }

    public func showCommands(_ shown: [String], of id: String) {
        guard shownCommands[id] != shown else { return }
        shownCommands[id] = shown
        commandsFile(id).save(shown)
    }

    private func commandsFile(_ id: String) -> JSONFile<[String]> {
        JSONFile("commands.json", in: dataDirectory.appendingPathComponent(id, isDirectory: true))
    }

    public func tileOn(_ plugin: String, _ tile: String) -> Bool {
        guard isEnabled(plugin), let declared = self.plugin(plugin)?.manifest.tiles?.first(where: { $0.id == tile }) else { return false }
        return choices(plugin)?.tiles[tile] ?? declared.onDock ?? true
    }
}
