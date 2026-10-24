import AppKit
import QuartzCore

/// The screen above a line, mirrored below it live: a backdrop over both, its capture shifted by a ramp
/// (`displacementMap`) so each row below shows the row as far above. Private Core Animation, as the glass is
/// (IMPLEMENTATION.md §3). It captures what is beneath it in the window too, so it goes under dock2's own.
@MainActor
final class ScreenMirror {
    static let isAvailable: Bool = {
        guard NSClassFromString("CABackdropLayer") != nil, let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let types = filterClass.perform(NSSelectorFromString("filterTypes"))?.takeUnretainedValue() as? [String]
        else { return false }
        return types.contains("displacementMap")
    }()

    /// Where it is placed, masked and blended.
    let layer = CALayer()
    private let backdrop: CALayer
    private let displacement: NSObject
    private var map: (height: Int, strip: Int, space: CGColorSpace)?

    init?() {
        guard Self.isAvailable else { return nil }
        backdrop = (NSClassFromString("CABackdropLayer") as! CALayer.Type).init()
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.setValue("dock2.mirror.\(UUID().uuidString)", forKey: "groupName")
        backdrop.setValue(1.0, forKey: "scale")
        let filterClass = NSClassFromString("CAFilter") as! NSObject.Type
        displacement = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "displacementMap")!
            .takeUnretainedValue() as! NSObject
        layer.addSublayer(backdrop)
    }

    /// Mirrors the screen about `line` into `strip`, which lies below it, in the layer's superlayer: the layer
    /// covers the strip and up to the line's reflection of the strip's foot. `space` is the window's colour space.
    func mirror(into strip: CGRect, about line: CGFloat, space: CGColorSpace) {
        let height = 2 * (line - strip.minY)
        layer.frame = CGRect(x: strip.minX, y: strip.minY, width: strip.width, height: height)
        backdrop.frame = layer.bounds
        let rows = Int(height.rounded()), stripRows = Int(strip.height.rounded())
        guard rows > 1, map?.height != rows || map?.strip != stripRows || map?.space != space else { return }
        map = (rows, stripRows, space)
        displacement.setValue(Self.map(height: rows, strip: stripRows, space: space), forKey: "inputMaskImage")
        displacement.setValue(Double(rows), forKey: "inputAmount")
        backdrop.filters = [displacement]
    }

    /// The ramp, top row first, four rows a point at 16 bits: green over the amount shifts each row of the strip up
    /// twice its distance below the middle; red, sideways, is 0; blue 1 shows the shifted image alone. In the
    /// window's colour space: converted, green leaks into red and the reflection leans.
    private static func map(height: Int, strip: Int, space: CGColorSpace) -> CGImage {
        let width = 4, rows = 4 * height
        var pixels = [UInt16](repeating: 0, count: width * rows * 4)
        for row in 0..<rows {
            let up = (Double(rows - row) - 0.5) / 4
            let shift = up < Double(strip) ? 1 - 2 * up / Double(height) : 0
            let green = UInt16((min(1, shift) * 65535).rounded())
            for x in 0..<width {
                let i = (row * width + x) * 4
                pixels[i + 1] = green
                pixels[i + 2] = 65535
                pixels[i + 3] = 65535
            }
        }
        let context = CGContext(data: &pixels, width: width, height: rows, bitsPerComponent: 16, bytesPerRow: width * 8, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        return context.makeImage()!
    }
}

/// A layer mirrored about a horizontal line as it is drawn, animations and all: a portal onto it, which the
/// render server draws from the layer itself. A portal draws only what was drawn before it, so it goes above
/// its source; nil where portals are missing.
@MainActor
final class LayerMirror {
    static let isAvailable = NSClassFromString("CAPortalLayer") != nil

    /// Where it is placed, masked and blended.
    let layer = CALayer()
    private let source: CALayer
    private var portal: CALayer?
    private var placed: (frame: CGRect, line: CGFloat)?

    init?(of source: CALayer) {
        guard Self.isAvailable else { return nil }
        self.source = source
    }

    /// Shows the source where it is, `frame` in their shared superlayer, flipped about `line` there. A portal
    /// on screen stops drawing once its frame or transform changes, so a new one takes its place.
    func mirror(_ frame: CGRect, about line: CGFloat) {
        guard placed?.frame != frame || placed?.line != line else { return }
        placed = (frame, line)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        portal?.removeFromSuperlayer()
        let portal = (NSClassFromString("CAPortalLayer") as! CALayer.Type).init()
        portal.setValue(source, forKey: "sourceLayer")
        layer.frame = frame
        portal.frame = layer.bounds
        let shift = 2 * (line - frame.minY - layer.bounds.midY)
        portal.transform = CATransform3DConcat(CATransform3DMakeScale(1, -1, 1), CATransform3DMakeTranslation(0, shift, 0))
        layer.addSublayer(portal)
        self.portal = portal
        CATransaction.commit()
    }
}
