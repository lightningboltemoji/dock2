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

/// The dock's content over the platter's glass: icons, dots and separators where `DockLayout` puts them,
/// in the stage's coordinates. It reports the pointer — hover, clicks, menus, drags — and decides nothing.
/// It draws nothing itself: its layers live in the glass's overlay.
@MainActor
final class DockView: NSView, NSDraggingSource {
    struct Tile: Equatable {
        var kind: TileKind
        var image: NSImage
        var running: Bool
        var dimmed: Bool = false
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
    private var elements: [DockItemElement] = []
    weak var dragHandler: DockDragHandler?

    private(set) var items: [Item] = []
    private(set) var layout: DockLayout?
    /// Holds everything the dock draws, so that auto-hide can slide it as one.
    private let content = CALayer()
    private var icons: [TileKind: TileLayer] = [:]
    private var dots: [TileKind: CALayer] = [:]
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
        overlay.addSublayer(content)
        registerForDraggedTypes([.fileURL, Self.tileType])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Showing

    /// Lays `items` out per `layout`, which must have been computed for exactly their kinds, in this view's
    /// coordinates. With `motion`, tiles slide to their new places, new ones grow in and old ones shrink away.
    func show(_ items: [Item], layout: DockLayout, scale: CGFloat, motion: Motion?) {
        precondition(items.map(\.kind) == layout.slots.map(\.kind), "the layout is not of these items")
        // A press outlives a relayout on the tile it began on, or ends with that tile.
        if let press = pressed {
            let kind = self.items.indices.contains(press.slot) ? self.items[press.slot].tileKind : nil
            pressed = kind.flatMap { kind in items.firstIndex { $0.tileKind == kind } }.map { ($0, press.at) }
        }
        self.items = items
        self.layout = layout
        // An app opened from its stand-in carries on as its running tile, in place, rather than one tile
        // going and another coming.
        for case .tile(let tile) in items {
            guard case .app(let app) = tile.kind, icons[tile.kind] == nil, let standIn = icons.removeValue(forKey: .temporary(app)) else { continue }
            icons[tile.kind] = standIn
            if let dot = dots.removeValue(forKey: .temporary(app)) { dots[tile.kind] = dot }
        }
        self.scale = scale
        makeElements()
        let dark = isDark

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Not `frame`: auto-hide may have a transform on it.
        content.bounds = bounds
        content.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()

        var liveTiles: Set<TileKind> = []
        var liveLines: Set<DockGroup> = []
        Motion.perform(motion) {
            for (item, slot) in zip(items, layout.slots) {
                switch item {
                case .tile(let tile):
                    liveTiles.insert(tile.kind)
                    place(tile, in: slot, dark: dark, motion: motion)
                case .separator(let group):
                    liveLines.insert(group)
                    let line = lines[group] ?? makeLayer(appearing: motion) { lines[group] = $0 }
                    Self.place(line, pixelAligned(slot.content, scale: scale))
                    styleLine(line, dark: dark)
                case .gap:
                    break
                }
            }
        }
        for (kind, icon) in icons where !liveTiles.contains(kind) {
            icons[kind] = nil
            disappear(icon, motion: motion)
            if let dot = dots.removeValue(forKey: kind) { disappear(dot, motion: motion) }
        }
        for (group, line) in lines where !liveLines.contains(group) {
            lines[group] = nil
            disappear(line, motion: motion)
        }
    }

    private func place(_ tile: Tile, in slot: DockLayout.Slot, dark: Bool, motion: Motion?) {
        let icon = icons[tile.kind] ?? {
            let icon = TileLayer()
            icons[tile.kind] = icon
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            content.addSublayer(icon)
            Self.place(icon, slot.content)
            icon.contentsScale = scale
            CATransaction.commit()
            if let motion { Self.appear(icon, motion: motion, grow: true) }
            return icon
        }()
        Self.place(icon, slot.content)
        icon.transform = CATransform3DIdentity
        if icon.image !== tile.image || icon.contentsScale != scale {
            icon.contentsScale = scale
            icon.image = tile.image
        }
        icon.isDimmed = tile.dimmed

        let dot = dots[tile.kind] ?? makeLayer(appearing: motion) { dots[tile.kind] = $0 }
        Self.place(dot, pixelAligned(slot.dot, scale: scale))
        dot.cornerRadius = slot.dot.width / 2
        dot.opacity = tile.running ? 1 : 0
        styleDot(dot, dark: dark)
    }

