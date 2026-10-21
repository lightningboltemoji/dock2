import AppKit
import Dock2Core
import Dock2System
import QuickLookThumbnailing

/// What a drop does ([files](product/files/README.md#drag-and-drop)): within one volume it moves and ⌥
/// makes it a copy; across volumes it copies and ⌘ makes it a move, as in Finder.
@MainActor
enum DropRule {
    static func moves(_ urls: [URL], to folder: URL, allowed: NSDragOperation) -> Bool {
        let sameVolume = urls.allSatisfy { sameVolume($0, folder) }
        // ⌥ leaves only copy; ⌘ leaves only generic, Finder's "move".
        if allowed == .copy { return false }
        if allowed == .generic || allowed == .move { return true }
        return sameVolume
    }

    static func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Nothing dropped into itself, or where it already is.
    static func accepts(_ urls: [URL], into folder: URL) -> Bool {
        !urls.isEmpty && !urls.contains { folder.canonical == $0.canonical || folder.path.hasPrefix($0.path + "/") }
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let first = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let second = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        return first.map { second?.isEqual($0) ?? false } ?? false
    }
}

/// A key a column hands to Files rather than handling itself.
enum ColumnKey {
    case left, right, open, enclosing, quickLook
    /// `~` or `/`: a path, typed into the path bar.
    case path(String)
}

/// Files' columns ([files](product/files/README.md#layout)), measured off Finder's column view: 246pt
/// columns, rows on a 22pt pitch from 6pt down, a 16pt icon 17pt in and 13pt names 20pt past it; then the
/// preview. They scroll sideways to keep the current column in view.
@MainActor
final class ColumnsView: NSView {
    static let columnWidth: CGFloat = 246
    static let previewWidth = PanelMetrics.filesSize.width - 3 * columnWidth

    private let scroll = NSScrollView()
    private let strip = NSView()
    private(set) var columns: [ColumnView] = []
    let preview = PreviewView()
    /// ⌘F's results, in the columns' place.
    let results = ColumnView()
    private var isSearching = false

