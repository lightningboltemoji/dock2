import AppKit
import Dock2Core

/// The name bubble over the hovered tile, in a window of its own above the Dock's.
@MainActor
final class LabelPanel: NSPanel {
    /// Room around the bubble for its rim and the hairline outside it.
    private static let margin: CGFloat = 4
    /// From the capsule's bottom up to the text's baseline.
    private static let baselineLift: CGFloat = 8.0

    private let glass: GlassView
    private let text = CATextLayer()
    private let font = NSFont.systemFont(ofSize: LabelMetrics.fontSize)

    init() {
        glass = GlassView(recipe: .label(dark: false))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = glass
        glass.layer!.addSublayer(text)
        text.alignmentMode = .center
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `name` over a tile centred at `centerX`, on a platter whose top is at `platterTop`.
    func show(_ name: String, centerX: CGFloat, platterTop: CGFloat, dark: Bool) {
        let string = NSAttributedString(string: name, attributes: [
            .font: font,
            .foregroundColor: NSColor(white: dark ? 1 : 0, alpha: 0.85),
        ])
        let body = LabelMetrics.body(textWidth: string.size().width, centerX: centerX, platterTop: platterTop)
        let tipY = body.minY - LabelMetrics.arrowDepth
        // Whole points: the window server snaps a window's origin, which would move everything in it.
        let frame = CGRect(x: body.minX - Self.margin, y: tipY - Self.margin,
                           width: body.width + 2 * Self.margin, height: body.maxY - tipY + 2 * Self.margin).integral

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrame(frame, display: false)
        let capsule = body.offsetBy(dx: -frame.minX, dy: -frame.minY)
        // The arrow is a rounded square turned 45°, centred on the capsule's bottom edge, so its lower
        // corner is the tip and the upper half melts into the capsule.
        let half = LabelMetrics.arrowDepth
        let side = half * 2 / 2.0.squareRoot()
        let arrowCenter = CGPoint(x: centerX - frame.minX, y: capsule.minY)
        glass.recipe = .label(dark: dark)
        glass.shapes = [
            GlassLayer.Shape(frame: capsule, cornerRadius: capsule.height / 2, curve: .circular),
            GlassLayer.Shape(frame: CGRect(x: arrowCenter.x - side / 2, y: arrowCenter.y - side / 2, width: side, height: side),
                             cornerRadius: LabelMetrics.arrowTipRadius, rotation: .pi / 4),
        ]
        let ascent = font.ascender, descent = -font.descender
        text.string = string
        text.contentsScale = NSScreen.screens.first { $0.frame.contains(CGPoint(x: centerX, y: platterTop)) }?.backingScaleFactor ?? 2
        text.frame = CGRect(x: capsule.minX, y: capsule.minY + Self.baselineLift - descent,
                            width: capsule.width, height: ascent + descent)
        CATransaction.commit()
        orderFrontRegardless()
    }
}
