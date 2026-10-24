import AppKit
import Dock2Core

/// Snow Leopard's shelf in the dock's content: beneath the tiles, the floor mirroring the screen above it; over
/// them, the tiles' own reflections. Both mirrors add what they reflect to the floor, in proportion to the
/// floor's reflectance. Its numbers were measured off Mac OS X 10.6's Dock and converted to sRGB.
@MainActor
final class Shelf {
    /// Catches the pointer over the footprint between the icons, as the glass does: the window passes it through
    /// wherever nothing is drawn.
    private let catcher = CALayer()
    /// The floor's picture, cut to the trapezoid.
    private let floor = CALayer()
    private let tones = CALayer()
    private let outline = CAShapeLayer()
    /// The screen's reflection over the floor, cut to it too. Not inside it: a masked layer is drawn apart, at its
    /// own size, and the backdrop's shift is scaled by how much that size differs from its own.
    private let screen = ScreenMirror()
    private let screenFade = CAGradientLayer()
    private let screenOutline = CAShapeLayer()
    /// Increase Contrast's: the trapezoid's edge.
    private let border = CAShapeLayer()
    private let tiles: LayerMirror?
    private let tilesFade = CAGradientLayer()

    /// The floor's reflectance by depth below the back edge, 0 to 1 at the lip: about a third at the back, a
    /// fifth from 0.8 on. Of the lip, the dark seam reflects 0.14 and the light edge hardly anything.
    private static let floorReflectance: [(depth: Double, amount: Double)] = [(0, 0.32), (0.6, 0.24), (0.8, 0.19), (1, 0.19)]
    private static let seamReflectance = 0.14, edgeReflectance = 0.03

    init(in content: CALayer, under tileLayer: CALayer) {
        catcher.backgroundColor = CGColor(gray: 0, alpha: 1 / 255)
        tones.contentsGravity = .resize
        tones.actions = ["contents": NSNull()]
        floor.addSublayer(tones)
        floor.mask = outline
        screenFade.mask = screenOutline
        screen?.layer.mask = screenFade
        screen?.layer.compositingFilter = "plusL"
        border.fillColor = nil
        border.lineWidth = 1
        tiles = LayerMirror(of: tileLayer)
        tiles?.layer.mask = tilesFade
        tiles?.layer.compositingFilter = "plusL"
        for layer in [catcher, floor, screen?.layer, border].compactMap({ $0 }) { content.insertSublayer(layer, below: tileLayer) }
        if let tiles { content.insertSublayer(tiles.layer, above: tileLayer) }
    }

    func remove() {
        for layer in [catcher, floor, screen?.layer, border, tiles?.layer] { layer?.removeFromSuperlayer() }
    }

