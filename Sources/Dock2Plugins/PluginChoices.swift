import Dock2Core
import Dock2TOML

/// What the person decided about a plugin, kept in the config file's `[plugins."<id>"]` so it follows them
/// from Mac to Mac. A key not written there is what the installed plugin's manifest says.
public struct PluginChoices: Equatable, Sendable {
    public var enabled: Bool
    /// What it declares that it may not do. Everything else it declares, it may — so a capability an update
    /// adds is granted, since the update that added it said so, and one revoked stays revoked.
    public var revoked: [PluginCapability]
    /// Its results in search; nil follows the manifest.
    public var results: Bool?
    /// Its tiles on the dock, by id; a missing one follows the manifest.
    public var tiles: [String: Bool]
    /// Its settings but the secure ones, which stay in its secrets, as the plugin parses them.
    public var settings: [String: String]

    public init(enabled: Bool, revoked: [PluginCapability] = [], results: Bool? = nil, tiles: [String: Bool] = [:],
                settings: [String: String] = [:]) {
        self.enabled = enabled
        self.revoked = revoked
        self.results = results
        self.tiles = tiles
        self.settings = settings
    }

    /// Whether it may use `capability`: declared, and not revoked.
    public func grants(_ capability: PluginCapability, in manifest: PluginManifest) -> Bool {
        manifest.capabilities.contains(capability) && !revoked.contains(capability)
    }

    /// No one has decided anything: a first-party plugin off, one the person installed on, since installing it
    /// was the question; `query` revoked when its results start off, since they are what it is for.
    static func defaults(_ plugin: InstalledPlugin) -> PluginChoices {
        let manifest = plugin.manifest
        let resultsOff = manifest.results.map { $0.onByDefault != true } ?? false
        return PluginChoices(enabled: !plugin.isFirstParty, revoked: resultsOff && manifest.capabilities.contains(.query) ? [.query] : [])
    }

    static func path(_ id: String, _ key: String...) -> [String] {
        Settings.pluginsTable + [id] + key
    }

    /// The choices `table` — the plugin's own, `[plugins."<id>"]` — writes, over the defaults, and what it gets wrong.
    static func read(_ table: TOMLTable?, for plugin: InstalledPlugin) -> (PluginChoices, [SettingsDiagnostic]) {
        var choices = defaults(plugin)
        guard var table else { return (choices, []) }
        var problems: [SettingsDiagnostic] = []
        func refuse(_ value: TOMLValue, _ key: [String], _ message: String) {
            problems.append(SettingsDiagnostic(line: value.line, message: "'\(TOMLDocument.spell(path(plugin.id) + key))' \(message)"))
        }
        if let value = table.take(["enabled"]) {
            if let flag = value.asBool { choices.enabled = flag } else { refuse(value, ["enabled"], "must be true or false, not \(value.kindName)") }
        }
        if let value = table.take(["revoked"]) {
            if let names = value.asArray?.map(\.asString), !names.contains(nil) {
                choices.revoked = names.compactMap { $0.flatMap(PluginCapability.init(rawValue:)) }
                for name in names.compactMap({ $0 }) where PluginCapability(rawValue: name) == nil {
                    refuse(value, ["revoked"], "names an unknown capability \"\(name)\"")
                }
            } else {
                refuse(value, ["revoked"], "must be a list of capabilities in quotes, not \(value.kindName)")
            }
        }
        if let value = table.take(["results"]) {
            if let flag = value.asBool { choices.results = flag } else { refuse(value, ["results"], "must be true or false, not \(value.kindName)") }
        }
        for tile in plugin.manifest.tiles ?? [] {
            guard let value = table.take(["tiles", tile.id]) else { continue }
            if let flag = value.asBool { choices.tiles[tile.id] = flag } else { refuse(value, ["tiles", tile.id], "must be true or false, not \(value.kindName)") }
        }
        for setting in plugin.manifest.settings ?? [] where setting.kind != .secure {
            guard let value = table.take(["settings", setting.id]) else { continue }
            if let text = text(value, as: setting.kind) {
                choices.settings[setting.id] = text
            } else {
                refuse(value, ["settings", setting.id], "must be \(setting.kind == .toggle ? "true or false" : setting.kind == .number ? "a number" : "a string"), not \(value.kindName)")
            }
        }
        table.acceptTable(["tiles"])
        table.acceptTable(["settings"])
        for leftover in table.leftovers {
            problems.append(SettingsDiagnostic(line: leftover.line, message: "\(plugin.manifest.name) has no setting '\(TOMLDocument.spell(path(plugin.id)))." + leftover.key + "'"))
        }
        return (choices, problems)
    }

    /// The edits that write `self` over `old`: each key that changed, set — or taken out where it is back to
    /// what the manifest says. A key it didn't change is left as the person spelled it.
    func edits(from old: PluginChoices, for plugin: InstalledPlugin) -> [SettingsEdit] {
        let defaults = Self.defaults(plugin)
        let id = plugin.id
        var edits: [SettingsEdit] = []
        func edit(_ key: [String], _ new: TOMLValue?, _ old: TOMLValue?, _ standard: TOMLValue?) {
            guard new?.spelled != old?.spelled else { return }
            edits.append(SettingsEdit(Self.path(id) + key, new?.spelled == standard?.spelled ? nil : new))
        }
        edit(["enabled"], .bool(enabled), .bool(old.enabled), .bool(defaults.enabled))
        func capabilities(_ list: [PluginCapability]) -> TOMLValue {
            .array(plugin.manifest.capabilities.filter(list.contains).map { .string($0.rawValue) } + list.filter { !plugin.manifest.capabilities.contains($0) }.map { .string($0.rawValue) })
        }
        edit(["revoked"], capabilities(revoked), capabilities(old.revoked), capabilities(defaults.revoked))
        let resultsDefault = plugin.manifest.results?.onByDefault ?? false
        edit(["results"], .bool(results ?? resultsDefault), .bool(old.results ?? resultsDefault), .bool(resultsDefault))
        for tile in plugin.manifest.tiles ?? [] {
            let standard = tile.onDock ?? true
            edit(["tiles", tile.id], .bool(tiles[tile.id] ?? standard), .bool(old.tiles[tile.id] ?? standard), .bool(standard))
        }
        for setting in plugin.manifest.settings ?? [] where setting.kind != .secure {
            let spell = { (text: String?) in text.map { Self.value($0, as: setting.kind) } }
            edit(["settings", setting.id], spell(settings[setting.id] ?? setting.defaultValue), spell(old.settings[setting.id] ?? setting.defaultValue),
                 spell(setting.defaultValue))
        }
        return edits
    }

    /// A setting's value as the plugin parses it: "true", "5" rather than "5.0", text.
    static func text(_ value: TOMLValue, as kind: PluginManifest.Setting.Kind) -> String? {
        switch kind {
        case .toggle:
            return value.asBool.map { $0 ? "true" : "false" }
        case .number:
            guard let number = value.asDouble else { return nil }
            return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .text, .choice, .folder, .secure:
            return value.asString
        }
    }

    /// The same, as the file writes it.
    static func value(_ text: String, as kind: PluginManifest.Setting.Kind) -> TOMLValue {
        switch kind {
        case .toggle: .bool(text == "true")
        case .number: Double(text).map(TOMLValue.number) ?? .string(text)
        case .text, .choice, .folder, .secure: .string(text)
        }
    }
}
