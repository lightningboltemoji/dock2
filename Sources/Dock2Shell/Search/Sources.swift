import AppKit
import Dock2Calc
import Dock2Core
import Dock2Plugins
import Dock2System

/// Something that answers queries with one section's results. `deliver` may be called before `search`
/// returns — the in-memory sources always do — and again later; `finished` says nothing more is coming.
@MainActor
protocol SearchSource: AnyObject {
    var section: SectionID { get }
    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], _ finished: Bool) -> Void) -> SearchCancel?
}

typealias SearchCancel = () -> Void

/// fend's answer to a query that asks something ([search](product/search/README.md#the-calculator)), worked
/// out off the main thread within the first frame's budget.
@MainActor
final class CalculatorSource: SearchSource {
    let section = SectionID.calculator
    static let symbol = "plus.forwardslash.minus"
    private let queue = DispatchQueue(label: "zip.tanner.dock2.calculator", qos: .userInitiated)

    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], Bool) -> Void) -> SearchCancel? {
        let question = query.text
        guard Calculator.asks(question) else {
            deliver([], true)
            return nil
        }
        let commaDecimals = Locale.current.decimalSeparator == ",", budget = SearchController.budget
        queue.async {
            let calculation = Calculator.calculate(question, budget: budget, commaDecimals: commaDecimals)
            DispatchQueue.main.async { deliver(calculation.map { [Self.result($0)] } ?? [], true) }
        }
        return nil
    }

    private nonisolated static func result(_ calculation: Calculation) -> SearchResult {
        SearchResult(id: "calc", section: .calculator, title: (calculation.isApproximate ? "≈ " : "= ") + calculation.answer,
                     match: Match(kind: .exact, ranges: []), payload: .answer(calculation.answer))
    }
}

/// The app catalog and the running apps ([apps](product/search/apps.md)). Running first, then dock2's own
/// opens, then the system's use count.
@MainActor
final class AppsSource: SearchSource {
    let section = SectionID.apps
    private let catalog: AppCatalog
    private let running: RunningApps
    private let usage: Usage

    init(catalog: AppCatalog, running: RunningApps, usage: Usage) {
        self.catalog = catalog
        self.running = running
        self.usage = usage
    }

    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], Bool) -> Void) -> SearchCancel? {
        var apps = catalog.apps
        let known = Set(apps.map(\.ref))
        for app in running.apps where !known.contains(app.ref) {
            if let entry = AppCatalog.app(at: URL(fileURLWithPath: app.ref.path)) { apps.append(entry) }
        }
        let results: [SearchResult] = apps.compactMap { app in
            let best = app.names.compactMap { name in Matcher.match(query, name, subsequence: true).map { (name, $0) } }
                .min { $0.1.kind < $1.1.kind }
            guard let (name, match) = best else { return nil }
            let isRunning = running.isRunning(app.ref)
            let id = Self.id(app.ref)
            // Running, then dock2's own opens; the system's count and last use only between equals.
            let system = catalog.systemUse(app)
            let tiebreak = min(system.count, 99_999) * 1e10 + (system.last?.timeIntervalSince1970 ?? 0)
            return SearchResult(id: id, section: .apps, title: name == app.names[0] ? name : app.names[0],
                                subtitle: nil, accessory: isRunning ? "Running" : nil, match: match,
                                signal: (isRunning ? 1e9 : 0) + usage.frecency(id), tiebreak: tiebreak, payload: .app(app.ref))
        }
        deliver(results, true)
        return nil
    }

    static func id(_ app: AppRef) -> String { "app:\(app.identity)" }
}

/// dock2's own commands.
@MainActor
final class CommandsSource: SearchSource {
    struct Command {
        let id: String
        let title: String
        let symbol: String
        /// What its symbol stands on ([visual](product/visual.md#icons-among-apps)): violet for what is about dock2
        /// itself, a colour of its own for what dock2 does, red to quit.
        let color: IconColor
        let keywords: [String]
    }

    let section = SectionID.commands
    private let usage: Usage
    static let builtIn: [Command] = [
        Command(id: "settings", title: "Settings", symbol: "gearshape", color: .violet, keywords: ["preferences"]),
        Command(id: "clipboard-history", title: "Clipboard History", symbol: "list.clipboard", color: IconColor(.orange),
                keywords: ["paste", "copied"]),
        Command(id: "toggle-autohide", title: "Toggle Auto-hide", symbol: "dock.rectangle", color: .violet, keywords: ["hide dock"]),
        Command(id: "quit", title: "Quit Dock2", symbol: "power", color: IconColor(.red), keywords: ["exit"]),
    ]

    init(usage: Usage) {
        self.usage = usage
    }

    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], Bool) -> Void) -> SearchCancel? {
        let results: [SearchResult] = Self.builtIn.compactMap { command in
            let match = ([command.title] + command.keywords).compactMap { Matcher.match(query, $0, subsequence: true) }
                .min { $0.kind < $1.kind }
            guard var match else { return nil }
            if Matcher.match(query, command.title, subsequence: true) == nil { match.ranges = [] }
            let id = "cmd:\(command.id)"
            return SearchResult(id: id, section: .commands, title: command.title, subtitle: "Dock2", match: match,
                                signal: usage.frecency(id), payload: .command(command.id))
        }
        deliver(results, true)
        return nil
    }
}

