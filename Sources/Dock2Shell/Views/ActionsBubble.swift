import AppKit
import Carbon.HIToolbox
import Dock2Core

/// What a view offers in its bar, at the field's trailing end ([views](product/plugins/views.md#the-bar)).
enum ViewActions {
    /// A form's submit: a click, or ⌘↩.
    case submit(String, run: () -> Void)
    /// The selection's actions, then the view's own, as ⌘K lists them; `perform` runs one on its item.
    case menu(ActionSet, perform: (ActionNode, String?) -> Void)
}

/// The bar's one control: a capsule of the label's glass at the field's trailing end — "Actions ⌘K", or a form's
/// submit — that opens into the actions' menu, the capsule growing up and to the left, concentric with the
/// panel's corner, its label giving way to rows that fill it. While open it takes the keys first (`key`).
@MainActor
final class ActionsBubble: NSView {
    static let pillHeight: CGFloat = 28
    /// From the menu's edge to the pill's place and to a row's band, so their corners are concentric with its.
    static let inset: CGFloat = 5
    static let rowHeight: CGFloat = 30
    static let separatorHeight: CGFloat = 9
    static let minimumWidth: CGFloat = 240
    static var cornerRadius: CGFloat { pillHeight / 2 + inset }
    /// What grows on, and what draws back on: the panel's own springs (`GrowthMotion`).
    static let opening = SidelineMotion.Spring(response: GrowthMotion.outResponse, damping: GrowthMotion.outDamping)
    static let closing = SidelineMotion.Spring(response: GrowthMotion.inResponse, damping: 1)

    /// Whose trailing end the pill sits at: a sibling, so its frame is in this view's coordinates.
    weak var field: FieldView?
    /// The menu opened or closed: what is behind it recedes while it is open.
    var onOpenChange: ((Bool) -> Void)?

    private(set) var isOpen = false
    private var offers: ViewActions?
    private let pill = BarPill()
    /// The pill's glass and, open, the menu's: its shadow, its glass, and its rows, cut to the glass as it grows.
    private let bubble = NSView()
    private let bubbleShadow = PanelShadow()
    private let glass = GlassView(recipe: .label(dark: false))
    private let rows = NSView()
    private let cut = CALayer()
    private var entries: [Entry] = []
    private var rowViews: [ActionRow] = []
    private var selection: Int?
    /// The glass's shape on its way, for a change of mind mid-flight to start from where it is.
    private var morph: Morph?
    private var closings = 0

    private enum Entry {
        case action(ActionNode, item: String?, chord: Chord?)
        case separator
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        bubble.wantsLayer = true
        bubble.isHidden = true
        rows.wantsLayer = true
        rows.layer!.opacity = 0
        cut.backgroundColor = .black
        rows.layer!.mask = cut
        for view in [bubbleShadow, glass, rows] as [NSView] { bubble.addSubview(view) }
        addSubview(bubble)
        pill.isHidden = true
        pill.onClick = { [weak self] in self?.pillClicked() }
        addSubview(pill)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - What it offers

    /// How far in from the field's trailing end the pill reaches, and the gap before it.
    var reserve: CGFloat { pill.isHidden ? 0 : PanelMetrics.margin + pill.intrinsicContentSize.width + 2 * PanelMetrics.unit }

    func setOffers(_ offers: ViewActions?) {
        self.offers = offers
        switch offers {
        case .submit(let title, _):
            pill.set(title: title, key: "⌘↩")
            pill.isHidden = false
        case .menu(let set, _):
            pill.set(title: "Actions", key: "⌘K")
            pill.isHidden = set.isEmpty
        case nil:
            pill.isHidden = true
        }
        matchAppearance()
        if isOpen {
            // Redrawn under the open menu — a sync, a plugin's update — it keeps up, or closes with nothing left.
            if case .menu(let set, _) = offers, !set.isEmpty {
                fill(set)
                Motion.together { place(animated: false) }
            } else {
                close(animated: false)
            }
        }
        needsLayout = true
    }

    private func pillClicked() {
        switch offers {
        case .submit(_, let run): run()
        case .menu: toggle()
        case nil: break
        }
    }

    // MARK: - Opening and closing

    func toggle() {
        if isOpen { close(animated: true) } else { open() }
    }

