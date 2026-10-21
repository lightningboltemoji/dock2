import Dock2Core
import Dock2System
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

/// What the user decided about a plugin: on or off, what it may reach, where it shows, its settings.
public struct PluginChoices: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var granted: [PluginCapability]
    /// Its results in search; nil follows the manifest's default.
    public var results: Bool?
    /// Its tiles on the dock, by id; a missing one follows the manifest.
    public var tiles: [String: Bool]
    public var settings: [String: String]
    /// Why dock2 switched it off, if it did.
    public var disabledBecause: String?
    /// What its manifest declared when the user last agreed to it: one it declares beyond this is new.
    public var declared: [PluginCapability]?

    public init(enabled: Bool, granted: [PluginCapability], results: Bool? = nil, tiles: [String: Bool] = [:],
                settings: [String: String] = [:], disabledBecause: String? = nil, declared: [PluginCapability]? = nil) {
        self.enabled = enabled
        self.granted = granted
        self.results = results
        self.tiles = tiles
        self.settings = settings
        self.disabledBecause = disabledBecause
        self.declared = declared
    }

    /// A plugin seen for the first time, holding what it declares — `query` only if its results start on,
    /// since they are what it is for.
    static func first(_ manifest: PluginManifest, enabled: Bool) -> PluginChoices {
        let resultsOff = manifest.results.map { $0.onByDefault != true } ?? false
        return PluginChoices(enabled: enabled, granted: manifest.capabilities.filter { !(resultsOff && $0 == .query) },
                             declared: manifest.capabilities)
    }

    /// These choices for `manifest`, an update's: what the user revoked stays revoked, and what it declares
    /// beyond what they last agreed to is granted, since the update that added it said so.
    func granting(_ manifest: PluginManifest) -> PluginChoices {
        let before = declared ?? manifest.capabilities
        var next = self
        next.granted = manifest.capabilities.filter { granted.contains($0) || !before.contains($0) }
        next.declared = manifest.capabilities
        return next
    }
}

/// The plugins on this Mac ([packaging](product/plugins/packaging.md)): first-party ones from dock2's own
/// resources, the user's from `Plugins/<id>/`, and the choices made about each in `plugins.json`.
@MainActor
@Observable
public final class PluginStore {
    public private(set) var plugins: [InstalledPlugin] = []
    public private(set) var choices: [String: PluginChoices]
    private let file: JSONFile<[String: PluginChoices]>
    private let firstParty: URL?
    private let installed: URL
    /// Data, storage and secrets live per plugin under here.
    public let dataDirectory: URL
    /// Each plugin's module compiled, by its hash (`PluginInstance`).
    public let cacheDirectory: URL
    /// A plugin installed, removed, switched or changed: search's sources follow.
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Secure settings as read from the plugins' secrets, so an event does not wait on the Keychain.
    private var secureValues: [String: [String: String]] = [:]
    /// The commands each plugin last said Commands lists (`setCommands`), kept in its data folder.
    private var shownCommands: [String: [String]] = [:]
    /// Secret reads and writes, in order and off the main thread: the Keychain may block on a prompt.
    @ObservationIgnored private let keychain = DispatchQueue(label: "zip.tanner.dock2.plugin-settings", qos: .userInitiated)
    /// A plugin's secure settings arrived from its secrets: a running plugin hears them.
    @ObservationIgnored public var onSecureSettings: ((String) -> Void)?

    public init(firstParty: URL? = PluginStore.bundledPlugins, directory: URL = Paths.directory) {
        self.firstParty = firstParty
        installed = directory.appendingPathComponent("Plugins", isDirectory: true)
        dataDirectory = directory.appendingPathComponent("PluginData", isDirectory: true)
        cacheDirectory = directory.appendingPathComponent("PluginCache", isDirectory: true)
        file = JSONFile("plugins.json", in: directory)
        choices = file.load() ?? [:]
        reload()
    }

