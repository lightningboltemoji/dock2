import AppKit

/// The stage window and its root view, covering the screen: transparent pixels pass clicks, moves and
/// scrolls to what is below, so its size costs nothing, and a size that never changes never interrupts the
/// glass's motion. It holds the glass the platter is a shape of.
@MainActor
final class Stage {
    /// The shapes of the shared glass, in the order they are drawn.
    enum Shape: Int, CaseIterable { case platter, panel }

    let window = StageWindow()
    /// The root view, in the stage's coordinates: the screen's, less its origin.
    let view = StageView()
    let glass = GlassView(recipe: .platter(dark: false))
    private(set) var screen: NSScreen
    private var shapes: [Shape: GlassLayer.Shape] = [:]

    init(screen: NSScreen) {
        self.screen = screen
        window.contentView = view
        view.addSubview(glass)
        view.onAppearanceChange = { [weak self] dark in self?.glass.recipe = .platter(dark: dark) }
        glass.recipe = .platter(dark: view.isDark)
    }

    /// The display's backing scale, for anything rasterised.
    var scale: CGFloat { screen.backingScaleFactor }

    /// The stage's bounds: what a layout is computed in.
    var bounds: CGRect { CGRect(origin: .zero, size: screen.frame.size) }

    /// A point in screen coordinates, in the stage's.
    func local(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - screen.frame.minX, y: point.y - screen.frame.minY)
    }

    func move(to screen: NSScreen) {
        self.screen = screen
        place()
    }

    /// Sets one shape of the shared glass, over `motion` if given.
    func setGlass(_ shape: Shape, _ value: GlassLayer.Shape?, motion: Motion? = nil) {
        shapes[shape] = value
        glass.setShapes(Shape.allCases.compactMap { shapes[$0] }, motion: motion)
    }

    /// The glass and all it holds faded in or out — over `motion`, or at once: a hidden dock under Reduce
    /// Motion.
    func fadeGlass(visible: Bool, over motion: Motion?) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motion?.duration ?? 0
            context.timingFunction = motion?.timing
            glass.animator().alphaValue = visible ? 1 : 0
        }
    }

    func show() {
        place()
        window.orderFrontRegardless()
    }

    private func place() {
        window.place(on: screen)
        glass.frame = view.bounds
    }
}

/// The stage's content view, in Cocoa's coordinates: origin at the bottom left.
@MainActor
final class StageView: NSView {
    var onAppearanceChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?(isDark)
    }
}