    var onSelect: ((Int, [FileEntry]) -> Void)?
    var onKey: ((Int, ColumnKey) -> Bool)?
    var onOpen: ((Int, FileEntry) -> Void)?
    var onRename: ((FileEntry) -> Void)?
    /// Items dropped into a folder, to move or copy there.
    var onDrop: (([URL], URL, _ moving: Bool) -> Void)?
    /// A problem's button, pressed.
    var onRemedy: ((FileProblem) -> Void)?
    /// A locked place's Allow Access…, pressed.
    /// Allow Access… under a locked folder's message.
    var onAllowAccess: ((URL) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = strip
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        strip.addSubview(preview)
        results.isHidden = true
        results.onSelect = { [weak self] entries in self?.onSelect?(-1, entries) }
        results.onOpen = { [weak self] entry in self?.onOpen?(-1, entry) }
        results.onRemedy = { [weak self] problem in self?.onRemedy?(problem) }
        addSubview(results)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// One column per listing, the preview after them when it has something to show.
    /// ⌘F's results beside the preview, in place of the columns; nil for the columns again.
    func showResults(_ listing: ColumnView.Listing?, preview item: PreviewView.Item?) {
        isSearching = listing != nil
        scroll.isHidden = isSearching
        results.isHidden = !isSearching
        if let listing { results.show(listing) }
        if isSearching {
            preview.removeFromSuperview()
            addSubview(preview)
            preview.show(item)
        } else if preview.superview !== strip {
            preview.removeFromSuperview()
            strip.addSubview(preview)
        }
        needsLayout = true
    }

    func show(_ listings: [ColumnView.Listing], focus: Int, preview item: PreviewView.Item?) {
        while columns.count < listings.count {
            let column = ColumnView()
            let index = columns.count
            column.onSelect = { [weak self] entries in self?.onSelect?(index, entries) }
            column.onKey = { [weak self] key in self?.onKey?(index, key) ?? false }
            column.onOpen = { [weak self] entry in self?.onOpen?(index, entry) }
            column.onRename = { [weak self] entry in self?.onRename?(entry) }
            column.onDrop = { [weak self] urls, folder, moving in self?.onDrop?(urls, folder, moving) }
            column.onRemedy = { [weak self] problem in self?.onRemedy?(problem) }
            column.onAllowAccess = { [weak self] folder in self?.onAllowAccess?(folder) }
            strip.addSubview(column)
            columns.append(column)
        }
        while columns.count > listings.count { columns.removeLast().removeFromSuperview() }
        for (column, listing) in zip(columns, listings) { column.show(listing) }
        preview.show(item)
        layoutStrip()
        reveal(focus)
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        results.frame = CGRect(x: 0, y: 0, width: bounds.width - Self.previewWidth, height: bounds.height)
        if isSearching {
            preview.isHidden = !preview.hasItem
            preview.frame = CGRect(x: bounds.width - Self.previewWidth, y: 0, width: Self.previewWidth, height: bounds.height)
        } else {
            layoutStrip()
        }
    }

    private func layoutStrip() {
        let height = bounds.height
        for (index, column) in columns.enumerated() {
            column.frame = CGRect(x: CGFloat(index) * Self.columnWidth, y: 0, width: Self.columnWidth, height: height)
        }
        let end = CGFloat(columns.count) * Self.columnWidth
        preview.isHidden = !preview.hasItem
        preview.frame = CGRect(x: end, y: 0, width: Self.previewWidth, height: height)
        strip.frame = CGRect(x: 0, y: 0, width: max(bounds.width, end + (preview.hasItem ? Self.previewWidth : 0)), height: height)
    }

    /// Scrolls to the far end by whole columns, but never past the column with the keys.
    private func reveal(_ focus: Int) {
        let overflow = max(0, strip.frame.width - bounds.width)
        let x = min(CGFloat(focus) * Self.columnWidth, (overflow / Self.columnWidth).rounded(.up) * Self.columnWidth)
        scroll.contentView.scroll(to: CGPoint(x: x, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func focus(_ index: Int) {
        guard columns.indices.contains(index) else { return }
        window?.makeFirstResponder(columns[index].table)
    }

    func cancelEditing() -> Bool {
        columns.contains { $0.cancelEditing() }
    }

    /// Where a menu for a column's selection opens: beside its row, or at the column's top.
    func anchor(for index: Int, selection: URL?) -> (view: NSView, point: CGPoint) {
        guard columns.indices.contains(index) else { return (self, CGPoint(x: 20, y: bounds.maxY - 20)) }
        let column = columns[index]
        if let selection, let rect = column.rowRect(selection) {
            return (column, CGPoint(x: rect.maxX - 40, y: rect.minY))
        }
        return (column, CGPoint(x: 20, y: column.bounds.maxY - 10))
    }
}

/// One folder's items: Finder's rows, the selection a rounded band — the accent colour in the column with
/// the keys, grey in the ones before it.
@MainActor
final class ColumnView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct Listing {
        var folder: URL
        var entries: [FileEntry]
        var selection: [URL]
        /// Shown in place of the items: a place macOS keeps closed, or an error.
        var message: String?
        /// Beside each name, where it is: for search's results.
        var details: [URL: String] = [:]
        /// Beneath a name, what could not be done to it.
        var problems: [URL: FileProblem] = [:]
        /// Folders macOS keeps closed to dock2: a lock in place of the chevron.
        var locked: Set<URL> = []
        /// The message is a locked place's: Allow Access… beneath it.
        var offersAccess = false
    }

    let table = ColumnTable()
    private let scroll = NSScrollView()
    private let separator = CALayer()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let allowAccess = NSButton(title: "Allow Access…", target: nil, action: nil)
    private var entries: [FileEntry] = []
    private var updating = false
    /// The row being renamed, which a reload must not take away; a listing that adds or removes items
    /// waits until it is done.
    private var editingRow: Int?
    private var waiting: Listing?
    private var folder: URL?
    private var isClosed = false
    private var details: [URL: String] = [:]
    private var problems: [URL: FileProblem] = [:]
    private var locked: Set<URL> = []
    var onDrop: (([URL], URL, Bool) -> Void)?
    var onRemedy: ((FileProblem) -> Void)?
    var onAllowAccess: ((URL) -> Void)?
    var onSelect: (([FileEntry]) -> Void)?
    var onKey: ((ColumnKey) -> Bool)?
    var onOpen: ((FileEntry) -> Void)?
    var onRename: ((FileEntry) -> Void)?

    static let rowHeight: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        let column = NSTableColumn(identifier: .init("name"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.onKey = { [weak self] key in self?.onKey?(key) ?? false }
        table.onDragExit = { [weak self] in self?.hover(nil) }
        table.onSlowClick = { [weak self] row in
            guard let self, self.entries.indices.contains(row) else { return }
            self.onRename?(self.entries[row])
        }
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: false)
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.registerForDraggedTypes([.fileURL])
        table.draggingDestinationFeedbackStyle = .regular
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        addSubview(scroll)
        separator.backgroundColor = NSColor.separatorColor.cgColor
        layer!.addSublayer(separator)
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.isHidden = true
        addSubview(message)
        allowAccess.bezelStyle = .push
        allowAccess.controlSize = .small
        allowAccess.target = self
        allowAccess.action = #selector(allowAccessPressed)
        allowAccess.isHidden = true
        addSubview(allowAccess)
    }

    @objc private func allowAccessPressed() {
        if let folder { onAllowAccess?(folder) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ listing: Listing) {
        if editingRow != nil, listing.entries.map(\.url) != entries.map(\.url) {
            waiting = listing
            return
        }
        updating = true
        defer { updating = false }
        folder = listing.folder
        isClosed = listing.message != nil
        let problems = listing.problems.filter { url, _ in listing.entries.contains { $0.url == url } }
        if listing.details != details || problems != self.problems || listing.locked != locked {
            details = listing.details
            self.problems = problems
            locked = listing.locked
            table.reloadData()
        }
        if listing.entries != entries {
            let old = entries
            entries = listing.entries
            if old.map(\.url) == entries.map(\.url) {
                let changed = IndexSet(entries.indices.filter { old[$0] != entries[$0] && $0 != editingRow })
                if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: [0]) }
            } else {
                table.reloadData()
            }
        }
        let rows = IndexSet(listing.selection.compactMap { url in entries.firstIndex { $0.url == url } })
        if rows != table.selectedRowIndexes { table.selectRowIndexes(rows, byExtendingSelection: false) }
        if let first = rows.first { table.scrollRowToVisible(first) }
        message.stringValue = listing.message ?? ""
        message.isHidden = listing.message == nil
        allowAccess.isHidden = !listing.offersAccess
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        table.tableColumns.first?.width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separator.frame = CGRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height)
        separator.backgroundColor = NSColor.separatorColor.cgColor
        CATransaction.commit()
        message.frame = CGRect(x: 16, y: bounds.height / 2 - 30, width: bounds.width - 32, height: 60)
        let button = allowAccess.fittingSize
        allowAccess.frame = CGRect(x: (bounds.width - button.width) / 2, y: message.frame.minY - button.height + 12,
                                   width: button.width, height: button.height)
    }

    var selected: [FileEntry] { table.selectedRowIndexes.map { entries[$0] } }

    func rowRect(_ url: URL) -> CGRect? {
        guard let row = entries.firstIndex(where: { $0.url == url }) else { return nil }
        return convert(table.rect(ofRow: row), from: table)
    }

    /// The row's name made editable in place; `done` hears the new name when ↩ or a click elsewhere ends
    /// it, nil when Esc does.
    func edit(_ url: URL, done: @escaping (String?) -> Void) {
        guard let row = entries.firstIndex(where: { $0.url == url }) else { return }
        table.scrollRowToVisible(row)
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell else { return }
        editingRow = row
        cell.beginEditing { [weak self] name in
            self?.editingRow = nil
            done(name)
            if let waiting = self?.waiting {
                self?.waiting = nil
                self?.show(waiting)
            }
        }
    }

    /// Esc while renaming: the old name stays. False when nothing was being renamed.
    func cancelEditing() -> Bool {
        guard let row = editingRow, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell else { return false }
        cell.cancelEditing()
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: FileCell.identifier, owner: nil) as? FileCell ?? FileCell()
        cell.show(entries[row], detail: details[entries[row].url], problem: problems[entries[row].url], locked: locked.contains(entries[row].url))
        cell.onRemedy = { [weak self] problem in self?.onRemedy?(problem) }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row), let problem = problems[entries[row].url] else { return Self.rowHeight }
        return Self.rowHeight + FileCell.problemHeight(problem, width: tableView.tableColumns.first?.width ?? ColumnsView.columnWidth)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SelectionRowView()
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        entries[row].name
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        onSelect?(selected)
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        entries[row].url as NSURL
    }

    /// Onto a folder's row, into that folder; anywhere else, into this column's.
    private func target(_ tableView: NSTableView, row: Int, operation: NSTableView.DropOperation) -> URL? {
        if operation == .on, entries.indices.contains(row), entries[row].isFolder { return entries[row].url }
        tableView.setDropRow(-1, dropOperation: .on)
        return isClosed ? nil : folder
    }

    /// The folder a drag is held over, and the wait before it opens: Finder's spring-loading, which a
    /// table's own drag handling never offers. The system's delay and its switch apply.
    private var springRow: Int?
    private var spring: DispatchWorkItem?

    private func hover(_ row: Int?) {
        guard row != springRow else { return }
        springRow = row
        spring?.cancel()
        spring = nil
        let global = UserDefaults(suiteName: UserDefaults.globalDomain)
        guard let row, entries.indices.contains(row), entries[row].isFolder,
              global?.object(forKey: "com.apple.springing.enabled") as? Bool ?? true else { return }
        let delay = global?.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        let open = DispatchWorkItem { [weak self] in
            guard let self, self.springRow == row, self.entries.indices.contains(row) else { return }
            self.onSelect?([self.entries[row]])
        }
        spring = open
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: open)
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        hover(operation == .on ? row : nil)
        let urls = DropRule.fileURLs(info)
        guard let target = target(tableView, row: row, operation: operation), DropRule.accepts(urls, into: target) else { return [] }
        return DropRule.moves(urls, to: target, allowed: info.draggingSourceOperationMask) ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation operation: NSTableView.DropOperation) -> Bool {
        hover(nil)
        let urls = DropRule.fileURLs(info)
        let into = operation == .on && entries.indices.contains(row) && entries[row].isFolder ? entries[row].url : folder
        guard let into, !isClosed || into != folder, DropRule.accepts(urls, into: into) else { return false }
        onDrop?(urls, into, DropRule.moves(urls, to: into, allowed: info.draggingSourceOperationMask))
        return true
    }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0 else { return }
        onOpen?(entries[table.clickedRow])
    }
}

