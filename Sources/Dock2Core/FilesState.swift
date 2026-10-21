import Foundation

extension URL {
    /// A file URL in one spelling — no trailing slash, no `.` or `..` — so an item equals itself however it
    /// was reached: a folder's URL gains a slash once it exists, and a listing's or an operation's may not.
    public var canonical: URL { URL(fileURLWithPath: standardizedFileURL.path, isDirectory: false) }

    /// The folder holding it, canonical: `deletingLastPathComponent` adds a slash.
    public var parentFolder: URL { deletingLastPathComponent().canonical }
}

/// Where Files is ([files](product/files/README.md)): its tabs, each a chain of columns — a folder each, a
/// selected folder opening the next — and the column the keys are in. Kept while dock2 runs.
public struct FilesState: Equatable, Sendable {
    public struct Column: Equatable, Sendable {
        public var folder: URL
        public var selection: [URL]

        public init(folder: URL, selection: [URL] = []) {
            self.folder = folder.canonical
            self.selection = selection.map(\.canonical)
        }
    }

    public struct Tab: Equatable, Sendable {
        public var columns: [Column]
        /// The column the keys are in.
        public var focus: Int

        public init(at folder: URL) {
            columns = [Column(folder: folder)]
            focus = 0
        }

        /// The current folder: what the path bar shows, and where a paste lands.
        public var folder: URL { columns[focus].folder }
        public var selection: [URL] { columns[focus].selection }
    }

    public private(set) var tabs: [Tab]
    public private(set) var current = 0

    /// As many as the bar has room for, a pill each beside the path.
    public static let maximumTabs = 6

    public init(home: URL) {
        tabs = [Tab(at: home)]
    }

    public var tab: Tab {
        get { tabs[current] }
        set { tabs[current] = newValue }
    }

    // MARK: - Moving about

    /// Goes to `folder` with its columns from `root` — home, or the volume it is on — and `selecting` in it;
    /// a single folder selected opens beside it when `opens`.
    public mutating func go(to folder: URL, root: URL, selecting: [URL] = [], opens: Bool = false) {
        var chain = [folder.canonical]
        if let inside = Self.relative(folder, to: root) {
            chain = [root.canonical]
            for name in inside { chain.append(chain[chain.count - 1].appendingPathComponent(name).canonical) }
        }
        tab.columns = zip(chain, chain.dropFirst().map { [$0] } + [[]]).map { Column(folder: $0, selection: $1) }
        tab.focus = chain.count - 1
        select(selecting, in: tab.focus, opens: opens)
    }

    /// Selects `items` in a column, closing the columns past it; a single folder, when `opens`, opens in
    /// the next. The keys go to that column.
    public mutating func select(_ items: [URL], in column: Int, opens: Bool) {
        guard tab.columns.indices.contains(column) else { return }
        let items = items.map(\.canonical)
        tab.columns[column].selection = items
        tab.columns.removeSubrange((column + 1)...)
        if opens, items.count == 1 { tab.columns.append(Column(folder: items[0])) }
        tab.focus = column
    }

    /// →: into the folder selected, whose column is open. False when there is none.
    @discardableResult
    public mutating func enter() -> Bool {
        guard tab.focus + 1 < tab.columns.count else { return false }
        tab.focus += 1
        return true
    }

    /// ←: back to the enclosing folder's column, leaving this one open with nothing selected, as Finder
    /// does. False in the first column.
    @discardableResult
    public mutating func leave() -> Bool {
        guard tab.focus > 0 else { return false }
        tab.columns[tab.focus].selection = []
        tab.columns.removeSubrange((tab.focus + 1)...)
        tab.focus -= 1
        return true
    }

    /// ⌘↑: the enclosing folder, with the current one selected in it; from the first column, a column for
    /// `parent` is added before it. Nothing above the root of the disk.
    public mutating func enclosing(parent: URL?) {
        if leave() { return }
        guard let parent, parent.canonical != tab.columns[0].folder else { return }
        tab.columns.insert(Column(folder: parent, selection: [tab.columns[0].folder]), at: 0)
        tab.focus = 0
    }

    // MARK: - Tabs

    /// ⌘T: a new tab at `folder`, after the one showing, and shown. False with no room for another.
    @discardableResult
    public mutating func newTab(at folder: URL) -> Bool {
        guard tabs.count < Self.maximumTabs else { return false }
        tabs.insert(Tab(at: folder), at: current + 1)
        current += 1
        return true
    }

    /// A tab's pill, clicked.
    public mutating func show(tab index: Int) {
        if tabs.indices.contains(index) { current = index }
    }

    /// ⌃⇥ and ⌃⇧⇥: the next tab or the previous, round the ends.
    public mutating func cycleTab(by offset: Int) {
        current = ((current + offset) % tabs.count + tabs.count) % tabs.count
    }

    /// ⌘W, or a pill's close button: the tab after it shows, or the one before when it was last. False for
    /// the only tab, which dismisses instead.
    public mutating func closeTab(_ index: Int? = nil) -> Bool {
        let index = index ?? current
        guard tabs.count > 1, tabs.indices.contains(index) else { return false }
        tabs.remove(at: index)
        if index < current || current == tabs.count { current -= 1 }
        return true
    }

    // MARK: - Changes on disk

    /// An item renamed or moved: every column and selection inside it follows.
    public mutating func moved(_ old: URL, to new: URL) {
        func follow(_ url: URL) -> URL {
            guard let inside = Self.relative(url, to: old) else { return url }
            return inside.reduce(new) { $0.appendingPathComponent($1) }.canonical
        }
        for index in tabs.indices {
            for column in tabs[index].columns.indices {
                tabs[index].columns[column].folder = follow(tabs[index].columns[column].folder)
                tabs[index].columns[column].selection = tabs[index].columns[column].selection.map(follow)
            }
        }
    }

    /// Items gone — deleted, trashed, moved away: unselected, and their columns closed. A tab whose first
    /// column went shows the folder that held it.
    public mutating func removed(_ urls: [URL]) {
        func gone(_ url: URL) -> Bool { urls.contains { Self.relative(url, to: $0) != nil } }
        for index in tabs.indices {
            var tab = tabs[index]
            if let first = tab.columns.firstIndex(where: { gone($0.folder) }) {
                if first == 0 {
                    tab = Tab(at: tab.columns[0].folder.parentFolder)
                } else {
                    tab.columns.removeSubrange(first...)
                    tab.focus = min(tab.focus, first - 1)
                }
            }
            for column in tab.columns.indices { tab.columns[column].selection.removeAll(where: gone) }
            tabs[index] = tab
        }
    }

    /// The names leading from `folder` to `url`; empty for the folder itself, nil when `url` is not in it.
    static func relative(_ url: URL, to folder: URL) -> [String]? {
        let path = url.standardizedFileURL.path, base = folder.standardizedFileURL.path
        if path == base { return [] }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }
}
