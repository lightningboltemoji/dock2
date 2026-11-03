import AppKit
import Dock2Core

/// What a screen's content sits on, inside the panel's glass: the system's content material — Finder's,
/// opaque and faintly tinted by the wallpaper — with corners concentric with the panel's. Increase Contrast
/// draws the system's border around it, as around the glass.
@MainActor
final class PanelSheet: NSView {
    private let material = NSVisualEffectView()
    private let border = CALayer()
    private var displayOptions: NSObjectProtocol?
    private(set) weak var held: NSView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.cornerRadius = PanelMetrics.sheetRadius
        layer!.cornerCurve = .continuous
        layer!.masksToBounds = true
        material.material = .contentBackground
        material.blendingMode = .behindWindow
        material.state = .active
        material.autoresizingMask = [.width, .height]
        material.frame = bounds
        addSubview(material)
        border.cornerRadius = PanelMetrics.sheetRadius
        border.cornerCurve = .continuous
        border.zPosition = 1
        layer!.addSublayer(border)
        displayOptions = DisplayOptions.observe { [weak self] in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            border.borderColor = NSColor.secondaryLabelColor.cgColor
        }
        border.borderWidth = DisplayOptions.increaseContrast ? 1 : 0
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        border.frame = bounds
        CATransaction.commit()
        held?.frame = bounds
    }

    /// Holds `view` in place of what it held, filling it.
    func hold(_ view: NSView) {
        if held !== view { held?.removeFromSuperview() }
        held = view
        view.frame = bounds
        addSubview(view)
    }

    func release() {
        held?.removeFromSuperview()
        held = nil
    }

    /// Fades it in where it stands, over the glass already there.
    func fadeIn() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.duration = GrowthMotion.contentFadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer!.add(fade, forKey: "appear")
    }
}
