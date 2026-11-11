import AppKit
import Carbon.HIToolbox
import Dock2Core

/// A pill of the label's glass at the trailing end of one of the panel's bars that opens into a menu: the capsule growing
/// away from its bar on the panel's opening spring, nested in the panel's corner and concentric with it, its label giving
/// way to its rows. While open it takes the keys first (`key`). Actions (`ActionsBubble`) and a scope (`ScopeMenu`) use it.
@MainActor
class BarMenu: NSView {
    /// The panel's edge its bar runs along: it opens away from it.
    enum Edge { case bottom, top }

    struct Item {
        /// What keeps it selected when the menu is filled again.
        var id: String
        var title: String
        var icon: Icon?
        var chord: Chord?
        var destructive = false
        /// One of a set of choices, with a check on the one chosen; nil for an item that is not.
        var checked: Bool?
    }

    enum Entry {
        case item(Item)
        case heading(String)
        case separator
    }

    static let pillHeight: CGFloat = 28
    /// From the menu's edge to the pill's place and to a row's band, so their corners are concentric with its.
    static let inset: CGFloat = 5
    static let rowHeight: CGFloat = 30
    static let headingHeight: CGFloat = 26
    static let separatorHeight: CGFloat = 9
    static let minimumWidth: CGFloat = 240
    static var cornerRadius: CGFloat { pillHeight / 2 + inset }
    /// What grows on, and what draws back on: the panel's own springs (`GrowthMotion`).
    static let opening = SidelineMotion.Spring(response: GrowthMotion.outResponse, damping: GrowthMotion.outDamping)
    static let closing = SidelineMotion.Spring(response: GrowthMotion.inResponse, damping: 1)

    let edge: Edge
    /// What opens and closes it while it has the keys: ⌘K, ⌘P.
    let chord: Chord
    /// The bar the pill stands on, and the room the open menu keeps within, in this view's coordinates: it spans its
    /// superview.
    var frames: () -> (bar: CGRect, room: CGRect)? = { nil }
    /// The menu opened or closed: what is behind it recedes while it is open.
    var onOpenChange: ((Bool) -> Void)?
    /// An item chosen, by its place in the entries.
    var onChoose: ((Int) -> Void)?
    /// A click on the pill; without it, the pill opens and closes the menu.
    var onPillClick: (() -> Void)?

    private(set) var isOpen = false
    private let pill = BarPill()
    /// The pill's glass and, open, the menu's: its shadow, its glass, and its rows, cut to the glass as it grows.
    private let bubble = NSView()
    private let bubbleShadow = PanelShadow()
    private let glass = GlassView(recipe: .label(dark: false))
    private let rows = NSView()
    /// Within the rows, what scrolls a menu taller than its room.
    private let scroll = OverlayScrollView()
    private let list = FlippedList()
    private let cut = CALayer()
    private(set) var entries: [Entry] = []
    private var rowViews: [NSView & BarMenuEntry] = []
    private var selection: Int?
    /// The glass's shape on its way, for a change of mind mid-flight to start from where it is.
    private var morph: Morph?
    private var closings = 0