/// The table in a column: the keys Finder gives meaning to go to Files; ↑ ↓ and type-select stay its own.
@MainActor
final class ColumnTable: NSTableView {
    var onKey: ((ColumnKey) -> Bool)?
    /// A drag left the table: no folder is held over any more.
    var onDragExit: (() -> Void)?
    /// A click on the name of the item already selected, not followed by another: Finder's rename.
    var onSlowClick: ((Int) -> Void)?
    private var pendingRename: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        pendingRename?.cancel()
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let wasSelected = row >= 0 && selectedRowIndexes == [row] && window?.firstResponder === self
        // The table's own loop runs until the button comes up: selecting, dragging, double-clicking.
        super.mouseDown(with: event)
        guard wasSelected, event.clickCount == 1, let up = window?.currentEvent, up.type == .leftMouseUp,
              hypot(up.locationInWindow.x - event.locationInWindow.x, up.locationInWindow.y - event.locationInWindow.y) < 4,
              let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell,
              cell.isOnName(cell.convert(event.locationInWindow, from: nil)) else { return }
        let rename = DispatchWorkItem { [weak self] in self?.onSlowClick?(row) }
        pendingRename = rename
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: rename)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key: ColumnKey?
        switch Int(event.keyCode) {
        case 123 where flags.isEmpty: key = .left
        case 124 where flags.isEmpty: key = .right
        case 36, 76: key = .open
        case 125 where flags == .command: key = .open
        case 126 where flags == .command: key = .enclosing
        case 49 where flags.isEmpty: key = .quickLook
        default:
            let typed = event.characters ?? ""
            key = (typed == "~" || typed == "/") ? .path(typed) : nil
        }
        if let key, onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    // The arrows' own handling of ← and → would move nothing in a one-column table: Files does it.
    override func moveLeft(_ sender: Any?) {}
    override func moveRight(_ sender: Any?) {}
}

