import Dock2Core
import QuartzCore

/// A duration and a timing curve, ready for Core Animation: one of the system Dock's measured motions, or
/// dock2's own entrance (`EntryMotion`).
struct Motion: Sendable {
    var duration: CFTimeInterval
    var curve: DockMotion.Curve

    init(_ duration: CFTimeInterval, _ curve: DockMotion.Curve) {
        self.duration = duration
        self.curve = curve
    }

    var timing: CAMediaTimingFunction { CAMediaTimingFunction(curve) }

    static let slide = Motion(DockMotion.slideDuration, DockMotion.slideCurve)
    static let reshape = Motion(DockMotion.reshapeDuration, DockMotion.reshapeCurve)
    static let rise = Motion(EntryMotion.riseDuration, EntryMotion.riseCurve)
    static let sink = Motion(EntryMotion.sinkDuration, EntryMotion.sinkCurve)

    /// The motion as the user wants it: none under Reduce Motion, whose changes fade instead (`crossfade`).
    @MainActor
    static func adjusted(_ motion: Motion?) -> Motion? {
        DisplayOptions.reduceMotion ? nil : motion
    }

    /// Fades `layer` from how it looks now to how the changes made in this transaction leave it: Reduce
    /// Motion's stand-in for a slide or a morph.
    static func crossfade(_ layer: CALayer?, over motion: Motion) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = motion.duration
        layer?.add(fade, forKey: "crossfade")
    }

    /// Animates `key` of `layer` to the value just set, from `from` — where it was, its presentation's: an
    /// implicit animation would jump if another were in flight.
    func animate(_ layer: CALayer, _ key: String, from: Any?) {
        guard let from else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.duration = duration
        animation.timingFunction = timing
        layer.add(animation, forKey: key)
    }

    /// Runs `changes` inside a transaction animating with this motion, or with no animation for nil.
    static func perform(_ motion: Motion?, _ changes: () -> Void) {
        CATransaction.begin()
        if let motion {
            CATransaction.setAnimationDuration(motion.duration)
            CATransaction.setAnimationTimingFunction(motion.timing)
        } else {
            CATransaction.setDisableActions(true)
        }
        changes()
        CATransaction.commit()
    }
}

extension CAMediaTimingFunction {
    convenience init(_ curve: DockMotion.Curve) {
        self.init(controlPoints: Float(curve.x1), Float(curve.y1), Float(curve.x2), Float(curve.y2))
    }
}
