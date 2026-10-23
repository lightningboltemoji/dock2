import AppKit
import Dock2Core

/// A minimised window's tile, laid out as the system Dock lays out its picture of the window: the window's
/// shape fitted to the tile, its app's icon in the corner. The shape is a blank window — its title bar, its
/// buttons — in the given appearance; a `size` of zero is a square one, and a nil `appIcon` leaves the corner bare.
enum WindowTileImage {
    static func image(size: CGSize, appIcon: NSImage?, dark: Bool) -> NSImage {
        NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                draw(size: size, appIcon: appIcon, dark: dark, in: rect)
            }
            return true
        }
    }

    private static func draw(size: CGSize, appIcon: NSImage?, dark: Bool, in rect: CGRect) {
        let metrics = DockMetrics(tileSize: rect.width)
        let frame = metrics.windowFrame(aspect: size.height > 0 ? size.width / size.height : 1, icon: rect)
        // The window's own proportions, at the scale it is drawn: a 28pt title bar, 12pt buttons, corners
        // of 16pt — none smaller than can be seen.
        let scale = size.width > 0 ? frame.width / size.width : frame.width / 800
        let radius = max(16 * scale, 1)
        let window = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSColor.windowBackgroundColor.setFill()
        window.fill()

        let titleBar = max(28 * scale, 3)
        NSGraphicsContext.saveGraphicsState()
        window.addClip()
        NSColor.separatorColor.setFill()
        CGRect(x: frame.minX, y: frame.maxY - titleBar, width: frame.width, height: max(scale, 0.5)).fill()
        let button = max(12 * scale, 1.5)
        for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.setFill()
            let x = frame.minX + max(9 * scale, 1) + CGFloat(index) * button * 5 / 3
            NSBezierPath(ovalIn: CGRect(x: x, y: frame.maxY - titleBar / 2 - button / 2, width: button, height: button)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // The window's hairline: black on a light window, white on a dark one.
        NSColor(white: dark ? 1 : 0, alpha: 0.2).setStroke()
        window.lineWidth = 0.5
        window.stroke()
        appIcon?.draw(in: metrics.windowAppIconFrame(icon: rect))
    }
}
