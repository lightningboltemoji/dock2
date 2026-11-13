import AppKit
import Dock2Core

/// One of Cairo's pictures on the plate in the user's colour, as a tile wears it ([icons](product/icons.md#cairos-pictures)):
/// drawn at the pixel size asked for, each of the picture's pixels a whole number of the screen's.
enum PictureIconImage {
    /// Nil when the plates are missing.
    static func image(_ icon: PictureIcon) -> NSImage? {
        guard IconPlate.isAvailable else { return nil }
        return IconPlate.image(size: 128) { side in render(icon.picture.art, filled: icon.filled, color: icon.color, side: side) }
    }

    private static func render(_ art: PixelArt, filled: Bool, color: IconColor, side: Int) -> CGImage? {
        guard let context = IconPlate.bitmap(side: side, color: color) else { return nil }
        IconPlate.layer(in: context, side: side) { drawPicture(art, filled: filled, in: context, side: side) }
        return context.makeImage()
    }

    /// White, or filled — its ink black, the paper it encloses white.
    private static func drawPicture(_ art: PixelArt, filled: Bool, in context: CGContext, side: Int) {
        let placement = art.placement(side: side, fraction: PictureIcon.pictureFraction * IconPlate.fraction)
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
    }
}
