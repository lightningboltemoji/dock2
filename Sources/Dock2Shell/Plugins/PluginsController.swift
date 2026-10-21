import AppKit
import Dock2Core
import Dock2Plugins
import Dock2System

/// Plugins in dock2's surfaces ([plugins](product/plugins/README.md)): their views on the panel's stack,
/// their commands and results in search, their tiles on the dock.
@MainActor
final class PluginsController: PluginHostDelegate {
    let host: PluginHost
    private let dock: DockController
    private let panel: PanelController
    private let settings: SettingsStore
    weak var interaction: InteractionController?
    /// The views each plugin has open, oldest first.
    private var views: [String: [PluginViewHost]] = [:]
    /// Search waiting on a plugin's answer, by query id.
    private var waiting: [Int: (plugin: String, deliver: @MainActor ([PluginResult]) -> Void)] = [:]
    /// The results last given, for their actions.
    private(set) var results: [String: PluginResult] = [:]
    private var queries = 0

    init(host: PluginHost, dock: DockController, panel: PanelController, settings: SettingsStore) {
        self.host = host
        self.dock = dock
        self.panel = panel
        self.settings = settings
        host.delegate = self
        dock.onPluginTile = { [weak self] key in
            guard let (plugin, tile) = Self.split(key) else { return }
            self?.host.send(.tile(id: tile), to: plugin)
        }
        dock.onRemovePluginTile = { [weak self] key in
            guard let self, let (plugin, tile) = Self.split(key) else { return }
            self.host.store.update(plugin) { $0.tiles[tile] = false }
            self.dock.setPluginTile(key, nil)
        }
    }

    static func split(_ key: String) -> (String, String)? {
        guard let slash = key.lastIndex(of: "/") else { return nil }
        return (String(key[..<slash]), String(key[key.index(after: slash)...]))
    }

    // MARK: - Search

    /// A query for a plugin with results on; `deliver` hears its answer once, if it comes.
    func query(_ text: String, plugin: String, deliver: @escaping @MainActor ([PluginResult]) -> Void) -> SearchCancel {
        queries += 1
        let id = queries
        waiting[id] = (plugin, deliver)
        host.send(.query(id: id, text: text), to: plugin)
        return { [weak self] in self?.waiting[id] = nil }
    }

    func runCommand(_ command: String, of plugin: String) {
        host.send(.command(id: command), to: plugin)
    }

    func runResult(_ result: String, action: String, of plugin: String) {
        host.send(.action(action: action, item: nil, view: nil, result: result, tile: nil), to: plugin)
    }

    // MARK: - PluginHostDelegate

    func plugin(_ id: String, show view: ViewNode, summoning: Bool) {
        // Only what the user did, or the answer to what it asked for, brings dock2 up for a view.
        guard summoning || interaction?.hasKeyboard == true else {
            warn("plugin \(id): a view shows only in answer to the user, or while dock2 has the keyboard")
            return
        }
        let viewHost = PluginViewHost(plugin: id, node: view, host: host)
        viewHost.onClose = { [weak self, weak viewHost] in
            self?.views[id]?.removeAll { $0 === viewHost }
        }
        views[id, default: []].append(viewHost)
        interaction?.showPluginView(viewHost)
    }

    func plugin(_ id: String, update view: ViewNode, answering: Int?) {
        guard let open = views[id]?.last(where: { $0.node.id == view.id }) ?? views[id]?.last else { return }
        open.update(view, answering: answering)
    }

    func pluginPopView(_ id: String) {
        guard let top = views[id]?.last, interaction?.isShowing(top) == true else { return }
        interaction?.popView()
    }

    func pluginCloseView(_ id: String) {
        while let top = views[id]?.last, interaction?.isShowing(top) == true {
            interaction?.popView()
        }
    }

    func pluginDismiss(_ id: String) {
        interaction?.dismiss()
    }

    func plugin(_ id: String, results: [PluginResult], for query: Int) {
        guard let wait = waiting.removeValue(forKey: query), wait.plugin == id else { return }
        for result in results { self.results["\(id):\(result.id)"] = result }
        wait.deliver(results)
    }

    func pluginIsShowing(_ id: String) -> Bool {
        !(views[id]?.isEmpty ?? true)
    }

    func plugin(_ id: String, tile: String, set node: TileNode?) {
        dock.setPluginTile("\(id)/\(tile)", node)
    }

    func plugin(_ id: String, toast text: String) {
        if panel.isShown { panel.toast(text) } else { panel.notice(text) }
    }

    /// dock2 lets go, then ⌘V to the app in front.
    func pluginPaste(_ id: String) {
        interaction?.dismiss()
        ClipboardController.paste(settings: settings) { [weak panel] in panel?.notice($0) }
    }

    func pluginDisabled(_ id: String, because reason: String) {
        let name = host.store.plugin(id)?.manifest.name ?? id
        warn("\(name) was switched off. \(reason)")
        panel.notice("\(name) was switched off")
    }
}

/// A plugin's view on the panel's stack: what the user does to it goes to the plugin as events, and the
/// plugin answers by updating it.
@MainActor
final class PluginViewHost: ViewHost {
    let plugin: String
    private(set) var node: ViewNode
    private let host: PluginHost
    var onUpdate: (() -> Void)?
    var onClose: (() -> Void)?

    init(plugin: String, node: ViewNode, host: PluginHost) {
        self.plugin = plugin
        self.node = node
        self.host = host
    }

    /// The filters sent, the last one's id; the newest answered.
    private var filters = 0, answered = 0

    /// An answer to a filter older than one already shown is dropped: a late reply from a server.
    func update(_ node: ViewNode, answering: Int? = nil) {
        if let answering {
            guard answering >= answered else { return }
            answered = answering
        }
        self.node = node
        onUpdate?()
    }

    func perform(action: String, item: String?, in context: ViewContext) {
        host.send(.action(action: action, item: item, view: node.id, result: nil, tile: nil), to: plugin)
    }

    func filter(_ text: String) {
        filters += 1
        host.send(.filter(view: node.id, text: text, id: filters), to: plugin)
    }

    func submit(_ values: [String: String], in context: ViewContext) {
        host.send(.submit(view: node.id, values: values), to: plugin)
    }

    func closed() {
        host.send(.viewClosed(view: node.id), to: plugin)
        onClose?()
    }
}
