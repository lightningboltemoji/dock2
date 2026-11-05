import AppKit
import Dock2Core

/// What the dock wants of whoever handles drags on it.
@MainActor
protocol DockDragHandler: AnyObject {
    /// Whether the tile in `slot` can be picked up.
    func canDrag(slot: Int) -> Bool
    /// A drag of the tile in `slot` began.
    func dragBegan(slot: Int)
    /// A drag from anywhere is over the dock at `point` (stage coordinates), carrying `pasteboard`; the
    /// operation it would get.
    func dragMoved(to point: CGPoint?, pasteboard: NSPasteboard, isTile: Bool) -> NSDragOperation
    /// The drag was released over the dock; whether it was taken.
    func dropped(at point: CGPoint, pasteboard: NSPasteboard, isTile: Bool) -> Bool
    /// A tile drag ended; `offTheDock` when it ended away from the dock.
    func tileDragEnded(offTheDock: Bool)
}

/// The dock's content over the platter's glass, or on Snow Leopard's shelf: icons, dots, numbers and separators where
/// `DockLayout` puts them, in the stage's coordinates. It reports the pointer — hover, clicks, menus, drags —
/// and decides nothing. It draws nothing itself: its layers live in the glass's overlay.
@MainActor
final class DockView: NSView, NSDraggingSource {
    struct Tile: Equatable {
        var kind: TileKind
        var image: NSImage
        var running: Bool
        var badge: String?
    }

    enum Item: Equatable {
        case tile(Tile)
        case separator(DockGroup)
        case gap

        var kind: DockLayout.Kind {
            switch self {
            case .tile: .tile
            case .separator: .separator
            case .gap: .gap
            }
        }

        var tileKind: TileKind? {
            if case .tile(let tile) = self { tile.kind } else { nil }
        }
    }

    /// The pasteboard type a tile carries while dragged: only dock2 reads it.
    static let tileType = NSPasteboard.PasteboardType("zip.tanner.dock2.tile")

    /// The slot under the pointer changed; nil when it left the tiles.
    var onHover: ((Int?) -> Void)?
    /// A tile was clicked: pressed and released over the same tile.
    var onClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    /// The menu for a tile's slot, or for the platter when nil.
    var menuFor: ((Int?) -> NSMenu?)?
    /// A click on the platter between tiles.
    var onPlatterClick: (() -> Void)?
    /// A tile's name, for VoiceOver.
    var nameFor: ((TileKind) -> String?)?
    /// The appearance changed: pictures drawn for one are redrawn for the other.
    var onAppearanceChange: (() -> Void)?
    private var elements: [DockItemElement] = []
    /// The puck's tiles, a group of their own after the platter's.
    private var sidelineGroup: NSAccessibilityElement?
    weak var dragHandler: DockDragHandler?

    private(set) var items: [Item] = []
    private(set) var layout: DockLayout?
    /// Holds everything the dock draws, so that auto-hide can slide it as one.
    private let content = CALayer()
    /// The icons alone, for the shelf to reflect.
    private let tiles = CALayer()
    private var shelf: Shelf?
    private var icons: [TileKind: TileLayer] = [:]
    private var dots: [TileKind: CALayer] = [:]
    private var numbers: [TileKind: CATextLayer] = [:]
    private var lines: [DockGroup: CALayer] = [:]
    private var scale: CGFloat = 2
    private var hovered: Int?
    private var pressed: (slot: Int, at: CGPoint)?

