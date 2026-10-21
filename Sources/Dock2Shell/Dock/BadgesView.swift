import AppKit
import Dock2Core

/// Number badges: 1–9 over the first nine tiles while ⌘ is held — small capsules of the label's glass,
/// centred on each icon's top edge, a digit over each. The mouse passes through.
@MainActor
final class BadgesView: NSView {
    private let glass = GlassView(recipe: .label(dark: false))
    private let digits = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glass)
        let host = NSView()
        host.wantsLayer = true
        host.layer!.addSublayer(digits)
        addSubview(host)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows a badge over each icon, numbered from 1, or hides them all for an empty list.
    func show(over icons: [CGRect], tileSize: Double, dark: Bool, scale: CGFloat) {
        guard !icons.isEmpty else {
            isHidden = true
            return
        }
        let diameter = min(max((tileSize * 0.27).rounded(), 18), 32)
        let font = NSFont.systemFont(ofSize: diameter * 0.6, weight: .semibold)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for view in subviews { view.frame = bounds }
        digits.frame = bounds
        digits.sublayers?.forEach { $0.removeFromSuperlayer() }
        var shapes: [GlassLayer.Shape] = []
        for (index, icon) in icons.enumerated() {
            let badge = CGRect(x: (icon.midX - diameter / 2).rounded(), y: (icon.maxY - diameter / 2).rounded(),
                               width: diameter, height: diameter)
            shapes.append(GlassLayer.Shape(frame: badge, cornerRadius: diameter / 2, curve: .circular))
            let text = CATextLayer()
            text.string = NSAttributedString(string: "\(index + 1)", attributes: [
                .font: font, .foregroundColor: NSColor(white: dark ? 1 : 0, alpha: dark ? 0.95 : 0.85),
            ])
            text.alignmentMode = .center
            text.contentsScale = scale
            let height = font.ascender - font.descender
            text.frame = CGRect(x: badge.minX, y: badge.midY - height / 2 + font.descender / 2, width: badge.width, height: height)
            digits.addSublayer(text)
        }
        glass.recipe = .label(dark: dark)
        glass.setShapes(shapes)
        isHidden = false
        CATransaction.commit()
    }
}
