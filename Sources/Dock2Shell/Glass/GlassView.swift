import AppKit

/// A view filled with glass in `shapes`: the tuned `GlassLayer` where its private API exists, AppKit's
/// stock glass in the first shape's rounded rect where it does not.
@MainActor
final class GlassView: NSView {
    var shapes: [GlassLayer.Shape] = [] {
        didSet { update() }
    }

    var recipe: GlassRecipe {
        didSet { glass?.recipe = recipe }
    }

    private var glass: GlassLayer?
    private var fallback: NSGlassEffectView?

    init(recipe: GlassRecipe) {
        self.recipe = recipe
        super.init(frame: .zero)
        wantsLayer = true
        if GlassLayer.isAvailable {
            let glass = GlassLayer(recipe: recipe)
            layer!.addSublayer(glass)
            self.glass = glass
        } else {
            let fallback = NSGlassEffectView()
            addSubview(fallback)
            self.fallback = fallback
            warn("this macOS lacks the glass dock2 tunes; using the system's standard glass")
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        update()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let glass {
            glass.frame = bounds
            glass.shapes = shapes
        } else if let fallback, let first = shapes.first {
            fallback.frame = first.frame
            fallback.cornerRadius = first.cornerRadius
        }
    }
}
