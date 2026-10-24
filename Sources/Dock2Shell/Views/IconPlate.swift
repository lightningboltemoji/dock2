import AppKit
import Dock2Core
import Dock2System

/// Icon Composer's plate for an empty icon, in any colour, at whatever pixel size it is drawn: what the Finder
/// tile's picture stands on, and every icon dock2 draws among apps' ([visual](product/visual.md#icons-among-apps)).
enum IconPlate {
    /// An app icon's plate within its image, as NSWorkspace's icons have it.
    static let fraction = 412.0 / 512
    /// A symbol's point size, as a fraction of the plate: one for every symbol, so SF Symbols' optical balance holds.
    static let symbolSize = 0.6
    /// A symbol's longer side at most, as a fraction of the plate: a wider one — play/pause — is drawn smaller.
    static let symbolLimit = 0.86

    static var isAvailable: Bool { plates != nil }

    /// A symbol on the plate: white, filled where it has a fill, with a layer's shadow.
    static func symbol(_ name: String, color: IconColor, size: Double) -> NSImage? {
        guard isAvailable else { return nil }
        return image(size: size) { side in
            guard let context = bitmap(side: side, color: color) else { return nil }
            if let glyph = glyph(name, plateSide: Double(side) * fraction) {
                let rect = CGRect(x: (Double(side) - glyph.size.width) / 2, y: (Double(side) - glyph.size.height) / 2,
                                  width: glyph.size.width, height: glyph.size.height)
                layer(in: context, side: side) { draw(glyph, in: rect, on: context) }
            }
            return context.makeImage()
        }
    }

    /// A picture filling the plate's shape, cropped to it; the plate shows where the picture is clear.
    static func picture(_ picture: NSImage, color: IconColor, size: Double) -> NSImage? {
        guard let plates else { return nil }
        return image(size: size) { side in
            guard let context = bitmap(side: side, color: color) else { return nil }
            let plate = plateRect(side: side)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            // A blend reaches only where its source is drawn: the clip keeps the picture off the margin, the plate
            // drawn in over it takes its corners.
            context.clip(to: plate)
            context.interpolationQuality = .high
            draw(picture, in: aspectFill(picture.size, in: plate), on: context)
            context.setBlendMode(.destinationIn)
            context.draw(plates.black, in: plate)
            context.endTransparencyLayer()
            return context.makeImage()
        }
    }

    static func empty(color: IconColor, size: Double) -> NSImage? {
        guard isAvailable else { return nil }
        return image(size: size) { side in bitmap(side: side, color: color)?.makeImage() }
    }

    /// Rendered by `render` at the pixel size it is drawn at, and drawn one to one, so it is sharp at any size.
    static func image(size: Double, _ render: @escaping (_ side: Int) -> CGImage?) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let side = Int(context.convertToDeviceSpace(rect).width.rounded())
            guard side > 0, let image = render(side) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: rect)
            return true
        }
    }

    /// `side` pixels square, the plate centred in it in `color`: black + (white − black) × colour, channel by
    /// channel in Display P3's encoded values; premultiplied, as the two share their alpha.
    static func bitmap(side: Int, color: IconColor) -> CGContext? {
        guard let plates, let black = context(side: side), let white = context(side: side),
              let ink = black.data?.assumingMemoryBound(to: UInt8.self), let paper = white.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        let plate = plateRect(side: side)
        for (context, image) in [(black, plates.black), (white, plates.white)] {
            context.interpolationQuality = .high
            context.draw(image, in: plate)
        }
        let channels = [color.red, color.green, color.blue].map { min(max($0, 0), 1) }
        for pixel in stride(from: 0, to: side * black.bytesPerRow, by: 4) where ink[pixel + 3] > 0 {
            for channel in 0..<3 {
                let k = Double(ink[pixel + channel]), w = Double(paper[pixel + channel])
                ink[pixel + channel] = UInt8(min(max(k + (w - k) * channels[channel], 0), 255).rounded())
            }
        }
        return black
    }

    /// `draw` as one layer, with the soft shadow Icon Composer gives a layer, fitted to its by eye.
    static func layer(in context: CGContext, side: Int, _ draw: () -> Void) {
        let plateSide = Double(side) * fraction
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -plateSide * 0.008), blur: plateSide * 0.02,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func plateRect(side: Int) -> CGRect {
        let plateSide = Double(side) * fraction
        return CGRect(x: (Double(side) - plateSide) / 2, y: (Double(side) - plateSide) / 2, width: plateSide, height: plateSide)
    }

    private static func glyph(_ name: String, plateSide: Double) -> NSImage? {
        let filled = NSImage(systemSymbolName: name + ".fill", accessibilityDescription: nil) != nil ? name + ".fill" : name
        func symbol(_ points: Double) -> NSImage? {
            NSImage(systemSymbolName: filled, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: points, weight: .semibold))
        }
        guard var template = symbol(plateSide * symbolSize) else { return nil }
        let longest = max(template.size.width, template.size.height)
        if longest > plateSide * symbolLimit, let smaller = symbol(plateSide * symbolSize * plateSide * symbolLimit / longest) {
            template = smaller
        }
        return template.tinted(.white)
    }

    private static func draw(_ image: NSImage, in rect: CGRect, on context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func aspectFill(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private static func context(side: Int) -> CGContext? {
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

extension NSImage {
    /// A template in `color`, as an image view tints one: monochrome, a fill's cut-outs left clear, where a
    /// one-colour palette would paint them too — the clipboard's lines.
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { [self] rect in
            draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