/// Finder's selection: a band inset 10.5pt and 10pt, radius 6; the accent colour while the table has the
/// keys, grey otherwise.
@MainActor
private final class SelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = CGRect(x: 10.5, y: 0, width: bounds.width - 20.5, height: bounds.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isEmphasized ? NSColor.controlAccentColor : NSColor(white: 0, alpha: 0.1)).setFill()
        path.fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

/// A row: the icon, the name, and a › for a folder; a cloud for an item not on this Mac.
@MainActor
private final class FileCell: NSTableCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("file")
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let accessory = NSImageView()
    private let detail = NSTextField(labelWithString: "")
    private let problemText = NSTextField(wrappingLabelWithString: "")
    private let remedy = NSButton(title: "", target: nil, action: nil)
    private var problem: FileProblem?
    private var isFolder = false
    var onRemedy: ((FileProblem) -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        imageView = icon
        textField = name
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingMiddle
        accessory.contentTintColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingHead
        detail.alignment = .right
        problemText.font = Self.problemFont
        problemText.textColor = .secondaryLabelColor
        // A wrapping label, its last line truncated: a plain label stays one line whatever its line break.
        problemText.lineBreakMode = .byWordWrapping
        problemText.maximumNumberOfLines = 2
        problemText.cell?.wraps = true
        problemText.cell?.truncatesLastVisibleLine = true
        remedy.bezelStyle = .inline
        remedy.controlSize = .small
        remedy.font = .systemFont(ofSize: 10, weight: .medium)
        remedy.target = self
        remedy.action = #selector(remedyPressed)
        for view in [icon, name, accessory, detail, problemText, remedy] { addSubview(view) }
    }

    @objc private func remedyPressed() {
        if let problem { onRemedy?(problem) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): endEditing(commit: true)
        case #selector(NSResponder.cancelOperation(_:)): endEditing(commit: false)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endEditing(commit: true)
    }

    func show(_ entry: FileEntry, detail: String? = nil, problem: FileProblem? = nil, locked: Bool = false) {
        self.detail.stringValue = detail ?? ""
        self.detail.isHidden = detail == nil
        self.problem = problem
        problemText.stringValue = problem?.message ?? ""
        problemText.isHidden = problem == nil
        toolTip = problem?.message
        let remedyTitle = problem.flatMap { FilesScreen.title(of: $0.remedy) }
        remedy.title = remedyTitle ?? ""
        remedy.isHidden = remedyTitle == nil
        icon.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        name.stringValue = entry.name
        name.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
        isFolder = entry.isFolder
        let symbol = locked ? "lock.fill" : entry.isCloudOnly ? "icloud.and.arrow.down" : entry.isFolder ? "chevron.right" : nil
        accessory.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        accessory.isHidden = symbol == nil
        setAccessibilityLabel([entry.isFolder ? "\(entry.name), folder" : entry.name, locked ? "locked" : nil, problem?.message]
            .compactMap { $0 }.joined(separator: ", "))
        needsLayout = true
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let selected = backgroundStyle == .emphasized
            name.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
            accessory.contentTintColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            detail.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
            problemText.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    private var editing: ((String?) -> Void)?

    /// Renaming in place, the name up to its extension selected, as Finder does.
    func beginEditing(done: @escaping (String?) -> Void) {
        editing = done
        name.isEditable = true
        name.isBezeled = false
        name.drawsBackground = true
        name.backgroundColor = .textBackgroundColor
        name.textColor = .labelColor
        name.delegate = self
        window?.makeFirstResponder(name)
        let base = (name.stringValue as NSString).deletingPathExtension
        name.currentEditor()?.selectedRange = NSRange(location: 0, length: (base.isEmpty ? name.stringValue : base).utf16.count)
    }

    func cancelEditing() { endEditing(commit: false) }

    func isOnName(_ point: CGPoint) -> Bool {
        name.frame.insetBy(dx: 0, dy: -2).contains(point)
    }

    private func endEditing(commit: Bool) {
        guard let done = editing else { return }
        editing = nil
        name.isEditable = false
        name.drawsBackground = false
        done(commit ? name.stringValue : nil)
    }

    override func layout() {
        super.layout()
        // The name's line keeps a plain row's place at the top; a problem takes the line below it.
        let line = CGRect(x: 0, y: bounds.height - ColumnView.rowHeight, width: bounds.width, height: ColumnView.rowHeight)
        icon.frame = CGRect(x: 17, y: line.midY - 8, width: 16, height: 16)
        let nameHeight = name.intrinsicContentSize.height
        // A result's folder takes up to two fifths of the row, its name the rest.
        let fitting = detail.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: line.height)).width
        let detailWidth = detail.isHidden || detail.stringValue.isEmpty ? 0 : min(fitting.rounded(.up) + 2, (bounds.width - 71) * 0.4)
        name.frame = CGRect(x: 37, y: line.midY - nameHeight / 2, width: bounds.width - 37 - 34 - detailWidth, height: nameHeight)
        let detailHeight = detail.intrinsicContentSize.height
        detail.frame = CGRect(x: bounds.width - 34 - detailWidth, y: line.midY - detailHeight / 2, width: detailWidth, height: detailHeight)
        accessory.frame = CGRect(x: bounds.width - 30, y: line.midY - 6, width: 12, height: 12)
        guard let problem else { return }
        // Beneath the name: the problem in up to two lines, then its remedy.
        let textHeight = Self.textHeight(problem.message, width: bounds.width - Self.problemInset)
        problemText.frame = CGRect(x: 37, y: line.minY - textHeight, width: bounds.width - Self.problemInset, height: textHeight)
        let remedySize = remedy.fittingSize
        remedy.frame = CGRect(x: 33, y: problemText.frame.minY - 2 - remedySize.height, width: remedySize.width, height: remedySize.height)
    }

    private static let problemFont = NSFont.systemFont(ofSize: 11)
    /// The text's left edge, under the name, and its right margin.
    private static let problemInset: CGFloat = 37 + 14
    private static let remedyHeight: CGFloat = 22

    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let line = (problemFont.ascender - problemFont.descender + problemFont.leading).rounded(.up)
        let fitted = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: problemFont]).height
        // A text field draws inside a couple of points of padding: without them the second line will not fit.
        return min(fitted.rounded(.up), 2 * line) + 4
    }

    /// What a problem adds to its row.
    static func problemHeight(_ problem: FileProblem, width: CGFloat) -> CGFloat {
        textHeight(problem.message, width: width - problemInset) + (FilesScreen.title(of: problem.remedy) == nil ? 4 : remedyHeight + 4)
    }
}

