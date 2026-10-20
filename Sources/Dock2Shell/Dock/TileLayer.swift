import AppKit
import QuartzCore

/// One tile's icon: drawn at its tile size, shaded while pressed, and hopping while its app launches.
final class TileLayer: CALayer {
    private let shade = CALayer()
    private let shadeMask = CALayer()
    private var bouncing = false

    /// How far a launch hop lifts the icon, as a fraction of the tile size.
    private static let hopHeight = 0.5
    /// One hop, up and down.
    private static let hopDuration: CFTimeInterval = 0.6

    /// Rendered at the layer's size and `contentsScale` when set, so set those first.
    var image: NSImage? {
        didSet { updateContents() }
    }

    var isPressed = false {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shade.isHidden = !isPressed
            CATransaction.commit()
        }
    }

    override init() {
        super.init()
        contentsGravity = .resizeAspect
        // The Dock darkens a pressed icon: a black wash cut to the icon's own alpha.
        shade.backgroundColor = CGColor(gray: 0, alpha: 0.35)
        shade.mask = shadeMask
        shadeMask.contentsGravity = .resizeAspect
        shade.isHidden = true
        addSublayer(shade)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = bounds
        shadeMask.frame = bounds
        CATransaction.commit()
    }

    private func updateContents() {
        // An icon from NSWorkspace says it is 32pt, and would hand over its 64px rendition to be
        // stretched: at the tile's own size it picks the one drawn for that size.
        let sized = image?.copy() as? NSImage
        sized?.size = bounds.size
        let contents = sized?.layerContents(forContentsScale: contentsScale)
        self.contents = contents
        shade.contentsScale = contentsScale
        shadeMask.contentsScale = contentsScale
        shadeMask.contents = contents
    }

    // MARK: - Launching

    /// Hops until `stopBouncing`, which lets the hop in the air land.
    func startBouncing() {
        guard !bouncing else { return }
        bouncing = true
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, bounds.height * Self.hopHeight, 0]
        hop.keyTimes = [0, 0.5, 1]
        hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        hop.duration = Self.hopDuration
        hop.repeatCount = .infinity
        hop.isAdditive = true
        add(hop, forKey: "bounce")
    }

    func stopBouncing() {
        guard bouncing else { return }
        bouncing = false
        guard let hop = animation(forKey: "bounce") else { return }
        // Where in its hop the icon is now, so it can come down from there.
        let elapsed = convertTime(CACurrentMediaTime(), from: nil) - hop.beginTime
        let phase = elapsed.truncatingRemainder(dividingBy: Self.hopDuration) / Self.hopDuration
        removeAnimation(forKey: "bounce")
        let height = bounds.height * Self.hopHeight
        let current = phase < 0.5 ? height * (1 - pow(1 - phase * 2, 2)) : height * (1 - pow((phase - 0.5) * 2, 2))
        guard current > 0.5 else { return }
        let land = CABasicAnimation(keyPath: "transform.translation.y")
        land.fromValue = current
        land.toValue = 0
        land.duration = Self.hopDuration / 2 * sqrt(current / height)
        land.timingFunction = CAMediaTimingFunction(name: .easeIn)
        land.isAdditive = true
        add(land, forKey: "land")
    }
}
