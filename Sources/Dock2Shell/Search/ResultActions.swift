import AppKit
import Dock2Core
import Dock2Plugins
import Dock2System

/// Something to do to a result. The first of a result's actions is ↩, the second ⌘↩; ⌘K lists them all.
@MainActor
struct ResultAction {
    var title: String
    /// Shown beside the title in the list, and on the selected row for the first.
    var key: String?
    /// Shown in place of the one before it while ⌥ is held.
    var isAlternate = false
    /// Opening a view keeps dock2 up; everything else dismisses it.
    var keepsOpen = false
    /// Asks first: what cannot be undone.
    var isDestructive = false
    /// What ⌥↩ runs: a clip's plain-text paste.
    var onOptionReturn = false
    /// A chord it answers to while its result is selected, as an action writes one: Quick Look's "cmd+y", a
    /// plugin action's own.
    var chord: String?
    /// Said where the field was, after the dismissal.
    var notice: String?
    /// A submenu's actions, worked out only when the menu opens: asking which apps open a file is slow.
    var children: (() -> [ResultAction])?
    /// Counts as a use of its result, for ranking: a command run. An app's opening counts where dock2 opens it.
    var isUse = false
    var run: () -> Void = {}
}

/// What every kind of result can do ([search](product/search/README.md#actions)).
@MainActor
struct ResultActions {
    let dock: DockController
    let settings: SettingsStore
    let running: RunningApps
    var openSettings: () -> Void
    /// Show in Files: the items selected in Files.
    var showInFiles: ([URL]) -> Void
    var quickLook: (URL) -> Void
    var clipboard: ClipboardController
    var openClipboardHistory: () -> Void
    var plugins: PluginsController

    func actions(for result: SearchResult) -> [ResultAction] {
        switch result.payload {
        case .app(let app): appActions(app)
        case .file(let path): fileActions(URL(fileURLWithPath: path))
        case .command(let id): [ResultAction(title: id == "clipboard-history" ? "Open" : "Run", key: "↩",
                                             keepsOpen: id == "clipboard-history", isUse: true, run: { self.run(command: id) })]
        case .clip(let id): clipActions(id)
        case .plugin(let plugin, let item): pluginActions(plugin, item)
        }
    }

    private func appActions(_ app: AppRef) -> [ResultAction] {
        var actions = [
            ResultAction(title: "Open", key: "↩", run: { dock.open(app) }),
            ResultAction(title: "Show in Files", key: "⌘↩", keepsOpen: true, run: {
                guard let url = AppDirectory.locate(app) else { return }
                showInFiles([url])
            }),
            ResultAction(title: "Show in Finder", isAlternate: true, run: {
                guard let url = AppDirectory.locate(app) else { return }
                FileViewerTakeover.showInFinder([url])
            }),
        ]
        if settings[Settings.pinned].contains(app) {
            actions.append(ResultAction(title: "Remove from Dock", run: { settings[Settings.pinned].removeAll { $0 == app } }))
        } else {
            actions.append(ResultAction(title: "Keep in Dock", run: { settings[Settings.pinned].append(app) }))
        }
        if let process = running.running(app) {
            actions.append(ResultAction(title: "Hide", run: { process.hide() }))
            actions.append(ResultAction(title: "Quit", run: { process.terminate() }))
            actions.append(ResultAction(title: "Force Quit", isAlternate: true, isDestructive: true, run: { process.forceTerminate() }))
        }
        return actions
    }