    init(edge: Edge, chord: Chord) {
        self.edge = edge
        self.chord = chord
        super.init(frame: .zero)
        wantsLayer = true
        bubble.wantsLayer = true
        bubble.isHidden = true
        rows.wantsLayer = true
        rows.layer!.opacity = 0
        cut.backgroundColor = .black
        rows.layer!.mask = cut
        list.wantsLayer = true
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        rows.addSubview(scroll)
        for view in [bubbleShadow, glass, rows] as [NSView] { bubble.addSubview(view) }
        addSubview(bubble)
        pill.isHidden = true
        pill.onClick = { [weak self] in self?.pillClicked() }
        addSubview(pill)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - What it offers

    /// How far in from the bar's trailing end the pill reaches, and the gap before it.
    var reserve: CGFloat { pill.isHidden ? 0 : PanelMetrics.margin + pill.intrinsicContentSize.width + 2 * PanelMetrics.unit }

    /// The pill's title, its icon before it and its key dimmed after it; no title hides it, and closes the menu.
    func setPill(title: String?, key: String, icon: Icon? = nil, role: NSAccessibility.Role = .button) {
        if let title { pill.set(title: title, key: key, icon: icon) }
        pill.setAccessibilityRole(role)
        pill.isHidden = title == nil
        matchAppearance()
        if pill.isHidden { close(animated: false) }
        needsLayout = true
    }

    /// What the menu lists. Open, it keeps up — a sync, a plugin's update — or closes with nothing left.
    func setEntries(_ entries: [Entry]) {
        let selected = selection.flatMap { Self.item(at: $0, in: self.entries)?.id }
        self.entries = entries
        guard isOpen else { return }
        guard entries.contains(where: { if case .item = $0 { true } else { false } }) else { return close(animated: false) }
        fill(keeping: selected)
        Motion.together { place(animated: false) }
    }

    private static func item(at index: Int, in entries: [Entry]) -> Item? {
        guard entries.indices.contains(index), case .item(let item) = entries[index] else { return nil }
        return item
    }

    private var hasItems: Bool { entries.contains { if case .item = $0 { true } else { false } } }

    private func pillClicked() {
        if let onPillClick { onPillClick() } else { toggle() }
    }

    // MARK: - Opening and closing

    func toggle() {
        if isOpen { close(animated: true) } else { open() }
    }

    func open() {
        guard !isOpen, !pill.isHidden, hasItems else { return }
        isOpen = true
        closings += 1
        selection = nil
        fill(keeping: nil)
        layoutSubtreeIfNeeded()
        bubble.isHidden = false
        Motion.together {
            if DisplayOptions.reduceMotion { crossfade() }
            place(animated: true, from: isMorphing ? nil : capsule)
            fade(rows.layer!, to: 1, over: 0.16, delay: DisplayOptions.reduceMotion ? 0 : 0.04)
            fade(pill, to: 0, over: 0.08)
            bubbleShadow.fade(in: true, duration: 0.2)
        }
        revealSelection()
        NSAccessibility.post(element: rows, notification: .created)
        onOpenChange?(true)
    }

    /// Back into the pill, or there at once without `animated`.
    func close(animated: Bool) {
        guard isOpen else { return }
        isOpen = false
        closings += 1
        let closing = closings
        onOpenChange?(false)
        guard animated else { return finishClosing() }
        if DisplayOptions.reduceMotion {
            Motion.together {
                crossfade()
                rest()
                fade(rows.layer!, to: 0, over: 0.15)
                fade(pill, to: 1, over: 0.15)
                bubbleShadow.fade(in: false, duration: 0.15)
            }
            after(0.15, closing)
            return
        }
        let frames = keyframes(to: (capsule, Self.pillHeight / 2), on: Self.closing)
        let duration = frames.step * Double(frames.values.count - 1)
        Motion.together {
            play(frames)
            fade(rows.layer!, to: 0, over: 0.08)
            bubbleShadow.fade(in: false, duration: duration * 0.6)
            // The label comes back as the glass nears the pill's size, so the capsule is never seen empty.
            fade(pill, to: 1, over: 0.12, delay: duration * 0.3)
        }
        after(duration, closing)
    }

    private func after(_ delay: CFTimeInterval, _ closing: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.closings == closing, !self.isOpen else { return }
            self.finishClosing()
        }
    }

    private func finishClosing() {
        Motion.together {
            for layer in [rows.layer!, pill.layer!] { layer.removeAllAnimations() }
            rows.layer!.opacity = 0
            pill.alphaValue = 1
            bubbleShadow.stopPlaying()
            bubbleShadow.fade(in: false, duration: 0)
            rest()
        }
        selection = nil
    }

    /// At rest: the glass is the pill's capsule, or nothing with no pill.
    private func rest() {
        morph = nil
        bubble.isHidden = pill.isHidden
        guard !pill.isHidden else { return }
        bubble.frame = bounds
        bubbleShadow.frame = bounds
        glass.frame = bounds
        play(Keyframes(values: [GlassLayer.Shape(frame: capsule, cornerRadius: Self.pillHeight / 2, curve: .continuous)],
                       step: 1, begin: CACurrentMediaTime(), loop: nil))
    }

