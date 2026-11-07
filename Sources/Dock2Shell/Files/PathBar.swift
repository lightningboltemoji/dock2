import AppKit
import Dock2Core
import Dock2System

/// Files' bar, in the field's place ([files](product/files/README.md#layout)), laid out as a search result is: the place
/// holding the folder, a pill of plate and name that lists the places; the folders inside it as a breadcrumb, or a path
/// being typed, or ⌘F's search; the tabs at its end.
@MainActor
final class PathBar: NSView, NSTextFieldDelegate, ScreenBar {
    struct Segment: Equatable {
        var title: String
        var url: URL
    }

    /// Everything but the tabs: the path, reading from the bar's leading end.
    let leadingEnd = NSView()
    var trailingEnd: NSView { tabs }
    /// Fades out over the gap between the path and the tabs.
    private let fadeToTabs: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.colors = [CGColor.black, CGColor.black, CGColor.clear]
        return layer
    }()
    var room: CALayer { fadeToTabs }
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
    /// The folder showing.
    private var folder: URL?
    /// The folders from the place to `folder`, past the place itself.
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
    /// What the place's pop-up lists, and the one holding the folder showing.
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
    fileprivate static let crumbPadding: CGFloat = 8
    /// The places' menu's plates, a box a row of it can hold.
    private static let menuPlate: CGFloat = 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        leadingEnd.wantsLayer = true
        tabs.wantsLayer = true
        leadingEnd.layer!.mask = fadeToTabs
        addSubview(leadingEnd)
        place.onClick = { [weak self] in self?.showPlaces() }
        place.onDrop = { [weak self] urls, folder, moving in self?.onDrop?(urls, folder, moving) }
        leadingEnd.addSubview(place)
        glyph.contentTintColor = .labelColor
        glyph.isHidden = true
        leadingEnd.addSubview(glyph)
        ellipsis.set(title: "", image: TabStrip.symbol("ellipsis", size: 13))
        ellipsis.padding = 8
        ellipsis.icon.contentTintColor = .secondaryLabelColor
        ellipsis.setAccessibilityLabel("Enclosing folders")
        ellipsis.onClick = { [weak self] in self?.showFolded() }
        leadingEnd.addSubview(ellipsis)
        selected.isInert = true
        selected.padding = 6
        selected.label.font = .systemFont(ofSize: Self.fontSize)
        selected.label.textColor = .labelColor
        selected.label.lineBreakMode = .byTruncatingMiddle
        leadingEnd.addSubview(selected)
        text.isBordered = false
        text.drawsBackground = false
        text.focusRingType = .none
        text.font = FieldLine.font
        text.cell?.usesSingleLineMode = true
        text.cell?.isScrollable = true
        text.delegate = self
        text.isHidden = true
        text.setAccessibilityLabel("Path")
        leadingEnd.addSubview(text)
        addSubview(tabs)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === leadingEnd ? nil : hit
    }

    /// The folders from the root to the one showing, and the item selected in that one, if any is: the place holding
    /// it stands for those down to itself, and the crumbs are what lies inside.
    func show(_ segments: [Segment], selected item: FileEntry?) {
        folder = segments.last?.url
        let inside = segments.dropFirst(Place.start(along: segments.map(\.url), in: places))
        let held = folder.flatMap { Place.holding($0, in: places) }.map { places[$0] }
        place.show(held, title: held?.name ?? inside.first?.title ?? "")
        place.folder = inside.first?.url
        let path = Array(inside.dropFirst())
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
                leadingEnd.addSubview(crumb)
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
        if item != selectedEntry {
            selectedEntry = item
            // A folder's own icon says nothing a crumb does not.
            selected.set(title: item?.name ?? "", image: item.flatMap { $0.isFolder ? nil : FileIcons.icon(for: $0) })
        }
        needsLayout = true
    }

    /// The place's pop-up: the places, with the keys that go to each, the one holding the folder showing
    /// checked; then the volumes; then Go to Folder….
    private func showPlaces() {
        guard let folder else { return }
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
        // A menu's frame stands a point outside what it draws: its edge meets the pill's.
        rise(builder.menu, from: place.frame.minX - 1, over: place)
    }

    /// Rises from the bar over the pane, its left edge on `x`, as a tile's menu rises from the dock, `pill` lit until it
    /// closes.
    private func rise(_ menu: NSMenu, from x: CGFloat, over pill: PillButton) {
        pill.isCurrent = true
        menu.popUp(positioning: nil, at: CGPoint(x: x, y: pill.frame.maxY + 2 + menu.size.height), in: self)
        pill.isCurrent = false
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
        leadingEnd.frame = bounds
        let height = bounds.height
        let y = (height - Self.pillHeight) / 2
        // The bar's last mark ends on the panel's margin.
        let inset = PanelMetrics.margin - Self.crumbPadding
        let tabsWidth = tabs.width(within: (bounds.width * 0.52).rounded())
        tabs.frame = CGRect(x: bounds.width - inset - tabsWidth, y: y, width: tabsWidth, height: Self.pillHeight)
        let end = tabs.frame.minX - (tabsWidth > 0 ? 16 : 0)
        let reach = max(tabs.frame.minX, 1)
        Motion.perform(nil) {
            fadeToTabs.frame = CGRect(x: 0, y: 0, width: reach, height: height)
            fadeToTabs.locations = [0, NSNumber(value: end / reach), 1]
        }

        glyph.frame = FieldLine.glyphFrame(for: glyph.image, height: height)
        text.frame = FieldLine.textFrame(text.font!, height: height, end: end)

        layoutCrumbs(to: end, y: y, hidden: mode != .segments)
    }

    /// Left to right from the margin: the place, then as many folders as fit, the last ones kept and those before them
    /// folded into "…"; then the item selected, where there is room.
    private func layoutCrumbs(to end: CGFloat, y: CGFloat, hidden typing: Bool) {
        let start = CGFloat(PanelMetrics.margin)
        // A chevron and the space either side of it.
        let step: CGFloat = 14
        let placeWidth = ceil(place.intrinsicContentSize.width)
        let widths = crumbs.map { ceil($0.intrinsicContentSize.width) }
        let ellipsisWidth = ceil(ellipsis.intrinsicContentSize.width)
        func total(_ fold: Int) -> CGFloat {
            let kept = widths.dropFirst(fold)
            return placeWidth + kept.reduce(0, +) + CGFloat(kept.count) * step + (fold > 0 ? ellipsisWidth + step : 0)
        }
        // The last folder truncates if even this much folding leaves it too long.
        var fold = 0
        while fold < widths.count - 1, total(fold) > end - start { fold += 1 }
        folded = Array(path.prefix(fold))

        // What shows, each with the chevron before it.
        var row: [(view: NSView, width: CGFloat, chevron: NSImageView?)] = [(place, placeWidth, nil)]
        if fold > 0 { row.append((ellipsis, ellipsisWidth, ellipsisChevron)) }
        for (index, crumb) in crumbs.enumerated() where index >= fold {
            row.append((crumb, widths[index], chevrons[index]))
        }
        let used = row.reduce(0) { $0 + $1.width + ($1.chevron == nil ? 0 : step) }
        let selectedWidth = ceil(selected.intrinsicContentSize.width)
        if selectedEntry != nil, start + used + step + min(selectedWidth, 120) <= end {
            row.append((selected, selectedWidth, selectedChevron))
        }
        // One weight throughout; the path's end — the item selected, or else the folder — in full colour.
        for pill in [place] + crumbs {
            pill.label.textColor = pill === row.last?.view ? .labelColor : .secondaryLabelColor
        }

        for view in [place] + crumbs as [NSView] + chevrons + [ellipsis, ellipsisChevron, selected, selectedChevron] { view.isHidden = true }
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
        leadingEnd.addSubview(chevron)
        return chevron
    }
}

