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

    /// The ground, clipped to the corners; the edge's light falls just outside them, so it is not.
    private let well = NSView()
    private let material = PanelGround.material()
    /// The ground's own shade, and how far past the ground it goes.
    private let shade = CALayer()
    private let past = CALayer()
    private let edge = GlassLayer(recipe: .inset(dark: true))
    /// The appearance the edge was built for: a new recipe builds it again, so only on a change.
    private var builtDark = true
    /// Room around the hole for the light just outside its foot.
    private static let margin: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        well.wantsLayer = true
        well.layer!.masksToBounds = true
        well.layer!.cornerCurve = .continuous
        material.autoresizingMask = [.width, .height]
        well.addSubview(material)
        for (index, layer) in [shade, past].enumerated() {
            layer.zPosition = CGFloat(index + 1)
            well.layer!.addSublayer(layer)
        }
        addSubview(well)
        edge.zPosition = 1
        layer!.addSublayer(edge)
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

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        well.frame = bounds
        well.layer!.cornerRadius = cornerRadius
        material.frame = well.bounds
        shade.frame = well.bounds
        past.frame = well.bounds
        edge.frame = bounds.insetBy(dx: -Self.margin, dy: -Self.margin)
        edge.setShapes([GlassLayer.Shape(frame: CGRect(x: Self.margin, y: Self.margin, width: bounds.width, height: bounds.height),
                                         cornerRadius: cornerRadius)])
        CATransaction.commit()
    }
}
