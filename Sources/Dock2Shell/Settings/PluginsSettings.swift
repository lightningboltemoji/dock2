import AppKit
import Dock2Core
import Dock2Plugins
import SwiftUI

/// The plugin store as Settings sees it ([settings](product/settings.md#sections)): every choice applied to
/// the running plugin at once — switched off, it stops; a setting changed, it hears. The store is
/// observable, so what `dock2 plugin` changes shows here too.
@MainActor
@Observable
final class PluginsModel {
    @ObservationIgnored let host: PluginHost
    /// The sheet up: what installing, or switching on, asks.
    var asking: PluginAsk?

    init(host: PluginHost) {
        self.host = host
    }

    var plugins: [InstalledPlugin] {
        host.store.plugins
    }

    /// What the config file says about the installed plugins that they can't use.
    var diagnostics: [SettingsDiagnostic] {
        host.store.diagnostics
    }

    func choices(_ id: String) -> PluginChoices? {
        host.store.choices(id)
    }

    /// Why it was stopped for failing, if it was.
    func suspended(_ id: String) -> String? {
        host.store.suspended[id]
    }

    func tryAgain(_ id: String) {
        host.resume(id)
    }

    private func changed(_ id: String, _ change: (inout PluginChoices) -> Void) {
        host.store.update(id, change)
    }

    /// The first time on this Mac, a first-party plugin asks first: the choice is written once the sheet is answered.
    func setEnabled(_ id: String, _ on: Bool) {
        if on, host.store.asksBeforeSwitchingOn(id), let plugin = host.store.plugin(id) {
            asking = host.store.ask(plugin.manifest, origin: plugin.origin, purpose: .switchOn)
            return
        }
        changed(id) { $0.enabled = on }
        host.store.resume(id)
        if on { host.startTiles() } else { host.stop(id) }
    }

    /// Revoked, what the capability holds open ends at once.
    func setGranted(_ id: String, _ capability: PluginCapability, _ on: Bool) {
        host.setGranted(id, capability, on)
    }

    /// Results are what `query` is for: switching them on grants it, and off takes it back.
    func setResults(_ id: String, _ on: Bool) {
        host.setResults(id, on)
    }

    func resultsOn(_ id: String) -> Bool {
        host.store.resultsOn(id)
    }

    func setTile(_ id: String, _ tile: String, _ on: Bool) {
        changed(id) { $0.tiles[tile] = on }
        host.stop(id)
        host.startTiles()
    }

    func tileOn(_ id: String, _ tile: String) -> Bool {
        host.store.tileOn(id, tile)
    }

    /// A command's global shortcut. The plugin never hears of it, so changing it restarts nothing.
    func shortcut(_ id: String, _ command: String) -> KeyChord? {
        choices(id)?.shortcuts[command]
    }

    func setShortcut(_ id: String, _ command: String, _ chord: KeyChord?) {
        changed(id) { $0.shortcuts[command] = chord }
    }

    func setting(_ id: String, _ key: String) -> String {
        host.store.settings(for: id)[key] ?? ""
    }

    func setSetting(_ id: String, _ key: String, _ value: String) {
        host.setSetting(id, key, value)
    }

    /// Install from a folder: the sheet shows what it would reach first.
    func install() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a plugin's folder (.dock2plugin)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            asking = host.store.ask(try host.store.inspect(folder), origin: .installed, purpose: .install(folder))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The sheet answered yes: what it switched off is revoked before the plugin first runs.
    func confirm(_ ask: PluginAsk) {
        asking = nil
        switch ask.purpose {
        case .install(let folder):
            do { try host.install(folder, decisions: ask.decisions) } catch { NSAlert(error: error).runModal() }
        case .switchOn:
            host.switchOn(ask.id, decisions: ask.decisions)
        }
    }

    func lines(_ plugin: InstalledPlugin, _ capability: PluginCapability) -> [String] {
        plugin.manifest.describe(capability, settings: host.store.settings(for: plugin.id))
    }

    func remove(_ id: String) {
        try? host.remove(id)
    }
}