/// The place a path starts from, as one pill as tall as the crumbs. Its plate stands in a square the pill's height on the
/// glyph line and its name starts where that ends, as a row's does; the pill starts further out, on the margin, since its
/// end curves away from the plate. A new place lands on a small spring.
@MainActor
private final class PlaceButton: PillButton {
    /// What an 18 pt plate is drawn in.
    private static let box: CGFloat = 22.5
    private var shown: Place?

    override init() {
        super.init()
        iconSize = Self.box
        leading = PanelMetrics.glyphLine - Self.box / 2 - PanelMetrics.margin
        spacing = (PathBar.pillHeight - Self.box) / 2 - NSTextField.textInset
        padding = PathBar.crumbPadding
        label.font = .systemFont(ofSize: PathBar.fontSize)
        toolTip = "Places"
        setAccessibilityRole(.popUpButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ place: Place?, title: String) {
        guard place != shown || title != label.stringValue || icon.image == nil else { return }
        let arriving = shown != nil && place != shown
        shown = place
        set(title: title, image: IconImages.plated(symbol: place?.symbol ?? "folder", color: place?.color ?? IconColor(.gray), size: iconSize))
        setAccessibilityLabel(place.map { "Places, \($0.name)" } ?? "Places")
        if arriving { land() }
    }

    /// A view's layer scales about its corner, so about its middle takes a move either side.
    private func land() {
        guard !DisplayOptions.reduceMotion, let layer = icon.layer else { return }
        let middle = CGPoint(x: icon.bounds.midX, y: icon.bounds.midY)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(middle.x, middle.y, 0), 0.8, 0.8, 1), -middle.x, -middle.y, 0)
        spring.toValue = CATransform3DIdentity
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