    /// Reduce Motion's stand-in for the morph: the glass and what it holds fade from one size to the other.
    private func crossfade() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        bubble.layer?.add(fade, forKey: "crossfade")
    }

    // MARK: - Keys

    /// A key while open: the arrows, ↩, an item's own chord, Esc and its own chord are the menu's; any other closes it
    /// and goes on, so typing reaches the field.
    func key(_ event: NSEvent) -> Bool {
        guard isOpen else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let code = Int(event.keyCode)
        if code == kVK_Escape {
            close(animated: true)
            return true
        }
        if code == kVK_UpArrow || code == kVK_DownArrow {
            move(by: code == kVK_UpArrow ? -1 : 1)
            return true
        }
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter, flags.isEmpty {
            if let selection { choose(selection) }
            return true
        }
        if chord.matches(event) {
            close(animated: true)
            return true
        }
        if let index = entries.firstIndex(where: { if case .item(let item) = $0 { item.chord?.matches(event) == true } else { false } }) {
            choose(index)
            return true
        }
        close(animated: true)
        return false
    }

    private var itemIndices: [Int] {
        entries.indices.filter { if case .item = entries[$0] { true } else { false } }
    }

    private func move(by step: Int) {
        let items = itemIndices
        guard !items.isEmpty else { return }
        let at = selection.flatMap { items.firstIndex(of: $0) } ?? -1
        select(items[min(max(at + step, 0), items.count - 1)])
        revealSelection()
    }

    /// The selected row in view, with the menu's inset around it.
    private func revealSelection() {
        guard let row = rowViews.first(where: { $0.index == selection }) else { return }
        list.scrollToVisible(row.frame.insetBy(dx: 0, dy: -Self.inset))
    }

    private func select(_ index: Int?) {
        selection = index
        for case let row as BarMenuRow in rowViews { row.isSelected = row.index == index }
        if let row = rowViews.first(where: { $0.index == index }) {
            NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
        }
    }

    private func choose(_ index: Int) {
        guard Self.item(at: index, in: entries) != nil else { return }
        close(animated: true)
        onChoose?(index)
    }

    // MARK: - Rows

    /// The entries as rows, the one selected kept — else the one chosen, else the first.
    private func fill(keeping selected: String?) {
        rowViews.forEach { $0.removeFromSuperview() }
        let items = entries.compactMap { if case .item(let item) = $0 { item } else { nil } }
        let columns = BarMenuRow.Columns(checks: items.contains { $0.checked != nil }, icons: items.contains { $0.icon != nil })
        rowViews = entries.enumerated().compactMap { index, entry -> (NSView & BarMenuEntry)? in
            switch entry {
            case .item(let item):
                let row = BarMenuRow(item: item, index: index, columns: columns)
                row.onHover = { [weak self] in self?.select(index) }
                row.onClick = { [weak self] in self?.choose(index) }
                return row
            case .heading(let title):
                return BarMenuHeading(title: title, index: index, columns: columns)
            case .separator:
                return nil
            }
        }
        rowViews.forEach { list.addSubview($0) }
        let indices = itemIndices
        let kept = indices.first { Self.item(at: $0, in: entries)?.id == selected }
        let chosen = indices.first { Self.item(at: $0, in: entries)?.checked == true }
        select(kept ?? chosen ?? indices.first)
    }

    /// The pill as the bar leaves it room: centred on the bar's midline, its end on the panel's margin, under the rows'
    /// trailing ends.
    private var capsule: CGRect {
        guard let bar = frames()?.bar else { return .zero }
        let width = pill.intrinsicContentSize.width
        return CGRect(x: bar.maxX - PanelMetrics.margin - width,
                      y: bar.minY + ((bar.height - Self.pillHeight) / 2).rounded(), width: width, height: Self.pillHeight)
    }

    private static func height(of entry: Entry) -> CGFloat {
        switch entry {
        case .item: rowHeight
        case .heading: headingHeight
        case .separator: separatorHeight
        }
    }

    private var rowsHeight: CGFloat { entries.reduce(0) { $0 + Self.height(of: $1) } }

    /// The open menu, as wide as its widest row and as tall as its rows, up to its room, where it scrolls: nested in the
    /// panel's corner, concentric with it, wherever the pill it grows from stands.
    private var menuFrame: CGRect {
        guard let (bar, room) = frames() else { return .zero }
        let pill = capsule
        let widest = rowViews.map(\.fittingWidth).max() ?? 0
        let width = max(Self.minimumWidth, widest + 2 * Self.inset, pill.width + 2 * Self.inset)
        // As far from its room's far edge as from the panel's corner.
        let corner = PanelMetrics.radius - Self.cornerRadius
        let x = bar.maxX - corner - width
        switch edge {
        case .bottom:
            let y = bar.minY + corner
            return CGRect(x: x, y: y, width: width, height: max(Self.pillHeight, min(Self.inset + rowsHeight + Self.inset, room.maxY - corner - y)))
        case .top:
            let top = bar.maxY - corner
            let height = max(Self.pillHeight, min(Self.inset + rowsHeight + Self.inset, top - room.minY - corner))
            return CGRect(x: x, y: top - height, width: width, height: height)
        }
    }

    override func layout() {
        super.layout()
        Motion.together {
            pill.frame = capsule
            if isMorphing {
                // Closing into a pill that changed on the way — the scope just chosen — it heads for the new one.
                if !isOpen, let morph, morph.to.frame != capsule { play(keyframes(to: (capsule, Self.pillHeight / 2), on: Self.closing)) }
                return
            }
            if isOpen { place(animated: false) } else { rest() }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        matchAppearance()
    }

    /// The glass whose appearance it was built for: a new recipe builds the glass again, so only on a change.
    private var glassIsDark: Bool?

    private func matchAppearance() {
        let dark = effectiveAppearance.isDark
        guard dark != glassIsDark else { return }
        glassIsDark = dark
        glass.recipe = .label(dark: dark)
    }

    /// The menu laid out at its open size, its glass and its cut moving there on the opening spring, from `start`
    /// or from wherever it is — or there at once.
    private func place(animated: Bool, from start: CGRect? = nil) {
        let open = menuFrame
        bubble.frame = bounds
        bubbleShadow.frame = bounds
        glass.frame = bounds
        rows.frame = open
        scroll.frame = rows.bounds
        list.frame = CGRect(x: 0, y: 0, width: open.width, height: max(open.height, Self.inset + rowsHeight + Self.inset))
        var y = Self.inset
        for (index, entry) in entries.enumerated() {
            let height = Self.height(of: entry)
            rowViews.first { $0.index == index }?.frame = CGRect(x: Self.inset, y: y, width: open.width - 2 * Self.inset, height: height)
            y += height
        }
        separatorLayers(width: open.width)
        let target = (frame: open, radius: Self.cornerRadius)
        guard animated, !DisplayOptions.reduceMotion else {
            morph = nil
            play(Keyframes(values: [GlassLayer.Shape(frame: open, cornerRadius: target.radius, curve: .continuous)],
                           step: 1, begin: CACurrentMediaTime(), loop: nil))
            return
        }
        play(keyframes(to: target, on: Self.opening, from: start.map { ($0, Self.pillHeight / 2) }))
    }

    private var separators: [CALayer] = []

    private func separatorLayers(width: CGFloat) {
        separators.forEach { $0.removeFromSuperlayer() }
        separators = []
        var y = Self.inset
        for entry in entries {
            if case .separator = entry {
                let line = CALayer()
                effectiveAppearance.performAsCurrentDrawingAppearance { line.backgroundColor = NSColor.separatorColor.cgColor }
                line.frame = CGRect(x: 2 * Self.inset + 6, y: y + Self.separatorHeight / 2, width: width - 4 * Self.inset - 12, height: 0.5)
                list.layer!.addSublayer(line)
                separators.append(line)
            }
            y += Self.height(of: entry)
        }
    }

    // MARK: - Motion

    /// A spring from one rounded rect to another, sampled for the glass, its shadow and the rows' cut alike.
    private struct Morph {
        var from: (frame: CGRect, radius: CGFloat)
        var to: (frame: CGRect, radius: CGFloat)
        var spring: SidelineMotion.Spring
        var begin: CFTimeInterval
        var duration: CFTimeInterval

        func shape(at time: CFTimeInterval) -> (frame: CGRect, radius: CGFloat) {
            let p = CGFloat(spring.progress(at: time - begin))
            let mix = { (a: CGFloat, b: CGFloat) in a + (b - a) * p }
            return (CGRect(x: mix(from.frame.minX, to.frame.minX), y: mix(from.frame.minY, to.frame.minY),
                           width: max(0, mix(from.frame.width, to.frame.width)), height: max(0, mix(from.frame.height, to.frame.height))),
                    mix(from.radius, to.radius))
        }
    }

    private var isMorphing: Bool {
        guard let morph else { return false }
        return CACurrentMediaTime() < morph.begin + morph.duration
    }

    /// From `start`, or from where the glass is now, to `target` on `spring`, a frame every 120th of a second
    /// until it settles.
    private func keyframes(to target: (frame: CGRect, radius: CGFloat), on spring: SidelineMotion.Spring,
                           from start: (frame: CGRect, radius: CGFloat)? = nil) -> Keyframes<GlassLayer.Shape> {
        let now = CACurrentMediaTime()
        let from = start ?? morph.map { $0.shape(at: now) } ?? target
        var morph = Morph(from: from, to: target, spring: spring, begin: now, duration: 0)
        let step = 1.0 / 120
        var values: [GlassLayer.Shape] = []
        var time = 0.0, still = 0
        while still < 3, time < 1.5 {
            let shape = morph.shape(at: now + time)
            values.append(GlassLayer.Shape(frame: shape.frame, cornerRadius: shape.radius, curve: .continuous))
            still = abs(1 - spring.progress(at: time)) < 0.002 ? still + 1 : 0
            time += step
        }
        values.append(GlassLayer.Shape(frame: target.frame, cornerRadius: target.radius, curve: .continuous))
        morph.duration = step * Double(values.count - 1)
        self.morph = morph
        return Keyframes(values: values, step: step, begin: now, loop: nil)
    }

    /// The glass, its shadow and the rows' cut, along one track.
    private func play(_ frames: Keyframes<GlassLayer.Shape>) {
        glass.play(frames.map { [$0] })
        bubbleShadow.play(frames)
        let origin = rows.frame.origin
        let last = frames.last
        cut.bounds = CGRect(origin: .zero, size: last.frame.size)
        cut.position = CGPoint(x: last.frame.midX - origin.x, y: last.frame.midY - origin.y)
        cut.cornerRadius = last.cornerRadius
        cut.cornerCurve = .continuous
        frames.play(on: cut, "bounds") { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }
        frames.play(on: cut, "position") { NSValue(point: CGPoint(x: $0.frame.midX - origin.x, y: $0.frame.midY - origin.y)) }
        frames.play(on: cut, "cornerRadius") { NSNumber(value: Double($0.cornerRadius)) }
    }

    /// A view's opacity, as `fade` takes a layer's: the view's own alpha set, so AppKit keeps it.
    private func fade(_ view: NSView, to alpha: CGFloat, over duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        guard let layer = view.layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        view.alphaValue = alpha
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = Float(alpha)
        fade.duration = duration
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        layer.add(fade, forKey: "fade")
    }

    /// From its presentation's opacity to `opacity`, after `delay`.
    private func fade(_ layer: CALayer, to opacity: Float, over duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = opacity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = opacity
        fade.duration = duration
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .backwards
        layer.add(fade, forKey: "fade")
    }

    // MARK: - The pointer

    /// The pill; while open the menu's rows — the list under them, which scrolls — and anywhere else, to close it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard isOpen else { return !pill.isHidden && pill.frame.contains(local) ? pill : nil }
        guard rows.frame.contains(local) else { return self }
        let inList = list.convert(local, from: self)
        return rowViews.first { $0 is BarMenuRow && $0.frame.contains(inList) } ?? list
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if isOpen, !rows.frame.contains(local) { close(animated: true) }
    }
}

