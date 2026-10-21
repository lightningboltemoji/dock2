import AppKit
import Dock2Core
import Dock2System

/// Files' bar, in the field's place ([files](product/files/README.md#layout)): the current folder as a
/// breadcrumb — a click on a folder goes there, a drop puts items in it, and the first is a pop-up of the
/// places — or a path being typed, Tab completing it, or ⌘F's search; the tabs at its end.
@MainActor
final class PathBar: NSView, NSTextFieldDelegate {
    struct Segment: Equatable {
        var title: String
        var url: URL
        /// The first segment's: Home's house, a volume's drive.
        var symbol: String?
    }

    private let glyph = NSImageView()
    private var crumbs: [PillButton] = []
    private var chevrons: [NSImageView] = []
    /// The folders left out of a path too long to show whole, behind one "…".
    private let ellipsis = PillButton()
    private var folded: [Segment] = []
    /// The item selected in the last folder, after it: named, not a place to go.
    private let selected = PillButton()
    private var selectedURL: URL?
    private let text = NSTextField()
    let tabs = TabStrip()
    private var path: [Segment] = []
    /// The pop-up showing: its handlers live in the builder.
    private var popUp: MenuBuilder?

    enum Mode { case segments, path, search }
    private(set) var mode = Mode.segments
    var isTyping: Bool { mode == .path }
    var isSearching: Bool { mode == .search }
    /// Its field has the keys: a path typed, or ⌘F's query.
    var isEditing: Bool { mode != .segments && text.currentEditor() != nil }

    /// A segment or a place chosen.
    var onGo: ((URL) -> Void)?
    /// The places' menu's Go to Folder….
    var onGoToFolder: (() -> Void)?
    /// What the first segment's pop-up lists, and the one holding the folder showing.
    var places: [Place] = []
    /// Items dropped on a segment.
    var onDrop: (([URL], URL, _ moving: Bool) -> Void)?
    /// While typing: the text, to follow; ↩ with it; Tab asking for its completion.
    var onTyped: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onComplete: ((String) -> String)?
    /// While searching: the text as it changes, and ↑ ↓ ↩ for the results.
    var onSearch: ((String) -> Void)?
    var onSearchCommand: ((Selector) -> Bool)?

    static let fontSize: CGFloat = 15
    /// The pills' height; centred in the bar, their corners are concentric with its ends.
    static let pillHeight: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        glyph.contentTintColor = .labelColor
        glyph.isHidden = true
        addSubview(glyph)
        ellipsis.set(title: "", image: TabStrip.symbol("ellipsis", size: 13))
        ellipsis.padding = 8
        ellipsis.icon.contentTintColor = .secondaryLabelColor
        ellipsis.setAccessibilityLabel("Enclosing folders")
        ellipsis.onClick = { [weak self] in self?.showFolded() }
        addSubview(ellipsis)
        selected.isInert = true
        selected.padding = 6
        selected.label.font = .systemFont(ofSize: Self.fontSize)
        selected.label.textColor = .labelColor
        selected.label.lineBreakMode = .byTruncatingMiddle
        addSubview(selected)
        text.isBordered = false
        text.drawsBackground = false
        text.focusRingType = .none
        text.font = .systemFont(ofSize: PanelMetrics.fontSize)
        text.cell?.usesSingleLineMode = true
        text.cell?.isScrollable = true
        text.delegate = self
        text.isHidden = true
        text.setAccessibilityLabel("Path")
        addSubview(text)
        addSubview(tabs)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    /// The segments, and the item selected in the last folder, if one is.
    func show(_ path: [Segment], selected item: URL?) {
        if path != self.path {
            self.path = path
            while crumbs.count < path.count {
                let crumb = PillButton()
                crumb.padding = 8
                let index = crumbs.count
                crumb.onClick = { [weak self] in
                    guard let self, self.path.indices.contains(index) else { return }
                    if index == 0 { self.showPlaces() } else { self.onGo?(self.path[index].url) }
                }
                if index == 0 {
                    crumb.accessory.image = TabStrip.symbol("chevron.up.chevron.down", size: 9, weight: .semibold)
                    crumb.accessory.contentTintColor = .secondaryLabelColor
                    crumb.accessory.isHidden = false
                    crumb.toolTip = "Places"
                    crumb.setAccessibilityRole(.popUpButton)
                }
                crumb.onDrop = { [weak self] urls, folder, moving in self?.onDrop?(urls, folder, moving) }
                addSubview(crumb)
                crumbs.append(crumb)
                chevrons.append(makeChevron())
            }
            while crumbs.count > path.count {
                crumbs.removeLast().removeFromSuperview()
                chevrons.removeLast().removeFromSuperview()
            }
            for (index, (crumb, segment)) in zip(crumbs, path).enumerated() {
                crumb.label.font = .systemFont(ofSize: Self.fontSize)
                crumb.set(title: segment.title, image: segment.symbol.flatMap { TabStrip.symbol($0, size: 13) })
                crumb.folder = segment.url
            }
        }
        if item != selectedURL {
            selectedURL = item
            selected.set(title: item.map { FileManager.default.displayName(atPath: $0.path) } ?? "",
                         image: item.map { NSWorkspace.shared.icon(forFile: $0.path) })
        }
        needsLayout = true
    }

