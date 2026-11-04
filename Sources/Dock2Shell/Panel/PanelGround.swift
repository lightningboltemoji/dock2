import AppKit
import Dock2Core

/// What the panel's pane lies on once it grows (`PanelMetrics.layering`): the window's own material, solid and faintly
/// tinted by the wallpaper — shaded in the light appearance, where it is white and the pane could lift it no further —
/// in the body's shape, under a hairline rim, the system's border under Increase Contrast.
@MainActor
final class PanelGround: NSView {
    private let material = PanelGround.material()
    /// The body's shape, and how solid the ground is: AppKit owns the view's own opacity.
    private let shape = CALayer()
    private let rim = CALayer()
    private let shade = CALayer()
    private var displayOptions: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        material.autoresizingMask = [.width, .height]
        material.frame = bounds
        addSubview(material)
        for layer in [shape, rim] {
            layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            layer.opacity = 0
        }
        shape.backgroundColor = .black
        layer!.mask = shape
        rim.borderWidth = 1
        rim.zPosition = 1
        layer!.addSublayer(rim)
        shade.zPosition = 0.5
        layer!.addSublayer(shade)
        displayOptions = DisplayOptions.observe { [weak self] in self?.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = bounds
        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.isDark
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let rim = DisplayOptions.increaseContrast ? NSColor.secondaryLabelColor
                : dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.05)
            self.rim.borderColor = rim.cgColor
        }
        shade.backgroundColor = Self.shade(dark: dark)
    }

    /// The ground's material: the window's own, behind the window. Anything showing the ground draws it so.
    static func material() -> NSVisualEffectView {
        let material = NSVisualEffectView()
        material.material = .windowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        return material
    }

    /// Over the material, in the light appearance: there it is white, and the glass could lift it no further.
    static func shade(dark: Bool) -> CGColor? {
        dark ? nil : NSColor(white: 0, alpha: 0.075).cgColor
    }

    /// In the body's shapes through `track`, as solid as `solidity` says.
    func play(_ track: Keyframes<GlassLayer.Shape>, solidity: Keyframes<Double>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shape, rim] {
            Self.place(layer, track.last)
            layer.opacity = Float(solidity.last)
            track.play(on: layer, "bounds") { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }
            track.play(on: layer, "position") { NSValue(point: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            track.play(on: layer, "cornerRadius") { NSNumber(value: Double(min($0.cornerRadius, $0.frame.height / 2))) }
            solidity.play(on: layer, "opacity") { NSNumber(value: $0) }
        }
        CATransaction.commit()
    }

    /// Solid, in `shape`, at once.
    func set(_ shape: GlassLayer.Shape) {
        play(Keyframes(values: [shape], step: 1, begin: CACurrentMediaTime()), solidity: Keyframes(values: [1], step: 1, begin: CACurrentMediaTime()))
    }

    /// Gone, until it plays again.
    func clear() {
        stopPlaying()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [shape, rim] { layer.opacity = 0 }
        CATransaction.commit()
    }

    func stopPlaying() {
        for layer in [shape, rim] { layer.stopKeyframes(["bounds", "position", "cornerRadius", "opacity"]) }
    }

    private static func place(_ layer: CALayer, _ shape: GlassLayer.Shape) {
        layer.bounds = CGRect(origin: .zero, size: shape.frame.size)
        layer.position = CGPoint(x: shape.frame.midX, y: shape.frame.midY)
        layer.cornerRadius = min(shape.cornerRadius, shape.frame.height / 2)
        layer.cornerCurve = shape.curve
    }
}
