import Dock2Core
import QuartzCore

/// A duration and a timing curve, ready for Core Animation: one of the system Dock's measured motions, or
/// dock2's own entrance (`EntryMotion`). Or springs, which the animations made explicitly (`animation`) take
/// instead; implicit ones cannot spring, and keep to the curve over the duration.
struct Motion: Sendable {
    var duration: CFTimeInterval
    var curve: DockMotion.Curve
    /// What grows or moves goes on `out`, what shrinks on `in`.
    var springs: (out: SidelineMotion.Spring, in: SidelineMotion.Spring)?

    init(_ duration: CFTimeInterval, _ curve: DockMotion.Curve,
         springs: (out: SidelineMotion.Spring, in: SidelineMotion.Spring)? = nil) {
        self.duration = duration
        self.curve = curve
        self.springs = springs
    }

    var timing: CAMediaTimingFunction { CAMediaTimingFunction(curve) }

    /// How far past its end this can carry something, as a part of the way there: a spring's first swing, none on a curve.
    var overshoot: Double {
        guard let springs else { return 0 }
        return max(Self.overshoot(springs.out), Self.overshoot(springs.in))
    }

    private static func overshoot(_ spring: SidelineMotion.Spring) -> Double {
        guard spring.damping < 1 else { return 0 }
        return exp(-Double.pi * spring.damping / (1 - spring.damping * spring.damping).squareRoot())
    }

    static let slide = Motion(DockMotion.slideDuration, DockMotion.slideCurve)
    static let reshape = Motion(DockMotion.reshapeDuration, DockMotion.reshapeCurve)
    static let rise = Motion(EntryMotion.riseDuration, EntryMotion.riseCurve)
    static let sink = Motion(EntryMotion.sinkDuration, EntryMotion.sinkCurve)
    /// The reshape, its explicit animations on the sideline's springs, as long as the slower takes to settle.
    static let sideline = Motion(
        max(CASpringAnimation(SidelineMotion.out).settlingDuration, CASpringAnimation(SidelineMotion.in).settlingDuration),
        DockMotion.reshapeCurve, springs: (SidelineMotion.out, SidelineMotion.in))

    /// A tile's number on its way out of its dot, and back: springs, and the fades that go with them.
    static let number = Motion(NumberMotion.leave, DockMotion.reshapeCurve, springs: (NumberMotion.rise, NumberMotion.fall))
    static let numberLeaving = Motion(NumberMotion.leave, DockMotion.reshapeCurve)
    static let numberLanding = Motion(NumberMotion.land, NumberMotion.landCurve)

    /// An animation of `keyPath` from `from` to the value set: on the curve, or on the spring for something that
    /// moves or grows, or for something that shrinks.
    func animation(_ keyPath: String, from: Any, growing: Bool = true) -> CABasicAnimation {
        guard let springs else {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = from
            animation.duration = duration
            animation.timingFunction = timing
            return animation
        }
        let animation = CASpringAnimation(growing ? springs.out : springs.in)
        animation.keyPath = keyPath
        animation.fromValue = from
        return animation
    }

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
        layer.add(animation(key, from: from), forKey: key)
    }

    /// Commits what `changes` does to layers as one. A transaction with none around it reaches the screen as it
    /// commits, so a change made of several would show half made while the rest of it is built.
    static func together<T>(_ changes: () -> T) -> T {
        CATransaction.begin()
        defer { CATransaction.commit() }
        return changes()
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

extension CASpringAnimation {
    /// The spring Core's `Spring` steps, the same by construction, running until it settles.
    convenience init(_ spring: SidelineMotion.Spring) {
        self.init()
        mass = 1
        stiffness = pow(2 * .pi / spring.response, 2)
        damping = 4 * .pi * spring.damping / spring.response
        duration = settlingDuration
    }
}

extension CALayer {
    private static let fadeKey = "fade"

    /// Fades in from nothing, `delay` from now. AppKit owns a view's layer's opacity, so this is an animation alone.
    func fadeIn(over duration: CFTimeInterval, after delay: CFTimeInterval = 0) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = convertTime(CACurrentMediaTime() + delay, from: nil)
        fade.duration = duration
        fade.fillMode = .backwards
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(fade, forKey: Self.fadeKey)
    }

    /// Fades out from how it looks now, and stays out until `stopFading`.
    func fadeOut(over duration: CFTimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = presentation()?.opacity ?? opacity
        fade.toValue = 0
        fade.duration = duration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(fade, forKey: Self.fadeKey)
    }

    func stopFading() {
        removeAnimation(forKey: Self.fadeKey)
    }
}
