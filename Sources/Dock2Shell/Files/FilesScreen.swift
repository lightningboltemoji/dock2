import AppKit
import Dock2Core
import Dock2System
import Quartz

/// Files ([files](product/files/README.md)): the columns over the path bar, at a size of its own. One for
/// as long as dock2 runs, so it opens where it was.
@MainActor
final class FilesScreen: Screen {
    private let files = FilesView()
    private let pathBar = PathBar()
    var view: NSView { files }
    var bar: NSView? { pathBar }
    var size: CGSize? {
        CGSize(width: PanelMetrics.filesSize.width, height: PanelMetrics.filesSize.height - PanelMetrics.fieldSize.height)
    }
    let title: String? = nil
    let usesField = false
    let isLoading = false
    var onChange: (() -> Void)?

    private(set) var state: FilesState
    private let operations: FileOperations
    private let settings: SettingsStore
    private var listings: [URL: Result<[FileEntry], Error>] = [:]
    private var watches: [URL: DirectoryWatch] = [:]
    private var foldersChanged: NSObjectProtocol?
    private var menu: MenuBuilder?
    private var quickLook: QLPreviewView?
    private var typedFolder: URL?

    /// ⌘F: a folder and the folders inside it — or, for "Show all…", the whole Mac — searched by name.
    private struct Search {
        var scope: URL?
        var text: String
        /// Search's own results, "Show all…": not Files' query to run again, but its files filtered again.
        var seeded = false
        var found: [URL] = []
        var results: [FileEntry] = []
        var selection: [URL] = []
    }

    private var search: Search?
    private var searching: FileSearch.Token?
    private var searchDelay: DispatchWorkItem?
    private let fileSearch = FileSearch()

    /// Opening a file, or Open in Finder: dock2 lets go.
    var onDismiss: (() -> Void)?
    var toast: ((String) -> Void)?
    /// Said where the field was, after dock2 let go: the grant landing while System Settings is in front.
    var notice: ((String) -> Void)?
    var confirm: ((String, @escaping () -> Void) -> Void)?

    /// What operations could not do, on the rows of the items they could not do it to — until the next
    /// operation starts, or Files closes.
    private var problems: [URL: FileProblem] = [:]
    private var jobCount = 0

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private var observations: [SettingsObservation] = []
    private var showsHidden: Bool { settings[Settings.showHiddenFiles] }

