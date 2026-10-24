import AppKit
import Dock2Core
import Dock2Plugins
import Dock2System

/// Search: one `SearchSession` per keystroke, its sources started together, its first frame drawn at the
/// budget or as soon as every source has answered, later answers added at the far end. Selection follows a
/// row's identity; an app selected wears the echo on the dock.
@MainActor
final class SearchController {
    /// The first frame waits this long for slow sources ([search](product/search/README.md#sources)).
    static let budget = 0.05

    /// Replaced as plugins come and go; a query already running keeps the ones it started with.
    var sources: [SearchSource]
    /// A built-in source switched off in Settings → Search is not asked.
    var isOff: (SectionID) -> Bool = { _ in false }
    private let panel: PanelController
    private let dock: DockController
    private let picks: PicksStore
    private let usage: Usage
    private var actions: ResultActions
    private var session: SearchSession?
    private var generation = 0
    private var unfinished: Set<Int> = []
    private var cancels: [SearchCancel] = []
    private var firstFrame: DispatchWorkItem?
    private var selection: String?
    private var icons: [String: NSImage] = [:]
    private var menu: MenuBuilder?
    /// The folders of the file results shown: one that changes may have taken a result away.
    private var watches: [URL: DirectoryWatch] = [:]
    /// An action ran that does not keep dock2 up.
    var onDone: (() -> Void)?
    /// "Show all…" chosen: its section, as a view to push.
    var onShowAll: ((ViewHost) -> Void)?
    /// Files' "Show all…": the query, for Files to search with across the Mac.
    /// Files' "Show all…": the query, and the section's files as search ranked them.
    var onShowAllFiles: ((String, [URL]) -> Void)?
    /// What to say at the end of a section — Files' places it cannot see — asked for each query.
    var notes: () -> [SectionID: String] = { [:] }
    /// What the user let dock2 see: a folder closed to it is not watched.
    var fileAccess: () -> FileAccessChoice = { .notAsked }
    /// A section's note chosen: where it can be done something about.
    var onNote: ((SectionID) -> Void)?

    init(sources: [SearchSource], panel: PanelController, dock: DockController, picks: PicksStore, usage: Usage, actions: ResultActions) {
        self.sources = sources
        self.panel = panel
        self.dock = dock
        self.picks = picks
        self.usage = usage
        self.actions = actions
        panel.results.onClick = { [weak self] id in self?.select(id) }
        panel.results.onDoubleClick = { [weak self] id in
            self?.select(id)
            self?.runPrimary()
        }
    }

    var hasResults: Bool { !(session?.rows.isEmpty ?? true) }

    // MARK: - Queries

    /// A new query for every change to the field; an empty one clears everything.
    /// What search may look in changed — macOS answered for a folder — so the query runs again: now if
    /// `now`, else when the search is next shown, a view's way back keeping its selection meanwhile.
    func requery(now: Bool) {
        guard let text = session?.query.text else { return }
        guard now else { return stale = true }
        session = nil
        update(text)
    }

    /// Its results were found while what search may look in was otherwise.
    private var stale = false

