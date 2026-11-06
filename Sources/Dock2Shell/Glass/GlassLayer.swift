import AppKit
import QuartzCore

/// Liquid Glass in a shape and recipe of our own, drawn by the window server from what lies behind the
/// window: `NSGlassEffectView`'s layer tree built by hand (IMPLEMENTATION.md §3). What it uses is private
/// (`PrivateType`): where a type is missing, `isAvailable` is false; a key that is missing goes unwritten.
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

    static let isAvailable = [PrivateType.backdropLayer, .sdfLayer, .sdfElementLayer, .sdfOutputEffect, .sdfShadowEffect,
                              .sdfHighlightEffect, .glassBackground, .vibrantColorMatrix].allSatisfy(\.exists)

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

    private var backdrop: CALayer?

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

    private static func lensKey(_ input: GlassInput) -> String { "filters.\(GlassInput.owner.rawValue).\(input.rawValue)" }

    /// A lens input `amount` of the way from the recipe's own value to the lens's.
    private func lensInput(_ input: GlassInput, at amount: Double) -> NSNumber {
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
                // A shape on springs keeps all of itself on one, so its edges move together.
                let size = element.bounds.size
                let growing = size.width >= start.bounds.width && size.height >= start.bounds.height
                for (key, value) in [("bounds", NSValue(rect: start.bounds)), ("position", NSValue(point: start.position)),
                                     ("cornerRadius", NSNumber(value: Double(start.radius)))] {
                    element.add(motion.animation(key, from: value, growing: growing), forKey: key)
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
        if let cast = recipe.cast {
            let effect = Private<ShadowKey>()
            effect.set(.color, cast.color)
            effect.set(.radius, cast.radius)
            effect.set(.invert, cast.inward)
            effect.set(.punchout, true)
            effect.set(.offset, NSValue(size: CGSize(width: 0, height: -cast.drop)))
            // An inward shadow starts a point in from its shape.
            addSublayer(sdfLayer(effect: effect.object, outset: cast.inward ? 1 : 0))
        }
        if recipe.hasFace { buildFace() }
        for rim in recipe.rims {
            let effect = Private<HighlightKey>()
            effect.set(.keyColor, rim.color)
            effect.set(.fillColor, rim.color)
            effect.set(.keyAngle, rim.keyAngle)
            effect.set(.fillAngle, rim.fillAngle)
            effect.set(.keyHeight, rim.height)
            effect.set(.fillHeight, rim.height)
            effect.set(.keyAmount, rim.keyAmount)
            effect.set(.fillAmount, rim.fillAmount)
            effect.set(.keySpread, rim.spread)
            effect.set(.fillSpread, rim.spread)
            effect.set(.curvature, rim.curvature)
            if let halo = rim.halo {
                effect.set(.diffuseHeightScale, halo.height)
                effect.set(.diffuseAmountScale, halo.amount)
                effect.set(.diffuseSpreadScale, halo.spread)
            }
            let layer = sdfLayer(effect: effect.object, outset: rim.outset)
            if rim.isVibrant { layer.filters = [Self.vibrancy()] }
            addSublayer(layer)
        }
    }

    /// What a vibrant rim is drawn through: the system's own matrix for a highlight on glass, read off AppKit's tree.
    private static func vibrancy() -> NSObject {
        let filter = Private<VibrancyInput>()
        var matrix: [Float] = [1.1202, -0.1894, -0.0190, 0, 0.1471,
                               -0.0563, 0.9871, -0.0191, 0, 0.1471,
                               -0.0563, -0.1893, 1.1574, 0, 0.1471,
                               0, 0, 0, 1, 0]
        let value = matrix.withUnsafeMutableBytes { NSValue(bytes: $0.baseAddress!, objCType: "{CAColorMatrix=ffffffffffffffffffff}") }
        filter.set(.inputColorMatrix, value)
        filter.set(.inputClamp, 1.2)
        return filter.object
    }

    /// The face: the backdrop, running the recipe's filter over what lies behind, within the shapes.
    private func buildFace() {
        let backdrop = Private<BackdropKey>()
        backdrop.object.frame = bounds
        backdrop.set(.windowServerAware, true)
        backdrop.set(.groupName, groupName)
        backdrop.set(.scale, recipe.scale)
        backdrop.set(.marginWidth, recipe.margin)
        backdrop.set(.sourceSublayerDefinesBounds, true)
        let source = sdfLayer(effect: PrivateType.sdfOutputEffect.make(), outset: 0)
        source.name = "shape"
        backdrop.object.addSublayer(source)

        let filter = Private<GlassInput>()
        filter.set(.inputSourceSublayerName, "shape")
        for (key, value) in recipe.filter { filter.set(key, value) }
        for input in recipe.lens.keys { filter.set(input, lensInput(input, at: lens)) }
        backdrop.object.filters = [filter.object]
        addSublayer(backdrop.object)
        self.backdrop = backdrop.object
    }

    /// An SDF layer covering the glass, holding every shape grown by `outset`. Its `contentsScale` stays
    /// at 1: the window server draws the field at the display's resolution regardless, and the rims'
    /// heights were fitted at that scale.
    private func sdfLayer(effect: NSObject, outset: CGFloat) -> CALayer {
        let layer = Private<SDFLayerKey>()
        layer.object.frame = bounds
        layer.set(.effect, effect)
        layer.set(.smoothness, recipe.smoothness)
        layer.set(.mergeElements, shapes.count > 1)
        let elements = shapes.map { shape in
            let element = PrivateType.sdfElementLayer.make() as! CALayer
            Self.place(element, shape, outset: outset)
            layer.object.addSublayer(element)
            return element
        }
        fields.append((outset, elements))
        return layer.object
    }

    private static func place(_ element: CALayer, _ shape: Shape, outset: CGFloat) {
        let frame = shape.frame.insetBy(dx: -outset, dy: -outset)
        element.bounds = CGRect(origin: .zero, size: frame.size)
        element.position = CGPoint(x: frame.midX, y: frame.midY)
        element.cornerRadius = shape.cornerRadius + outset
        element.cornerCurve = shape.curve
        element.setAffineTransform(CGAffineTransform(rotationAngle: shape.rotation))
    }
}