    init(operations: FileOperations, settings: SettingsStore) {
        self.operations = operations
        self.settings = settings
        state = FilesState(home: Self.home)
        files.columns.onSelect = { [weak self] column, entries in self?.selected(entries, in: column) }
        files.columns.onKey = { [weak self] column, key in self?.key(key, in: column) ?? false }
        files.columns.onOpen = { [weak self] _, entry in self?.open(entry) }
        files.columns.onRename = { [weak self] entry in self?.rename(entry.url) }
        files.columns.onDrop = { [weak self] urls, folder, moving in self?.drop(urls, into: folder, moving: moving) }
        files.columns.onRemedy = { [weak self] problem in self?.remedy(problem) }
        files.columns.onAllowAccess = { [weak self] folder in self?.allowAccess(to: folder) }
        pathBar.onDrop = { [weak self] urls, folder, moving in self?.drop(urls, into: folder, moving: moving) }
        pathBar.onGo = { [weak self] url in self?.go(to: url) }
        pathBar.onChip = { [weak self] in self?.switchTab() }
        pathBar.onPlaces = { Places.all.map { ($0.name, $0.url) } }
        // A folder allowed, or refused, in System Settings: what was listed of it is read again.
        foldersChanged = NotificationCenter.default.addObserver(forName: FileAccess.foldersChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.listings = [:]
                if let search = self.search, !search.seeded { self.runSearch() } else if let found = self.search?.found {
                    // What was closed when search's files were listed may be open now.
                    self.search?.results = self.open(found)
                }
                self.render()
            }
        }
        pathBar.onTyped = { [weak self] text in self?.follow(text) }
        pathBar.onSubmit = { [weak self] text in self?.submit(text) }
        pathBar.onComplete = { [weak self] text in self?.complete(text) ?? text }
        pathBar.onSearch = { [weak self] text in self?.searchChanged(text) }
        pathBar.onSearchCommand = { [weak self] selector in self?.searchCommand(selector) ?? false }
        operations.observe { [weak self] in self?.jobsChanged() }
        operations.onError = { [weak self] problem in self?.report(problem) }
        operations.ask = { [weak self] question, reply in self?.files.banner.ask(question, reply) }
        for key in [Settings.foldersFirst, Settings.showHiddenFiles, Settings.previewColumn] {
            observations.append(settings.observe(key) { [weak self] _ in
                self?.listings = [:]
                self?.render()
            })
        }
    }

    // MARK: - Ways in

    /// Where Files was, or `folder`.
    func open(at folder: URL? = nil) {
        if let folder { go(to: folder) }
    }

    /// Show in Files, and "Show in Finder" taken over: the items selected in the folder that holds them.
    func reveal(_ urls: [URL]) {
        let urls = urls.map(\.canonical)
        guard let first = urls.first else { return }
        // Inside a closed folder, the closed folder holding it: nothing deeper is looked at.
        let folder = shown(first.parentFolder)
        let items = urls.filter { $0.parentFolder == folder }
        let opens = items.count == 1 && reachable(folder) && (DirectoryListing.entry(items[0], closed: linkClosed)?.isFolder ?? false)
        state.go(to: folder, root: Self.root(of: folder), selecting: items, opens: opens)
        render()
    }

    /// A path typed into search's field: the path bar takes it over.
    func beginPath(_ text: String) {
        pathBar.beginTyping(text)
    }

    /// ⌘F in `scope`; or search's Files section, "Show all…", listed as search found it — its exclusions
    /// and ranking kept — until the query is changed here.
    func beginSearch(_ text: String = "", scope: URL?, found: [URL] = []) {
        let results = open(found)
        search = Search(scope: scope?.canonical, text: text, seeded: !found.isEmpty, found: found, results: results,
                        selection: results.first.map { [$0.url] } ?? [])
        let name = scope.map { "“\(Self.title($0))”" } ?? "this Mac"
        pathBar.beginSearching(text, placeholder: "Search \(name)")
        render()
    }

    private func endSearch() {
        searching?.cancel()
        searchDelay?.cancel()
        search = nil
        pathBar.endTyping()
        render()
        files.columns.focus(state.tab.focus)
    }

    private func searchChanged(_ text: String) {
        // The text begun with is already listed.
        guard text != search?.text else { return }
        search?.text = text
        search?.seeded = false
        searchDelay?.cancel()
        let run = DispatchWorkItem { [weak self] in self?.runSearch() }
        searchDelay = run
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: run)
    }

    private func runSearch() {
        guard let search else { return }
        searching?.cancel()
        let query = Query(search.text)
        guard !query.isEmpty else {
            self.search?.results = []
            self.search?.selection = []
            render()
            return
        }
        let text = search.text, scope = search.scope
        // Probed once, here: the walk asks of every folder it meets.
        let choice = settings[Settings.fileAccess], granted = FileAccess.hasFullDiskAccess
        let closed: @Sendable (URL) -> Bool = { !granted && FileAccess.asks($0, choice: choice) }
        searching = fileSearch.search(query, within: scope?.path, showsHidden: showsHidden, closed: closed) { [weak self] hits in
            guard let self, self.search?.text == text else { return }
            let ranked = Self.rank(hits, query: query, scope: scope).prefix(Self.resultLimit)
            let results = ranked.map { URL(fileURLWithPath: $0.path, isDirectory: $0.isFolder) }.filter { !self.closedBySpelling($0.parentFolder) }
                .compactMap { DirectoryListing.entry($0, closed: self.linkClosed) }
            self.search?.results = results
            self.search?.selection = results.first.map { [$0.url] } ?? []
            self.render()
        }
    }

    static let resultLimit = 500

    /// The best matches first; within a folder the nearer, across the Mac by search's own signal.
    static func rank(_ hits: [FileSearch.Hit], query: Query, scope: URL?) -> [FileSearch.Hit] {
        let now = Date()
        let scored = hits.compactMap { hit -> (hit: FileSearch.Hit, kind: MatchKind, signal: Double)? in
            guard let match = Matcher.match(query, hit.name) else { return nil }
            let signal = scope == nil
                ? FileRanking.signal(path: hit.path, lastUsed: hit.lastUsed, modified: hit.modified, home: home.path, near: [], now: now)
                : -Double(hit.path.split(separator: "/").count)
            return (hit, match.kind, signal)
        }
        return scored.sorted { ($0.kind, -$0.signal, $0.hit.name) < ($1.kind, -$1.signal, $1.hit.name) }.map(\.hit)
    }

    /// ↑ ↓ through the results, ↩ opening the one selected, from the search field.
    private func searchCommand(_ selector: Selector) -> Bool {
        guard let search else { return false }
        let urls = search.results.map(\.url)
        let index = search.selection.first.flatMap { urls.firstIndex(of: $0) }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            if let next = index.map({ min($0 + 1, urls.count - 1) }) ?? (urls.isEmpty ? nil : 0) { self.search?.selection = [urls[next]] }
        case #selector(NSResponder.moveUp(_:)):
            if let index { self.search?.selection = [urls[max(index - 1, 0)]] }
        case #selector(NSResponder.insertNewline(_:)):
            if let entry = selectedEntries.first { open(entry) }
            return true
        default:
            return false
        }
        render()
        return true
    }

    // MARK: - Screen

    func focus() {
        render()
        // The first time Files opens without Full Disk Access, unless the first launch asked already.
        if settings[Settings.fileAccess] == .notAsked, !FileAccess.hasFullDiskAccess { askForAccess() }
        if pathBar.isTyping { return }
        files.columns.focus(state.tab.focus)
    }

    /// The ask, in the banner; a locked place's Allow Access… brings it back.
    /// What opens a locked folder: the ask, before the user answered it; once they chose to be asked about
    /// each folder, Files and Folders' switch for one macOS refused, and Full Disk Access for other apps'
    /// data — the choice they made standing either way.
    private func allowAccess(to folder: URL) {
        guard settings[Settings.fileAccess] == .folders else { return askForAccess() }
        let root = FileAccess.protectedRoot(of: FileAccess.reached(folder.path, choice: .folders))
        let refused = root.map(FileAccess.refused.contains) ?? false
        NSWorkspace.shared.open(refused ? FileAccess.filesAndFoldersPane : FileAccess.fullDiskAccessPane)
        if !refused {
            FileAccess.awaitFullDiskAccess { [weak self] in
                self?.listings = [:]
                self?.render()
            }
        }
        onDismiss?()
    }

    private func askForAccess() {
        guard !files.banner.isAskingForAccess, !FileAccess.hasFullDiskAccess else { return }
        files.banner.askForAccess { [weak self] choice in
            guard let self else { return }
            // macOS's answers for the three folders come on the main queue.
            FileAccess.answer(choice, settings: self.settings, folders: { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.listings = [:]
                    self?.render()
                }
            }, granted: { [weak self] in
                self?.listings = [:]
                self?.render()
                self?.notice?("dock2 can see all your files now")
            })
            if choice == .fullDisk { self.onDismiss?() }
            self.listings = [:]
            self.render()
        }
    }

    func cancel() -> Bool {
        if quickLook != nil {
            closeQuickLook()
            return true
        }
        if files.columns.cancelEditing() { return true }
        if files.banner.cancelQuestion() { return true }
        if search != nil {
            endSearch()
            return true
        }
        if pathBar.isTyping {
            pathBar.endTyping()
            typedFolder = nil
            render()
            files.columns.focus(state.tab.focus)
            return true
        }
        return false
    }

    func filter(_ text: String) {}
    func command(_ selector: Selector) -> Bool { false }

    func closed() {
        pathBar.endTyping()
        closeQuickLook()
        problems = [:]
    }

    // MARK: - Showing

    private func render() {
        if let search {
            let details = Dictionary(search.results.map { ($0.url, Self.located($0.url, in: search.scope)) }, uniquingKeysWith: { a, _ in a })
            files.columns.showResults(ColumnView.Listing(folder: search.scope ?? Self.home, entries: search.results,
                                                         selection: search.selection, details: details, problems: problems),
                                      preview: previewItem(for: search.selection, in: search.results))
            files.banner.show(jobs: operations.jobs)
            return
        }
        files.columns.showResults(nil, preview: nil)
        let tab = state.tab
        var folders = tab.columns.map(\.folder)
        if let typedFolder, !folders.contains(typedFolder) { folders = [typedFolder] }
        watch(Set(folders))
        let listings = tab.columns.map { column in
            let result = listing(column.folder)
            switch result {
            case .success(let entries):
                // By spelling, cheap for every item; a link into a closed folder shows locked once opened.
                let locked = Set(entries.filter { $0.isFolder && closedBySpelling($0.url) }.map(\.url))
                return ColumnView.Listing(folder: column.folder, entries: entries, selection: column.selection, problems: problems, locked: locked)
            case .failure(let error):
                return ColumnView.Listing(folder: column.folder, entries: [], selection: [], message: Self.describe(error),
                                          offersAccess: Self.isClosedForAccess(error))
            }
        }
        files.columns.show(listings, focus: tab.focus, preview: previewItem())
        let selected = tab.selection.count == 1 ? tab.selection.first.flatMap { url in
            entries(in: tab.folder).first { $0.url == url }?.name
        } : nil
        pathBar.show(Self.segments(tab.folder), selected: selected, other: state.other.map { (Self.title($0.folder), $0.folder) })
        pathBar.showProgress(otherTabProgress())
        files.banner.show(jobs: operations.jobs)
    }

    private func previewItem() -> PreviewView.Item? {
        let tab = state.tab
        // The column after the focus is the selected folder's own: no preview beside it.
        guard tab.focus == tab.columns.count - 1 else { return nil }
        return previewItem(for: tab.selection, in: entries(in: tab.folder))
    }

    private func previewItem(for selection: [URL], in entries: [FileEntry]) -> PreviewView.Item? {
        guard settings[Settings.previewColumn] else { return nil }
        if selection.count > 1 { return .several(selection.count) }
        guard let url = selection.first, let entry = entries.first(where: { $0.url == url }) else { return nil }
        if entry.isFolder {
            // Counted only where looking asks nothing: a protected folder found by search would prompt.
            let closed = Self.closedWithoutAccess(url, settings: settings) != nil
            return .folder(entry, count: closed ? nil : (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count)
        }
        return .file(entry)
    }

    private func entries(in folder: URL) -> [FileEntry] {
        (try? listing(folder).get()) ?? []
    }

    private func listing(_ folder: URL) -> Result<[FileEntry], Error> {
        if let cached = listings[folder] { return cached }
        let result: Result<[FileEntry], Error>
        if let closed = Self.closedWithoutAccess(folder, settings: settings) {
            result = .failure(closed)
        } else {
            result = Result { try DirectoryListing.list(folder, showsHidden: showsHidden, foldersFirst: settings[Settings.foldersFirst], closed: linkClosed) }
        }
        listings[folder] = result
        return result
    }

    /// Watches exactly the folders shown; a change lists that folder again.
    private func watch(_ folders: Set<URL>) {
        for folder in watches.keys where !folders.contains(folder) { watches[folder] = nil }
        for folder in folders where watches[folder] == nil {
            watches[folder] = DirectoryWatch(folder, choice: settings[Settings.fileAccess]) { [weak self] in
                self?.listings[folder] = nil
                self?.pruneVanished(in: folder)
                self?.render()
            }
        }
        for folder in listings.keys where !folders.contains(folder) { listings[folder] = nil }
    }

    /// Selections of items no longer there, after a folder changed.
    private func pruneVanished(in folder: URL) {
        let present = Set(entries(in: folder).map(\.url))
        let gone = state.tabs.flatMap { $0.columns.filter { $0.folder == folder }.flatMap(\.selection) }.filter { !present.contains($0) }
        if !gone.isEmpty { state.removed(gone) }
    }

    // MARK: - Moving about

    private func selected(_ entries: [FileEntry], in column: Int) {
        // The results' list, while searching.
        if column < 0 {
            search?.selection = entries.map(\.url)
            render()
            return
        }
        state.select(entries.map(\.url), in: column, opens: entries.count == 1 && entries[0].isFolder)
        render()
        files.columns.focus(column)
    }

    @discardableResult
    private func key(_ key: ColumnKey, in column: Int) -> Bool {
        switch key {
        case .left:
            if state.leave() { render(); files.columns.focus(state.tab.focus) }
        case .right:
            enter()
        case .open:
            if files.banner.acceptQuestion() { return true }
            if let entry = selectedEntries.first, selectedEntries.count == 1 { open(entry) } else { openSelection() }
        case .enclosing:
            enclosing()
        case .quickLook:
            toggleQuickLook()
        case .path(let typed):
            let start = PathInput.isPath(typed) && typed == "/" ? "/" : "~/"
            pathBar.beginTyping(start)
        }
        return true
    }

    /// →, or opening a folder in place: into it, its first item selected.
    private func enter() {
        guard state.enter() else { return }
        if state.tab.selection.isEmpty, let first = entries(in: state.tab.folder).first {
            state.select([first.url], in: state.tab.focus, opens: first.isFolder)
        }
        render()
        files.columns.focus(state.tab.focus)
    }

    private func enclosing() {
        let first = state.tab.columns[0].folder
        let parent = first.path == "/" ? nil : first.parentFolder
        state.enclosing(parent: parent)
        render()
        files.columns.focus(state.tab.focus)
    }

    func go(to url: URL) {
        let url = shown(url.canonical)
        typedFolder = nil
        let isFolder = DirectoryListing.entry(url, closed: linkClosed)?.isFolder ?? true
        if isFolder {
            state.go(to: url, root: Self.root(of: url))
        } else {
            let folder = url.parentFolder
            state.go(to: folder, root: Self.root(of: folder), selecting: [url])
        }
        render()
        files.columns.focus(state.tab.focus)
    }

    /// What the keys act on: the results' selection while searching, the column's otherwise.
    private var selection: [URL] { search?.selection ?? state.tab.selection }

    private var selectedEntries: [FileEntry] {
        let selection = Set(self.selection)
        return (search?.results ?? entries(in: state.tab.folder)).filter { selection.contains($0.url) }
    }

    /// Where a result is, from the folder searched: "Sources/Dock2Core".
    static func located(_ url: URL, in scope: URL?) -> String {
        let folder = url.parentFolder.path
        if let scope, folder.hasPrefix(scope.path) {
            let inside = folder.dropFirst(scope.path.count).drop { $0 == "/" }
            return inside.isEmpty ? "" : String(inside)
        }
        return abbreviate(url.parentFolder)
    }

    /// ↩: a folder opens in place; a file in its app, and dock2 lets go. A folder found by search is gone to.
    private func open(_ entry: FileEntry) {
        if search != nil, entry.isFolder {
            endSearch()
            go(to: entry.url)
            return
        }
        if entry.isFolder {
            if !state.tab.selection.contains(entry.url) { state.select([entry.url], in: state.tab.focus, opens: true) }
            enter()
            return
        }
        NSWorkspace.shared.open(entry.url)
        onDismiss?()
    }

    private func openSelection() {
        let files = selectedEntries.filter { !$0.isFolder }.map(\.url)
        guard !files.isEmpty else { return }
        files.forEach { NSWorkspace.shared.open($0) }
        onDismiss?()
    }

    // MARK: - Typing a path

    /// The columns follow the deepest folder the typed path reaches.
    private func follow(_ text: String) {
        let path = PathInput.expand(text, home: Self.home.path)
        // Told it is not a folder, a URL reads nothing to find out: the path may be inside a closed one.
        var url = shown(URL(fileURLWithPath: path, isDirectory: false))
        while url.path != "/", !(DirectoryListing.entry(url, closed: linkClosed)?.isFolder ?? false) { url.deleteLastPathComponent() }
        guard url != state.tab.folder else { return }
        state.go(to: url, root: Self.root(of: url))
        render()
    }

    /// Whether Files may look in `folder` — list it, read what an item in it is — without raising macOS's
    /// prompt, judged where its links lead: nothing inside a closed folder is looked at, only shown locked.
    private func reachable(_ folder: URL) -> Bool {
        Self.closedWithoutAccess(folder, settings: settings) == nil
    }

    /// Search's files as Files lists them: those in folders open to dock2.
    private func open(_ found: [URL]) -> [FileEntry] {
        found.filter { !closedBySpelling($0.parentFolder) }.compactMap { DirectoryListing.entry($0, closed: linkClosed) }
    }

    /// By spelling alone, cheap enough for every item in a listing or a search.
    private func closedBySpelling(_ folder: URL) -> Bool {
        FileAccess.isClosed(folder, choice: settings[Settings.fileAccess])
    }

    /// What a listed link may lead into unread: judged where its links lead, a link to a link included —
    /// links are few, so this is the one place a listing pays for following them.
    private var linkClosed: (URL) -> Bool {
        let choice = settings[Settings.fileAccess]
        return { FileAccess.isClosedReached($0, choice: choice) }
    }

    /// Where Files can go for `url`: itself, if what it is can be read, else the closed folder holding it.
    private func shown(_ url: URL) -> URL {
        var url = url
        while url.path != "/", !reachable(url.parentFolder) { url = url.parentFolder }
        return url
    }

    private func complete(_ text: String) -> String {
        let (folder, _) = PathInput.split(text, home: Self.home.path)
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard reachable(url) else { return text }
        let entries = (try? DirectoryListing.list(url, showsHidden: true, closed: linkClosed)) ?? []
        return PathInput.complete(text, entries: entries.map { ($0.url.lastPathComponent, $0.isFolder) })
    }

    private func submit(_ text: String) {
        let url = URL(fileURLWithPath: PathInput.expand(text, home: Self.home.path), isDirectory: false)
        guard shown(url) != url || FileManager.default.fileExists(atPath: url.path) else {
            toast?("Nothing at \(text)")
            return
        }
        pathBar.endTyping()
        go(to: url)
    }

    // MARK: - Tabs

    private func switchTab() {
        state.switchTab()
        render()
        files.columns.focus(state.tab.focus)
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        if quickLook != nil {
            closeQuickLook()
            return
        }
        guard let url = selection.first else { return }
        // Inset, with corners of its own: the panel's are rounder than a preview's square edge.
        let preview = QLPreviewView(frame: files.bounds.insetBy(dx: 10, dy: 10), style: .normal)!
        preview.autoresizingMask = [.width, .height]
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 18.5
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.previewItem = url as NSURL
        files.addSubview(preview)
        quickLook = preview
    }

    private func closeQuickLook() {
        quickLook?.close()
        quickLook?.removeFromSuperview()
        quickLook = nil
        files.columns.focus(state.tab.focus)
    }

    // MARK: - Keys

    func keyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let tab = state.tab
        // While the path bar's field is edited, the text keys are its own: copying text, not files.
        if pathBar.isEditing, Self.textEditing.contains(where: { $0 == (flags, key) }) { return false }
        // ⌘↩ on a result: where it is, in the columns.
        if search != nil, flags == .command, key == "\r" {
            let urls = selection
            endSearch()
            if !urls.isEmpty { reveal(urls) }
            files.columns.focus(state.tab.focus)
            return true
        }
        switch (flags, key) {
        case ([.command], "f"):
            if Self.closedWithoutAccess(tab.folder, settings: settings) == nil { beginSearch(scope: tab.folder) }
        case ([.control], "\t"): switchTab()
        case ([.command], "t"):
            state.toggleTab(home: Self.home)
            render()
            files.columns.focus(state.tab.focus)
        case ([.command], "w"):
            if state.closeTab() { render(); files.columns.focus(state.tab.focus) } else { onDismiss?() }
        case ([.command], "c"): copySelection()
        case ([.command], "v"): paste(moving: false)
        case ([.command, .shift], "v"), ([.command, .option], "v"): paste(moving: true)
        case ([.command], "d"):
            operations.duplicate(selection) { [weak self] made in self?.select(made) }
        case ([.command, .shift], "n"): newFolder()
        case ([.command], "\u{8}"), ([.command], "\u{7f}"): trash()
        case ([.command, .option], "\u{8}"), ([.command, .option], "\u{7f}"): deleteNow()
        case ([.command], "z"): operations.undo { [weak self] made in self?.select(made) }
        case ([.command, .shift], "z"): operations.redo { [weak self] made in self?.select(made) }
        case ([.command, .shift], "h"): go(to: Self.home)
        case ([.command, .shift], "d"): go(to: Self.home.appendingPathComponent("Desktop"))
        case ([.command, .shift], "o"): go(to: Self.home.appendingPathComponent("Documents"))
        case ([.command, .option], "l"): go(to: Self.home.appendingPathComponent("Downloads"))
        case ([.command, .shift], "a"): go(to: URL(fileURLWithPath: "/Applications"))
        // The period by its key, where ⇧ makes it ">", or as typed, where ⇧ is what types it.
        case ([.command, .shift], _) where event.keyCode == 47 || event.characters == ".":
            settings[Settings.showHiddenFiles].toggle()
        case ([.command, .shift], "g"): pathBar.beginTyping(Self.abbreviate(tab.folder) + "/")
        case ([.command], "e"): eject()
        case ([.command], "."): operations.cancel()
        case ([.command], "k"): showActions()
        case ([.command], "y"): toggleQuickLook()
        case ([.command], _) where event.keyCode == 126: enclosing()
        case ([.command], _) where event.keyCode == 125: self.key(.open, in: tab.focus)
        default: return false
        }
        return true
    }

    /// ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z and ⌘⌫, as a text field takes them.
    private static let textEditing: [(NSEvent.ModifierFlags, String)] = [
        ([.command], "a"), ([.command], "c"), ([.command], "v"), ([.command], "x"), ([.command], "z"),
        ([.command, .shift], "z"), ([.command], "\u{8}"), ([.command], "\u{7f}"),
    ]

    // MARK: - Operations

    /// What an operation made, selected where it landed.
    private func select(_ urls: [URL]) {
        let urls = urls.map(\.canonical)
        guard let first = urls.first else {
            render()
            return
        }
        let folder = first.parentFolder
        listings[folder] = nil
        if folder == state.tab.folder {
            state.select(urls.filter { $0.parentFolder == folder }, in: state.tab.focus, opens: false)
        } else {
            reveal(urls)
        }
        render()
        files.columns.focus(state.tab.focus)
    }

    private func copySelection() {
        let urls = selection
        guard !urls.isEmpty else { return }
        OwnWrite.write { $0.writeObjects(urls.map { $0 as NSURL }) }
        toast?(urls.count == 1 ? "Copied" : "Copied \(urls.count) items")
    }

    private func paste(moving: Bool) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        let folder = state.tab.folder
        let done: @MainActor ([URL]) -> Void = { [weak self] made in self?.select(made) }
        if moving { operations.move(urls, to: folder, done: done) } else { operations.copy(urls, to: folder, done: done) }
    }

    /// A drop from anywhere: what landed in the folder showing is selected.
    private func drop(_ urls: [URL], into folder: URL, moving: Bool) {
        let done: @MainActor ([URL]) -> Void = { [weak self] made in
            guard let self else { return }
            if made.first?.parentFolder == self.state.tab.folder { self.select(made) } else { self.render() }
        }
        if moving { operations.move(urls, to: folder, done: done) } else { operations.copy(urls, to: folder, done: done) }
    }

    private func newFolder() {
        do {
            let url = try operations.newFolder(in: state.tab.folder).canonical
            select([url])
            rename(url)
        } catch {
            report(FileProblem(error, item: state.tab.folder))
        }
    }

    private func trash() {
        let urls = selection
        guard !urls.isEmpty else { return }
        operations.trash(urls) { [weak self] _ in self?.render() }
        toast?(urls.count == 1 ? "Moved to Trash" : "Moved \(urls.count) items to Trash")
    }

    private func deleteNow() {
        let urls = selection
        guard !urls.isEmpty else { return }
        let what = urls.count == 1 ? "Delete “\(urls[0].lastPathComponent)” at once" : "Delete \(urls.count) items at once"
        confirm?(what) { [weak self] in self?.operations.delete(urls) { _ in self?.render() } }
    }

    private func eject() {
        guard let url = selectedEntries.first(where: \.isVolume)?.url ?? (DirectoryListing.entry(state.tab.folder, closed: linkClosed)?.isVolume == true ? state.tab.folder : nil) else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            go(to: Self.home)
        } catch {
            toast?(error.localizedDescription)
        }
    }

    /// The name in its row becomes editable; ↩ renames, Esc keeps it.
    private func rename(_ url: URL) {
        files.columns.columns[safe: state.tab.focus]?.edit(url) { [weak self] name in
            guard let self else { return }
            guard let name, name != url.lastPathComponent else {
                self.files.columns.focus(self.state.tab.focus)
                return
            }
            do {
                let renamed = try self.operations.rename(url, to: name).canonical
                self.state.moved(url, to: renamed)
                self.listings[url.parentFolder] = nil
                self.render()
            } catch {
                self.report(FileProblem(error, item: url))
            }
            self.files.columns.focus(self.state.tab.focus)
        }
    }

    /// ⌘K: what can be done to the selection, or to the folder.
    private func showActions() {
        let selection = selectedEntries
        let builder = MenuBuilder()
        if selection.count == 1, let problem = problems[selection[0].url], let title = Self.title(of: problem.remedy) {
            builder.item(title) { [weak self] in self?.remedy(problem) }
            builder.separator()
        }
        if let entry = selection.first {
            builder.item("Open") { [weak self] in self?.key(.open, in: 0) }
            if selection.count == 1, !entry.isFolder {
                builder.submenu("Open With") { [weak self] submenu in
                    for app in NSWorkspace.shared.urlsForApplications(toOpen: entry.url).prefix(12) {
                        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
                        submenu.item(name) {
                            NSWorkspace.shared.open([entry.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                            self?.onDismiss?()
                        }
                    }
                }
            }
            builder.item("Quick Look") { [weak self] in self?.toggleQuickLook() }
            builder.separator()
            if selection.count == 1 { builder.item("Rename") { [weak self] in self?.rename(entry.url) } }
            builder.item("Duplicate") { [weak self] in
                self?.operations.duplicate(selection.map(\.url)) { made in self?.select(made) }
            }
            builder.item("Copy") { [weak self] in self?.copySelection() }
            builder.item("Copy Path") { [weak self] in
                OwnWrite.write { $0.setString(selection.map(\.url.path).joined(separator: "\n"), forType: .string) }
                self?.toast?("Copied")
            }
            builder.separator()
            builder.item("Move to Trash") { [weak self] in self?.trash() }
            builder.separator()
        }
        builder.item("New Folder") { [weak self] in self?.newFolder() }
        builder.item("Open in Finder") { [weak self] in
            guard let self else { return }
            // The folder itself with nothing selected; else Finder shows the selection.
            if selection.isEmpty { FileViewerTakeover.openInFinder(self.state.tab.folder) } else { FileViewerTakeover.showInFinder(selection.map(\.url)) }
            self.onDismiss?()
        }
        menu = builder
        let anchor = files.columns.anchor(for: state.tab.focus, selection: state.tab.selection.first)
        builder.menu.popUp(positioning: nil, at: anchor.point, in: anchor.view)
    }

    // MARK: - Problems

    /// On the item's row when it is in view, else a toast.
    private func report(_ problem: FileProblem) {
        guard let item = problem.item, isShown(item) else {
            toast?(problem.message)
            return
        }
        problems[item] = problem
        render()
    }

    /// How far the operations going into the other tab's folder have got, once they have run a moment.
    private func otherTabProgress() -> Double? {
        guard let other = state.other?.folder else { return nil }
        let going = operations.jobs.filter { job in
            guard let destination = job.destination?.canonical, Date().timeIntervalSince(job.started) >= FilesBanner.delay else { return false }
            return destination == other || destination.path.hasPrefix(other.path + "/")
        }
        guard !going.isEmpty else { return nil }
        let total = going.map(\.progress.totalUnitCount).reduce(0, +)
        return total > 0 ? Double(going.map(\.progress.completedUnitCount).reduce(0, +)) / Double(total) : 0
    }

    private func isShown(_ url: URL) -> Bool {
        if let search { return search.results.contains { $0.url == url } }
        return state.tab.columns.contains { $0.folder == url.parentFolder } && entries(in: url.parentFolder).contains { $0.url == url }
    }

    /// A new operation starts afresh: the last one's problems go.
    private func jobsChanged() {
        let count = operations.jobs.count
        defer { jobCount = count }
        files.banner.show(jobs: operations.jobs)
        pathBar.showProgress(otherTabProgress())
        guard count > jobCount, !problems.isEmpty else { return }
        problems = [:]
        render()
    }

    private func remedy(_ problem: FileProblem) {
        switch problem.remedy {
        case .allowAccess:
            // The pane, and a watch for the grant landing — the choice the user made at the ask stands.
            NSWorkspace.shared.open(FileAccess.fullDiskAccessPane)
            FileAccess.awaitFullDiskAccess { [weak self] in
                self?.listings = [:]
                self?.render()
                self?.notice?("dock2 can see all your files now")
            }
        case .openInFinder: FileViewerTakeover.showInFinder(problem.item.map { [$0] } ?? [state.tab.folder])
        case .none: return
        }
        onDismiss?()
    }

    static func title(of remedy: FileProblem.Remedy) -> String? {
        switch remedy {
        case .allowAccess: "Allow Access…"
        case .openInFinder: "Show in Finder"
        case .none: nil
        }
    }

    // MARK: - Places

    /// Home for what is in it, otherwise the root of its volume: where its columns start.
    static func root(of url: URL) -> URL {
        if url.path == home.path || url.path.hasPrefix(home.path + "/") { return home }
        return (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
    }

    static func segments(_ folder: URL) -> [PathBar.Segment] {
        let root = root(of: folder)
        var segments = [PathBar.Segment(title: title(root), url: root)]
        var url = root
        for name in folder.path.dropFirst(root.path.count).split(separator: "/") {
            url.appendPathComponent(String(name))
            segments.append(PathBar.Segment(title: String(name), url: url))
        }
        return segments
    }

    /// "~" for home, a volume's name for its root, otherwise the folder's name.
    static func title(_ folder: URL) -> String {
        if folder.path == home.path { return "~" }
        if (try? folder.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true {
            return (try? folder.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? folder.lastPathComponent
        }
        return FileManager.default.displayName(atPath: folder.path)
    }

    static func abbreviate(_ url: URL) -> String {
        url.path == home.path ? "~" : url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
    }

    // MARK: - Access

    /// A place dock2 keeps locked itself: what Allow Access… would open. A folder macOS or its owner refuses
    /// is the error it is, which access would not change.
    struct ClosedForAccess: LocalizedError {
        var errorDescription: String? { "dock2 can't see in here." }
    }

    /// A place macOS would ask about, when dock2 has neither Full Disk Access nor the user's leave to ask:
    /// shown locked rather than raising a prompt by looking.
    static func closedWithoutAccess(_ folder: URL, settings: SettingsStore) -> Error? {
        FileAccess.isClosedReached(folder, choice: settings[Settings.fileAccess]) ? ClosedForAccess() : nil
    }

    static func describe(_ error: Error) -> String {
        error.localizedDescription
    }

    static func isClosedForAccess(_ error: Error) -> Bool {
        error is ClosedForAccess
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
