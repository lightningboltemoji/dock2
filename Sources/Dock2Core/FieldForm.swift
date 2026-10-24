import CoreGraphics
import Foundation

/// What the search field is while nothing is typed, and how it turns into the field as something is
/// ([panel](../../.agents/product/panel.md#the-fields-form)).
public enum FieldForm: String, Sendable, CaseIterable, Codable {
    /// Spotlight's: the field itself, empty.
    case capsule
    /// A bead of glass that pours out into the field.
    case drop
    /// A gem turning inside a marble, unrolled into the field.
    case gem
    /// Droplets drifting about one another, flung into line.
    case lavaLamp

    public var title: String {
        switch self {
        case .capsule: "Capsule"
        case .drop: "Drop"
        case .gem: "Gem"
        case .lavaLamp: "Lava lamp"
        }
    }
}

/// A shape of the field's glass, from the field's centre with y up: a rounded rect, turned about its centre.
public struct FormShape: Sendable, Equatable {
    public var frame: CGRect
    public var cornerRadius: Double
    /// Continuous corners, as the grown panel has; otherwise circular, as a capsule's.
    public var continuous = false
    public var rotation = 0.0

    static func circle(_ center: CGPoint, _ diameter: Double) -> FormShape {
        let d = max(diameter, 0.5)
        return FormShape(frame: CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d), cornerRadius: d / 2)
    }

    static func capsule(_ center: CGPoint, width: Double, height: Double, rotation: Double = 0) -> FormShape {
        let w = max(width, 0.5), h = max(height, 0.5)
        return FormShape(frame: CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h),
                         cornerRadius: min(w, h) / 2, rotation: rotation)
    }
}

/// Something drawn over the glass, from its place in the field: moved, scaled about its centre, faded.
public struct FormPlacement: Sendable, Equatable {
    public var offset: CGPoint
    public var scale: Double
    public var alpha: Double
}

/// A face of the gem, drawn beneath the glass.
public struct FormFace: Sendable, Equatable {
    public var corners: [CGPoint]
    public var hue, saturation, brightness, alpha: Double
    /// Its edges' white, as an alpha.
    public var edge: Double
    /// Greater is nearer.
    public var depth: Double
}

/// The field's form at one moment, from the field's centre.
public struct FormFrame: Sendable {
    /// The body — the field, or the panel grown from it — then the shapes that melt into it.
    public var shapes: [FormShape]
    public var glyph: FormPlacement
    public var text: FormPlacement
    /// The spinner's alpha, at the field's trailing end.
    public var trailing: Double
    public var faces: [FormFace]

    public var body: FormShape { shapes[0] }
}

/// A duration and a curve, for what the form carries of the panel's own motion.
public struct FormTiming: Sendable {
    public var duration: Double
    public var curve: DockMotion.Curve

    public init(_ duration: Double, _ curve: DockMotion.Curve) {
        self.duration = duration
        self.curve = curve
    }
}

/// A field form's motion, simulated: each shape on springs of its own, riding on the panel's own motion — its
/// growth (`Growth`), its rise and its sinking. Deterministic, and repeating every `period` at rest, so it can be
/// sampled ahead and looped. The capsule has no shapes of its own: it is the panel's motion alone.
public struct FieldMotion: Sendable {
    public static let period = 24.0
    /// The simulation's step.
    static let tick = 1.0 / 240

    public let form: FieldForm
    public private(set) var time: Double
    private var space: FormSpace
    private var sim: any FormSim
    /// The body as the panel wants it, on its way there.
    private var goal: Growth
    private var lift: Tween<Double>
    private var scale: Tween<Double>
    private var text = TextMotion()
    /// Emptied while the panel was grown: the form waits for it to be the field again.
    private var pendingRest = false

    /// `target` is the body as the panel would draw it, from the field's centre.
    public init(form: FieldForm, field: CGSize, target: CGRect, time: Double, resting: Bool) {
        let space = FormSpace(band: CGRect(x: target.minX, y: target.minY, width: target.width, height: field.height),
                              height: field.height)
        switch form {
        case .capsule: sim = CapsuleSim()
        case .drop: sim = DropSim(space: space, resting: resting)
        case .gem: sim = GemSim(space: space, resting: resting, time: time)
        case .lavaLamp: sim = LavaSim(space: space, resting: resting, time: time)
        }
        self.form = form
        self.time = time
        self.space = space
        goal = Growth(target)
        lift = Tween(0, at: time)
        scale = Tween(1, at: time)
        if !sim.isResting { text = TextMotion(at: space.band.minX + space.textHome) }
    }