    private func fileActions(_ url: URL) -> [ResultAction] {
        var actions = [
            ResultAction(title: "Open", key: "↩", run: { NSWorkspace.shared.open(url) }),
            ResultAction(title: "Show in Files", key: "⌘↩", keepsOpen: true, run: { showInFiles([url]) }),
            ResultAction(title: "Quick Look", key: "⌘Y", keepsOpen: true, chord: "cmd+y", run: { quickLook(url) }),
        ]
        actions.append(ResultAction(title: "Open With", children: {
            let apps = OpenWith.apps(for: [url])
            return ([apps.preferred].compactMap { $0 } + apps.others).map { app in
                ResultAction(title: app == apps.preferred ? "\(OpenWith.name(app)) (default)" : OpenWith.name(app), run: {
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                })
            }
        }))
        actions.append(ResultAction(title: "Copy Path", notice: "Copied", run: {
            OwnWrite.write { $0.setString(url.path, forType: .string) }
        }))
        // The file itself, for any app to paste, as Files' ⌘C writes it.
        actions.append(ResultAction(title: "Copy", notice: "Copied", run: {
            OwnWrite.write { $0.writeObjects([url as NSURL]) }
        }))
        actions.append(ResultAction(title: "Move to Trash", notice: "Moved to Trash", run: { NSWorkspace.shared.recycle([url]) }))
        actions.append(ResultAction(title: "Show in Finder", run: { FileViewerTakeover.showInFinder([url]) }))
        return actions
    }

    /// A command runs, staying up if it opens a view; a result's actions are the plugin's own.
    private func pluginActions(_ plugin: String, _ item: String) -> [ResultAction] {
        if item.hasPrefix("cmd:") {
            let command = String(item.dropFirst(4))
            let opensView = plugins.host.store.plugin(plugin)?.manifest.commands?.first { $0.id == command }?.view == true
            return [ResultAction(title: opensView ? "Open" : "Run", key: "↩", keepsOpen: opensView, isUse: true,
                                 run: { plugins.runCommand(command, of: plugin) })]
        }
        let id = String(item.dropFirst(4))
        guard let result = plugins.results["\(plugin):\(id)"] else { return [] }
        return (result.actions ?? []).map { action in
            // The plugin decides what follows — a view, a copy that lets go, an app coming forward.
            ResultAction(title: action.title, keepsOpen: true, isDestructive: action.destructive == true, chord: action.key, run: {
                plugins.runResult(id, action: action.id, of: plugin)
            })
        }
    }

    /// ↩ pastes and ⌘↩ copies, or the other way round as Settings says; ⌥↩ pastes plain text.
    private func clipActions(_ id: String) -> [ResultAction] {
        guard let entry = clipboard.entry(id) else { return [] }
        let paste = ResultAction(title: "Paste", run: { clipboard.paste(id) })
        let copy = ResultAction(title: "Copy", notice: "Copied", run: { clipboard.copy(id) })
        var actions = settings[Settings.clipboardPastes] ? [paste, copy] : [copy, paste]
        actions.append(ResultAction(title: "Paste as Plain Text", onOptionReturn: true, run: { clipboard.paste(id, plain: true) }))
        actions.append(ResultAction(title: entry.pinned ? "Unpin" : "Pin", chord: "cmd+shift+p", run: { clipboard.setPinned(id, !entry.pinned) }))
        // As in the history: Open for a file or a link, Quick Look for a file — the rest stays sealed.
        if entry.kind == .files || entry.kind == .link {
            actions.append(ResultAction(title: "Open", chord: "cmd+o", run: { clipboard.open(id) }))
        }
        if entry.kind == .files, let file = entry.files.first {
            actions.append(ResultAction(title: "Quick Look", key: "⌘Y", keepsOpen: true, chord: "cmd+y", run: { quickLook(URL(fileURLWithPath: file)) }))
            actions.append(ResultAction(title: "Show in Files", keepsOpen: true, run: { showInFiles(entry.files.map { URL(fileURLWithPath: $0) }) }))
        }
        // ⌘⌫ edits the query here; in the history it deletes. Neither asks first.
        actions.append(ResultAction(title: "Delete", chord: "cmd+shift+d", run: { clipboard.delete(id) }))
        return actions
    }

    private func run(command id: String) {
        switch id {
        case "settings": openSettings()
        case "clipboard-history": openClipboardHistory()
        case "toggle-autohide": settings[Settings.autohide].toggle()
        case "quit": NSApp.terminate(nil)
        default: warn("no command \(id)")
        }
    }
}