/// The last column: a file's thumbnail and what it is; a folder's count; how many are selected.
@MainActor
final class PreviewView: NSView {
    enum Item {
        case file(FileEntry)
        case folder(FileEntry, count: Int?)
        case several(Int)
    }

    private let image = NSImageView()
    private let name = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextField(wrappingLabelWithString: "")
    private var item: Item?
    private var request: QLThumbnailGenerator.Request?
    var hasItem: Bool { item != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        image.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center
        details.font = .systemFont(ofSize: 11)
        details.textColor = .secondaryLabelColor
        details.alignment = .center
        for view in [image, name, details] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ item: Item?) {
        self.item = item
        if let request { QLThumbnailGenerator.shared.cancel(request) }
        request = nil
        switch item {
        case .file(let entry):
            image.image = NSWorkspace.shared.icon(forFile: entry.url.path)
            name.stringValue = entry.name
            details.stringValue = Self.describe(entry)
            thumbnail(entry.url)
        case .folder(let entry, let count):
            image.image = NSWorkspace.shared.icon(forFile: entry.url.path)
            name.stringValue = entry.name
            details.stringValue = count.map { $0 == 1 ? "1 item" : "\($0) items" } ?? "Folder"
        case .several(let count):
            image.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            name.stringValue = "\(count) items"
            details.stringValue = ""
        case nil:
            image.image = nil
        }
        needsLayout = true
    }

