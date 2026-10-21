import AppKit
import Dock2Core

/// Plays a field form (`FieldMotion`) on the panel's glass, shadow, clips and gem faces, and the field over
/// them. At every change the motion is sampled ahead and handed to the window server as keyframes, so a busy
/// main thread never stalls it; resting, it loops.
@MainActor
final class FormDriver {
    let form: FieldForm
    private let glass: GlassView
    private let field: FieldView
    private let shadow: PanelShadow
    private let clip: CALayer
    /// The rows' mask, from the field's top-left: kept to the body's width.
    private let rows: CALayer
    private let faces: GemFaces
    /// In the panel's coordinates: what the form's own are from.
    private let fieldFrame: CGRect
    /// The motion as it was at the last change, and when its rest loop takes over, if it rests.
    private var baked: FieldMotion
    private var loopsFrom: CFTimeInterval?
    /// One period of the rest, from time zero.
    private var loop: [FormFrame]?

    /// Keyframes a second while something happens, and while resting.
    private static let rate = 60.0
    private static let loopRate = 20.0

    init?(form: FieldForm, glass: GlassView, field: FieldView, shadow: PanelShadow, clip: CALayer, rows: CALayer,
          faces: GemFaces, fieldFrame: CGRect, target: CGRect, resting: Bool) {
        guard let motion = FieldMotion(form: form, field: fieldFrame.size, target: Self.relative(target, to: fieldFrame),
                                       time: CACurrentMediaTime(), resting: resting) else { return nil }
        self.form = form
        self.glass = glass
        self.field = field
        self.shadow = shadow
        self.clip = clip
        self.rows = rows
        self.faces = faces
        self.fieldFrame = fieldFrame
        baked = motion
        glass.setLensed(resting)
    }

    var isResting: Bool { baked.isResting }

    /// Puts it in place, risen in from below when `arriving`.
    func start(arriving: Bool) {
        change { if arriving { $0.arrive(over: FormTiming(Motion.rise)) } }
    }

    /// The body as the panel wants it — the field, or the panel grown from it — at once or over `motion`.
    func setTarget(_ shape: GlassLayer.Shape, motion: Motion?) {
        let rect = Self.relative(shape.frame, to: fieldFrame)
        guard rect != baked.target else { return }
        change { $0.setTarget(rect, over: motion.map(FormTiming.init)) }
    }

    func pour() {
        guard baked.isResting else { return }
        change { [field] in $0.pour(textWidth: field.textWidth) }
        glass.setLensed(false, motion: .slide)
    }

    func rest(cleared: Bool) {
        guard !baked.isResting else { return }
        change(ghosted: cleared) { $0.rest(cleared: cleared) }
        glass.setLensed(true, motion: .slide)
    }

    /// A letter more in the field.
    func typed() {
        change { [field] in $0.type(textWidth: field.textWidth) }
    }

    /// Sinks it back the way it came, over `motion`.
    func leave(over motion: Motion) {
        change(for: motion.duration) { $0.leave(over: FormTiming(motion)) }
    }

    /// The same motion again, from now: the glass's tree was built again, losing what it played.
    func replay() {
        change { _ in }
    }

    /// Leaves everything where the motion last put it, no longer moving.
    func stop() {
        glass.stopPlaying()
        shadow.stopPlaying()
        clip.stopKeyframes(["bounds", "position", "cornerRadius"])
        rows.stopKeyframes(["bounds", "position"])
        faces.stop()
        field.stopPlaying()
        field.hitArea = nil
        loopsFrom = nil
    }

    // MARK: - Baking

    private static func relative(_ rect: CGRect, to field: CGRect) -> CGRect {
        rect.offsetBy(dx: -field.midX, dy: -field.midY)
    }

    /// Where the motion is at `time`: carried on from the last change, or in its loop.
    private func motion(at time: CFTimeInterval) -> FieldMotion {
        if let loopsFrom, time >= loopsFrom,
           let resting = FieldMotion.resting(form, field: fieldFrame.size, target: baked.target, at: time) {
            return resting
        }
        var motion = baked
        motion.advance(to: time)
        return motion
    }

