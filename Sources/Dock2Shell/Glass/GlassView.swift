import AppKit
import Dock2System

/// A view filled with glass in `shapes`: the tuned `GlassLayer` where its private API exists, AppKit's
/// stock glass in the first shape's rounded rect where it does not. Reduce Transparency fills the shapes
/// solid instead, and Increase Contrast draws the system's border around them.
@MainActor
final class GlassView: NSView {
    private(set) var shapes: [GlassLayer.Shape] = []
    private var motion: Motion?

    var recipe: GlassRecipe {
        didSet { glass?.recipe = recipe }
    }

    private var glass: GlassLayer?
    private var fallback: NSGlassEffectView?
    /// The shapes as one path: a solid fill, a border, or both.
    private let plain = CAShapeLayer()
    private var displayOptions: NSObjectProtocol?

    /// Drawn over the glass, in the same layer tree, so a compositing filter on anything inside — the
    /// dots' plus-lighter, the separators' plus-darker — blends with the glass beneath.
    let overlay = CALayer()

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
        plain.fillColor = nil
        plain.lineWidth = 1
        layer!.addSublayer(plain)
        overlay.blendsThrough()
        layer!.addSublayer(overlay)
        displayOptions = DisplayOptions.observe { [weak self] in self?.update() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Glass is never what is clicked: the views over it are.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Frosts it or clears it (`GlassLayer.setFrosted`); a solid fill, or AppKit's glass, stays as it is.
    func setFrosted(_ frosted: Bool, motion: Motion? = nil) {
        glass?.setFrosted(frosted, motion: motion)
    }

    /// Becomes its recipe's lens, or its own glass again (`GlassLayer.setLensed`).
    func setLensed(_ lensed: Bool, motion: Motion? = nil) {
        glass?.setLensed(lensed, motion: motion)
    }

    /// Plays its shapes through `keyframes` (`GlassLayer.play`), a solid fill and a border along with them;
    /// AppKit's glass keeps to the last.
    func play(_ keyframes: Keyframes<[GlassLayer.Shape]>) {
        shapes = keyframes.last
        updatePlain()
        placeFallback()
        if !plain.isHidden { keyframes.map(Self.outline).play(on: plain, "path") { $0 } }
        glass?.play(keyframes)
    }

    func stopPlaying() {
        glass?.stopPlaying()
        plain.stopKeyframes(["path"])
    }

    /// Reshapes the glass, over `motion` if given (`GlassLayer.setShapes`).
    func setShapes(_ shapes: [GlassLayer.Shape], motion: Motion? = nil) {
        self.shapes = shapes
        self.motion = motion
        update()
        self.motion = nil
    }

    override func layout() {
        super.layout()
        update()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = bounds
        plain.frame = bounds
        CATransaction.commit()
        updatePlain()
        let solid = DisplayOptions.reduceTransparency
        glass?.isHidden = solid
        fallback?.isHidden = solid
        if let glass {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glass.frame = bounds
            CATransaction.commit()
            glass.setShapes(shapes, motion: motion)
        } else {
            placeFallback()
        }
    }

    private func placeFallback() {
        guard let fallback, let first = shapes.first else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fallback.frame = first.frame
        fallback.cornerRadius = first.cornerRadius
        CATransaction.commit()
    }

    /// The shapes as one path.
    private static func outline(_ shapes: [GlassLayer.Shape]) -> CGPath {
        shapes.reduce(CGMutablePath()) { union, shape in
            let rotation = CGAffineTransform(translationX: shape.frame.midX, y: shape.frame.midY).rotated(by: shape.rotation)
                .translatedBy(x: -shape.frame.midX, y: -shape.frame.midY)
            let outline = CGPath(roundedRect: shape.frame, cornerWidth: min(shape.cornerRadius, shape.frame.width / 2),
                                 cornerHeight: min(shape.cornerRadius, shape.frame.height / 2), transform: [rotation])
            return union.isEmpty ? outline.mutableCopy()! : union.union(outline).mutableCopy()!
        }
    }

    /// The fill and the border, from the shapes as one path; the path follows a shape's motion.
    private func updatePlain() {
        let solid = DisplayOptions.reduceTransparency, bordered = DisplayOptions.increaseContrast
        var fill: CGColor?, stroke: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = solid ? NSColor.windowBackgroundColor.cgColor : nil
            stroke = bordered ? NSColor.secondaryLabelColor.cgColor : nil
        }
        let path = Self.outline(shapes)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plain.stopKeyframes(["path"])
        plain.isHidden = !(solid || bordered)
        plain.fillColor = fill
        plain.strokeColor = stroke
        if let motion, !plain.isHidden, let from = plain.presentation()?.path ?? plain.path {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = from
            animation.duration = motion.duration
            animation.timingFunction = motion.timing
            plain.add(animation, forKey: "path")
        }
        plain.path = path
        CATransaction.commit()
    }
}

extension CALayer {
    /// Lets a compositing filter on a sublayer blend with what lies beneath this layer, rather than with
    /// this layer's own empty group: Core Animation's private `allowsGroupBlending`, off. Where it is
    /// missing, filters blend with nothing and draw as their plain colour.
    func blendsThrough() {
        guard responds(to: NSSelectorFromString("setAllowsGroupBlending:")) else { return }
        setValue(false, forKey: "allowsGroupBlending")
    }
}