struct PluginsSection: View {
    @Bindable var model: PluginsModel

    var body: some View {
        if model.plugins.isEmpty {
            Section {
                Text("No plugins are installed.").foregroundStyle(.secondary)
            }
        }
        ForEach(model.plugins, id: \.id) { plugin in
            PluginSection(model: model, plugin: plugin)
        }
        Section {
            Button("Install from a Folder…") { model.install() }
        } footer: {
            Text("A plugin reaches only what you allow it here, and can be switched off or removed at any time.")
        }
        // On one section alone: a sheet on each would ask once per plugin.
        .sheet(item: $model.asking) { ask in
            PluginAskSheet(ask: ask, cancel: { model.asking = nil }, confirm: model.confirm)
        }
    }
}

/// dock2's lines for a capability — what it enforces — then what the plugin says, never in their place.
private struct CapabilityLabel: View {
    let lines: [String]
    var caption: [String] = []
    let plugin: String
    let reason: String?
    var note: String?
    var warns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if warns {
                    Label { Text(line) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                } else {
                    Text(line)
                }
            }
            ForEach(Array(caption.enumerated()), id: \.offset) { _, line in Text(line).font(.caption).foregroundStyle(.secondary) }
            if let reason, !reason.isEmpty {
                Text("\(plugin) says: “\(reason)”").font(.caption).foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// What installing a plugin, or switching a first-party one on, asks: the plugin, then a switch for each
/// capability; an update shows what is new, and the rest as it was.
private struct PluginAskSheet: View {
    @State var ask: PluginAsk
    let cancel: () -> Void
    let confirm: (PluginAsk) -> Void

    var body: some View {
        let manifest = ask.manifest
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let icon = IconImages.plated(manifest.icon ?? .symbol("puzzlepiece.extension"), tint: manifest.tint, size: 48) {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(manifest.name).font(.title2.weight(.semibold))
                    Text([manifest.author.map { "by \($0)" }, from, "Version \(manifest.version)"].compactMap { $0 }.joined(separator: " · "))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            Form {
                if let description = manifest.description {
                    Section { Text(description) }
                }
                Section {
                    ForEach($ask.rows) { $row in
                        Toggle(isOn: $row.on) {
                            CapabilityLabel(lines: row.lines, plugin: manifest.name, reason: row.reason, note: row.note, warns: row.isFullTrust)
                        }
                    }
                } header: {
                    Text(ask.isUpdate ? "This version also asks to" : "It asks to")
                } footer: {
                    if ask.rows.isEmpty { Text("It asks for nothing beyond its own storage.") }
                }
                if ask.isUpdate {
                    Section("As before") {
                        ForEach(ask.unchanged) { row in
                            LabeledContent {
                                Text(row.on ? "On" : "Off").foregroundStyle(.secondary)
                            } label: {
                                CapabilityLabel(lines: row.lines, plugin: manifest.name, reason: row.reason)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 280, idealHeight: idealHeight)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            ToolbarItem(placement: .confirmationAction) { Button(ask.purpose == .switchOn ? "Turn On" : "Install") { confirm(ask) } }
        }
    }

    /// Its rows without scrolling, up to a height that leaves the window around it.
    private var idealHeight: CGFloat {
        let rows = ask.rows.count + ask.unchanged.count + (ask.manifest.description == nil ? 0 : 1) + (ask.isUpdate ? 1 : 0)
        return min(640, 230 + 76 * CGFloat(max(rows, 1)))
    }

    /// Where it came from.
    private var from: String {
        switch ask.purpose {
        case .switchOn: "Comes with Dock2"
        case .install(let folder): "From \((folder.path as NSString).abbreviatingWithTildeInPath), not from Dock2"
        }
    }
}

private extension PluginOrigin {
    /// Where it came from, as its row says.
    var describe: String {
        switch self {
        case .firstParty: "Comes with Dock2"
        case .development: "Debug runs only"
        case .installed: "Installed from a folder"
        }
    }
}

private struct PluginSection: View {
    let model: PluginsModel
    let plugin: InstalledPlugin

    var body: some View {
        let manifest = plugin.manifest
        let choices = model.choices(plugin.id)
        let enabled = choices?.enabled ?? false
        Section {
            Toggle(isOn: Binding(get: { enabled }, set: { model.setEnabled(plugin.id, $0) })) {
                HStack(spacing: 10) {
                    if let icon = IconImages.plated(manifest.icon ?? .symbol("puzzlepiece.extension"), tint: manifest.tint, size: 28) {
                        Image(nsImage: icon).resizable().frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading) {
                        Text(manifest.name)
                        Text([manifest.description, manifest.author.map { "by \($0)" },
                              plugin.origin.describe, "Version \(manifest.version)"]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let reason = model.suspended(plugin.id) {
                HStack {
                    Text("Stopped: \(reason)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { model.tryAgain(plugin.id) }
                }
            }
            // Every grant, on or off, to revoke any of them; `query`'s is the results switch below.
            ForEach(manifest.capabilities.declared.filter { $0 != .query || manifest.results == nil }, id: \.self) { capability in
                Toggle(isOn: Binding(get: { choices?.grants(capability, in: manifest) ?? false }, set: { model.setGranted(plugin.id, capability, $0) })) {
                    CapabilityLabel(lines: model.lines(plugin, capability), plugin: manifest.name, reason: manifest.capabilities.reason(capability),
                                    warns: capability == .run && manifest.capabilities.runsWithFullTrust)
                }
            }
            if enabled {
                if manifest.results != nil {
                    Toggle(isOn: Binding(get: { model.resultsOn(plugin.id) }, set: { model.setResults(plugin.id, $0) })) {
                        CapabilityLabel(lines: ["Show its results in search"], caption: manifest.capabilities.declares(.query) ? model.lines(plugin, .query) : [],
                                        plugin: manifest.name, reason: manifest.capabilities.reason(.query))
                    }
                }
                ForEach(manifest.tiles ?? [], id: \.id) { tile in
                    Toggle("\(tile.title) on the dock", isOn: Binding(get: { model.tileOn(plugin.id, tile.id) }, set: { model.setTile(plugin.id, tile.id, $0) }))
                }
                ForEach(manifest.settings ?? [], id: \.id) { setting in
                    PluginSettingRow(model: model, plugin: plugin.id, setting: setting)
                }
            }
            if plugin.origin == .installed {
                Button("Remove \(manifest.name)", role: .destructive) { model.remove(plugin.id) }
            }
        }
    }
}

/// One of a plugin's settings, drawn by its kind.
private struct PluginSettingRow: View {
    /// A whole number as plugins parse one: "5", not "5.0".
    static func text(of number: Double?) -> String {
        guard let number else { return "" }
        let whole = number.rounded()
        return whole == number && abs(number) < 1e15 ? String(Int(whole)) : String(number)
    }

    let model: PluginsModel
    let plugin: String
    let setting: PluginManifest.Setting

    var body: some View {
        let value = Binding(get: { model.setting(plugin, setting.id) }, set: { model.setSetting(plugin, setting.id, $0) })
        switch setting.kind {
        case .toggle:
            Toggle(setting.title, isOn: Binding(get: { value.wrappedValue == "true" }, set: { value.wrappedValue = $0 ? "true" : "false" }))
        case .choice:
            Picker(setting.title, selection: value) {
                ForEach(setting.options ?? [], id: \.value) { option in Text(option.title).tag(option.value) }
            }
        case .secure:
            SecureField(setting.title, text: value)
        case .number:
            TextField(setting.title, value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Self.text(of: $0) }),
                      format: .number)
        case .folder:
            LabeledContent(setting.title) {
                HStack {
                    Text(value.wrappedValue.isEmpty ? "None" : (value.wrappedValue as NSString).abbreviatingWithTildeInPath)
                        .foregroundStyle(value.wrappedValue.isEmpty ? .secondary : .primary)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { value.wrappedValue = url.path }
                    }
                }
            }
        case .text:
            TextField(setting.title, text: value)
        }
    }
}
