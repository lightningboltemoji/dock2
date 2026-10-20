import AppKit
import Dock2Core

/// The Dock's content: the glass platter, the icons and the running dots. It reports hover and opens
/// apps; the controller owns everything else.
@MainActor
final class DockView: NSView {
    /// The tile under the pointer changed; nil when the pointer left the platter.
    var onHover: ((Int?) -> Void)?
    /// A tile was clicked: pressed and released over the same tile.
    var onOpen: ((Int) -> Void)?
    var onQuit: (() -> Void)?

    private let glass = GlassView(recipe: .platter(dark: false))
    /// Holds the icons and dots, above the glass: a layer the backdrop sits under is a layer it refracts.
    private let content = NSView()
    private var tiles: [TileLayer] = []
    private var dots: [CALayer] = []
    private var layout: DockLayout?
    /// The platter's origin in this view.
    private var platterOrigin: CGPoint = .zero
    private var hovered: Int?
    private var pressed: Int?
    private var tracking: NSTrackingArea?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        content.wantsLayer = true
        addSubview(glass)
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Lays out `icons` per `layout`, whose platter sits at `platterOrigin` in this view, for a display
    /// of backing `scale`.
    func show(_ layout: DockLayout, icons: [NSImage], platterOrigin: CGPoint, scale: CGFloat) {
        self.layout = layout
        self.platterOrigin = platterOrigin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let platter = CGRect(origin: platterOrigin, size: layout.platter.size)
        content.frame = bounds
        glass.frame = platter
        glass.shapes = [GlassLayer.Shape(frame: CGRect(origin: .zero, size: platter.size),
                                         cornerRadius: layout.metrics.cornerRadius)]

        while tiles.count < icons.count {
            let tile = TileLayer()
            content.layer!.addSublayer(tile)
            tiles.append(tile)
            let dot = CALayer()
            content.layer!.addSublayer(dot)
            dots.append(dot)
        }
        while tiles.count > icons.count {
            tiles.removeLast().removeFromSuperlayer()
            dots.removeLast().removeFromSuperlayer()
        }
        let offset = CGPoint(x: platterOrigin.x - layout.platter.minX, y: platterOrigin.y - layout.platter.minY)
        for (index, tile) in tiles.enumerated() {
            let spot = layout.tiles[index]
            tile.frame = spot.icon.offsetBy(dx: offset.x, dy: offset.y)
            tile.contentsScale = scale
            tile.image = icons[index]
            // Snapped in screen space, where the Dock snaps it, then moved into the view.
            let dot = pixelAligned(spot.dot, scale: scale).offsetBy(dx: offset.x, dy: offset.y)
            dots[index].frame = dot
            dots[index].cornerRadius = dot.width / 2
        }
        updateAppearance()
        updateTracking()
    }

    func setRunning(_ running: Bool, at index: Int) {
        guard dots.indices.contains(index) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dots[index].isHidden = !running
        CATransaction.commit()
    }

    func setBouncing(_ bouncing: Bool, at index: Int) {
        guard tiles.indices.contains(index) else { return }
        bouncing ? tiles[index].startBouncing() : tiles[index].stopBouncing()
    }

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let dark = isDark
        glass.recipe = .platter(dark: dark)
        // Measured black in the light appearance; white in the dark one is the Dock's convention.
        for dot in dots { dot.backgroundColor = CGColor(gray: dark ? 1 : 0, alpha: 1) }
    }

    // MARK: - The pointer

    private func updateTracking() {
        if let tracking { removeTrackingArea(tracking) }
        guard let layout else { return }
        let area = NSTrackingArea(rect: CGRect(origin: platterOrigin, size: layout.platter.size),
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// The tile under a point in this view.
    private func tile(at point: CGPoint) -> Int? {
        guard let layout else { return nil }
        let screenPoint = CGPoint(x: point.x - platterOrigin.x + layout.platter.minX,
                                  y: point.y - platterOrigin.y + layout.platter.minY)
        return layout.tileIndex(at: screenPoint)
    }

    private func hover(_ index: Int?) {
        guard index != hovered else { return }
        hovered = index
        onHover?(index)
    }

    override func mouseEntered(with event: NSEvent) { hover(tile(at: convert(event.locationInWindow, from: nil))) }
    override func mouseMoved(with event: NSEvent) { hover(tile(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { hover(nil) }

    override func mouseDown(with event: NSEvent) {
        pressed = tile(at: convert(event.locationInWindow, from: nil))
        if let pressed { tiles[pressed].isPressed = true }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        tiles[pressed].isPressed = tile(at: convert(event.locationInWindow, from: nil)) == pressed
    }

    override func mouseUp(with event: NSEvent) {
        guard let index = pressed else { return }
        pressed = nil
        tiles[index].isPressed = false
        if tile(at: convert(event.locationInWindow, from: nil)) == index { onOpen?(index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit dock2", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func quit() { onQuit?() }
}