    /// Resting at `time`, long enough that whatever it rested from has died away: what its loop shows then.
    public static func resting(_ form: FieldForm, field: CGSize, target: CGRect, at time: Double) -> FieldMotion {
        var motion = FieldMotion(form: form, field: field, target: target, time: time - 4, resting: true)
        motion.advance(to: time)
        return motion
    }

    public var isResting: Bool { sim.isResting || pendingRest }

    /// The body as the panel last asked for it, from the field's centre.
    public var target: CGRect { goal.target }

    /// Nothing will move again until something happens to it; never while resting, which goes on moving.
    public var isSettled: Bool {
        !sim.isResting && sim.isSettled && text.isSettled && goal.isSettled && time >= lift.end && time >= scale.end
    }

    public mutating func advance(to end: Double) {
        guard end > time else { return }
        if isSettled {
            time = end
            return
        }
        while time < end {
            if pendingRest, goal.isWithin(1) {
                pendingRest = false
                sim.rest(space: space, time: time)
            }
            let dt = min(Self.tick, end - time)
            goal.step(dt)
            sim.step(dt, space: space, time: time)
            if !isResting { text.left.to(textCarried) }
            text.step(dt)
            time += dt
        }
    }

    /// The body as the panel now wants it, from the field's centre: there at once, or growing to it.
    public mutating func setTarget(_ rect: CGRect, animated: Bool) {
        goal.to(rect, animated: animated)
        space.band = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: space.height)
    }

    /// Rises in from below and smaller, as the field does.
    public mutating func arrive(over timing: FormTiming) {
        lift = Tween(from: -EntryMotion.riseDistance, to: 0, at: time, timing)
        scale = Tween(from: EntryMotion.riseScale, to: 1, at: time, timing)
        sim.arrive()
    }

    /// Sinks back the way it came.
    public mutating func leave(over timing: FormTiming) {
        lift = Tween(from: lift.value(at: time), to: -EntryMotion.riseDistance, at: time, timing)
        scale = Tween(from: scale.value(at: time), to: EntryMotion.riseScale, at: time, timing)
    }

    /// Something was typed into the empty field, `textWidth` wide: the form becomes the field.
    public mutating func pour(textWidth: Double) {
        guard isResting else { return }
        guard !pendingRest else {
            // Still the field: the text comes back where it is.
            pendingRest = false
            text.show(width: textWidth, at: space.band.minX + space.textHome)
            return
        }
        sim.pour(space: space, time: time)
        text.pour(width: textWidth, at: textCarried)
    }

    /// Poured, the text rides beside the magnifier, where the body's left end carries them.
    private var textCarried: Double { sim.carried(space: space) + space.textHome - space.glyphHome }

    /// The field emptied — `cleared` at once, or deleted to nothing: the field becomes the form, once whatever
    /// grew from it has shrunk back. The capsule stays the field.
    public mutating func rest(cleared: Bool) {
        guard !isResting, form != .capsule else { return }
        pendingRest = true
        text.rest(cleared: cleared)
    }

    /// A letter more, the text now `textWidth` wide.
    public mutating func type(textWidth: Double) {
        text.width = textWidth
        guard !sim.isResting else { return }
        sim.typed(caret: text.left.value + textWidth * text.scale.value, time: time)
    }

    public var frame: FormFrame {
        let now = goal.value
        let band = CGRect(x: now.minX, y: now.minY, width: now.width, height: space.height)
        let pose = sim.pose(band: band, time: time)
        // What grew from the field grows above it, and keeps the panel's continuous corners.
        let extent = max(0, now.height - space.height)
        var body = FormShape(frame: pose.body, cornerRadius: min(pose.body.width, pose.body.height) / 2, rotation: pose.bodyRotation)
        if extent > 0.5 {
            body.frame.size.height += extent
            body.continuous = true
        }
        let shapes = ([body] + pose.extras).map(placed)
        let right = shapes.map(\.frame.maxX).max() ?? 0
        let poured = !sim.isResting
        let glyph = FormPlacement(offset: CGPoint(x: pose.glyph.x - (band.minX + space.glyphHome), y: pose.glyph.y - PanelMetrics.glyphLift),
                                  scale: pose.glyphScale, alpha: pose.glyphAlpha)
        return FormFrame(
            shapes: shapes,
            glyph: glyph,
            text: FormPlacement(offset: CGPoint(x: text.left.value - (band.minX + space.textHome), y: 0), scale: text.scale.value,
                                alpha: max(0, min(1, text.alpha.value))),
            trailing: poured ? max(0, min(1, (right - (band.maxX - 50)) / 20)) : 0,
            faces: pose.faces.map { face in
                var face = face
                face.corners = face.corners.map(placed)
                return face
            })
    }

    /// Lifted and scaled about the field's centre, as it rises and sinks.
    private func placed(_ point: CGPoint) -> CGPoint {
        let s = scale.value(at: time)
        return CGPoint(x: point.x * s, y: point.y * s + lift.value(at: time))
    }

    private func placed(_ shape: FormShape) -> FormShape {
        let s = scale.value(at: time)
        var shape = shape
        let origin = placed(shape.frame.origin)
        shape.frame = CGRect(x: origin.x, y: origin.y, width: shape.frame.width * s, height: shape.frame.height * s)
        shape.cornerRadius *= s
        return shape
    }
}