    /// Counts thumbnails asked for, so a late one for an item no longer shown is dropped.
    private var thumbnails = 0

    private func thumbnail(_ url: URL) {
        thumbnails += 1
        let generation = thumbnails
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 180, height: 180),
                                                   scale: window?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        self.request = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            guard image != nil else { return }
            DispatchQueue.main.async {
                guard let self, self.thumbnails == generation else { return }
                self.image.image = image
            }
        }
    }

    private static func describe(_ entry: FileEntry) -> String {
        var lines: [String] = []
        let size = entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        lines.append([entry.kind, size].compactMap { $0 }.joined(separator: " · "))
        let format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        if let created = entry.created { lines.append("Created \(created.formatted(format))") }
        if let modified = entry.modified { lines.append("Modified \(modified.formatted(format))") }
        return lines.joined(separator: "\n")
    }

    override func layout() {
        super.layout()
        let width = bounds.width - 32
        image.frame = CGRect(x: 16, y: bounds.height - 16 - 160, width: width, height: 160)
        let nameHeight = name.sizeThatFits(CGSize(width: width, height: 60)).height
        name.frame = CGRect(x: 16, y: image.frame.minY - 12 - nameHeight, width: width, height: nameHeight)
        let detailsHeight = details.sizeThatFits(CGSize(width: width, height: 120)).height
        details.frame = CGRect(x: 16, y: name.frame.minY - 6 - detailsHeight, width: width, height: detailsHeight)
    }
}