/// The rows' document: its first row at the top.
@MainActor
private final class FlippedList: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
}

/// The bar's pill, over its capsule of glass: an icon, a title and its key dimmed after it, as a toast's buttons say
/// theirs; lit under the pointer.
@MainActor
private final class BarPill: PillButton {
    private var shown: (title: String, key: String, icon: Icon?)?

    func set(title: String, key: String, icon: Icon?) {
        guard shown?.title != title || shown?.key != key || shown?.icon != icon else { return }
        shown = (title, key, icon)
        set(title: title, image: IconImages.image(icon, size: iconSize))
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  \(key)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                        .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = text
        setAccessibilityHelp(key)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

/// A row of the menu, by its place among the entries, and what it needs across.
@MainActor
private protocol BarMenuEntry: AnyObject {
    var index: Int { get }
    var fittingWidth: CGFloat { get }
}

/// One of the menu's items: a check if it is among choices, its icon if any has one, its title — red when it cannot be
/// undone — and its key at the end; a band behind it while selected, which the pointer moves.
@MainActor
private final class BarMenuRow: NSView, Hoverable, BarMenuEntry {
    /// The columns before the title, each there when any row needs it, so the titles line up.
    struct Columns {
        var checks: Bool
        var icons: Bool

        static let padding: CGFloat = 10
        var iconX: CGFloat { Self.padding + (checks ? 20 : 0) }
        var textX: CGFloat { iconX + (icons ? 24 : 0) }
    }

    let index: Int
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    private let check = NSImageView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let band = CALayer()
    private let columns: Columns

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateBand()
            setAccessibilitySelected(isSelected)
        }
    }

