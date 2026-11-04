import AppKit
import Dock2Core

/// Where a screen's content sits: on the panel's pane, the glass laid over its ground, its corners the pane's.
@MainActor
final class PanelSheet: NSView {
    private(set) weak var held: NSView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.cornerRadius = PanelMetrics.sheetRadius
        layer!.cornerCurve = .continuous
        layer!.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
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