    func update(_ text: String) {
        // The same query again — back from a view — keeps its results and selection, unless they are stale.
        if let session, session.query == Query(text), !stale {
            render()
            return
        }
        stale = false
        generation += 1
        cancels.forEach { $0() }
        cancels = []
        firstFrame?.cancel()
        let query = Query(text)
        guard !query.isEmpty, !query.isPath else {
            session = nil
            selection = nil
            render()
            return
        }
        session = SearchSession(query: query, picks: picks.picks.candidates(for: query))
        session?.notes = notes()
        selection = nil
        let generation = self.generation
        unfinished = Set(sources.indices)
        for (index, source) in sources.enumerated() {
            if isOff(source.section) {
                unfinished.remove(index)
                continue
            }
            if let cancel = source.search(query, deliver: { [weak self] results, finished in
                self?.receive(results, finished: finished, from: index, generation: generation)
            }) {
                cancels.append(cancel)
            }
        }
        guard session?.frozen == false else { return }
        let frame = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.freeze()
        }
        firstFrame = frame
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.budget, execute: frame)
    }

    private func receive(_ results: [SearchResult], finished: Bool, from source: Int, generation: Int) {
        guard generation == self.generation, session != nil else { return }
        session?.add(results)
        if finished { unfinished.remove(source) }
        if session?.frozen == true {
            render()
        } else if unfinished.isEmpty {
            firstFrame?.cancel()
            freeze()
        }
    }

    private func freeze() {
        session?.freeze()
        selection = session?.topHit?.id
        render()
    }

    // MARK: - Showing

    private func render() {
        let rows = session?.rows ?? []
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
        if selection == nil { selection = rows.first(where: \.isSelectable)?.id }
        let working = session != nil && !unfinished.isEmpty
        panel.field.setBusy(working)
        var shown = rows.map { row -> RowModel in
            switch row {
            case .result(let result, _):
                let image = icon(row)
                return RowModel(id: row.id, kind: .item, icon: { image }, title: result.title, subtitle: result.subtitle,
                                accessory: result.accessory, primary: primaryTitle(row),
                                dimmed: session?.vanished.contains(row.id) ?? false)
            case .showAll(let section, let count):
                return RowModel(id: row.id, kind: .more, title: "Show all \(count) \(section.title.lowercased())…", primary: "Show")
            case .note(_, let text):
                return RowModel(id: row.id, kind: .item, icon: { Self.lock }, title: text, subtitle: "Settings → Permissions",
                                primary: "Allow")
            case .title(let section):
                return RowModel(id: row.id, kind: .title, title: section.title)
            }
        }
        if let session, session.isEmpty, !working {
            shown.insert(RowModel(id: "none", kind: .message, title: "No results for “\(session.query.text)”"), at: 0)
        }
        panel.setResults(shown, selection: selection)
        echo()
        watchFiles(in: rows)
    }

    /// A file result that goes while shown dims in place until the next keystroke
    /// ([search](product/search/README.md#stability)).
    private func watchFiles(in rows: [SearchSession.Row]) {
        let folders = Set(rows.compactMap { row -> URL? in
            guard case .result(let result, _) = row, case .file(let path) = result.payload else { return nil }
            return URL(fileURLWithPath: path).parentFolder
        })
        for folder in watches.keys where !folders.contains(folder) { watches[folder] = nil }
        for folder in folders where watches[folder] == nil {
            watches[folder] = DirectoryWatch(folder, choice: fileAccess()) { [weak self] in self?.lookForVanished(in: folder) }
        }
    }

    private func lookForVanished(in folder: URL) {
        guard let rows = session?.rows else { return }
        var changed = false
        for row in rows {
            guard case .result(let result, _) = row, case .file(let path) = result.payload,
                  URL(fileURLWithPath: path).parentFolder == folder, !FileManager.default.fileExists(atPath: path),
                  session?.vanished.contains(result.id) == false else { continue }
            session?.vanish(result.id)
            changed = true
        }
        if changed { render() }
    }

    private func primaryTitle(_ row: SearchSession.Row) -> String {
        guard case .result(let result, _) = row else { return "Show" }
        return actions.actions(for: result).first?.title ?? "Open"
    }

    private func icon(_ row: SearchSession.Row) -> NSImage? {
        guard case .result(let result, _) = row else { return nil }
        if let icon = icons[result.id] { return icon }
        let icon = actions.icon(for: result)
        icons[result.id] = icon
        return icon
    }

    /// The selected app's tile, if it has one, wears the ring and its label.
    private func echo() {
        guard let row = session?.rows.first(where: { $0.id == selection }), case .result(let result, _) = row,
              case .app(let app) = result.payload else {
            dock.setEcho(nil)
            return
        }
        dock.setEcho(app)
    }

    // MARK: - Keys

    private var selectable: [String] { (session?.rows ?? []).filter(\.isSelectable).map(\.id) }

    /// ↑ is +1: away from the field, toward the less likely.
    func moveSelection(by step: Int) {
        let ids = selectable
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -1
        select(ids[min(max(index + step, 0), ids.count - 1)])
    }

    private func select(_ id: String) {
        selection = id
        panel.results.select(id)
        echo()
    }

    private var selected: SearchResult? {
        guard let row = session?.rows.first(where: { $0.id == selection }), case .result(let result, _) = row else { return nil }
        return result
    }

    func runPrimary() { run(index: 0) }
    func runSecondary() { run(index: 1) }

    /// A ⌘-letter one of the selection's actions answers to; false if none does.
    func runShortcut(_ event: NSEvent) -> Bool {
        guard let result = selected, let query = session?.query,
              let action = actions.actions(for: result).first(where: { Chord($0.chord)?.matches(event) == true }) else { return false }
        perform(action, on: result, query: query)
        return true
    }

    /// ⌥↩: the action that answers to it, if the selection has one.
    func runOption() {
        guard let result = selected, let query = session?.query,
              let action = actions.actions(for: result).first(where: \.onOptionReturn) else { return }
        perform(action, on: result, query: query)
    }

    private static let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))

    private func run(index: Int) {
        if let row = session?.rows.first(where: { $0.id == selection }), case .note(let section, _) = row {
            onNote?(section)
            onDone?()
            return
        }
        if let row = session?.rows.first(where: { $0.id == selection }), case .showAll(let section, _) = row, let session {
            if section == .files, let onShowAllFiles {
                let found = session.all(in: .files).compactMap { result -> URL? in
                    if case .file(let path) = result.payload { URL(fileURLWithPath: path) } else { nil }
                }
                onShowAllFiles(session.query.text, found)
                return
            }
            let query = session.query
            onShowAll?(SectionHost(section: section, results: session.all(in: section), actions: actions) { [weak self] action, result in
                self?.execute(action, on: result, query: query)
            })
            return
        }
        guard let result = selected, let query = session?.query else { return }
        let list = actions.actions(for: result).filter { !$0.isAlternate }
        guard list.indices.contains(index) else { return }
        perform(list[index], on: result, query: query)
    }

    private func perform(_ action: ResultAction, on result: SearchResult, query: Query) {
        if action.isDestructive {
            panel.confirm(.init(question: "\(action.title)?", action: action.title)) { [weak self] in
                self?.execute(action, on: result, query: query)
            }
        } else {
            execute(action, on: result, query: query)
        }
    }

    private func execute(_ action: ResultAction, on result: SearchResult, query: Query) {
        picks.update { $0.record(result.id, title: result.title, for: query) }
        if action.isUse { usage.record(result.id) }
        action.run()
        if action.keepsOpen {
            render()
        } else {
            onDone?()
            if let notice = action.notice { panel.notice(notice) }
        }
    }

    /// ⌘K: every action for the selection, as a menu at its row.
    func showActions() {
        guard let result = selected, let query = session?.query, let frame = panel.results.frame(of: result.id) else { return }
        let builder = MenuBuilder()
        var index = 0
        for action in actions.actions(for: result) {
            let perform: () -> Void = { [weak self] in self?.perform(action, on: result, query: query) }
            if let submenu = action.submenu {
                builder.submenu(action.title) { [weak self] menu in
                    submenu(menu) { self?.perform(action, on: result, query: query) }
                }
            } else if let children = action.children {
                builder.submenu(action.title) { [weak self] submenu in
                    for child in children() {
                        submenu.item(child.title) { self?.perform(child, on: result, query: query) }
                    }
                }
            } else if action.isAlternate {
                builder.alternate(action.title, perform)
            } else {
                // The first is ↩ and the second ⌘↩, as in a view's menu.
                let chord = Chord(action.chord) ?? Chord(index == 0 ? "return" : index == 1 ? "cmd+return" : nil)
                builder.action(action.title, chord: chord, destructive: action.isDestructive, perform)
            }
            if !action.isAlternate { index += 1 }
        }
        menu = builder
        builder.menu.popUp(positioning: nil, at: CGPoint(x: frame.maxX - 200, y: frame.maxY), in: panel.results)
    }
}