    /// Moves a layer by its bounds and position, never its frame: a tile growing in or shrinking away has a
    /// scale on it, and a frame set through a scale is a different size.
    private static func place(_ layer: CALayer, _ rect: CGRect) {
        layer.bounds = CGRect(origin: .zero, size: rect.size)
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
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

    /// Fades a layer in, growing it from nothing when `grow`. Explicit animations: implicit ones do not run
    /// on a layer added in the same transaction.
    private static func appear(_ layer: CALayer, motion: Motion, grow: Bool) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        var animations: [CAAnimation] = [fade]
        if grow {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.01
            scale.toValue = 1
            animations.append(scale)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = motion.duration
        group.timingFunction = motion.timing
        group.fillMode = .backwards
        layer.add(group, forKey: "appear")
    }

    private func disappear(_ layer: CALayer, motion: Motion?) {
        guard let motion else {
            layer.removeFromSuperlayer()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(motion.duration)
        CATransaction.setAnimationTimingFunction(motion.timing)
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        layer.opacity = 0
        if layer is TileLayer { layer.transform = CATransform3DMakeScale(0.01, 0.01, 1) }
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

    var hoveredSlot: Int? { hovered }

    // MARK: - Accessibility

    /// The tiles as dock items, the system Dock's way: VoiceOver lists them, presses them, opens their menus.
    private func makeElements() {
        guard let layout else { return }
        elements = zip(items, layout.slots).enumerated().compactMap { index, pair in
            guard case .tile(let tile) = pair.0 else { return nil }
            // In the list's space, which is the platter's.
            let frame = pair.1.frame.offsetBy(dx: -layout.platter.minX, dy: -layout.platter.minY)
            return DockItemElement(slot: index, kind: tile.kind, name: nameFor?(tile.kind) ?? "", running: tile.running,
                                   frame: frame, parent: self,
                                   press: { [weak self] slot in self?.onClick?(slot, []) },
                                   showMenu: { [weak self] slot in self?.popUpMenu(slot) })
        }
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
    override func accessibilityChildren() -> [Any]? { elements }
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

    /// From `popOpacity` of whatever opacity the layer has to all of it: a dimmed tile to its dimness, the dot
    /// of an app not running to none.
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

    // MARK: - Appearance

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = isDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for dot in dots.values { styleDot(dot, dark: dark) }
        for line in lines.values { styleLine(line, dark: dark) }
        CATransaction.commit()
    }

    /// Black in the light appearance; in the dark one the Dock adds 124 of 255 to whatever is behind,
    /// which a plus-lighter blend of grey 105 does.
    private func styleDot(_ dot: CALayer, dark: Bool) {
        dot.backgroundColor = CGColor(gray: dark ? 105 / 255 : 0, alpha: 1)
        dot.compositingFilter = dark ? "plusL" : nil
    }

    /// The separator takes 57 of 255 from whatever is behind it in the light appearance, a plus-darker blend
    /// of grey 188, and adds 65 in the dark, a plus-lighter grey 50 — each once colour management has had its say.
    private func styleLine(_ line: CALayer, dark: Bool) {
        line.backgroundColor = CGColor(gray: (dark ? 50 : 188) / 255, alpha: 1)
        line.compositingFilter = dark ? "plusL" : "plusD"
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
            if layout?.platter.contains(at) == true { onPlatterClick?() }
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
        guard let layout, layout.platter.contains(point(event)) else { return nil }
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

    /// Where a drag is over the dock: the platter, and a little above and below it.
    private var dropZone: CGRect? { layout?.platter.insetBy(dx: 0, dy: -12) }

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
