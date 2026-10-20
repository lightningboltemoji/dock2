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

    var shapes: [Shape] = [] {
        didSet { if shapes != oldValue { rebuild() } }
    }

    var recipe: GlassRecipe {
        didSet { rebuild() }
    }

    /// Names the backdrop's group, so no two glasses ever sample each other.
    private let groupName = "dock2.glass.\(UUID().uuidString)"

    init(recipe: GlassRecipe) {
        self.recipe = recipe
        super.init()
    }

    override init(layer: Any) {
        recipe = (layer as? GlassLayer)?.recipe ?? GlassRecipe.platter(dark: false)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        for layer in sublayers ?? [] where layer.frame != bounds { rebuild(); return }
    }

    // MARK: - The tree

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        sublayers?.forEach { $0.removeFromSuperlayer() }
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
        for shape in shapes {
            let element = Self.make("CASDFElementLayer")
            let frame = shape.frame.insetBy(dx: -outset, dy: -outset)
            element.bounds = CGRect(origin: .zero, size: frame.size)
            element.position = CGPoint(x: frame.midX, y: frame.midY)
            element.cornerRadius = shape.cornerRadius + outset
            element.cornerCurve = shape.curve
            if shape.rotation != 0 { element.setAffineTransform(CGAffineTransform(rotationAngle: shape.rotation)) }
            layer.addSublayer(element)
        }
        return layer
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