    var isHovered = false {
        didSet { if isHovered, !oldValue { onHover?() } }
    }

    init(item: BarMenu.Item, index: Int, columns: Columns) {
        self.index = index
        self.columns = columns
        super.init(frame: .zero)
        wantsLayer = true
        band.cornerRadius = BarMenu.cornerRadius - BarMenu.inset
        band.cornerCurve = .continuous
        layer!.addSublayer(band)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        check.contentTintColor = .labelColor
        check.isHidden = item.checked != true
        icon.image = IconImages.image(item.icon, size: 16)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.isHidden = icon.image == nil
        title.stringValue = item.title
        title.font = .systemFont(ofSize: 13)
        title.textColor = item.destructive ? .systemRed : .labelColor
        title.lineBreakMode = .byTruncatingTail
        key.stringValue = item.chord?.glyphs ?? ""
        key.font = .systemFont(ofSize: 12, weight: .medium)
        key.textColor = .secondaryLabelColor
        key.alignment = .right
        for view in [check, icon, title, key] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        if item.checked == true { setAccessibilityValue(NSNumber(value: true)) }
        if let chord = item.chord { setAccessibilityHelp(chord.glyphs) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What the row asks for: its title and its key side by side, never truncated.
    var fittingWidth: CGFloat {
        let keyWidth = key.stringValue.isEmpty ? 0 : ceil(key.intrinsicContentSize.width) + 24
        return columns.textX + title.unboundedWidth + keyWidth + Columns.padding
    }

    override func layout() {
        super.layout()
        let keyWidth = ceil(key.intrinsicContentSize.width)
        let height = title.intrinsicContentSize.height
        let padding = Columns.padding
        check.frame = CGRect(x: padding, y: (bounds.height - 14) / 2, width: 14, height: 14)
        icon.frame = CGRect(x: columns.iconX, y: (bounds.height - 16) / 2, width: 16, height: 16)
        key.frame = CGRect(x: bounds.width - padding - keyWidth, y: ((bounds.height - height) / 2).rounded(), width: keyWidth, height: height)
        let end = key.stringValue.isEmpty ? bounds.width - padding : key.frame.minX - 12
        title.frame = CGRect(x: columns.textX, y: ((bounds.height - height) / 2).rounded(), width: max(0, end - columns.textX), height: height)
        Motion.together { band.frame = bounds }
        updateBand()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBand()
    }

    private func updateBand() {
        Motion.together { band.backgroundColor = isSelected ? PillButton.ink(0.1).resolved(for: effectiveAppearance) : nil }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A section's title among the menu's items, as a menu titles one: small, in the secondary label colour, over the
/// items' icons.
@MainActor
private final class BarMenuHeading: NSView, BarMenuEntry {
    let index: Int
    private let label = NSTextField(labelWithString: "")
    private let columns: BarMenuRow.Columns

    init(title: String, index: Int, columns: BarMenuRow.Columns) {
        self.index = index
        self.columns = columns
        super.init(frame: .zero)
        label.stringValue = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        setAccessibilityElement(false)
        label.setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var fittingWidth: CGFloat { columns.iconX + label.unboundedWidth + BarMenuRow.Columns.padding }

    override func layout() {
        super.layout()
        let height = label.intrinsicContentSize.height
        // Its text sits low, nearer the items it titles.
        label.frame = CGRect(x: columns.iconX, y: bounds.height - height - 4, width: max(0, bounds.width - columns.iconX - BarMenuRow.Columns.padding),
                             height: height)
    }

    override var isFlipped: Bool { true }
}

extension NSTextField {
    /// What it takes across to draw its text whole: a truncating label's intrinsic width falls a few points short.
    var unboundedWidth: CGFloat { ceil(sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)).width) }
}

extension NSColor {
    /// As drawn in `appearance`, for a layer.
    func resolved(for appearance: NSAppearance) -> CGColor {
        var color: CGColor = cgColor
        appearance.performAsCurrentDrawingAppearance { color = cgColor }
        return color
    }
}