/// Clipboard history's entries ([clipboard](product/clipboard.md#finding-it)), by their text or file names,
/// the newest first.
@MainActor
final class ClipboardSource: SearchSource {
    let section = SectionID.clipboard
    private let clipboard: ClipboardController
    private let settings: SettingsStore

    init(clipboard: ClipboardController, settings: SettingsStore) {
        self.clipboard = clipboard
        self.settings = settings
    }

    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], Bool) -> Void) -> SearchCancel? {
        guard settings[Settings.clipboardHistory] else {
            deliver([], true)
            return nil
        }
        let now = Date()
        let results = clipboard.history.matches(query).map { entry, match in
            SearchResult(id: "clip:\(entry.id)", section: .clipboard, title: entry.title, subtitle: ClipboardHost.subtitle(entry, now: now),
                         match: match, signal: entry.date.timeIntervalSince1970, payload: .clip(entry.id))
        }
        deliver(results, true)
        return nil
    }
}

/// Plugins' commands, among dock2's own in the Commands section, named by the plugin.
@MainActor
final class PluginCommandsSource: SearchSource {
    let section = SectionID.commands
    private let store: PluginStore
    private let usage: Usage

    init(store: PluginStore, usage: Usage) {
        self.store = store
        self.usage = usage
    }

    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], Bool) -> Void) -> SearchCancel? {
        var results: [SearchResult] = []
        for plugin in store.plugins where store.isEnabled(plugin.id) {
            for command in store.commands(of: plugin.id) {
                guard let match = ([command.title] + (command.keywords ?? [])).compactMap({ Matcher.match(query, $0, subsequence: true) })
                    .min(by: { $0.kind < $1.kind }) else { continue }
                let id = "plugin:\(plugin.id):cmd:\(command.id)"
                results.append(SearchResult(id: id, section: .commands, title: command.title,
                                            subtitle: command.subtitle ?? plugin.manifest.name, match: match,
                                            signal: usage.frecency(id), payload: .plugin(plugin: plugin.id, item: "cmd:\(command.id)")))
            }
        }
        deliver(results, true)
        return nil
    }
}

/// One plugin's results, in a section of its own: the query goes to the plugin, its answer comes back
/// when it comes — after the first frame, at the section's end.
@MainActor
final class PluginResultsSource: SearchSource {
    let section: SectionID
    private let plugin: InstalledPlugin
    private let plugins: PluginsController

    init(plugin: InstalledPlugin, order: Int, plugins: PluginsController) {
        self.plugin = plugin
        self.plugins = plugins
        section = .plugin(plugin.id, order: order, title: plugin.manifest.results?.title ?? plugin.manifest.name)
    }

    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], Bool) -> Void) -> SearchCancel? {
        guard plugins.host.store.resultsOn(plugin.id), query.text.count >= plugin.manifest.results?.minimumQuery ?? 1 else {
            deliver([], true)
            return nil
        }
        let section = self.section, id = plugin.id
        return plugins.query(query.text, plugin: id) { items in
            // The plugin's own order, under how each matched.
            let results = items.enumerated().map { index, item in
                SearchResult(id: "plugin:\(id):\(item.id)", section: section, title: item.title, subtitle: item.subtitle,
                             match: Matcher.match(query, item.title, subsequence: true) ?? Match(kind: .subsequence, ranges: []),
                             signal: -Double(index), payload: .plugin(plugin: id, item: "res:\(item.id)"))
            }
            deliver(results, true)
        }
    }
}

/// The Spotlight index ([file search](product/search/files.md)).
@MainActor
final class FilesSource: SearchSource {
    let section = SectionID.files
    private let files = FileSearch()
    private let settings: SettingsStore
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// The protected folders only where looking asks nothing: naming one in a query's scope raises macOS's
    /// prompt.
    private var nearPlaces: [String] {
        let places = [home + "/Library/Mobile Documents/com~apple~CloudDocs"].filter { FileManager.default.fileExists(atPath: $0) }
        let choice = settings[Settings.fileAccess]
        return places + FileAccess.protectedFolders.filter { !FileAccess.isClosed($0, choice: choice) }.map(\.path)
    }

    func search(_ query: Query, deliver: @escaping @MainActor ([SearchResult], Bool) -> Void) -> SearchCancel? {
        let near = nearPlaces
        let home = self.home
        let now = Date()
        let homeFolders = FileAccess.protectedFolders.map(\.path) + [home + "/Library/Mobile Documents/com~apple~CloudDocs"]
            + settings[Settings.searchFirst]
        let excluded = settings[Settings.searchExcluded].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let token = files.search(query, scope: FileSearch.Scope(near: near)) { hits in
            let results: [SearchResult] = hits.compactMap { hit in
                guard !excluded.contains(where: { hit.path.hasPrefix($0) }), let match = Matcher.match(query, hit.name) else { return nil }
                let folder = (hit.path as NSString).deletingLastPathComponent
                return SearchResult(id: "file:\(hit.path)", section: .files, title: hit.name,
                                    subtitle: FileRanking.abbreviate(folder, home: home), match: match,
                                    signal: FileRanking.signal(path: hit.path, lastUsed: hit.lastUsed, modified: hit.modified,
                                                               home: home, near: homeFolders, now: now),
                                    payload: .file(hit.path))
            }
            deliver(results, true)
        }
        return { token.cancel() }
    }
}
