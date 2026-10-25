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
        /// About the frame's centre, anticlockwise: set, never played (`play`).
        var rotation: CGFloat = 0

        /// Grown all round, as a rim's field draws it.
        func outset(_ outset: CGFloat) -> Shape {
            var shape = self
            shape.frame = frame.insetBy(dx: -outset, dy: -outset)
            shape.cornerRadius += outset
            return shape
        }
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

    /// The filter's input a frost fills.
    static let fillKey = "inputFaceColorMatrixFillColor"
    private var backdrop: CALayer?

    /// The face filled with the recipe's frost, or clear again; the same through a rebuild.
    private(set) var isFrosted = false

    /// Frosts the face or clears it, over `motion` if given, from however frosted it is now. The new value
    /// and its animation go in one transaction: committed apart, a frame would show the value alone.
    func setFrosted(_ frosted: Bool, motion: Motion? = nil) {
        guard frosted != isFrosted else { return }
        isFrosted = frosted
        guard let backdrop else { return }
        let key = "filters.glassBackground." + Self.fillKey
        let from = (backdrop.presentation() ?? backdrop).value(forKeyPath: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.setValue(fill, forKeyPath: key)
        if let motion {
            let animation = CABasicAnimation(keyPath: key)
            animation.fromValue = from
            animation.duration = motion.duration
            animation.timingFunction = motion.timing
            backdrop.add(animation, forKey: "frost")
        }
        CATransaction.commit()
    }

    private var fill: Any? { isFrosted ? recipe.frost ?? recipe.filter[Self.fillKey] : recipe.filter[Self.fillKey] }

    /// How far the glass is its recipe's lens (`GlassRecipe.lens`), from 0, its own inputs, to 1; the same through a
    /// rebuild.
    private(set) var lens = 0.0

    /// Plays how far the glass is its lens through `keyframes`, as the shapes play, and leaves it at the last.
    func playLens(_ keyframes: Keyframes<Double>) {
        lens = keyframes.last
        guard let backdrop else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for input in recipe.lens.keys {
            let key = Self.lensKey(input)
            backdrop.setValue(lensInput(input, at: lens), forKeyPath: key)
            keyframes.play(on: backdrop, key) { lensInput(input, at: $0) }
        }
        CATransaction.commit()
    }

    private static func lensKey(_ input: String) -> String { "filters.glassBackground." + input }

    /// A lens input `amount` of the way from the recipe's own value to the lens's.
    private func lensInput(_ input: String, at amount: Double) -> NSNumber {
        let own = (recipe.filter[input] as? NSNumber)?.doubleValue ?? 0
        let lensed = (recipe.lens[input] as? NSNumber)?.doubleValue ?? own
        return NSNumber(value: own + (lensed - own) * amount)
    }

    /// A resize rebuilds the tree, which ends any shape's motion in flight: the stage never resizes but for a
    /// display change.
    override func layoutSublayers() {
        super.layoutSublayers()
        for layer in sublayers ?? [] where layer.frame != bounds { rebuild(); return }
    }

    /// Reshapes the glass. With the same number of shapes the tree is kept and each shape moves to its
    /// new frame — over `motion`, evaluated by the window server frame by frame, when one is given.
    func setShapes(_ shapes: [Shape], motion: Motion? = nil) {
        // The same shapes again — a layout — leave what is playing alone.
        guard shapes != self.shapes else { return }
        isPlaying = false
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
                element.stopKeyframes(Self.keyPaths)
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

    /// Shapes played through keyframes are on the elements, until `setShapes` or `stopPlaying`.
    private(set) var isPlaying = false
    private static let keyPaths = ["bounds", "position", "cornerRadius"]

    /// Plays the shapes through `keyframes`, each shape's element following its own, and leaves them at the
    /// last. With a different number of shapes the tree is built again first. Played shapes never turn: an angle's
    /// in-between differs between an element's transform and a path's points (`FormShape`).
    func play(_ keyframes: Keyframes<[Shape]>) {
        let last = keyframes.last
        assert(last.allSatisfy { $0.rotation == 0 }, "a played glass shape never turns")
        if last.count != shapes.count || fields.isEmpty {
            shapes = last
            rebuild()
        }
        shapes = last
        isPlaying = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for field in fields {
            for (index, element) in field.elements.enumerated() {
                Self.place(element, last[index], outset: field.outset)
                let track = keyframes.map { $0[index].outset(field.outset) }
                track.play(on: element, "bounds") { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }
                track.play(on: element, "position") { NSValue(point: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                track.play(on: element, "cornerRadius") { NSNumber(value: Double($0.cornerRadius)) }
            }
        }
        CATransaction.commit()
    }

    /// Ends what `play` started, the shapes left at its last.
    func stopPlaying() {
        guard isPlaying else { return }
        isPlaying = false
        for element in fields.flatMap(\.elements) { element.stopKeyframes(Self.keyPaths) }
        backdrop?.stopKeyframes(recipe.lens.keys.map(Self.lensKey))
    }

    // MARK: - The tree

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        isPlaying = false
        sublayers?.forEach { $0.removeFromSuperlayer() }
        fields = []
        backdrop = nil
        guard Self.isAvailable, !shapes.isEmpty else { return }

        let backdrop = Self.make("CABackdropLayer")
        backdrop.frame = bounds
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue(groupName, forKey: "groupName")
        backdrop.setValue(recipe.scale, forKey: "scale")
        backdrop.setValue(true, forKey: "sourceSublayerDefinesBounds")
        let source = sdfLayer(effect: Self.object("CASDFOutputEffect"), outset: 0)
        source.name = "shape"
        backdrop.addSublayer(source)

        let filter = Self.filter("glassBackground")
        filter.setValue("glassBackground", forKey: "name")
        filter.setValue("shape", forKey: "inputSourceSublayerName")
        for (key, value) in recipe.filter { filter.setValue(value, forKey: key) }
        if let fill { filter.setValue(fill, forKey: Self.fillKey) }
        for input in recipe.lens.keys { filter.setValue(lensInput(input, at: lens), forKey: input) }
        backdrop.filters = [filter]
        addSublayer(backdrop)
        self.backdrop = backdrop

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
