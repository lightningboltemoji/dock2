import AppKit
import Dock2Core
import Dock2System

/// Files' bar, in the field's place ([files](product/files/README.md#layout)), laid out as a search result is: the
/// place holding the folder on a plate, which lists the places; from the text line, the folder as a breadcrumb — a click
/// goes there, a drop puts items in it — or a path being typed, or ⌘F's search; the tabs at its end.
@MainActor
final class PathBar: NSView, NSTextFieldDelegate {
    struct Segment: Equatable {
        var title: String
        var url: URL
    }

    private let place = PlaceButton()
    private let glyph = NSImageView()
    private var crumbs: [PillButton] = []
    private var chevrons: [NSImageView] = []
    /// The folders left out of a path too long to show whole, behind one "…".
    private let ellipsis = PillButton()
    private var folded: [Segment] = []
    /// The item selected in the last folder, after it: named, not a place to go.
    private let selected = PillButton()
    private var selectedEntry: FileEntry?
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
    /// A place's ⏏ in the places' menu: a disk ejected, a server disconnected.
    var onEject: ((Place) -> Void)?
    /// What the plate's pop-up lists, and the one holding the folder showing.
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

    static let fontSize = PanelMetrics.titleFont
    /// The pills' height, centred in the bar.
    static let pillHeight: CGFloat = 28
    private static let crumbPadding: CGFloat = 8
    /// The places' menu's plates, a box a row of it can hold.
    private static let menuPlate: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        place.onClick = { [weak self] in self?.showPlaces() }
        addSubview(place)
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
        text.font = FieldLine.font
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
    func show(_ path: [Segment], selected item: FileEntry?) {
        if path != self.path {
            self.path = path
            while crumbs.count < path.count {
                let crumb = PillButton()
                crumb.padding = Self.crumbPadding
                let index = crumbs.count
                crumb.onClick = { [weak self] in
                    guard let self, self.path.indices.contains(index) else { return }
                    self.onGo?(self.path[index].url)
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
            for (crumb, segment) in zip(crumbs, path) {
                crumb.label.font = .systemFont(ofSize: Self.fontSize)
                crumb.set(title: segment.title, image: nil)
                crumb.folder = segment.url
            }
        }
        place.show(path.last.flatMap { Place.holding($0.url, in: places) }.map { places[$0] })
        if item != selectedEntry {
            selectedEntry = item
            // A folder's own icon says nothing a crumb does not.
            selected.set(title: item?.name ?? "", image: item.flatMap { $0.isFolder ? nil : FileIcons.icon(for: $0) })
        }
        needsLayout = true
    }

    /// The plate's pop-up: the places, with the keys that go to each, the one holding the folder showing
    /// checked; then the volumes; then Go to Folder….
    private func showPlaces() {
        guard let folder = path.last?.url else { return }
        let builder = MenuBuilder()
        let lit = Place.holding(folder, in: places)
        var volumes = false
        for (index, place) in places.enumerated() {
            if !volumes, place.isLocation {
                volumes = true
                builder.separator()
            }
            let go: () -> Void = { [weak self] in self?.onGo?(place.url) }
            let plate = IconImages.plated(symbol: place.symbol, color: place.color, size: Self.menuPlate)
            let item: NSMenuItem
            if place.ejects {
                item = builder.row(PlaceMenuRow(title: place.name, plate: plate, checked: index == lit, choose: go) { [weak self] in self?.onEject?(place) })
            } else {
                item = builder.action(place.name, icon: plate, chord: place.chord, go)
            }
            // A view's item draws no check, but its state keeps the column every title is set past.
            item.state = index == lit ? .on : .off
        }
        builder.separator()
        builder.action("Go to Folder…", icon: TabStrip.symbol("arrow.right.circle", size: 14), chord: Chord("shift+cmd+g")) { [weak self] in
            self?.onGoToFolder?()
        }
        popUp = builder
        // A menu's frame stands a point outside what it draws: its edge meets the plate's.
        rise(builder.menu, from: PanelMetrics.glyphLine - PlaceButton.plate / 2 - 1, over: place)
    }

    /// Rises from the bar over the pane, its left edge on `x`, as a tile's menu rises from the dock.
    private func rise(_ menu: NSMenu, from x: CGFloat, over view: NSView) {
        menu.popUp(positioning: nil, at: CGPoint(x: x, y: view.frame.maxY + 2 + menu.size.height), in: self)
    }

    /// "…": the folders it stands for, nearest last, as Finder lists a path.
    private func showFolded() {
        let builder = MenuBuilder()
        for segment in folded {
            let item = builder.item(segment.title) { [weak self] in self?.onGo?(segment.url) }
            item.image = FileIcons.icon(for: segment.url)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        popUp = builder
        rise(builder.menu, from: ellipsis.frame.minX, over: ellipsis)
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
        glyph.image = FieldLine.symbol(symbol)
        glyph.isHidden = false
        text.isHidden = false
        text.stringValue = initial
        text.placeholderAttributedString = placeholder.map {
            NSAttributedString(string: $0, attributes: [.font: FieldLine.font, .foregroundColor: NSColor.secondaryLabelColor])
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
        let y = (height - Self.pillHeight) / 2
        // The bar's last mark ends on the panel's margin.
        let inset = PanelMetrics.margin - Self.crumbPadding
        let tabsWidth = tabs.width(within: (bounds.width * 0.52).rounded())
        tabs.frame = CGRect(x: bounds.width - inset - tabsWidth, y: y, width: tabsWidth, height: Self.pillHeight)
        let end = tabs.frame.minX - (tabsWidth > 0 ? 16 : 0)

        glyph.frame = FieldLine.glyphFrame(for: glyph.image, height: height)
        text.frame = FieldLine.textFrame(text.font!, height: height, end: end)

        let typing = mode != .segments
        let box = PlaceButton.box
        place.frame = CGRect(x: PanelMetrics.glyphLine - box / 2, y: (height - box) / 2, width: box, height: box)
        place.isHidden = typing
        // The first crumb's title starts on the text line, where a typed path does.
        layoutCrumbs(from: PanelMetrics.textLeft - Self.crumbPadding - NSTextField.textInset, to: end, y: y, hidden: typing)
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
        if selectedEntry != nil, start + used + step + min(selectedWidth, 120) <= end {
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
        let chevron = NSImageView(image: TabStrip.symbol("chevron.right", size: 9, weight: .semibold)!)
        chevron.contentTintColor = .tertiaryLabelColor
        addSubview(chevron)
        return chevron
    }
}

/// The place a path starts from, on a plate the size of the field's magnifier, which stands where it does: a control, so
/// it answers the pointer with its whole body, and a new place lands on a small spring.
@MainActor
private final class PlaceButton: PillButton {
    static let plate = CGFloat(PanelMetrics.glyphSize)
    static let box = (plate / IconPlate.fraction).rounded()
    private var shown: Place?

    override init() {
        super.init()
        padding = 0
        iconSize = Self.box
        toolTip = "Places"
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ place: Place?) {
        guard place != shown || icon.image == nil else { return }
        let arriving = shown != nil
        shown = place
        set(title: "", image: IconImages.plated(symbol: place?.symbol ?? "folder", color: place?.color ?? IconColor(.gray), size: iconSize))
        setAccessibilityLabel(place.map { "Places, \($0.name)" } ?? "Places")
        if arriving { spring(from: 0.8, to: 1) }
    }

    override var fill: NSColor? { nil }

    override func hoverChanged() { spring(from: scale, to: isHovered ? 1.07 : 1) }

    private var scale: CGFloat = 1

    /// A view's layer scales about its corner, so about its middle takes a move either side.
    private func transform(_ scale: CGFloat) -> CATransform3D {
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(middle.x, middle.y, 0), scale, scale, 1), -middle.x, -middle.y, 0)
    }

    private func spring(from start: CGFloat, to end: CGFloat) {
        guard let layer else { return }
        scale = end
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform(end)
        CATransaction.commit()
        guard !DisplayOptions.reduceMotion else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = transform(start)
        spring.toValue = transform(end)
        spring.stiffness = 420
        spring.damping = 18
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "spring")
    }
}

extension Place {
    /// One of Finder's Locations — a disk, a server, Network: the pop-up's second section.
    var isLocation: Bool {
        switch kind {
        case .volume, .server, .network: true
        default: false
        }
    }

    var symbol: String {
        switch kind {
        case .home: "house"
        case .desktop: "menubar.dock.rectangle"
        case .documents: "doc"
        case .downloads: "arrow.down.circle"
        case .applications: "square.grid.2x2"
        case .iCloudDrive: "icloud"
        case .volume(_, local: false), .server: "server.rack"
        case .network: "network"
        case .volume(internal: true, _): "internaldrive"
        case .volume: "externaldrive"
        }
    }

    /// What says which place this is, on its plate.
    var color: IconColor {
        switch kind {
        case .home: IconColor(.blue)
        case .desktop: IconColor(.purple)
        case .documents: IconColor(.orange)
        case .downloads: IconColor(.green)
        case .applications: IconColor(.pink)
        case .iCloudDrive: IconColor(red: 0.35, green: 0.68, blue: 0.98)
        case .volume(_, local: false), .server, .network: IconColor(red: 0.36, green: 0.42, blue: 0.86)
        case .volume: IconColor(.gray)
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
        case .volume, .server, .network: nil
        }
    }
}