    /// The first segment's pop-up: the places, with the keys that go to each, the one holding the folder
    /// showing checked; then the volumes; then Go to Folder….
    private func showPlaces() {
        guard let first = crumbs.first, let folder = path.last?.url else { return }
        let builder = MenuBuilder()
        let lit = Place.holding(folder, in: places)
        var checked: NSMenuItem?
        var volumes = false
        for (index, place) in places.enumerated() {
            if case .volume = place.kind, !volumes {
                volumes = true
                builder.separator()
            }
            let item = builder.action(place.name, icon: TabStrip.symbol(place.symbol, size: 14), chord: place.chord) { [weak self] in
                self?.onGo?(place.url)
            }
            item.state = index == lit ? .on : .off
            if index == lit { checked = item }
        }
        builder.separator()
        builder.action("Go to Folder…", icon: TabStrip.symbol("arrow.right.circle", size: 14), chord: Chord("shift+cmd+g")) { [weak self] in
            self?.onGoToFolder?()
        }
        popUp = builder
        // As a pop-up button's: the place checked over the crumb, its title over the crumb's.
        builder.menu.popUp(positioning: checked, at: CGPoint(x: first.label.frame.minX - 30, y: first.label.frame.maxY + 2), in: first)
    }

    /// "…": the folders it stands for, nearest last, as Finder lists a path.
    private func showFolded() {
        let builder = MenuBuilder()
        for segment in folded {
            let item = builder.item(segment.title) { [weak self] in self?.onGo?(segment.url) }
            item.image = NSWorkspace.shared.icon(forFile: segment.url.path)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        popUp = builder
        builder.menu.popUp(positioning: nil, at: CGPoint(x: ellipsis.frame.minX, y: ellipsis.frame.maxY + 6), in: self)
    }

    // MARK: - Typing a path

    func beginTyping(_ initial: String) {
        begin(.path, initial, placeholder: nil, symbol: "folder")
        onTyped?(initial)
    }

    /// ⌘F: the field becomes a search of `scope`.
    func beginSearching(_ initial: String, placeholder: String) {
        begin(.search, initial, placeholder: placeholder, symbol: "magnifyingglass")
        onSearch?(initial)
    }

    private func begin(_ mode: Mode, _ initial: String, placeholder: String?, symbol: String) {
        self.mode = mode
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 21, weight: .medium))
        glyph.isHidden = false
        text.isHidden = false
        text.stringValue = initial
        text.placeholderAttributedString = placeholder.map {
            NSAttributedString(string: $0, attributes: [.font: NSFont.systemFont(ofSize: PanelMetrics.fontSize), .foregroundColor: NSColor.secondaryLabelColor])
        }
        needsLayout = true
        window?.makeFirstResponder(text)
        text.currentEditor()?.selectedRange = NSRange(location: initial.utf16.count, length: 0)
    }

    /// Back to the segments, from typing a path or searching.
    func endTyping() {
        guard mode != .segments else { return }
        mode = .segments
        glyph.isHidden = true
        text.isHidden = true
        needsLayout = true
    }

    func controlTextDidChange(_ notification: Notification) {
        switch mode {
        case .path: onTyped?(text.stringValue)
        case .search: onSearch?(text.stringValue)
        case .segments: break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if mode == .search { return onSearchCommand?(selector) ?? false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            let completed = onComplete?(text.stringValue) ?? text.stringValue
            text.stringValue = completed
            textView.selectedRange = NSRange(location: completed.utf16.count, length: 0)
            onTyped?(completed)
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(text.stringValue)
        default:
            return false
        }
        return true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let height = bounds.height
        let inset = (height - Self.pillHeight) / 2
        let y = inset
        let tabsWidth = tabs.width(within: (bounds.width * 0.52).rounded())
        tabs.frame = CGRect(x: bounds.width - inset - tabsWidth, y: y, width: tabsWidth, height: Self.pillHeight)
        let end = tabs.frame.minX - (tabsWidth > 0 ? 16 : 0)

        glyph.frame = CGRect(x: PanelMetrics.glyphLeft, y: (height - 26) / 2 + PanelMetrics.glyphLift, width: 26, height: 26)
        let font = text.font!
        let lineHeight = (font.ascender - font.descender + font.leading).rounded(.up) + 2
        text.frame = CGRect(x: PanelMetrics.textLeft - 3.5, y: PanelMetrics.baseline + font.descender - 2.5,
                            width: end - PanelMetrics.textLeft, height: lineHeight)

        let typing = mode != .segments
        layoutCrumbs(from: inset, to: end, y: y, hidden: typing)
    }

    /// Left to right from `start`: as many folders as fit, the first always and the last ones kept, those
    /// between folded into "…"; then the item selected, where there is room.
    private func layoutCrumbs(from start: CGFloat, to end: CGFloat, y: CGFloat, hidden typing: Bool) {
        // A chevron and the space either side of it.
        let step: CGFloat = 14
        let widths = crumbs.map { ceil($0.intrinsicContentSize.width) }
        let ellipsisWidth = ceil(ellipsis.intrinsicContentSize.width)
        func total(_ fold: Int) -> CGFloat {
            guard !widths.isEmpty else { return 0 }
            let kept = [widths[0]] + widths.dropFirst(1 + fold)
            return kept.reduce(0, +) + CGFloat(kept.count - 1) * step + (fold > 0 ? ellipsisWidth + step : 0)
        }
        // The last folder truncates if even this much folding leaves it too long.
        var fold = 0
        while fold < max(0, widths.count - 2), total(fold) > end - start { fold += 1 }
        folded = fold > 0 ? Array(path[1...fold]) : []

        // What shows, each with the chevron before it.
        var row: [(view: NSView, width: CGFloat, chevron: NSImageView?)] = []
        for (index, crumb) in crumbs.enumerated() where index == 0 || index > fold {
            if index == fold + 1, fold > 0 { row.append((ellipsis, ellipsisWidth, ellipsisChevron)) }
            row.append((crumb, widths[index], index == 0 ? nil : chevrons[index]))
        }
        let used = row.reduce(0) { $0 + $1.width + ($1.chevron == nil ? 0 : step) }
        let selectedWidth = ceil(selected.intrinsicContentSize.width)
        if selectedURL != nil, start + used + step + min(selectedWidth, 120) <= end {
            row.append((selected, selectedWidth, selectedChevron))
        }
        // One weight throughout; the path's end — the item selected, or else the folder — in full colour.
        for (index, crumb) in crumbs.enumerated() {
            let end = index == crumbs.count - 1 && row.last?.view === crumb
            crumb.label.textColor = end ? .labelColor : .secondaryLabelColor
            crumb.icon.contentTintColor = crumb.label.textColor
        }

        for view in crumbs as [NSView] + chevrons + [ellipsis, ellipsisChevron, selected, selectedChevron] { view.isHidden = true }
        guard !typing else { return }
        var x = start
        for item in row {
            if let chevron = item.chevron {
                chevron.isHidden = false
                chevron.frame = CGRect(x: x + 1, y: y + (Self.pillHeight - 12) / 2, width: 12, height: 12)
                x += step
            }
            item.view.isHidden = false
            item.view.frame = CGRect(x: x, y: y, width: min(item.width, max(0, end - x)), height: Self.pillHeight)
            x += item.width
        }
    }

    private lazy var ellipsisChevron = makeChevron()
    private lazy var selectedChevron = makeChevron()

    private func makeChevron() -> NSImageView {
        let chevron = NSImageView(image: TabStrip.symbol("chevron.right", size: 10, weight: .semibold)!)
        chevron.contentTintColor = .tertiaryLabelColor
        addSubview(chevron)
        return chevron
    }
}

extension Place {
    var symbol: String {
        switch kind {
        case .home: "house"
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .applications: "square.grid.2x2"
        case .iCloudDrive: "icloud"
        case .volume(_, local: false): "server.rack"
        case .volume(internal: true, _): "internaldrive"
        case .volume: "externaldrive"
        }
    }

    /// Finder's key for it, which Files keeps.
    var chord: Chord? {
        switch kind {
        case .home: Chord("shift+cmd+h")
        case .desktop: Chord("shift+cmd+d")
        case .documents: Chord("shift+cmd+o")
        case .downloads: Chord("opt+cmd+l")
        case .applications: Chord("shift+cmd+a")
        case .iCloudDrive: Chord("shift+cmd+i")
        case .volume: nil
        }
    }
}
