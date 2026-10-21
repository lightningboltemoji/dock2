import AppKit
import Dock2Core

/// The name bubble over a tile: its own glass, a capsule merged with a turned square for the arrow, and the
/// name drawn above it. Placed in the stage's coordinates; the mouse passes through it.
@MainActor
final class LabelView: NSView {
    /// Room around the bubble for its rim and the hairline outside it.
    private static let margin: CGFloat = 4
    /// From the capsule's bottom up to the text's baseline.
    private static let baselineLift: CGFloat = 8.0

    private let glass = GlassView(recipe: .label(dark: false))
    private let text = CATextLayer()
    private let font = NSFont.systemFont(ofSize: LabelMetrics.fontSize)

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glass)
        // Above the glass's own view, never inside it: a layer below a backdrop is refracted by it.
        let textHost = NSView()
        textHost.wantsLayer = true
        textHost.layer!.addSublayer(text)
        addSubview(textHost)
        text.alignmentMode = .center
        // A new string is drawn as the run loop's transaction commits, outside `show`'s: its contents would
        // fade from the last name over a quarter second.
        text.actions = ["contents": NSNull()]
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows `name` over a tile centred at `centerX`, on a platter whose top is at `platterTop`: both in the
    /// coordinates of the view this one sits in.
    func show(_ name: String, centerX: CGFloat, platterTop: CGFloat, dark: Bool, scale: CGFloat) {
        let string = NSAttributedString(string: name, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: dark ? 1 : 0, alpha: dark ? 0.95 : 0.85),
        ])
        let body = LabelMetrics.body(textWidth: string.size().width, centerX: centerX, platterTop: platterTop)
        let tipY = body.minY - LabelMetrics.arrowDepth
        // Whole points, so the glass's edges land where the Dock's do.
        let frame = CGRect(x: body.minX - Self.margin, y: tipY - Self.margin,
                           width: body.width + 2 * Self.margin, height: body.maxY - tipY + 2 * Self.margin).integral

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        let bounds = CGRect(origin: .zero, size: frame.size)
        for view in subviews { view.frame = bounds }
        let capsule = body.offsetBy(dx: -frame.minX, dy: -frame.minY)
        // The arrow is a rounded square turned 45°, centred on the capsule's bottom edge, so its lower
        // corner is the tip and the upper half melts into the capsule.
        let half = LabelMetrics.arrowDepth
        let side = half * 2 / 2.0.squareRoot()
        let arrowCenter = CGPoint(x: centerX - frame.minX, y: capsule.minY)
        glass.recipe = .label(dark: dark)
        glass.setShapes([
            GlassLayer.Shape(frame: capsule, cornerRadius: capsule.height / 2, curve: .circular),
            GlassLayer.Shape(frame: CGRect(x: arrowCenter.x - side / 2, y: arrowCenter.y - side / 2, width: side, height: side),
                             cornerRadius: LabelMetrics.arrowTipRadius, rotation: .pi / 4),
        ])
        let ascent = font.ascender, descent = -font.descender
        text.string = string
        text.contentsScale = scale
        text.frame = CGRect(x: capsule.minX, y: capsule.minY + Self.baselineLift - descent,
                            width: capsule.width, height: ascent + descent)
        isHidden = false
        CATransaction.commit()
    }

    func hide() {
        isHidden = true
    }
}
