import AppKit
import Dock2Core
import QuartzCore

/// One tile's icon: drawn at its tile size, shaded while pressed, hopping while its app launches, and
/// with a progress bar across its foot while Files copies.
final class TileLayer: CALayer {
    private let shade = CALayer()
    private let shadeMask = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private var bouncing = false

    private var bounceHeight: CGFloat = 0

    /// Rendered at the layer's size and `contentsScale` when set, so set those first.
    var image: NSImage? {
        didSet { updateContents() }
    }

    /// A temporary tile's icon is dimmed until its app opens.
    var isDimmed = false {
        didSet { opacity = isDimmed ? 0.5 : 1 }
    }

    var isPressed = false {
        didSet { updateShade() }
    }

    /// The ring: keyboard focus, which the system Dock draws as it draws a press.
    var isFocused = false {
        didSet { updateShade() }
    }

    /// 0 to 1, or nil for none.
    var progress: Double? {
        didSet { updateProgress() }
    }

    private func updateProgress() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.isHidden = progress == nil
        let size = bounds.size
        // As the Dock draws a download's: most of the icon's width, near its foot.
        let height = max(5, (size.height * 0.085).rounded())
        let frame = CGRect(x: size.width * 0.14, y: size.height * 0.1, width: size.width * 0.72, height: height)
        track.frame = frame
        track.cornerRadius = height / 2
        fill.cornerRadius = (height - 2) / 2
        fill.frame = CGRect(x: 1, y: 1, width: max(height - 2, (frame.width - 2) * min(1, max(0, progress ?? 0))), height: height - 2)
        fill.backgroundColor = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
    }

    private func updateShade() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.isHidden = !(isPressed || isFocused)
        CATransaction.commit()
    }

    override init() {
        super.init()
        contentsGravity = .resizeAspect
        // The Dock darkens a pressed or keyboard-focused icon to 48%: a black wash cut to its own alpha.
        shade.backgroundColor = CGColor(gray: 0, alpha: 0.52)
        shade.mask = shadeMask
        shadeMask.contentsGravity = .resizeAspect
        shade.isHidden = true
        addSublayer(shade)
        track.backgroundColor = CGColor(gray: 1, alpha: 0.9)
        track.borderColor = CGColor(gray: 0, alpha: 0.3)
        track.borderWidth = 0.5
        track.isHidden = true
        track.addSublayer(fill)
        addSublayer(track)
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
        updateProgress()
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

    /// Hops `height` points, again and again, until `stopBouncing` lets the hop in the air land: the
    /// system Dock's parabola, one hop every `DockMotion.hopPeriod`.
    func startBouncing(height: CGFloat) {
        guard !bouncing else { return }
        bouncing = true
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, height, 0]
        hop.keyTimes = [0, 0.5, 1]
        hop.timingFunctions = [CAMediaTimingFunction(DockMotion.hopRise), CAMediaTimingFunction(DockMotion.hopFall)]
        hop.duration = DockMotion.hopPeriod
        hop.repeatCount = .infinity
        hop.isAdditive = true
        hop.beginTime = convertTime(CACurrentMediaTime(), from: nil)
        add(hop, forKey: "bounce")
        bounceHeight = height
    }

    func stopBouncing() {
        guard bouncing else { return }
        bouncing = false
        guard let hop = animation(forKey: "bounce") else { return }
        // Where in its hop the icon is now, so it can come down from there as it would have.
        let elapsed = convertTime(CACurrentMediaTime(), from: nil) - hop.beginTime
        let phase = elapsed.truncatingRemainder(dividingBy: DockMotion.hopPeriod) / DockMotion.hopPeriod
        removeAnimation(forKey: "bounce")
        let height = bounceHeight
        let current = height * (1 - pow(2 * phase - 1, 2))
        guard current > 0.5 else { return }
        // On the way up it rises to the top first; on the way down it is already falling.
        let land = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let falling = phase >= 0.5
        land.values = falling ? [current, 0] : [current, height, 0]
        land.keyTimes = falling ? [0, 1] : [0, NSNumber(value: (0.5 - phase) / (1 - phase)), 1]
        land.timingFunctions = falling ? [CAMediaTimingFunction(name: .easeIn)]
            : [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(DockMotion.hopFall)]
        land.duration = (1 - phase) * DockMotion.hopPeriod
        land.isAdditive = true
        add(land, forKey: "land")
    }
}