    /// Fits the shelf to `layout`, in a transaction animating with `motion` if it is given. `space` is the
    /// window's colour space.
    func update(_ layout: DockLayout, bounds: CGRect, scale: CGFloat, space: CGColorSpace, motion: Motion?) {
        guard let shelf = layout.shelf else { return }
        catcher.frame = layout.platter
        floor.frame = shelf.floor
        let local = CGRect(origin: .zero, size: shelf.floor.size)
        tones.frame = local
        // Drawn at the size it is moving to, and stretched on the way there.
        if pictured?.size != local.size || pictured?.scale != scale {
            pictured = (local.size, scale)
            tones.contentsScale = scale
            tones.contents = Self.floorPicture(shelf, scale: scale)
        }
        let trapezoid = Self.trapezoid(local, lean: shelf.lean)
        for shape in [outline, screenOutline, border] {
            let from = shape.presentation()?.path ?? shape.path
            shape.path = trapezoid
            motion?.animate(shape, "path", from: from)
        }
        outline.frame = local
        screenOutline.frame = local
        border.frame = shelf.floor

        // The screen's reflection reaches the screen's edge; the tiles' ends at the lip.
        screen?.mirror(into: shelf.floor, about: shelf.mirrorLine, space: space)
        screenFade.frame = local
        Self.fade(screenFade, Self.reflectance(shelf, lip: true), from: shelf.floor.minY, to: shelf.floor.maxY)
        tiles?.mirror(bounds, about: shelf.iconLine)
        tilesFade.frame = CGRect(x: shelf.floor.minX, y: shelf.lipTop, width: shelf.floor.width, height: shelf.iconLine - shelf.lipTop)
        Self.fade(tilesFade, Self.reflectance(shelf, lip: false), from: shelf.lipTop, to: shelf.iconLine)

        // Snow Leopard had one appearance, the light one.
        border.isHidden = !DisplayOptions.increaseContrast
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            border.strokeColor = NSColor.secondaryLabelColor.cgColor
        }
        screen?.layer.isHidden = DisplayOptions.reduceTransparency
    }

    private var pictured: (size: CGSize, scale: CGFloat)?

    // MARK: - Reflectance

    /// The reflectance up the shelf, to the back edge from the lip's top, or with `lip` from the screen's edge:
    /// heights and amounts, a height twice where the amount steps.
    private static func reflectance(_ shelf: DockLayout.Shelf, lip: Bool) -> [(y: Double, amount: Double)] {
        let back = shelf.floor.maxY, floorDepth = back - shelf.lipTop
        let floor = floorReflectance.reversed().map { (y: back - $0.depth * floorDepth, amount: $0.amount) }
        guard lip else { return floor }
        let seam = shelf.lipTop - (shelf.lipTop - shelf.floor.minY) / 3
        return [(shelf.floor.minY, edgeReflectance), (seam, edgeReflectance), (seam, seamReflectance),
                (shelf.lipTop, seamReflectance)] + floor
    }

    /// Makes `layer` a mask of `stops`, which run up past both ends, from the height `bottom` up to `top`: its own
    /// bottom and top.
    private static func fade(_ layer: CAGradientLayer, _ stops: [(y: Double, amount: Double)], from bottom: Double, to top: Double) {
        func amount(at y: Double) -> Double {
            for (a, b) in zip(stops, stops.dropFirst()) where a.y < b.y && a.y <= y && y <= b.y {
                return a.amount + (b.amount - a.amount) * (y - a.y) / (b.y - a.y)
            }
            return y < stops[0].y ? stops[0].amount : stops[stops.count - 1].amount
        }
        let knots = [(y: bottom, amount: amount(at: bottom))] + stops.filter { $0.y > bottom && $0.y < top }
            + [(y: top, amount: amount(at: top))]
        layer.colors = knots.map { CGColor(gray: 0, alpha: $0.amount) }
        layer.locations = knots.map { NSNumber(value: ($0.y - bottom) / (top - bottom)) }
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
    }

    // MARK: - Pictures

    private static func trapezoid(_ rect: CGRect, lean: Double) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                CGPoint(x: rect.maxX - lean, y: rect.maxY), CGPoint(x: rect.minX + lean, y: rect.maxY)])
        path.closeSubpath()
        return path
    }

    /// The floor: a light grey and a darker one, each brightening towards the front, meeting along an S across
    /// the shelf; then the lip, a dark seam over a light edge, 235 in the middle falling as `27u²` to its ends,
    /// with `u` 1 at the back edge's. Greys in sRGB.
    private static func floorPicture(_ shelf: DockLayout.Shelf, scale: CGFloat) -> CGImage? {
        let size = shelf.floor.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let lip = shelf.lipTop - shelf.floor.minY, back = size.height, floorDepth = back - lip
        // By depth from the back edge to the lip.
        func y(_ depth: Double) -> Double { back - depth * floorDepth }
        func grey(_ value: Double) -> CGColor { CGColor(srgbRed: value / 255, green: value / 255, blue: value / 255, alpha: 1) }
        func vertical(_ back: Double, _ front: Double) {
            let gradient = CGGradient(colorsSpace: nil, colors: [grey(front), grey(back)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y(1)), end: CGPoint(x: 0, y: y(0)),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        vertical(118, 174)
        context.saveGState()
        context.addPath(darkerGrey(shelf))
        context.clip()
        vertical(97.5, 129.5)
        context.restoreGState()

        context.setFillColor(grey(96))
        context.fill(CGRect(x: 0, y: lip * 2 / 3, width: size.width, height: lip / 3))
        let stops = (0...16).map { Double($0) / 16 }
        let colors = stops.map { location in
            let u = (location * size.width - size.width / 2) / (size.width / 2 - shelf.lean)
            return grey(235 - 27 * u * u)
        }
        let edge = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: stops.map { CGFloat($0) })!
        context.clip(to: CGRect(x: 0, y: 0, width: size.width, height: lip * 2 / 3))
        context.drawLinearGradient(edge, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
        return context.makeImage()
    }

    /// The darker grey's region, in front of the floor's step, in the floor's own coordinates.
    private static func darkerGrey(_ shelf: DockLayout.Shelf) -> CGPath {
        let steps = 128
        let curve = (0...steps).map { i in
            let point = shelf.floorStep(across: Double(i) / Double(steps))
            return CGPoint(x: point.x - shelf.floor.minX, y: point.y - shelf.floor.minY)
        }
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: curve[0].y)] + curve
                      + [CGPoint(x: shelf.floor.width, y: curve[steps].y), CGPoint(x: shelf.floor.width, y: 0)])
        path.closeSubpath()
        return path
    }
}

