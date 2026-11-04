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
    var tile: TileKind? { .finder }
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
    /// Files shown again where it was: macOS's sign-in window took dock2's place, and the mount it asked
    /// for is done.
    var onReturn: (() -> Void)?
    var toast: ((String) -> Void)?
    /// Said where the field was, after dock2 let go: the grant landing while System Settings is in front.
    var notice: ((String) -> Void)?
    var confirm: ((Feedback.Confirmation, @escaping () -> Void) -> Void)?

    /// What operations could not do, on the rows of the items they could not do it to — until the next
    /// operation starts, or Files closes.
    private var problems: [URL: FileProblem] = [:]
    private var jobCount = 0

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private var observations: [SettingsObservation] = []
    private var showsHidden: Bool { settings[Settings.showHiddenFiles] }
    /// The places' pop-up's, read as Files opens and as volumes come and go: the volumes are asked for each time.
    private var places = Places.all
    /// The servers connected to, read with the places.
    private var servers = Servers.connected
    private var volumes: [NSObjectProtocol] = []
    /// Network's servers, browsed while Files shows Network.
    private let browser = NetworkBrowser()

    /// A server's shares, or a share's mount: asked for once, kept until Try Again ([servers](product/files/README.md#servers)).
    private enum Fetch<Value> {
        case waiting
        case done(Value)
        case failed(ServerProblem)
    }

    private var shareListings: [URL: Fetch<ShareListing.Listing>] = [:]
    /// By the share's address, until it is mounted and its columns move to where it was mounted.
    private var mounts: [URL: Fetch<Void>] = [:]
    /// macOS's sign-in window came forward while a mount waited, dismissing dock2: its window is at the
    /// Dock's level, above the sign-in's, so it cannot stay up beneath it.
    private var steppedAsideForSignIn = false
    private static let signIn = "com.apple.NetAuthAgent"

    init(operations: FileOperations, settings: SettingsStore) {
        self.operations = operations
        self.settings = settings
        state = FilesState(home: Self.home)
        files.columns.onSelect = { [weak self] column, entries in self?.selected(entries, in: column) }
        files.columns.onKey = { [weak self] column, key in self?.key(key, in: column) ?? false }
        files.columns.onOpen = { [weak self] _, entry in self?.open(entry) }
        files.columns.onRename = { [weak self] entry in self?.rename(entry.url) }
        files.columns.onMenu = { [weak self] column, entry in self?.contextMenu(in: column, on: entry) }
        files.columns.onDrop = { [weak self] urls, folder, moving in self?.drop(urls, into: folder, moving: moving) }
        files.columns.onRemedy = { [weak self] problem in self?.remedy(problem) }
        files.columns.onMessageButton = { [weak self] folder in self?.messageButton(in: folder) }
        files.columns.onEject = { [weak self] entry in self?.eject(entry) }
        pathBar.onEject = { [weak self] place in self?.eject(place) }
        browser.onChange = { [weak self] in self?.render() }
        pathBar.onDrop = { [weak self] urls, folder, moving in self?.drop(urls, into: folder, moving: moving) }
        pathBar.onGo = { [weak self] url in self?.go(to: url) }
        pathBar.tabs.onSelect = { [weak self] index in self?.showTab(index) }
        pathBar.tabs.onClose = { [weak self] index in self?.closeTab(index) }
        pathBar.tabs.onNew = { [weak self] in self?.newTab() }
        pathBar.tabs.onDrop = { [weak self] urls, folder, moving in self?.drop(urls, into: folder, moving: moving) }
        pathBar.onGoToFolder = { [weak self] in
            guard let self else { return }
            self.pathBar.beginTyping(Self.abbreviate(self.state.tab.folder) + "/")
        }
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
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumes.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.canonical
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if name == NSWorkspace.didUnmountNotification, let volume { self.unmounted(volume) }
                    self.servers = Servers.connected
                    self.places = Places.all
                    self.render()
                }
            })
        }
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
        goState(to: folder, selecting: items, opens: opens)
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
        places = Places.all
        servers = Servers.connected
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
                self?.notice?("Dock2 can see all your files now")
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
        browser.stop()
        steppedAsideForSignIn = signingIn > 0 && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.signIn
    }

    /// Mounts that may show macOS's sign-in window, under way.
    private var signingIn = 0

    /// A mount through macOS's sign-in window done: Files comes back to show it, unless it was cancelled.
    private func signedIn(_ succeeded: Bool) {
        signingIn -= 1
        guard steppedAsideForSignIn, signingIn == 0 else { return }
        steppedAsideForSignIn = false
        if succeeded { onReturn?() }
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
                let locked = Set(entries.filter { $0.isFolder && $0.url.isFileURL && closedBySpelling($0.url) }.map(\.url))
                return ColumnView.Listing(folder: column.folder, entries: entries, selection: column.selection, problems: problems, locked: locked)
            case .failure(let error):
                return ColumnView.Listing(folder: column.folder, entries: [], selection: [], message: Self.describe(error),
                                          button: Self.button(for: error))
            }
        }
        files.columns.show(listings, focus: tab.focus, preview: previewItem())
        let selected = tab.selection.count == 1 ? tab.selection.first.flatMap { url in
            entries(in: tab.folder).first { $0.url == url }
        } : nil
        pathBar.places = places
        pathBar.show(Self.segments(tab.folder, places: places), selected: selected)
        showTabs()
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
        if entry.remote != nil { return .folder(entry, count: nil) }
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
        if !folder.isFileURL { return remoteListing(folder) }
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
        for folder in folders where watches[folder] == nil && folder.isFileURL {
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
            open(selectedEntries)
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
        state.enclosing(parent: Servers.parent(of: state.tab.columns[0].folder))
        render()
        files.columns.focus(state.tab.focus)
    }

    func go(to url: URL) {
        let url = url.isFileURL ? shown(url.canonical) : location(url)
        typedFolder = nil
        let isFolder = !url.isFileURL || (DirectoryListing.entry(url, closed: linkClosed)?.isFolder ?? true)
        if isFolder {
            goState(to: url)
        } else {
            goState(to: url.parentFolder, selecting: [url])
        }
        render()
        files.columns.focus(state.tab.focus)
    }

    /// The tab's columns from `folder`'s root to it, a share's server above the root.
    private func goState(to folder: URL, selecting: [URL] = [], opens: Bool = false) {
        let root = Self.root(of: folder)
        state.go(to: folder, root: root, above: Self.above(root), selecting: selecting, opens: opens)
    }

    /// A server or a share as its column holds it: who it is reached as left out, a share mounted already
    /// where it is mounted.
    private func location(_ url: URL) -> URL {
        guard let server = Servers.server(of: url) else { return url }
        guard Servers.isShare(url) else { return server }
        return servers.first { $0.url == server }?.root(of: url.lastPathComponent) ?? Servers.plain(url)
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
        if entry.isFolder, let column = column(holding: entry.url) {
            let tab = state.tab
            // Selected where the keys are, its column is open already.
            if tab.focus != column || tab.selection != [entry.url] || column + 1 == tab.columns.count {
                state.select([entry.url], in: column, opens: true)
            }
            enter()
            return
        }
        NSWorkspace.shared.open(entry.url)
        onDismiss?()
    }

    /// Several opened: the files, each in its app; a folder alone opens in place.
    private func open(_ entries: [FileEntry]) {
        if entries.count == 1 { return open(entries[0]) }
        let files = entries.filter { !$0.isFolder }.map(\.url)
        guard !files.isEmpty else { return }
        files.forEach { NSWorkspace.shared.open($0) }
        onDismiss?()
    }

    /// The column listing `url`'s folder — a share's server's, a server's Network's; none while searching,
    /// which lists results instead.
    private func column(holding url: URL) -> Int? {
        guard search == nil else { return nil }
        let parent = Servers.parent(of: url)
        return state.tab.columns.firstIndex { $0.folder == url.parentFolder || $0.folder == parent }
    }

    // MARK: - Typing a path

    /// The columns follow the deepest folder the typed path reaches.
    private func follow(_ text: String) {
        guard !PathInput.isAddress(text) else { return }
        let path = PathInput.expand(text, home: Self.home.path)
        // Told it is not a folder, a URL reads nothing to find out: the path may be inside a closed one.
        var url = shown(URL(fileURLWithPath: path, isDirectory: false))
        while url.path != "/", !(DirectoryListing.entry(url, closed: linkClosed)?.isFolder ?? false) { url.deleteLastPathComponent() }
        guard url != state.tab.folder else { return }
        goState(to: url)
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
        guard !PathInput.isAddress(text) else { return text }
        let (folder, _) = PathInput.split(text, home: Self.home.path)
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard reachable(url) else { return text }
        let entries = (try? DirectoryListing.list(url, showsHidden: true, closed: linkClosed)) ?? []
        return PathInput.complete(text, entries: entries.map { ($0.url.lastPathComponent, $0.isFolder) })
    }

    private func submit(_ text: String) {
        if PathInput.isAddress(text) {
            guard let url = URL(string: text), Servers.server(of: url) != nil else {
                toast?("Nothing at \(text)")
                return
            }
            pathBar.endTyping()
            return go(to: url)
        }
        let url = URL(fileURLWithPath: PathInput.expand(text, home: Self.home.path), isDirectory: false)
        guard shown(url) != url || FileManager.default.fileExists(atPath: url.path) else {
            toast?("Nothing at \(text)")
            return
        }
        pathBar.endTyping()
        go(to: url)
    }

    // MARK: - Tabs

    private func showTabs() {
        let tabs = state.tabs.map { TabStrip.Tab(title: Self.title($0.folder), folder: $0.folder, progress: progress(into: $0.folder)) }
        pathBar.tabs.show(tabs, current: state.current, canAdd: state.tabs.count < FilesState.maximumTabs)
    }

    /// ⌘T, or New Tab: at Home, beside the tab showing.
    private func newTab() {
        guard state.newTab(at: Self.home) else { return NSSound.beep() }
        tabChanged()
    }

    private func showTab(_ index: Int) {
        guard index != state.current else { return }
        state.show(tab: index)
        tabChanged()
    }

    private func cycleTab(by offset: Int) {
        guard state.tabs.count > 1 else { return }
        state.cycleTab(by: offset)
        tabChanged()
    }

    private func closeTab(_ index: Int? = nil) {
        if state.closeTab(index) { tabChanged() } else { onDismiss?() }
    }

    /// Another tab's columns, crossfaded in: a place changing, not a view sliding.
    private func tabChanged() {
        if search != nil { endSearch() }
        if pathBar.isTyping { pathBar.endTyping() }
        typedFolder = nil
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        files.columns.layer?.add(fade, forKey: "tab")
        render()
        files.columns.focus(state.tab.focus)
    }

    // MARK: - Quick Look

    /// Space: the selection's first item, or `item`, filling the view.
    private func toggleQuickLook(_ item: URL? = nil) {
        if quickLook != nil {
            closeQuickLook()
            return
        }
        guard let url = item ?? selection.first, url.isFileURL else { return }
        // The whole sheet, whose corners round it.
        let preview = QLPreviewView(frame: files.bounds, style: .normal)!
        preview.autoresizingMask = [.width, .height]
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
        // Network's column and a server's hold no files: nothing is copied, pasted or made there.
        let onDisk = tab.folder.isFileURL
        switch (flags, key) {
        case ([.command], "f"):
            if onDisk, Self.closedWithoutAccess(tab.folder, settings: settings) == nil { beginSearch(scope: tab.folder) }
        case ([.control], "\t"): cycleTab(by: 1)
        case ([.control, .shift], "\t"), ([.control, .shift], "\u{19}"): cycleTab(by: -1)
        case ([.command, .shift], "]"), ([.command, .shift], "}"): cycleTab(by: 1)
        case ([.command, .shift], "["), ([.command, .shift], "{"): cycleTab(by: -1)
        case ([.command], "t"): newTab()
        case ([.command], "w"): closeTab()
        case ([.command], "c"): if onDisk { copy(selection) }
        case ([.command], "v"): if onDisk { paste(moving: false) }
        case ([.command, .shift], "v"), ([.command, .option], "v"): if onDisk { paste(moving: true) }
        case ([.command], "d"):
            if onDisk { operations.duplicate(selection) { [weak self] made in self?.select(made) } }
        case ([.command, .shift], "n"): if onDisk { newFolder(in: tab.folder) }
        case ([.command], "\u{8}"), ([.command], "\u{7f}"): if onDisk { trash(selection) }
        case ([.command, .option], "\u{8}"), ([.command, .option], "\u{7f}"): if onDisk { deleteNow() }
        case ([.command], "z"): operations.undo { [weak self] made in self?.select(made) }
        case ([.command, .shift], "z"): operations.redo { [weak self] made in self?.select(made) }
        case ([.command, .shift], "h"): go(to: Self.home)
        case ([.command, .shift], "d"): go(to: Self.home.appendingPathComponent("Desktop"))
        case ([.command, .shift], "o"): go(to: Self.home.appendingPathComponent("Documents"))
        case ([.command, .option], "l"): go(to: Self.home.appendingPathComponent("Downloads"))
        case ([.command, .shift], "a"): go(to: URL(fileURLWithPath: "/Applications"))
        case ([.command, .shift], "i"): if let cloud = places.first(where: { $0.kind == .iCloudDrive }) { go(to: cloud.url) }
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

    private func copy(_ urls: [URL]) {
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

    private func newFolder(in folder: URL) {
        do {
            let url = try operations.newFolder(in: folder).canonical
            select([url])
            rename(url)
        } catch {
            report(FileProblem(error, item: folder))
        }
    }

    private func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        operations.trash(urls) { [weak self] _ in self?.render() }
        toast?(urls.count == 1 ? "Moved to Trash" : "Moved \(urls.count) items to Trash")
    }

    private func deleteNow() {
        let urls = selection
        guard !urls.isEmpty else { return }
        let what = urls.count == 1 ? "Delete “\(urls[0].lastPathComponent)” at once?" : "Delete \(urls.count) items at once?"
        confirm?(.init(question: what, action: "Delete")) { [weak self] in self?.operations.delete(urls) { _ in self?.render() } }
    }

    // MARK: - Ejecting

    /// ⌘E: the selection that ejects, else the server whose column this is, else the disk or share the
    /// folder is on.
    private func eject() {
        if let entry = selectedEntries.first(where: \.ejects) { return eject(entry) }
        let folder = state.tab.folder
        if let server = servers.first(where: { $0.url == folder }) { return disconnect(server) }
        guard folder.isFileURL, let volume = (try? folder.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              let entry = DirectoryListing.entry(volume, closed: linkClosed), entry.ejects else { return }
        eject(entry)
    }

    /// A row's ⏏, or ⌘K's: a server disconnected; a share, or a disk, ejected.
    private func eject(_ entry: FileEntry) {
        if entry.remote == .server {
            if let server = servers.first(where: { $0.url == entry.url }) { disconnect(server) }
            return
        }
        let name = entry.remote == nil ? Self.title(entry.url) : entry.name
        Eject.eject(entry.url) { [weak self] error in
            if let error { self?.toast?(Eject.message(error, name: name)) }
        }
    }

    /// The places pop-up's ⏏.
    private func eject(_ place: Place) {
        if place.kind == .server, let server = servers.first(where: { $0.url == place.url }) { return disconnect(server) }
        guard let entry = DirectoryListing.entry(place.url, closed: linkClosed) else { return }
        eject(entry)
    }

    /// Every share mounted from `server`; its shares listed again, as a guest now.
    private func disconnect(_ server: Server) {
        Eject.disconnect(server) { [weak self] share, error in
            guard let self else { return }
            if let share, let error { self.toast?(Eject.message(error, name: share.lastPathComponent)) }
            self.shareListings[server.url] = nil
            self.render()
        }
    }

    /// A volume gone, by ⏏ or otherwise: its columns close, and a tab that started in it shows its server,
    /// or Home.
    private func unmounted(_ volume: URL) {
        let server = servers.first { $0.shares.contains(volume) }?.url
        state.removed([volume], parent: { _ in server ?? Self.home })
        listings[volume] = nil
    }

    // MARK: - Servers

    /// Network's servers, a server's shares, a share mounting: what their columns list, fetched as they are
    /// first shown ([servers](product/files/README.md#servers)).
    private func remoteListing(_ folder: URL) -> Result<[FileEntry], Error> {
        if folder == Servers.network {
            browser.start()
            let announced = Set(browser.servers)
            let urls = browser.servers + servers.map(\.url).filter { !announced.contains($0) }
            let entries = urls.map { url in
                FileEntry(remote: .server, url: url, name: Servers.name(of: url), ejects: servers.contains { $0.url == url })
            }
            if entries.isEmpty {
                return .failure(browser.isDenied ? ColumnMessage(text: "Dock2 isn't allowed to see the local network.", button: "Open Settings…")
                                                 : ColumnMessage(text: "No servers found."))
            }
            return .success(FinderOrder.sorted(entries, name: \.name, isFolder: { _ in false }))
        }
        if Servers.isServer(folder) {
            switch shareListings[folder] {
            case nil:
                list(folder)
                return .failure(ColumnMessage(text: "Connecting…"))
            case .waiting:
                return .failure(ColumnMessage(text: "Connecting…"))
            case .failed(let problem):
                return .failure(ColumnMessage(text: Self.describe(problem, at: folder), button: problem == .needsSignIn ? "Connect As…" : "Try Again"))
            case .done(let listing):
                let server = servers.first { $0.url == folder }
                let entries = listing.shares.map { name in
                    if let root = server?.root(of: name) { return FileEntry(remote: .share(mounted: true), url: root, name: name, ejects: true) }
                    return FileEntry(remote: .share(mounted: false), url: Servers.address(of: name, on: folder), name: name, ejects: false)
                }
                return .success(FinderOrder.sorted(entries, name: \.name, isFolder: { _ in false }))
            }
        }
        guard Servers.isShare(folder) else { return .success([]) }
        // A share is mounted as it is selected, as Finder's columns do.
        switch mounts[folder] {
        case nil:
            mount(folder)
            return .failure(ColumnMessage(text: "Connecting…"))
        case .waiting, .done:
            return .failure(ColumnMessage(text: "Connecting…"))
        case .failed(let problem):
            return .failure(ColumnMessage(text: Self.describe(problem, at: folder), button: problem == .cancelled ? "Connect" : "Try Again"))
        }
    }

    private func list(_ server: URL) {
        shareListings[server] = .waiting
        ShareListing.list(server, as: servers.first { $0.url == server }?.user) { [weak self] result in
            guard let self, case .waiting = self.shareListings[server] else { return }
            switch result {
            case .success(let listing): self.shareListings[server] = .done(listing)
            case .failure(let problem): self.shareListings[server] = .failed(problem)
            }
            self.render()
        }
    }

    /// Mounted as the server is connected as, or as its listing was; macOS asks if it needs more. Its columns
    /// follow it to where it was mounted.
    private func mount(_ address: URL) {
        guard let server = Servers.server(of: address) else { return }
        mounts[address] = .waiting
        var user = servers.first { $0.url == server }?.user
        if user == nil, case .done(let listing) = shareListings[server] { user = listing.user }
        signingIn += 1
        ShareMount.mount(Servers.address(of: address.lastPathComponent, on: server, user: user)) { [weak self] result in
            guard let self else { return }
            defer { self.signedIn(result.isSuccess) }
            switch result {
            case .success(let points):
                self.mounts[address] = nil
                self.servers = Servers.connected
                self.places = Places.all
                if let point = points.first { self.state.moved(address, to: point) }
            case .failure(let problem):
                self.mounts[address] = .failed(problem)
            }
            self.render()
        }
    }

    /// Connect As…: macOS's window, asking for a name whatever the Keychain holds; the server's shares are
    /// listed again as whoever signed in.
    private func connect(as server: URL) {
        signingIn += 1
        ShareMount.mount(Servers.address(of: nil, on: server), signIn: true) { [weak self] result in
            guard let self else { return }
            defer { self.signedIn(result.isSuccess) }
            if case .failure(let problem) = result, problem != .cancelled { self.toast?(Self.describe(problem, at: server)) }
            self.servers = Servers.connected
            self.places = Places.all
            self.shareListings[server] = nil
            self.render()
        }
    }

    /// A column message's button: Allow Access…, or for the network, Try Again, Connect, Connect As… and
    /// Local Network's switch.
    private func messageButton(in folder: URL) {
        guard !folder.isFileURL else { return allowAccess(to: folder) }
        if folder == Servers.network {
            NSWorkspace.shared.open(Self.localNetworkPane)
            onDismiss?()
        } else if Servers.isServer(folder) {
            if case .failed(.needsSignIn) = shareListings[folder] { return connect(as: folder) }
            shareListings[folder] = nil
        } else {
            mounts[folder] = nil
        }
        render()
    }

    static let localNetworkPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    static func describe(_ problem: ServerProblem, at url: URL) -> String {
        let name = Servers.server(of: url).map(Servers.name(of:)) ?? url.absoluteString
        switch problem {
        case .unreachable: return "“\(name)” can't be reached."
        case .needsSignIn, .cancelled: return "Not Connected"
        case .failed(let code) where code > 0: return "“\(name)”: \(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)"
        case .failed(let code): return "“\(name)” can't be opened (error \(code))."
        }
    }

    /// The name in its row becomes editable; ↩ renames, Esc keeps it.
    private func rename(_ url: URL) {
        guard let column = column(holding: url), state.tab.columns[column].folder.isFileURL else { return }
        files.columns.columns[safe: column]?.edit(url) { [weak self] name in
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

    /// ⌘K: what can be done to the selection, or to the folder, beside it.
    private func showActions() {
        let builder = actions(for: selectedEntries, in: state.tab.folder)
        let anchor = files.columns.anchor(for: state.tab.focus, selection: state.tab.selection.first)
        builder.menu.popUp(positioning: nil, at: anchor.point, in: anchor.view)
    }

    /// A right-click on an item: ⌘K's menu for the selection when the item is in it, otherwise for the item
    /// alone, the selection left as it was. Between items, the column's folder's.
    private func contextMenu(in column: Int, on entry: FileEntry?) -> NSMenu? {
        if column < 0 {
            guard let search, let entry else { return nil }
            let targets = search.selection.contains(entry.url) ? selectedEntries : [entry]
            return actions(for: targets, in: search.scope ?? state.tab.folder).menu
        }
        guard let shown = state.tab.columns[safe: column] else { return nil }
        let targets = entry.map { entry in
            shown.selection.contains(entry.url) ? entries(in: shown.folder).filter { shown.selection.contains($0.url) } : [entry]
        } ?? []
        return actions(for: targets, in: shown.folder).menu
    }

    /// What can be done to `targets`, or with none, in `folder`.
    private func actions(for targets: [FileEntry], in folder: URL) -> MenuBuilder {
        if !folder.isFileURL || targets.contains(where: { $0.remote != nil }) { return networkActions(for: targets, in: folder) }
        let builder = MenuBuilder()
        menu = builder
        let urls = targets.map(\.url)
        if targets.count == 1, let problem = problems[urls[0]], let title = Self.title(of: problem.remedy) {
            builder.item(title) { [weak self] in self?.remedy(problem) }
            builder.separator()
        }
        if let entry = targets.first {
            builder.item("Open") { [weak self] in self?.open(targets) }
            if !targets.contains(where: \.isFolder) {
                builder.submenu("Open With") { [weak self] submenu in
                    OpenWithMenu.fill(submenu, for: urls) { self?.onDismiss?() }
                }
            }
            builder.item("Quick Look") { [weak self] in self?.toggleQuickLook(entry.url) }
            builder.separator()
            // A result's row is no column's: it has nowhere to be renamed.
            if targets.count == 1, search == nil { builder.item("Rename") { [weak self] in self?.rename(entry.url) } }
            builder.item("Duplicate") { [weak self] in
                self?.operations.duplicate(urls) { made in self?.select(made) }
            }
            builder.separator()
            builder.item("Copy") { [weak self] in self?.copy(urls) }
            builder.item("Copy Path") { [weak self] in
                OwnWrite.write { $0.setString(urls.map(\.path).joined(separator: "\n"), forType: .string) }
                self?.toast?("Copied")
            }
            if targets.count == 1, !entry.isFolder, !entry.isPackage, let kind = FileContents.kind(of: entry.url, local: !entry.isCloudOnly) {
                builder.item("Copy Contents") { [weak self] in self?.copyContents(entry, as: kind) }
            }
            // The other tabs' folders: what tabs are for.
            let others = state.tabs.indices.filter { $0 != state.current }.map { state.tabs[$0].folder }
                .filter { folder in DropRule.accepts(urls, into: folder) && !urls.allSatisfy { $0.parentFolder == folder } }
            if !others.isEmpty {
                builder.separator()
                for folder in others {
                    builder.item("Copy to “\(Self.title(folder))”") { [weak self] in self?.drop(urls, into: folder, moving: false) }
                    builder.item("Move to “\(Self.title(folder))”") { [weak self] in self?.drop(urls, into: folder, moving: true) }
                }
            }
            builder.separator()
            if targets.count == 1, entry.ejects { builder.item("Eject") { [weak self] in self?.eject(entry) } }
            builder.item("Move to Trash") { [weak self] in self?.trash(urls) }
            builder.separator()
        }
        builder.item("New Folder") { [weak self] in self?.newFolder(in: folder) }
        builder.item("Open in Finder") { [weak self] in
            // The folder itself with nothing chosen; else Finder shows the items.
            if urls.isEmpty { FileViewerTakeover.openInFinder(folder) } else { FileViewerTakeover.showInFinder(urls) }
            self?.onDismiss?()
        }
        return builder
    }

    /// In Network's column and a server's: opening, ejecting, and the server's Connect As… and Disconnect.
    private func networkActions(for targets: [FileEntry], in folder: URL) -> MenuBuilder {
        let builder = MenuBuilder()
        menu = builder
        if targets.count == 1, let entry = targets.first {
            builder.item("Open") { [weak self] in self?.open(entry) }
            if entry.ejects { builder.item(entry.remote == .server ? "Disconnect" : "Eject") { [weak self] in self?.eject(entry) } }
        }
        let server = targets.count == 1 && targets[0].remote == .server ? targets[0].url : Servers.isServer(folder) ? folder : nil
        if let server {
            if !builder.menu.items.isEmpty { builder.separator() }
            builder.item("Connect As…") { [weak self] in self?.connect(as: server) }
            if targets.isEmpty, let connected = servers.first(where: { $0.url == server }) {
                builder.item("Disconnect") { [weak self] in self?.disconnect(connected) }
            }
        }
        return builder
    }

    /// A file's text, or its picture, read off the main thread. Past `FileContents.askAbove` it asks first:
    /// that much is likely a mistake.
    private func copyContents(_ entry: FileEntry, as kind: FileContents.Kind) {
        let url = entry.url
        let copy = { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let read = Result { try FileContents.read(url, as: kind) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch read {
                        case .success(let contents):
                            OwnWrite.write { FileContents.write(contents, to: $0) }
                            self?.toast?("Copied")
                        case .failure(let error):
                            self?.report(FileProblem(error, item: url))
                        }
                    }
                }
            }
        }
        guard let size = entry.size, size > FileContents.askAbove else { return copy() }
        let amount = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        confirm?(.init(question: "“\(entry.name)” is \(amount).", action: "Copy Contents", destructive: false), copy)
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

    /// How far the operations going into `folder` have got, once they have run a moment: shown on the pill
    /// of a tab not showing.
    private func progress(into folder: URL) -> Double? {
        guard folder != state.tab.folder else { return nil }
        let going = operations.jobs.filter { job in
            guard let destination = job.destination?.canonical, Date().timeIntervalSince(job.started) >= FilesBanner.delay else { return false }
            return destination == folder || destination.path.hasPrefix(folder.path + "/")
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
        showTabs()
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
                self?.notice?("Dock2 can see all your files now")
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

    /// Home for what is in it, otherwise the root of its volume: where its columns start. A share not yet
    /// mounted starts at its server, and Network at itself.
    static func root(of url: URL) -> URL {
        if !url.isFileURL { return Servers.server(of: url) ?? url }
        if url.path == home.path || url.path.hasPrefix(home.path + "/") { return home }
        return (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(fileURLWithPath: "/")
    }

    /// The columns before a root: a share's server.
    static func above(_ root: URL) -> [URL] {
        guard root.isFileURL, root != home, let server = Servers.server(ofRoot: root) else { return [] }
        return [server]
    }

    /// The folders from its root to it, the root with its place's symbol — a share's server before it.
    static func segments(_ folder: URL, places: [Place]) -> [PathBar.Segment] {
        if !folder.isFileURL {
            guard let server = Servers.server(of: folder) else { return [PathBar.Segment(title: "Network", url: Servers.network, symbol: "network")] }
            let share = Servers.isShare(folder) ? [PathBar.Segment(title: folder.lastPathComponent, url: folder)] : []
            return [PathBar.Segment(title: Servers.name(of: server), url: server, symbol: "server.rack")] + share
        }
        let root = root(of: folder)
        var segments: [PathBar.Segment]
        if let server = above(root).first {
            segments = [PathBar.Segment(title: Servers.name(of: server), url: server, symbol: "server.rack"), PathBar.Segment(title: title(root), url: root)]
        } else {
            let place = places.first { $0.url.canonical == root.canonical }
            segments = [PathBar.Segment(title: title(root), url: root, symbol: place?.symbol ?? "internaldrive")]
        }
        var url = root
        for name in folder.path.dropFirst(root.path.count).split(separator: "/") {
            url.appendPathComponent(String(name))
            segments.append(PathBar.Segment(title: String(name), url: url))
        }
        return segments
    }

    /// "Home" for home, a volume's name for its root, a server's or a share's, otherwise the folder's name.
    static func title(_ folder: URL) -> String {
        if !folder.isFileURL { return Servers.isShare(folder) ? folder.lastPathComponent : Servers.name(of: folder) }
        if folder.path == home.path { return "Home" }
        if (try? folder.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true {
            return (try? folder.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? folder.lastPathComponent
        }
        return FileManager.default.displayName(atPath: folder.path)
    }

    /// `~` for home, a server's address as Connect to Server takes it, Home again for Network.
    static func abbreviate(_ url: URL) -> String {
        if url == Servers.network { return "~" }
        if !url.isFileURL { return url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString }
        return url.path == home.path ? "~" : url.path.hasPrefix(home.path + "/") ? "~" + url.path.dropFirst(home.path.count) : url.path
    }

    // MARK: - Access

    /// A place dock2 keeps locked itself: what Allow Access… would open. A folder macOS or its owner refuses
    /// is the error it is, which access would not change.
    struct ClosedForAccess: LocalizedError {
        var errorDescription: String? { "Dock2 can't see in here." }
    }

    /// A place macOS would ask about, when dock2 has neither Full Disk Access nor the user's leave to ask:
    /// shown locked rather than raising a prompt by looking.
    static func closedWithoutAccess(_ folder: URL, settings: SettingsStore) -> Error? {
        FileAccess.isClosedReached(folder, choice: settings[Settings.fileAccess]) ? ClosedForAccess() : nil
    }

    /// A column's message in place of its items, and the button beneath it: a server connecting, not
    /// answering, wanting a name.
    struct ColumnMessage: LocalizedError {
        var text: String
        var button: String?
        var errorDescription: String? { text }
    }

    static func describe(_ error: Error) -> String {
        error.localizedDescription
    }

    static func button(for error: Error) -> String? {
        if error is ClosedForAccess { return "Allow Access…" }
        return (error as? ColumnMessage)?.button
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { true } else { false }
    }
}