/// The field, from its centre: its band — the body's field-high part, as the panel now wants it — and its
/// height.
struct FormSpace: Sendable {
    var band: CGRect
    let height: Double

    /// The magnifier's centre and the text's left edge, from the band's left end.
    var glyphHome: Double { PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2 }
    var textHome: Double { PanelMetrics.textLeft }

    /// The magnifier's centre as a body pouring out carries it: as far in from the body's left end as its place
    /// is from the field's, or in the body's middle while the body is narrower than that.
    func carried(left: Double, width: Double) -> Double { left + min(glyphHome, width / 2) }

    /// How closely the magnifier and the text follow where the body carries them, critically damped: never ahead.
    static let carry = 0.06

    /// How far in from a body's end a droplet `d` across lies inside it, deeper than the field's glass melts shapes
    /// together (12 pt), so it adds nothing to the body's outline.
    static func tucked(_ d: Double) -> Double { d / 2 + 14 }

    /// How far past a pouring body's end the middle of a droplet `length` along it rides, `since` the letter:
    /// standing out of the end while the body starts to open, then sunk inside it (`tucked`) by 0.1 s.
    static func lead(_ length: Double, since: Double) -> Double {
        let s = min(max((since - 0.055) / 0.04, 0), 1), sink = s * s * (3 - 2 * s)
        return -8 * (1 - sink) - tucked(length) * sink
    }

    /// How quickly a droplet gathers onto its end of the body from where it was when the letter came.
    static let gather = 0.05
}

/// What one form computes; `FieldMotion` composes it with the panel's own motion.
protocol FormSim: Sendable {
    var isResting: Bool { get }
    var isSettled: Bool { get }
    mutating func pour(space: FormSpace, time: Double)
    mutating func rest(space: FormSpace, time: Double)
    mutating func typed(caret: Double, time: Double)
    mutating func arrive()
    mutating func step(_ dt: Double, space: FormSpace, time: Double)
    /// Where everything is, around `band`.
    func pose(band: CGRect, time: Double) -> FormPose
    /// Where the body's left end carries the magnifier as it pours (`FormSpace.carried`), from the field's centre.
    func carried(space: FormSpace) -> Double
}

extension FormSim {
    mutating func typed(caret: Double, time: Double) {}
}

struct FormPose {
    /// The body's field-high part.
    var body: CGRect
    var bodyRotation = 0.0
    var extras: [FormShape] = []
    /// The magnifier's centre.
    var glyph: CGPoint
    var glyphScale = 1.0
    var glyphAlpha = 1.0
    var faces: [FormFace] = []
}

