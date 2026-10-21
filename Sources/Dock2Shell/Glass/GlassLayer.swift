import AppKit
import QuartzCore

/// Liquid Glass in a shape and recipe of our own, drawn by the window server from what lies behind the
/// window: `NSGlassEffectView`'s layer tree built by hand (IMPLEMENTATION.md §3). Its classes are private
/// and looked up by name; where one is missing, `isAvailable` is false.
final class GlassLayer: CALayer {
    struct Shape: Equatable {
        /// Before rotation, in the glass layer's coordinates.
        var frame: CGRect
        var cornerRadius: CGFloat
        var curve: CALayerCornerCurve = .continuous
        /// About the frame's centre, anticlockwise.
        var rotation: CGFloat = 0
    }

    static let isAvailable: Bool = {
        let classes = ["CABackdropLayer", "CASDFLayer", "CASDFElementLayer", "CASDFOutputEffect",
                       "CASDFKeyFillHighlightEffect", "CAFilter"]
        guard classes.allSatisfy({ NSClassFromString($0) != nil }),
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let types = filterClass.perform(NSSelectorFromString("filterTypes"))?.takeUnretainedValue() as? [String]
        else { return false }
        return types.contains("glassBackground")
    }()

    private(set) var shapes: [Shape] = []

    var recipe: GlassRecipe {
        didSet { rebuild() }
    }

    /// Names the backdrop's group, so no two glasses ever sample each other.
    private let groupName = "dock2.glass.\(UUID().uuidString)"
    /// Every SDF layer in the tree with how far it grows the shapes, and its element per shape.
    private var fields: [(outset: CGFloat, elements: [CALayer])] = []

    init(recipe: GlassRecipe) {
        self.recipe = recipe
        super.init()
    }

    override init(layer: Any) {
        recipe = (layer as? GlassLayer)?.recipe ?? GlassRecipe.platter(dark: false)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A resize rebuilds the tree, which ends any shape's motion in flight: the stage never resizes but for a
    /// display change.
    override func layoutSublayers() {
        super.layoutSublayers()
        for layer in sublayers ?? [] where layer.frame != bounds { rebuild(); return }
    }

    /// Reshapes the glass. With the same number of shapes the tree is kept and each shape moves to its
    /// new frame — over `motion`, evaluated by the window server frame by frame, when one is given.
    func setShapes(_ shapes: [Shape], motion: Motion? = nil) {
        guard shapes != self.shapes else { return }
        guard shapes.count == self.shapes.count, !fields.isEmpty else {
            self.shapes = shapes
            rebuild()
            return
        }
        self.shapes = shapes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for field in fields {
            for (element, shape) in zip(field.elements, shapes) {
                // Explicit, from wherever the shape is now: an implicit animation would not run on an
                // element made in the same transaction, and would jump if one were already in flight.
                let from = element.presentation() ?? element
                let start = (bounds: from.bounds, position: from.position, radius: from.cornerRadius)
                Self.place(element, shape, outset: field.outset)
                guard let motion else { continue }
                for (key, value) in [("bounds", NSValue(rect: start.bounds)), ("position", NSValue(point: start.position)),
                                     ("cornerRadius", NSNumber(value: Double(start.radius)))] {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = value
                    animation.duration = motion.duration
                    animation.timingFunction = motion.timing
                    element.add(animation, forKey: key)
                }
            }
        }
        CATransaction.commit()
    }

    // MARK: - The tree

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        sublayers?.forEach { $0.removeFromSuperlayer() }
        fields = []
        guard Self.isAvailable, !shapes.isEmpty else { return }

        let backdrop = Self.make("CABackdropLayer")
        backdrop.frame = bounds
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(groupName, forKey: "groupName")
        backdrop.setValue(0.5, forKey: "scale")
        backdrop.setValue(true, forKey: "sourceSublayerDefinesBounds")
        let source = sdfLayer(effect: Self.object("CASDFOutputEffect"), outset: 0)
        source.name = "shape"
        backdrop.addSublayer(source)

        let filter = Self.filter("glassBackground")
        filter.setValue("glassBackground", forKey: "name")
        filter.setValue("shape", forKey: "inputSourceSublayerName")
        for (key, value) in recipe.filter { filter.setValue(value, forKey: key) }
        backdrop.filters = [filter]
        addSublayer(backdrop)

        for rim in recipe.rims {
            let effect = Self.object("CASDFKeyFillHighlightEffect")
            effect.setValue(rim.color, forKey: "keyColor")
            effect.setValue(rim.color, forKey: "fillColor")
            effect.setValue(rim.keyAngle, forKey: "keyAngle")
            effect.setValue(rim.fillAngle, forKey: "fillAngle")
            effect.setValue(rim.height, forKey: "keyHeight")
            effect.setValue(rim.height, forKey: "fillHeight")
            effect.setValue(rim.keyAmount, forKey: "keyAmount")
            effect.setValue(rim.fillAmount, forKey: "fillAmount")
            effect.setValue(rim.spread, forKey: "keySpread")
            effect.setValue(rim.spread, forKey: "fillSpread")
            addSublayer(sdfLayer(effect: effect, outset: rim.outset))
        }
    }

    /// An SDF layer covering the glass, holding every shape grown by `outset`. Its `contentsScale` stays
    /// at 1: the window server draws the field at the display's resolution regardless, and the rims'
    /// heights were fitted at that scale.
    private func sdfLayer(effect: NSObject, outset: CGFloat) -> CALayer {
        let layer = Self.make("CASDFLayer")
        layer.frame = bounds
        layer.setValue(effect, forKey: "effect")
        layer.setValue(recipe.smoothness, forKey: "smoothness")
        layer.setValue(shapes.count > 1, forKey: "mergeElements")
        let elements = shapes.map { shape in
            let element = Self.make("CASDFElementLayer")
            Self.place(element, shape, outset: outset)
            layer.addSublayer(element)
            return element
        }
        fields.append((outset, elements))
        return layer
    }

    private static func place(_ element: CALayer, _ shape: Shape, outset: CGFloat) {
        let frame = shape.frame.insetBy(dx: -outset, dy: -outset)
        element.bounds = CGRect(origin: .zero, size: frame.size)
        element.position = CGPoint(x: frame.midX, y: frame.midY)
        element.cornerRadius = shape.cornerRadius + outset
        element.cornerCurve = shape.curve
        element.setAffineTransform(CGAffineTransform(rotationAngle: shape.rotation))
    }

    private static func make(_ name: String) -> CALayer {
        (NSClassFromString(name) as! CALayer.Type).init()
    }

    private static func object(_ name: String) -> NSObject {
        (NSClassFromString(name) as! NSObject.Type).init()
    }

    private static func filter(_ type: String) -> NSObject {
        let filterClass = NSClassFromString("CAFilter") as! NSObject.Type
        return filterClass.perform(NSSelectorFromString("filterWithType:"), with: type)!.takeUnretainedValue() as! NSObject
    }
}