    /// Everything read again, the choices too: another dock2 process — `dock2 plugin` — changed them.
    public func reloadFromDisk() {
        choices = file.load() ?? [:]
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
                    warn("plugin at \(folder.lastPathComponent) not loaded: \(error)")
                }
            }
        }
        plugins = found
        // First-party plugins start off, holding what they declare; one dock2's update gave more holds that too.
        for plugin in found where plugin.isFirstParty {
            choices[plugin.id] = choices[plugin.id].map { $0.granting(plugin.manifest) } ?? .first(plugin.manifest, enabled: false)
        }
        shownCommands = Dictionary(uniqueKeysWithValues: found.compactMap { plugin in commandsFile(plugin.id).load().map { (plugin.id, $0) } })
        for plugin in found where secureValues[plugin.id] == nil { readSecure(plugin) }
        save()
    }

    /// Reads a plugin's secure settings on the secrets' queue, once; one kept in the clear in `plugins.json`
    /// moves into its secrets first.
    private func readSecure(_ plugin: InstalledPlugin) {
        let keys = (plugin.manifest.settings ?? []).filter { $0.kind == .secure }.map(\.id)
        guard !keys.isEmpty else { return }
        let id = plugin.id
        secureValues[id] = [:]
        var plain: [String: String] = [:]
        for key in keys {
            guard let value = choices[id]?.settings[key] else { continue }
            plain[key] = value
            choices[id]?.settings[key] = nil
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

    public func isEnabled(_ id: String) -> Bool {
        choices[id]?.enabled ?? false
    }

    public func update(_ id: String, _ change: (inout PluginChoices) -> Void) {
        guard var choice = choices[id] else { return }
        change(&choice)
        choices[id] = choice
        save()
    }

    /// The manifest read and validated, before the user is asked: what `install` would grant.
    public func inspect(_ folder: URL) throws -> PluginManifest {
        let manifest = try Self.manifest(in: folder)
        if let bundled = plugin(manifest.id), bundled.isFirstParty {
            throw PluginManifest.Problem.comesWithDock2(bundled.manifest.name)
        }
        return manifest
    }

    /// Copies a folder in, granting what it asks — the caller asked the user first.
    @discardableResult
    public func install(_ folder: URL) throws -> InstalledPlugin {
        let manifest = try inspect(folder)
        // The choices as on disk: another dock2 process — a running dock2, `dock2 plugin dev` — may have
        // changed them since this store read them, and installing writes them all back.
        choices = file.load() ?? choices
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let target = installed.appendingPathComponent(manifest.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: folder, to: target)
        // An update keeps the user's choices — one they switched off stays off — and one switched off for
        // failing gets its new code's chance.
        if var next = choices[manifest.id]?.granting(manifest) {
            next.enabled = next.enabled || next.disabledBecause != nil
            next.disabledBecause = nil
            choices[manifest.id] = next
        } else {
            choices[manifest.id] = .first(manifest, enabled: true)
        }
        reload()
        return InstalledPlugin(folder: target, manifest: manifest, isFirstParty: false)
    }

    /// Removes its code, its storage, its secrets and its choices. A first-party plugin stays: it can only
    /// be switched off.
    public func remove(_ id: String) throws {
        guard let plugin = plugin(id), !plugin.isFirstParty else { return }
        try FileManager.default.removeItem(at: plugin.folder)
        let secrets = secrets(id)
        keychain.async { secrets.clear() }
        secureValues[id] = nil
        try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(id))
        Self.removeCompiled(of: id, in: cacheDirectory)
        choices[id] = nil
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
        var values: [String: String] = [:]
        for setting in plugin.manifest.settings ?? [] {
            let chosen = setting.kind == .secure ? secureValues[id]?[setting.id] : choices[id]?.settings[setting.id]
            values[setting.id] = chosen ?? setting.defaultValue
        }
        return values
    }

    /// A setting changed: a secure one into the plugin's secrets, never `plugins.json`
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
        guard let plugin = plugin(id), plugin.manifest.results != nil, isEnabled(id),
              choices[id]?.granted.contains(.query) == true else { return false }
        return choices[id]?.results ?? plugin.manifest.results?.onByDefault ?? false
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
        return choices[plugin]?.tiles[tile] ?? declared.onDock ?? true
    }

    private func save() {
        file.save(choices)
        onChange?()
    }
}