/// The text's left edge, from the field's centre, the same in every form: it lands beside the magnifier and rides out
/// with it, carried by the body's left end; cleared at once, it is drawn into the middle as it fades.
struct TextMotion: Sendable {
    var left = Spring(0), scale = Spring(1), alpha = Spring(0)
    var width = 0.0

    init() {}

    /// Already in place.
    init(at home: Double) {
        left = Spring(home, response: FormSpace.carry, damping: 1)
        alpha = Spring(1)
    }

    mutating func pour(width: Double, at place: Double) {
        self.width = width
        left = Spring(place, response: FormSpace.carry, damping: 1)
        scale = Spring(0.55)
        scale.to(1, response: 0.35, damping: 0.55)
        alpha = Spring(0)
        alpha.to(1, response: 0.12, damping: 1)
    }

    mutating func show(width: Double, at home: Double) {
        self.width = width
        left = Spring(home, response: FormSpace.carry, damping: 1)
        scale = Spring(1)
        alpha.to(1, response: 0.12, damping: 1)
    }

    mutating func rest(cleared: Bool) {
        guard cleared else {
            alpha = Spring(0)
            return
        }
        left.to(-width / 2, response: 0.35, damping: 1)
        scale.to(0.3, response: 0.3, damping: 1)
        alpha.to(0, response: 0.18, damping: 1)
    }

    mutating func step(_ dt: Double) {
        left.step(dt)
        scale.step(dt)
        alpha.step(dt)
    }

    var isSettled: Bool { left.isSettled() && scale.isSettled(0.002) && alpha.isSettled(0.002) }
}

/// A damped spring on one number: `response` is its undamped period, `damping` the fraction of critical.
struct Spring: Sendable {
    var value: Double
    var velocity = 0.0
    var target: Double
    var response: Double
    var damping: Double

    init(_ value: Double, response: Double = 0.5, damping: Double = 0.75) {
        self.value = value
        target = value
        self.response = response
        self.damping = damping
    }

    mutating func to(_ target: Double, response: Double? = nil, damping: Double? = nil) {
        self.target = target
        if let response { self.response = response }
        if let damping { self.damping = damping }
    }

    /// Two semi-implicit Euler steps: stable for the stiffest spring a form uses.
    mutating func step(_ dt: Double) {
        let k = pow(2 * .pi / response, 2), c = 4 * .pi * damping / response, h = dt / 2
        for _ in 0..<2 {
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
        }
    }

    /// Put there, moving at `velocity`, with nowhere else to go.
    mutating func place(_ value: Double, velocity: Double) {
        self.value = value
        self.velocity = velocity
        target = value
    }

    func isSettled(_ tolerance: Double = 0.05) -> Bool {
        abs(value - target) < tolerance && abs(velocity) < tolerance * 10
    }
}

/// From one value to another over a Bézier curve, from a start time.
struct Tween<Value: Interpolable>: Sendable {
    var from: Value
    var to: Value
    var start: Double
    var duration: Double
    var curve: DockMotion.Curve

    init(_ value: Value, at time: Double) {
        self.init(from: value, to: value, at: time, nil)
    }

    init(from: Value, to: Value, at time: Double, _ timing: FormTiming?) {
        self.from = timing == nil ? to : from
        self.to = to
        start = time
        duration = timing?.duration ?? 0
        curve = timing?.curve ?? DockMotion.slideCurve
    }

    var end: Double { start + duration }

    func value(at time: Double) -> Value {
        guard duration > 0, time < end else { return to }
        return from.interpolated(to: to, by: curve.progress(at: max(0, time - start) / duration))
    }
}

protocol Interpolable: Sendable {
    func interpolated(to other: Self, by t: Double) -> Self
}

extension Double: Interpolable {
    func interpolated(to other: Double, by t: Double) -> Double { self + (other - self) * t }
}

extension DockMotion.Curve {
    /// The curve's progress at `x` of the way through its time, as Core Animation evaluates it.
    func progress(at x: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        // Solve x(s) = x for the curve's parameter by bisection, then read y(s).
        func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - s) * (1 - s) * s * p1 + 3 * (1 - s) * s * s * p2 + s * s * s
        }
        var low = 0.0, high = 1.0
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if bezier(mid, x1, x2) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, y1, y2)
    }
}