/// The shelf's marks, drawn once for each size and scale.
@MainActor
enum ShelfArt {
    private static var lights: [String: CGImage] = [:]
    private static var lanes: [String: CGImage] = [:]

    /// A running app's light, to be added to what is beneath it, filling `size` with its foot on the screen's
    /// edge: a white core 8pt up in an azure glow, the glow's spill across the lip's seam, and a white shine on
    /// the lip. Fitted at tile size 56, where `size` is 32 × 16, as Gaussians and blurred boxes.
    static func light(size: CGSize, scale: CGFloat) -> CGImage? {
        let key = "\(size.width)x\(size.height)@\(scale)"
        if let image = lights[key] { return image }
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let k = size.width / 32
        let glow = (r: 0.16, g: 0.56, b: 1.0), spill = (r: 0.76, g: 0.87, b: 1.0)
        func gauss(_ u: Double, _ sigma: Double) -> Double { exp(-u * u / (2 * sigma * sigma)) }
        func box(_ u: Double, _ half: Double, _ blur: Double) -> Double {
            0.5 * (erf((u + half) / (sqrt(2) * blur)) - erf((u - half) / (sqrt(2) * blur)))
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let y = (Double(height - row) - 0.5) / scale
            for column in 0..<width {
                let x = (Double(column) + 0.5) / scale - size.width / 2
                let core = 2.87 * box(x, 3.14 * k, 0.79 * k) * box(y - 8 * k, 0.3 * k, 0.79 * k)
                let halo = 0.66 * gauss(x, 3.42 * k) * gauss(y - 8 * k, 2.26 * k)
                let seam = 0.35 * gauss(x, 6.62 * k) * gauss(y - 2.5 * k, 0.78 * k)
                let shine = min(1, max(0, (1.1 - hypot(x / (4.6 * k), y / (1.9 * k))) / 0.25))
                let white = core + shine
                let rgb = [white + halo * glow.r + seam * spill.r, white + halo * glow.g + seam * spill.g,
                           white + halo * glow.b + seam * spill.b].map { min(1, $0) }
                let i = (row * width + column) * 4
                for c in 0..<3 { pixels[i + c] = UInt8((rgb[c] * 255).rounded()) }
                pixels[i + 3] = pixels[i..<(i + 3)].max()!
            }
        }
        let image = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        lights[key] = image
        return image
    }

    /// The separator's lane: its dashes, rects within `size`, white at a third.
    static func lane(_ dashes: [CGRect], size: CGSize, scale: CGFloat) -> CGImage? {
        let key = "\(dashes)@\(scale)"
        if let image = lanes[key] { return image }
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.33))
        context.fill(dashes)
        let image = context.makeImage()
        lanes[key] = image
        return image
    }
}
