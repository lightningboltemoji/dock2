import AppKit
import Dock2Core

/// A still picture of a dock — its glass, its tiles — laid out as the stage would, centred in the view, over
/// a gradient so the glass has something to be glass over. Not the desktop picture: AppKit reports a
/// fallback image for the system's own wallpapers, not the one showing.
@MainActor
final class DockPreview: NSView {
    private let desktop = CAGradientLayer()
    private let glass = GlassView(recipe: .platter(dark: false))
    private let icons: [NSImage]
    private let metrics: DockMetrics

    init(icons: [NSImage], tileSize: Double) {
        self.icons = icons
        // A preview fits the window: the real size, up to a size that leaves room around it.
        metrics = DockMetrics(tileSize: min(tileSize, 64))
        super.init(frame: .zero)
        wantsLayer = true
        // Below the glass, in the same window: the backdrop refracts it.
        desktop.colors = [CGColor(srgbRed: 0.33, green: 0.30, blue: 0.62, alpha: 1),
                          CGColor(srgbRed: 0.12, green: 0.13, blue: 0.32, alpha: 1),
                          CGColor(srgbRed: 0.42, green: 0.48, blue: 0.70, alpha: 1)]
        desktop.startPoint = CGPoint(x: 0, y: 1)
        desktop.endPoint = CGPoint(x: 1, y: 0)
        desktop.cornerRadius = 12
        desktop.cornerCurve = .continuous
        layer!.addSublayer(desktop)
        addSubview(glass)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        desktop.frame = bounds
        CATransaction.commit()
        glass.frame = bounds
        glass.recipe = .platter(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        var screen = bounds
        screen.origin.y = (bounds.height - metrics.platterHeight) / 2 - metrics.bottomGap
        let layout = DockLayout(metrics: metrics, tileCount: icons.count, screen: screen)
        glass.setShapes([GlassLayer.Shape(frame: layout.platter, cornerRadius: metrics.cornerRadius)])
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.overlay.sublayers?.forEach { $0.removeFromSuperlayer() }
        let scale = window?.backingScaleFactor ?? 2
        for (icon, slot) in zip(icons, layout.slots) {
            let tile = TileLayer()
            tile.frame = slot.content
            tile.contentsScale = scale
            tile.image = icon
            glass.overlay.addSublayer(tile)
        }
        CATransaction.commit()
    }
}