    /// Applies `event` to the motion as it is now, then plays what follows: until it settles, or for `horizon`
    /// at most; resting, for long enough that what it rested from dies away, then its loop.
    private func change(for horizon: Double? = nil, ghosted: Bool = false, _ event: (inout FieldMotion) -> Void) {
        let now = CACurrentMediaTime()
        var motion = self.motion(at: now)
        event(&motion)
        baked = motion
        let step = 1 / Self.rate
        var frames = [motion.frame], time = now
        let end = now + (horizon ?? 4), calm = motion.isResting ? now + 3 : now
        while time < end, !motion.isSettled || time < calm {
            time += step
            motion.advance(to: time)
            frames.append(motion.frame)
        }
        let loops = motion.isResting && horizon == nil
        loopsFrom = loops ? time : nil
        let loop = loops ? restLoop().map { Keyframes<FormFrame>.Loop(values: $0, step: 1 / Self.loopRate,
                                                                       offset: time.truncatingRemainder(dividingBy: FieldMotion.period)) } : nil
        play(Keyframes(values: frames, step: step, begin: now, loop: loop), ghosted: ghosted)
    }

    private func restLoop() -> [FormFrame]? {
        if let loop { return loop }
        guard var motion = FieldMotion.resting(form, field: fieldFrame.size, target: baked.target, at: 0) else { return nil }
        let count = Int(FieldMotion.period * Self.loopRate)
        let frames = (0..<count).map { index -> FormFrame in
            motion.advance(to: Double(index) / Self.loopRate)
            return motion.frame
        }
        loop = frames
        return frames
    }

    private func play(_ track: Keyframes<FormFrame>, ghosted: Bool) {
        let origin = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        let shapes = track.map { $0.shapes.map { Self.glassShape($0, from: origin) } }
        let body = shapes.map { $0[0] }
        glass.play(shapes)
        shadow.play(body)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.bounds = CGRect(origin: .zero, size: body.last.frame.size)
        clip.position = CGPoint(x: body.last.frame.midX, y: body.last.frame.midY)
        clip.cornerRadius = min(body.last.cornerRadius, body.last.frame.height / 2)
        clip.cornerCurve = body.last.curve
        CATransaction.commit()
        // The rows' bounds keep their own origin under the mask's left edge, so what it holds stays put.
        let span = body.map { (x: $0.frame.minX - fieldFrame.minX, width: $0.frame.width) }
        Motion.perform(nil) {
            rows.bounds = CGRect(x: span.last.x, y: 0, width: span.last.width, height: RowsView.unbounded)
            rows.position = CGPoint(x: span.last.x, y: 0)
        }
        span.play(on: rows, "bounds") { NSValue(rect: CGRect(x: $0.x, y: 0, width: $0.width, height: RowsView.unbounded)) }
        span.play(on: rows, "position") { NSValue(point: CGPoint(x: $0.x, y: 0)) }
        body.play(on: clip, "bounds") { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }
        body.play(on: clip, "position") { NSValue(point: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        body.play(on: clip, "cornerRadius") { NSNumber(value: Double(min($0.cornerRadius, $0.frame.height / 2))) }
        if form == .gem { faces.play(track.map(\.faces), within: body, origin: origin) }
        field.play(glyph: track.map(\.glyph), text: track.map(\.text), trailing: track.map(\.trailing),
                   textWidth: field.textWidth, ghosted: ghosted)
        // At rest only the form takes clicks, not the rest of the field around it.
        field.hitArea = baked.isResting ? CGRect(x: fieldFrame.width / 2 - 48, y: fieldFrame.height / 2 - 48, width: 96, height: 96) : nil
    }

    private static func glassShape(_ shape: FormShape, from origin: CGPoint) -> GlassLayer.Shape {
        GlassLayer.Shape(frame: shape.frame.offsetBy(dx: origin.x, dy: origin.y), cornerRadius: shape.cornerRadius,
                         curve: shape.continuous ? .continuous : .circular, rotation: shape.rotation)
    }
}

extension FormTiming {
    init(_ motion: Motion) {
        self.init(motion.duration, motion.curve)
    }
}
