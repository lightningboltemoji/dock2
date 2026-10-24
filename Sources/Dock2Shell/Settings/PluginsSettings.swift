import AppKit
import Dock2Core
import Dock2Plugins
import SwiftUI

/// The plugin store as Settings sees it ([settings](product/settings.md#sections)): every choice applied to
/// the running plugin at once — switched off, it stops; a setting changed, it hears. The store is
/// observable, so what `dock2 plugin` changes shows here too.
@MainActor
final class PluginsModel {
    let host: PluginHost

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

    func setEnabled(_ id: String, _ on: Bool) {
        changed(id) { $0.enabled = on }
        host.store.resume(id)
        if on { host.startTiles() } else { host.stop(id) }
    }

    func setGranted(_ id: String, _ capability: PluginCapability, _ on: Bool) {
        changed(id) { choice in
            choice.revoked.removeAll { $0 == capability }
            if !on { choice.revoked.append(capability) }
        }
    }

    /// Results are what `query` is for: switching them on grants it, and off takes it back.
    func setResults(_ id: String, _ on: Bool) {
        changed(id) { choice in
            choice.results = on
            choice.revoked.removeAll { $0 == .query }
            if !on { choice.revoked.append(.query) }
        }
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

    func setting(_ id: String, _ key: String) -> String {
        host.store.settings(for: id)[key] ?? ""
    }

    func setSetting(_ id: String, _ key: String, _ value: String) {
        host.store.setSetting(id, key, value)
        host.send(.settings(host.store.settings(for: id)), to: id)
    }

    /// Install from a folder: its capabilities shown and agreed to first.
    func install() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a plugin's folder (.dock2plugin)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let manifest = try host.store.inspect(folder)
            let alert = NSAlert()
            alert.messageText = "Install \(manifest.name)?"
            let reaches = manifest.capabilities.map { "• " + $0.describe(hosts: manifest.hosts ?? []) }
            alert.informativeText = (reaches.isEmpty ? "It asks for nothing beyond its own storage." : "It may:\n" + reaches.joined(separator: "\n"))
                + "\n\nInstalled from a folder, not from Dock2."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try host.install(folder)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func remove(_ id: String) {
        try? host.remove(id)
    }
}

struct PluginsSection: View {
    let model: PluginsModel

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
                              plugin.isFirstParty ? "Comes with Dock2" : "Installed from a folder", "Version \(manifest.version)"]
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
            ForEach(manifest.capabilities.filter { $0 != .query || manifest.results == nil }, id: \.self) { capability in
                Toggle(capability.describe(hosts: manifest.allowedHosts(settings: model.host.store.settings(for: plugin.id))),
                       isOn: Binding(get: { choices?.grants(capability, in: manifest) ?? false },
                                     set: { model.setGranted(plugin.id, capability, $0) }))
            }
            if enabled {
                if manifest.results != nil {
                    Toggle("Show its results in search", isOn: Binding(get: { model.resultsOn(plugin.id) }, set: { model.setResults(plugin.id, $0) }))
                }
                ForEach(manifest.tiles ?? [], id: \.id) { tile in
                    Toggle("\(tile.title) on the dock", isOn: Binding(get: { model.tileOn(plugin.id, tile.id) }, set: { model.setTile(plugin.id, tile.id, $0) }))
                }
                ForEach(manifest.settings ?? [], id: \.id) { setting in
                    PluginSettingRow(model: model, plugin: plugin.id, setting: setting)
                }
            }
            if !plugin.isFirstParty {
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