    func open() {
        guard !isOpen, case .menu(let set, _) = offers, !set.isEmpty else { return }
        isOpen = true
        closings += 1
        selection = nil
        fill(set)
        layoutSubtreeIfNeeded()
        bubble.isHidden = false
        Motion.together {
            if DisplayOptions.reduceMotion { crossfade() }
            place(animated: true, from: isMorphing ? nil : capsule)
            fade(rows.layer!, to: 1, over: 0.16, delay: DisplayOptions.reduceMotion ? 0 : 0.04)
            fade(pill, to: 0, over: 0.08)
            bubbleShadow.fade(in: true, duration: 0.2)
        }
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

    /// A key while open: the arrows, ↩, an action's own chord, Esc and ⌘K are the menu's; any other closes it
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
            if let selection { run(selection) }
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "k" {
            close(animated: true)
            return true
        }
        if let index = entries.firstIndex(where: { if case .action(_, _, let chord?) = $0 { chord.matches(event) } else { false } }) {
            run(index)
            return true
        }
        close(animated: true)
        return false
    }

    private func move(by step: Int) {
        let actions = entries.indices.filter { if case .action = entries[$0] { true } else { false } }
        guard !actions.isEmpty else { return }
        let at = selection.flatMap { actions.firstIndex(of: $0) } ?? -1
        select(actions[min(max(at + step, 0), actions.count - 1)])
    }

    private func select(_ index: Int?) {
        selection = index
        for row in rowViews { row.isSelected = row.index == index }
        if let row = rowViews.first(where: { $0.index == index }) {
            NSAccessibility.post(element: row, notification: .focusedUIElementChanged)
        }
    }

    private func run(_ index: Int) {
        guard case .action(let node, let item, _) = entries[index], case .menu(_, let perform) = offers else { return }
        close(animated: true)
        perform(node, item)
    }

    // MARK: - Rows

    /// The item's actions, then the view's: the first two primary — ↩ and ⌘↩ — unless they have chords of their own.
    private func fill(_ set: ActionSet) {
        var entries: [Entry] = []
        func add(_ actions: [ActionNode], item: String?, primary: Bool) {
            for (index, node) in actions.enumerated() {
                let chord = Chord(node.key) ?? (primary ? Chord(index == 0 ? "return" : index == 1 ? "cmd+return" : nil) : nil)
                entries.append(.action(node, item: item, chord: chord))
            }
        }
        add(set.items, item: set.item, primary: true)
        if !set.items.isEmpty, !set.view.isEmpty { entries.append(.separator) }
        add(set.view, item: nil, primary: set.items.isEmpty)
        let selected = selection.flatMap { index -> String? in
            guard self.entries.indices.contains(index), case .action(let node, _, _) = self.entries[index] else { return nil }
            return node.id
        }
        self.entries = entries
        rowViews.forEach { $0.removeFromSuperview() }
        let iconned = entries.contains { if case .action(let node, _, _) = $0 { node.icon != nil } else { false } }
        rowViews = entries.enumerated().compactMap { index, entry in
            guard case .action(let node, _, let chord) = entry else { return nil }
            let row = ActionRow(node: node, chord: chord, index: index, iconned: iconned)
            row.onHover = { [weak self] in self?.select(index) }
            row.onClick = { [weak self] in self?.run(index) }
            rows.addSubview(row)
            return row
        }
        let kept = entries.firstIndex { if case .action(let node, _, _) = $0 { node.id == selected } else { false } }
        select(kept ?? entries.firstIndex { if case .action = $0 { true } else { false } })
    }

    /// The pill as the field leaves it room: centred on the field's midline, its end on the panel's margin, under the
    /// rows' trailing ends.
    private var capsule: CGRect {
        guard let field else { return .zero }
        let width = pill.intrinsicContentSize.width
        let frame = field.frame
        return CGRect(x: frame.maxX - PanelMetrics.margin - width,
                      y: frame.minY + ((frame.height - Self.pillHeight) / 2).rounded(), width: width, height: Self.pillHeight)
    }

    private var rowsHeight: CGFloat {
        entries.reduce(0) { total, entry in
            if case .separator = entry { total + Self.separatorHeight } else { total + Self.rowHeight }
        }
    }

    /// The open menu, as wide as its widest row: nested in the panel's corner, concentric with it, wherever the pill
    /// it grows from stands.
    private var menuFrame: CGRect {
        let pill = capsule
        let widest = rowViews.map(\.fittingWidth).max() ?? 0
        let width = max(Self.minimumWidth, widest + 2 * Self.inset, pill.width + 2 * Self.inset)
        let height = Self.inset + rowsHeight + Self.inset
        guard let field = field?.frame else { return .zero }
        let corner = PanelMetrics.radius - Self.cornerRadius
        return CGRect(x: field.maxX - corner - width, y: field.minY + corner, width: width, height: height)
    }