    /// The view takes the pointer; what it draws goes into `overlay`, over the platter's glass and in its
    /// layer tree, which is where the dots' and separators' blends can see the glass.
    init(overlay: CALayer) {
        super.init(frame: .zero)
        content.blendsThrough()
        // A sublayer added or removed inside an animating transaction would otherwise cross-fade the
        // whole row between its old and new arrangement.
        content.actions = ["sublayers": NSNull()]
        tiles.actions = ["sublayers": NSNull()]
        content.addSublayer(tiles)
        overlay.addSublayer(content)
        registerForDraggedTypes([.fileURL, Self.tileType])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Showing

    /// Lays `items` out per `layout`, which must have been computed for exactly their kinds, in this view's
    /// coordinates. With `motion`, tiles slide to their new places, new ones grow in and old ones shrink away, and
    /// one crossing between the row and the puck flies over the rest.
    func show(_ items: [Item], layout: DockLayout, scale: CGFloat, motion: Motion?) {
        precondition(items.map(\.kind) == layout.slots.map(\.kind), "the layout is not of these items")
        // A press outlives a relayout on the tile it began on, or ends with that tile.
        if let press = pressed {
            let kind = self.items.indices.contains(press.slot) ? self.items[press.slot].tileKind : nil
            pressed = kind.flatMap { kind in items.firstIndex { $0.tileKind == kind } }.map { ($0, press.at) }
        }
        let wasSidelined = sidelined
        self.items = items
        self.layout = layout
        self.scale = scale
        let crossing = wasSidelined.symmetricDifference(sidelined)
        makeElements()
        let dark = isDark

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Not `frame`: auto-hide may have a transform on it.
        content.bounds = bounds
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        tiles.frame = bounds
        if layout.shelf == nil {
            shelf?.remove()
            shelf = nil
        } else if shelf == nil {
            shelf = Shelf(in: content, under: tiles)
        }
        CATransaction.commit()

        var liveTiles: Set<TileKind> = []
        var liveLines: Set<DockGroup> = []
        shows += 1
        let show = shows
        CATransaction.begin()
        // Icons drawn larger for the way are drawn at their size once there.
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.shows == show else { return }
                for icon in self.icons.values { icon.drawnAt = 1 }
            }
        }
        Motion.perform(motion) {
            shelf?.update(layout, bounds: bounds, scale: scale,
                          space: window?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB(), motion: motion)
            for (item, slot) in zip(items, layout.slots) {
                switch item {
                case .tile(let tile):
                    liveTiles.insert(tile.kind)
                    place(tile, in: slot, dark: dark, motion: motion, crossing: crossing.contains(tile.kind))
                case .separator(let group):
                    liveLines.insert(group)
                    let new = lines[group] == nil
                    let line = lines[group] ?? makeLayer(appearing: motion) { lines[group] = $0 }
                    let frame = pixelAligned(slot.content, scale: scale)
                    Self.move(line, to: frame, motion: new ? nil : motion)
                    styleLine(line, dark: dark, dashes: slot.dashes.map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) })
                case .gap:
                    break
                }
            }
        }
        for (kind, icon) in icons where !liveTiles.contains(kind) {
            icons[kind] = nil
            disappear(icon, motion: motion)
            if let dot = dots.removeValue(forKey: kind) { disappear(dot, motion: motion) }
            if let number = numbers.removeValue(forKey: kind) { disappear(number, motion: motion) }
        }
        for (group, line) in lines where !liveLines.contains(group) {
            lines[group] = nil
            disappear(line, motion: motion)
        }
        CATransaction.commit()
    }

    /// Counts `show`s, so the end of one superseded by a later one does nothing.
    private var shows = 0

    /// The tiles on the puck.
    private var sidelined: Set<TileKind> {
        guard let layout else { return [] }
        return Set(items.indices.compactMap { layout.isSidelined($0) ? items[$0].tileKind : nil })
    }

    private func place(_ tile: Tile, in slot: DockLayout.Slot, dark: Bool, motion: Motion?, crossing: Bool) {
        let frame = pixelSnapped(slot.content, scale: scale)
        let icon: TileLayer
        if let existing = icons[tile.kind] {
            icon = existing
            move(icon, to: frame, motion: motion, crossing: crossing)
        } else {
            icon = TileLayer()
            icons[tile.kind] = icon
            Motion.perform(nil) {
                tiles.addSublayer(icon)
                Self.place(icon, frame)
                icon.contentsScale = scale
            }
            if let motion { Self.appear(icon, motion: motion, grow: true) }
        }
        if icon.image !== tile.image || icon.contentsScale != scale {
            icon.contentsScale = scale
            icon.image = tile.image
        }
        icon.badge = tile.badge
        placeMark(of: tile, in: slot, number: numbered[tile.kind], dark: dark, motion: motion)
    }

    /// What stands under a tile: its dot, or its number in the dot's place. On the puck a tile has no dot: one
    /// leaving fades where it stood, and one hidden goes to its place unseen.
    private func placeMark(of tile: Tile, in slot: DockLayout.Slot, number: Int?, dark: Bool, motion: Motion?) {
        let new = dots[tile.kind] == nil
        let dot = dots[tile.kind] ?? makeLayer(appearing: motion) { dots[tile.kind] = $0 }
        if !slot.dot.isEmpty {
            Self.move(dot, to: pixelAligned(slot.dot, scale: scale), motion: new || dot.opacity == 0 ? nil : motion)
        }
        Self.fade(dot, to: tile.running && !slot.dot.isEmpty && number == nil ? 1 : 0, motion: new ? nil : motion)
        styleDot(dot, dark: dark)
        guard let number, let metrics = layout?.metrics else {
            if let shown = numbers[tile.kind] { Self.fade(shown, to: 0, motion: motion) }
            return
        }
        let layer = numbers[tile.kind] ?? makeNumber(of: tile.kind)
        Motion.perform(nil) {
            layer.string = "\(number)"
            layer.contentsScale = scale
            styleNumber(layer, size: metrics.numberSize, dark: dark)
        }
        Self.move(layer, to: numberFrame(in: slot, metrics: metrics), motion: layer.opacity == 0 ? nil : motion)
        Self.fade(layer, to: 1, motion: motion)
    }

    /// Moves a layer by its bounds and position, never its frame: a tile growing in or shrinking away has a
    /// scale on it, and a frame set through a scale is a different size.
    private static func place(_ layer: CALayer, _ rect: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// Moves `layer` to `rect` over `motion` from wherever it shows now, or there at once for none. Explicit
    /// animations, which a spring can drive and which never jump when another is in flight; the same place again
    /// leaves the one in flight alone.
    private static func move(_ layer: CALayer, to rect: CGRect, motion: Motion?) {
        guard layer.bounds.size != rect.size || layer.position != CGPoint(x: rect.midX, y: rect.midY) else { return }
        let shown = layer.presentation() ?? layer
        let from = (bounds: shown.bounds, position: shown.position)
        Motion.perform(nil) { place(layer, rect) }
        guard let motion else { return ["bounds", "position"].forEach(layer.removeAnimation(forKey:)) }
        layer.add(motion.animation("position", from: NSValue(point: from.position)), forKey: "position")
        guard from.bounds.size != rect.size else { return }
        let growing = rect.width >= from.bounds.width && rect.height >= from.bounds.height
        layer.add(motion.animation("bounds", from: NSValue(rect: from.bounds), growing: growing), forKey: "bounds")
    }

    /// Moves a tile's icon to `rect`, sized there at once and shown growing or shrinking on the way by a scale, so
    /// its badge, shade and bar scale with it. One crossing between the row and the puck flies over the rest, up as
    /// it leaves and down as it arrives, as high as a launch's hop.
    private func move(_ icon: TileLayer, to rect: CGRect, motion: Motion?, crossing: Bool) {
        guard icon.bounds.size != rect.size || icon.position != CGPoint(x: rect.midX, y: rect.midY) else { return }
        let shown = icon.presentation() ?? icon
        let from = (position: shown.position, width: shown.bounds.width * shown.transform.m11)
        Motion.perform(nil) {
            Self.place(icon, rect)
            icon.transform = CATransform3DIdentity
            icon.zPosition = crossing ? 1 : 0
        }
        // From where it shows, lifted or not: a new move takes over the lift too.
        icon.removeAnimation(forKey: "lift")
        guard let motion, rect.width > 0 else {
            ["position", "resize"].forEach(icon.removeAnimation(forKey:))
            icon.drawnAt = 1
            return
        }
        icon.add(motion.animation("position", from: NSValue(point: from.position)), forKey: "position")
        if abs(from.width - rect.width) > 0.5 {
            icon.drawnAt = max(1, from.width / rect.width)
            icon.add(motion.animation("transform.scale", from: from.width / rect.width, growing: rect.width > from.width),
                     forKey: "resize")
        }
        guard crossing, let springs = motion.springs, let layout else { return }
        let rate = 120.0, height = layout.metrics.hopHeight
        let lift = CAKeyframeAnimation(keyPath: "position")
        let values = SidelineMotion.lift(on: springs.out, rate: rate)
        lift.values = values.map { NSValue(point: CGPoint(x: 0, y: $0 * height)) }
        lift.duration = Double(values.count - 1) / rate
        lift.isAdditive = true
        icon.add(lift, forKey: "lift")
    }

    /// Fades `layer` to `opacity` over `motion` from however it shows now, or at once for none.
    private static func fade(_ layer: CALayer, to opacity: Float, motion: Motion?) {
        guard layer.opacity != opacity else { return }
        let from = (layer.presentation() ?? layer).opacity
        Motion.perform(nil) { layer.opacity = opacity }
        guard let motion else { return layer.removeAnimation(forKey: "opacity") }
        layer.add(motion.animation("opacity", from: from, growing: false), forKey: "opacity")
    }

    private func makeLayer(appearing motion: Motion?, _ keep: (CALayer) -> Void) -> CALayer {
        let layer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.addSublayer(layer)
        CATransaction.commit()
        keep(layer)
        if let motion { Self.appear(layer, motion: motion, grow: false) }
        return layer
    }

    private func makeNumber(of kind: TileKind) -> CATextLayer {
        let number = CATextLayer()
        Motion.perform(nil) {
            number.alignmentMode = .center
            number.opacity = 0
            content.addSublayer(number)
        }
        numbers[kind] = number
        return number
    }

    /// Fades a layer in, growing it from nothing when `grow`. Explicit animations: implicit ones do not run
    /// on a layer added in the same transaction.
    private static func appear(_ layer: CALayer, motion: Motion, grow: Bool) {
        var animations = ["appear": motion.animation("opacity", from: 0, growing: false)]
        if grow { animations["grow"] = motion.animation("transform.scale", from: 0.01) }
        for (key, animation) in animations {
            animation.fillMode = .backwards
            layer.add(animation, forKey: key)
        }
    }

    private func disappear(_ layer: CALayer, motion: Motion?) {
        guard let motion else {
            layer.removeFromSuperlayer()
            return
        }
        let shown = layer.presentation() ?? layer
        let shrinks = layer is TileLayer
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        Motion.perform(nil) {
            layer.opacity = 0
            if shrinks { layer.transform = CATransform3DMakeScale(0.01, 0.01, 1) }
        }
        layer.add(motion.animation("opacity", from: shown.opacity, growing: false), forKey: "opacity")
        if shrinks {
            layer.add(motion.animation("transform", from: NSValue(caTransform3D: shown.transform), growing: false), forKey: "transform")
        }
        CATransaction.commit()
    }

    /// The tile's icon, for a drag image or a poof.
    func iconFrame(of kind: TileKind) -> CGRect? {
        icons[kind]?.frame
    }

    /// Darkens the tile a drop would open with, as a press does.
    func setHighlighted(_ kind: TileKind?) {
        for (tile, icon) in icons { icon.isPressed = tile == kind }
    }

    /// The ring: keyboard focus on one tile, or none.
    func setRing(_ kind: TileKind?) {
        for (tile, icon) in icons { icon.isFocused = tile == kind }
        // VoiceOver stays in the field while the arrows walk the ring, as it does for the results: the tile
        // ringed is said aloud, once.
        defer { ringed = kind }
        guard let kind, kind != ringed, let element = elements.first(where: { $0.kind == kind }) else { return }
        let text = [element.accessibilityLabel(), element.accessibilityValue() as? String].compactMap { $0 }.joined(separator: ", ")
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private var ringed: TileKind?

    /// A tile's picture changed, nothing else.
    func setImage(_ image: NSImage, for kind: TileKind) {
        guard let index = items.firstIndex(where: { $0.tileKind == kind }),
              case .tile(var tile) = items[index] else { return }
        tile.image = image
        items[index] = .tile(tile)
        icons[kind]?.image = image
    }

    /// A tile's badge changed, nothing else.
    func setBadge(_ badge: String?, for kind: TileKind) {
        guard let index = items.firstIndex(where: { $0.tileKind == kind }),
              case .tile(var tile) = items[index], tile.badge != badge else { return }
        tile.badge = badge
        items[index] = .tile(tile)
        icons[kind]?.badge = badge
    }

    var hoveredSlot: Int? { hovered }

    // MARK: - Accessibility

    /// The tiles as dock items, the system Dock's way: VoiceOver lists them, presses them, opens their menus.
    /// The puck's are a group after them.
    private func makeElements() {
        guard let layout else { return }
        let group = layout.puck.map { puck in
            let group = NSAccessibilityElement()
            group.setAccessibilityRole(.group)
            group.setAccessibilityLabel("Sideline")
            group.setAccessibilityParent(self)
            group.setAccessibilityFrameInParentSpace(puck.frame.offsetBy(dx: -layout.platter.minX, dy: -layout.platter.minY))
            return group
        }
        elements = zip(items, layout.slots).enumerated().compactMap { index, pair in
            guard case .tile(let tile) = pair.0 else { return nil }
            // In its parent's space: the list's, which is the platter's, or the group's, which is the puck's.
            let sidelined = layout.isSidelined(index)
            let origin = sidelined ? layout.puck?.frame.origin ?? .zero : layout.platter.origin
            return DockItemElement(slot: index, kind: tile.kind, name: nameFor?(tile.kind) ?? "", running: tile.running,
                                   frame: pair.1.frame.offsetBy(dx: -origin.x, dy: -origin.y),
                                   parent: sidelined ? group ?? self : self,
                                   press: { [weak self] slot in self?.onClick?(slot, []) },
                                   showMenu: { [weak self] slot in self?.popUpMenu(slot) })
        }
        group?.setAccessibilityChildren(elements.filter { layout.isSidelined($0.slot) })
        sidelineGroup = group
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private func popUpMenu(_ slot: Int) {
        guard let layout, layout.slots.indices.contains(slot), let menu = menuFor?(slot) else { return }
        let frame = layout.slots[slot].frame
        menu.popUp(positioning: nil, at: CGPoint(x: frame.minX, y: frame.maxY + menu.size.height + 8), in: self)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "Dock" }
    override func accessibilityChildren() -> [Any]? {
        let row: [Any] = elements.filter { layout?.isSidelined($0.slot) != true }
        return row + (sidelineGroup.map { [$0] } ?? [])
    }
    override func accessibilityFrame() -> NSRect {
        guard let platter = layout?.platter, let window else { return super.accessibilityFrame() }
        return window.convertToScreen(convert(platter, to: nil))
    }

    func setProgress(_ progress: Double?, _ kind: TileKind) {
        icons[kind]?.progress = progress
    }

    func setBouncing(_ bouncing: Bool, _ kind: TileKind, height: CGFloat) {
        guard let icon = icons[kind] else { return }
        bouncing ? icon.startBouncing(height: height) : icon.stopBouncing()
    }

    /// Auto-hide: slides everything down by `offset`, over `motion`.
    func slide(by offset: CGFloat, motion: Motion?) {
        Motion.perform(motion) {
            content.transform = CATransform3DMakeTranslation(0, -offset, 0)
        }
    }

    /// The tiles pop onto the platter as it slides in, in a wave from `origin`, an x in this view's
    /// coordinates, starting `delay` from now: each icon grows from small past its size and settles, fading
    /// in with its dot, and the separators fade in as the wave passes.
    func popIn(from origin: CGFloat, after delay: CFTimeInterval) {
        guard let layout else { return }
        let placed = zip(items, layout.slots).filter { $0.0.kind != .gap }
        let delays = EntryMotion.waveDelays(placed.map { Double($0.1.content.midX) }, from: Double(origin),
                                            step: Double(layout.metrics.tileWidth))
        let start = content.convertTime(CACurrentMediaTime(), from: nil) + delay
        for ((item, _), wave) in zip(placed, delays) {
            let begin = start + wave
            switch item {
            case .tile(let tile):
                if let icon = icons[tile.kind] { Self.pop(icon, at: begin) }
                if let dot = dots[tile.kind] { Self.fadeIn(dot, at: begin) }
            case .separator(let group):
                if let line = lines[group] { Self.fadeIn(line, at: begin) }
            case .gap:
                break
            }
        }
    }

    private static func pop(_ layer: CALayer, at begin: CFTimeInterval) {
        let spring = CASpringAnimation(perceptualDuration: EntryMotion.popSpring.duration, bounce: EntryMotion.popSpring.bounce)
        spring.keyPath = "transform.scale"
        spring.fromValue = EntryMotion.popScale
        spring.toValue = 1
        spring.duration = spring.settlingDuration
        spring.beginTime = begin
        spring.fillMode = .backwards
        layer.add(spring, forKey: "pop")
        fadeIn(layer, at: begin)
    }

    /// From `popOpacity` of whatever opacity the layer has to all of it: the dot of an app not running to none.
    private static func fadeIn(_ layer: CALayer, at begin: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Double(layer.opacity) * EntryMotion.popOpacity
        fade.duration = EntryMotion.popFade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.beginTime = begin
        fade.fillMode = .backwards
        layer.add(fade, forKey: "popFade")
    }

    /// The next arrangement fades in over the last: Reduce Motion's reshape.
    func crossfade(over motion: Motion) {
        Motion.crossfade(content, over: motion)
    }

    // MARK: - Numbers

    private static let numberFade = Motion(0.15, DockMotion.reshapeCurve)

    /// Holding ⌘: the tiles ⌘1–⌘9 reach show their numbers in their dots' places.
    var showsNumbers = false {
        didSet {
            guard showsNumbers != oldValue, let layout else { return }
            let numbered = numbered, dark = isDark
            Motion.together {
                for (item, slot) in zip(items, layout.slots) {
                    guard case .tile(let tile) = item else { continue }
                    placeMark(of: tile, in: slot, number: numbered[tile.kind], dark: dark, motion: Self.numberFade)
                }
            }
        }
    }

    /// The number each tile is showing.
    var numbered: [TileKind: Int] {
        guard showsNumbers, let layout else { return [:] }
        let row = items.prefix(layout.rowCount).map(\.tileKind)
        return Dictionary(uniqueKeysWithValues: DockModel.numbered(row).enumerated().compactMap { number, index in
            row[index].map { ($0, number + 1) }
        })
    }

    /// A line of type around the indicator's place, its digits' middle on the indicator's centre.
    private func numberFrame(in slot: DockLayout.Slot, metrics: DockMetrics) -> CGRect {
        let font = Self.numberFont(size: metrics.numberSize)
        let height = font.ascender - font.descender
        let top = slot.frame.minY + metrics.numberCenterHeight - font.capHeight / 2 + font.ascender
        return pixelAligned(CGRect(x: slot.dot.midX - slot.frame.width / 2, y: top - height, width: slot.frame.width, height: height),
                            scale: scale)
    }

    private static func numberFont(size: Double) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    // MARK: - Appearance

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = isDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if style == .glass {
            for dot in dots.values { styleDot(dot, dark: dark) }
            for line in lines.values { styleLine(line, dark: dark, dashes: []) }
            for number in numbers.values { styleNumber(number, size: number.fontSize, dark: dark) }
        }
        CATransaction.commit()
        onAppearanceChange?()
    }

    private var style: DockStyle { layout?.metrics.style ?? .glass }

    /// On the glass, black in the light appearance; in the dark one the Dock adds 124 of 255 to whatever is
    /// behind, which a plus-lighter blend of grey 105 does. On the shelf, Snow Leopard's light, added.
    private func styleDot(_ dot: CALayer, dark: Bool) {
        switch style {
        case .glass:
            dot.contents = nil
            dot.cornerRadius = dot.bounds.width / 2
            dot.backgroundColor = CGColor(gray: dark ? 105 / 255 : 0, alpha: 1)
            dot.compositingFilter = dark ? "plusL" : nil
        case .snowLeopard:
            dot.cornerRadius = 0
            dot.backgroundColor = nil
            dot.contentsScale = scale
            dot.contents = ShelfArt.light(size: dot.bounds.size, scale: scale)
            dot.compositingFilter = "plusL"
        }
    }

    /// In the dot's ink, which in the dark appearance is what it adds. On the shelf, the light's white.
    private func styleNumber(_ number: CATextLayer, size: CGFloat, dark: Bool) {
        number.font = Self.numberFont(size: size)
        number.fontSize = size
        switch style {
        case .glass:
            number.foregroundColor = CGColor(gray: dark ? 105 / 255 : 0, alpha: 1)
            number.compositingFilter = dark ? "plusL" : nil
        case .snowLeopard:
            number.foregroundColor = CGColor(gray: 1, alpha: 1)
            number.compositingFilter = nil
        }
    }

    /// On the glass, the separator takes 57 of 255 from whatever is behind it in the light appearance, a
    /// plus-darker blend of grey 188, and adds 65 in the dark, a plus-lighter grey 50 — each once colour
    /// management has had its say. On the shelf, its lane of `dashes`.
    private func styleLine(_ line: CALayer, dark: Bool, dashes: [CGRect]) {
        switch style {
        case .glass:
            line.contents = nil
            line.backgroundColor = CGColor(gray: (dark ? 50 : 188) / 255, alpha: 1)
            line.compositingFilter = dark ? "plusL" : "plusD"
        case .snowLeopard:
            line.backgroundColor = nil
            line.compositingFilter = nil
            line.contentsScale = scale
            line.contents = ShelfArt.lane(dashes, size: line.bounds.size, scale: scale)
        }
    }

    // MARK: - The pointer

    private func point(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func tile(at point: CGPoint) -> Int? {
        layout?.tileIndex(at: point)
    }

    private func hover(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        onHover?(index)
    }

    /// The pointer moved to `point`, in the stage's coordinates, or onto another window for nil.
    func hover(at point: CGPoint?) {
        hover(point.flatMap(tile(at:)))
    }

    override func mouseDown(with event: NSEvent) {
        let at = point(event)
        guard let index = tile(at: at) else {
            pressed = nil
            if layout?.contains(at) == true { onPlatterClick?() }
            return
        }
        pressed = (index, at)
        if case .tile(let tile) = items[index] { icons[tile.kind]?.isPressed = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let at = point(event)
        if hypot(at.x - pressed.at.x, at.y - pressed.at.y) > 3, dragHandler?.canDrag(slot: pressed.slot) == true {
            beginTileDrag(pressed.slot, event: event)
            return
        }
        if case .tile(let tile) = items[pressed.slot] { icons[tile.kind]?.isPressed = self.tile(at: at) == pressed.slot }
    }

    override func mouseUp(with event: NSEvent) {
        guard let (index, _) = pressed else { return }
        pressed = nil
        if case .tile(let tile) = items[index] { icons[tile.kind]?.isPressed = false }
        if tile(at: point(event)) == index { onClick?(index, event.modifierFlags) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let layout, layout.contains(point(event)) else { return nil }
        hover(nil)
        return menuFor?(tile(at: point(event)))
    }

    // MARK: - Dragging a tile

    private func beginTileDrag(_ slot: Int, event: NSEvent) {
        guard case .tile(let tile) = items[slot], let icon = icons[tile.kind] else { return }
        pressed = nil
        icon.isPressed = false
        hover(nil)
        let item = NSPasteboardItem()
        item.setString(String(slot), forType: Self.tileType)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(icon.frame, contents: tile.image)
        dragHandler?.dragBegan(slot: slot)
        let session = beginDraggingSession(with: [dragging], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated {
            guard let window else { return }
            // Taken by the dock, it is not off it — the drop may already have resized the platter. Not taken,
            // where it ended decides: a drag Esc cancelled over the dock reports no operation either.
            let local = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            dragHandler?.tileDragEnded(offTheDock: operation == [] && dropZone?.contains(local) != true)
        }
    }

    // MARK: - Drops

    /// Where a drag is over the dock: the platter and the puck, and a little above and below them.
    private var dropZone: CGRect? { layout?.extent.insetBy(dx: 0, dy: -12) }

    private func isTileDrag(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.types?.contains(Self.tileType) == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let at = convert(sender.draggingLocation, from: nil)
        let over = dropZone?.contains(at) ?? false
        return dragHandler?.dragMoved(to: over ? at : nil, pasteboard: sender.draggingPasteboard, isTile: isTileDrag(sender)) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let sender else { return }
        _ = dragHandler?.dragMoved(to: nil, pasteboard: sender.draggingPasteboard, isTile: isTileDrag(sender))
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let at = convert(sender.draggingLocation, from: nil)
        return dragHandler?.dropped(at: at, pasteboard: sender.draggingPasteboard, isTile: isTileDrag(sender)) ?? false
    }
}
