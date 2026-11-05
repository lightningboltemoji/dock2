import AppKit

/// A selection let down through the pane's glass to the ground beneath it: the ground's own material, in corners of
/// its own, edged as the pane's edge is from the other side (`GlassRecipe.inset`). Where it marks the keys among
/// lists, it goes a little past the ground.
@MainActor
final class GroundInset: NSView {
    var cornerRadius: CGFloat = 12 {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    /// The list it is in has the keys, among others that might.
    var isFocused = false {
        didSet { if isFocused != oldValue { needsDisplay = true } }
    }

    /// The ground and its edge, clipped to the corners.
    private let well = NSView()
    private let material = PanelGround.material()
    /// The ground's own shade, and how far past the ground it goes.
    private let shade = CALayer()
    private let past = CALayer()
    private let edge = GlassLayer(recipe: .inset(dark: true))
    /// The appearance the edge was built for: a new recipe builds it again, so only on a change.
    private var builtDark = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        well.wantsLayer = true
        well.layer!.masksToBounds = true
        well.layer!.cornerCurve = .continuous
        material.autoresizingMask = [.width, .height]
        well.addSubview(material)
        for (index, layer) in [shade, past, edge].enumerated() {
            layer.zPosition = CGFloat(index + 1)
            well.layer!.addSublayer(layer)
        }
        addSubview(well)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        shade.backgroundColor = PanelGround.shade(dark: dark)
        // Past the ground, toward black: further in light, where the ground starts lighter.
        past.backgroundColor = isFocused ? NSColor(white: 0, alpha: dark ? 0.24 : 0.11).cgColor : nil
        if dark != builtDark {
            builtDark = dark
            edge.recipe = .inset(dark: dark)
        }
    }

    /// Plays how solid it is through `keyframes`, as the ground it is let down to comes and goes, and leaves it at
    /// the last. The well's opacity is AppKit's, so it is set as the view's alpha and only animated on its layer.
    func playSolidity(_ keyframes: Keyframes<Double>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        well.alphaValue = keyframes.last
        keyframes.play(on: well.layer!, "opacity") { NSNumber(value: $0) }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        well.frame = bounds
        well.layer!.cornerRadius = cornerRadius
        material.frame = well.bounds
        shade.frame = well.bounds
        past.frame = well.bounds
        edge.frame = well.bounds
        edge.setShapes([GlassLayer.Shape(frame: well.bounds, cornerRadius: cornerRadius)])
        CATransaction.commit()
    }
}
