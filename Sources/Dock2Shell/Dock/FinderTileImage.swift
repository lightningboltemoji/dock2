import AppKit
import Dock2Core
import Dock2System

/// The Finder tile in the user's own icon ([icon](product/files/icon.md)): one of Cairo's pictures on a blend
/// of Icon Composer's plates, filled black and white, in their colour; drawn at the pixel size asked for, each
/// of the picture's pixels a whole number of the screen's.
enum FinderTileImage {
    /// Nil for Finder's own icon, or when the plates are missing.
    static func image(_ icon: FinderIcon) -> NSImage? {
        guard let picture = icon.picture, let plates else { return nil }
        return NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let side = Int(context.convertToDeviceSpace(rect).width.rounded())
            guard side > 0, let image = render(picture.art, filled: icon.filled, color: icon.color, plates: plates, side: side)
            else { return false }
            // Rendered at the pixel size it is drawn at, so drawn one to one.
            context.interpolationQuality = .none
            context.draw(image, in: rect)
            return true
        }
    }

    /// An app icon's plate within its image, as NSWorkspace's icons have it.
    static let plateFraction = 412.0 / 512

    private static func render(_ art: PixelArt, filled: Bool, color: IconColor, plates: Plates, side: Int) -> CGImage? {
        let plateSide = Double(side) * plateFraction
        let plate = CGRect(x: (Double(side) - plateSide) / 2, y: (Double(side) - plateSide) / 2, width: plateSide, height: plateSide)
        guard let black = bitmap(side: side), let white = bitmap(side: side),
              let ink = black.data?.assumingMemoryBound(to: UInt8.self), let paper = white.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        for (context, image) in [(black, plates.black), (white, plates.white)] {
            context.interpolationQuality = .high
            context.draw(image, in: plate)
        }
        // black + (white − black) × colour, channel by channel in Display P3's encoded values; premultiplied, as
        // the two share their alpha.
        let channels = [color.red, color.green, color.blue].map { min(max($0, 0), 1) }
        for pixel in stride(from: 0, to: side * black.bytesPerRow, by: 4) where ink[pixel + 3] > 0 {
            for channel in 0..<3 {
                let k = Double(ink[pixel + channel]), w = Double(paper[pixel + channel])
                ink[pixel + channel] = UInt8(min(max(k + (w - k) * channels[channel], 0), 255).rounded())
            }
        }
        drawPicture(art, filled: filled, in: black, side: side, plateSide: plateSide)
        return black.makeImage()
    }

    /// White, or filled — its ink black, the paper it encloses white — with the soft shadow Icon Composer
    /// gives a layer, fitted to its by eye.
    private static func drawPicture(_ art: PixelArt, filled: Bool, in context: CGContext, side: Int, plateSide: Double) {
        let placement = art.placement(side: side, fraction: FinderIcon.pictureFraction * plateFraction)
        context.setShadow(offset: CGSize(width: 0, height: -plateSide * 0.008), blur: plateSide * 0.02,
                          color: CGColor(gray: 0, alpha: 0.35))
        // One layer, so the shadow falls from the whole shape.
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.interpolationQuality = .none
        let s = placement.scale
        for (part, gray) in filled ? [(art, 0.0), (art.inside, 1)] : [(art, 1)] {
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            for y in 0..<part.height {
                for x in 0..<part.width where part.isInk(x: x, y: y) {
                    // The placement counts from the top; the context, from the bottom.
                    context.fill(CGRect(x: placement.x + Double(x) * s, y: Double(side) - placement.y - Double(y + 1) * s, width: s, height: s))
                }
            }
        }
        context.endTransparencyLayer()
    }

    private static func bitmap(side: Int) -> CGContext? {
        CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                  space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private struct Plates {
        let black: CGImage
        let white: CGImage
    }

    /// `Resources/Plates` inside the bundle; run from `.build`, what `make plates` put beside it.
    private static let plates: Plates? = {
        let folder = Bundle.main.bundleIdentifier == Dock2Identity.bundleIdentifier
            ? Bundle.main.resourceURL?.appendingPathComponent("Plates")
            : Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("plates")
        func load(_ name: String) -> CGImage? {
            guard let url = folder?.appendingPathComponent("\(name).png"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let black = load("default-black"), let white = load("default-white") else { return nil }
        return Plates(black: black, white: white)
    }()
}