    override func layout() {
        super.layout()
        Motion.together {
            pill.frame = capsule
            guard !isMorphing else { return }
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
        var y = open.height - Self.inset
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                y -= Self.separatorHeight
            case .action:
                y -= Self.rowHeight
                rowViews.first { $0.index == index }?.frame = CGRect(x: Self.inset, y: y, width: open.width - 2 * Self.inset, height: Self.rowHeight)
            }
        }
        separatorLayers(in: open)
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

    private func separatorLayers(in open: CGRect) {
        separators.forEach { $0.removeFromSuperlayer() }
        separators = []
        var y = open.height - Self.inset
        for entry in entries {
            switch entry {
            case .separator:
                y -= Self.separatorHeight
                let line = CALayer()
                effectiveAppearance.performAsCurrentDrawingAppearance { line.backgroundColor = NSColor.separatorColor.cgColor }
                line.frame = CGRect(x: 2 * Self.inset + 6, y: y + Self.separatorHeight / 2, width: open.width - 4 * Self.inset - 12, height: 0.5)
                rows.layer!.addSublayer(line)
                separators.append(line)
            case .action:
                y -= Self.rowHeight
            }
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

    /// The pill; while open the menu's rows, and anywhere else, to close it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        guard isOpen else { return !pill.isHidden && pill.frame.contains(local) ? pill : nil }
        let inRows = rows.convert(local, from: self)
        return rowViews.first { $0.frame.contains(inRows) } ?? self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if isOpen, !rows.frame.contains(local) { close(animated: true) }
    }
}

/// The bar's pill, over its capsule of glass: a title and its key dimmed after it, as a toast's buttons say theirs;
/// lit under the pointer.
@MainActor
private final class BarPill: PillButton {
    private var shown: (title: String, key: String)?

    func set(title: String, key: String) {
        guard shown?.title != title || shown?.key != key else { return }
        shown = (title, key)
        set(title: title, image: nil)
        let text = NSMutableAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        text.append(NSAttributedString(string: "  \(key)", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                                        .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = text
        setAccessibilityHelp(key)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
}

/// One of the menu's actions: its icon if any has one, its title — red when it cannot be undone — and its key at
/// the end; a band behind it while selected, which the pointer moves.
@MainActor
private final class ActionRow: NSView, Hoverable {
    let index: Int
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let key = NSTextField(labelWithString: "")
    private let band = CALayer()
    private let iconned: Bool

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

    init(node: ActionNode, chord: Chord?, index: Int, iconned: Bool) {
        self.index = index
        self.iconned = iconned
        super.init(frame: .zero)
        wantsLayer = true
        band.cornerRadius = ActionsBubble.cornerRadius - ActionsBubble.inset
        band.cornerCurve = .continuous
        layer!.addSublayer(band)
        icon.image = IconImages.image(node.icon, size: 16)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.isHidden = icon.image == nil
        title.stringValue = node.title
        title.font = .systemFont(ofSize: 13)
        title.textColor = node.destructive == true ? .systemRed : .labelColor
        title.lineBreakMode = .byTruncatingTail
        key.stringValue = chord?.glyphs ?? ""
        key.font = .systemFont(ofSize: 12, weight: .medium)
        key.textColor = .secondaryLabelColor
        key.alignment = .right
        for view in [icon, title, key] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(node.title)
        if let chord { setAccessibilityHelp(chord.glyphs) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static let padding: CGFloat = 10
    private var textX: CGFloat { Self.padding + (iconned ? 24 : 0) }

    /// What the row asks for: its title and its key side by side, never truncated.
    var fittingWidth: CGFloat {
        let keyWidth = key.stringValue.isEmpty ? 0 : ceil(key.intrinsicContentSize.width) + 24
        return textX + ceil(title.intrinsicContentSize.width) + keyWidth + Self.padding
    }

    override func layout() {
        super.layout()
        let keyWidth = ceil(key.intrinsicContentSize.width)
        let height = title.intrinsicContentSize.height
        icon.frame = CGRect(x: Self.padding, y: (bounds.height - 16) / 2, width: 16, height: 16)
        key.frame = CGRect(x: bounds.width - Self.padding - keyWidth, y: ((bounds.height - height) / 2).rounded(), width: keyWidth, height: height)
        let end = key.stringValue.isEmpty ? bounds.width - Self.padding : key.frame.minX - 12
        title.frame = CGRect(x: textX, y: ((bounds.height - height) / 2).rounded(), width: max(0, end - textX), height: height)
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

extension NSColor {
    /// As drawn in `appearance`, for a layer.
    func resolved(for appearance: NSAppearance) -> CGColor {
        var color: CGColor = cgColor
        appearance.performAsCurrentDrawingAppearance { color = cgColor }
        return color
    }
}
