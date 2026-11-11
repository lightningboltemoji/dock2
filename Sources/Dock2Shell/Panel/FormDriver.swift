import AppKit
import Dock2Core

/// What rides the glass of a screen laid out for the panel at `rest`, under a scope's bar `head` past the ground's rim
/// (`ScreenRide`).
struct ScreenRiders {
    var rest: CGRect
    var head: CGFloat = 0
    var leading, trailing, room, pane, contents, scope: CALayer?
    /// What the scope shows within: from the pane's top up as the glass moves, so it comes out from behind it; from the
    /// field's at rest, for its menu.
    var scopeCut: CALayer?

    var layers: [CALayer] { [leading, trailing, room, pane, contents, scope].compactMap { $0 } }
}

/// Plays the panel's motion and its field's form (`FieldMotion`) on the glass, shadow, clips, rows' reveal, what
/// rides the glass, gem faces and field. Sampled ahead at each change and handed to the window server as keyframes,
/// so a busy main thread never stalls it; resting, it loops, or holds still.
@MainActor
final class FormDriver {
    let form: FieldForm
    private let glass: GlassView
    /// Grown, the glass over what grew, and the solid ground beneath it and the field's glass (`PanelMetrics.layering`).
    private let pane: GlassView
    private let ground: PanelGround
    private let field: FieldView
    private let shadow: PanelShadow
    private let clip: CALayer
    /// The rows' mask, from the field's top-left: kept to the body's width.
    private let rows: CALayer
    /// Search's rows, their selection let down to the ground.
    private let results: RowsView
    /// Within it, the rows the glass covers yet, from the field up.
    private let reveal: CALayer
    /// Rides the glass's top edge, never below the field's: the feedback's anchor.
    private let above: NSView
    private let faces: GemFaces
    /// In the panel's coordinates: what the form's own are from.
    private let fieldFrame: CGRect
    /// The motion as it was at the last change, and when its rest loop takes over, if it rests.
    private var baked: FieldMotion
    private var loopsFrom: CFTimeInterval?
    /// The screen showing, or leaving: played with the glass from the next change on.
    var riders: ScreenRiders? {
        didSet {
            oldValue?.layers.forEach { $0.stopKeyframes(["transform"]) }
            oldValue?.scopeCut?.stopKeyframes(["position"])
        }
    }
    /// Cleared at once, the text plays as a ghost of what was cleared through every change until a letter comes.
    private var ghosted = false

    init(form: FieldForm, glass: GlassView, pane: GlassView, ground: PanelGround, field: FieldView, shadow: PanelShadow, clip: CALayer, rows: CALayer,
         results: RowsView, reveal: CALayer, above: NSView, faces: GemFaces, fieldFrame: CGRect, target: CGRect, resting: Bool) {
        let motion = FieldMotion(form: form, field: fieldFrame.size, target: Self.relative(target, to: fieldFrame),
                                 time: CACurrentMediaTime(), resting: resting, reduceMotion: DisplayOptions.reduceMotion)
        self.form = form
        self.glass = glass
        self.pane = pane
        self.ground = ground
        self.field = field
        self.shadow = shadow
        self.clip = clip
        self.rows = rows
        self.results = results
        self.reveal = reveal
        self.above = above
        self.faces = faces
        self.fieldFrame = fieldFrame
        baked = motion
    }

    var isResting: Bool { baked.isResting }

    /// Puts it in place, risen in from below when `arriving`.
    func start(arriving: Bool) {
        change { if arriving { $0.arrive(over: FormTiming(Motion.rise)) } }
    }

    /// The body as the panel wants it — the field, or the panel grown from it, a scope's bar `head` past its rim — at
    /// once, or growing to it; its ground fading in or out unless not `fading` (`FieldMotion.setTarget`).
    func setTarget(_ shape: GlassLayer.Shape, head: CGFloat, animated: Bool, fading: Bool) {
        let rect = Self.relative(shape.frame, to: fieldFrame)
        guard rect != baked.target || head != baked.headTarget else { return }
        change { $0.setTarget(rect, head: head, animated: animated, fading: fading) }
    }

    /// The capsule rests with its placeholder showing: emptied, nothing is carried away.
    private var isCapsule: Bool { form == .capsule }

    func pour() {
        guard baked.isResting else { return }
        ghosted = false
        change { [field] in $0.pour(textWidth: field.textWidth) }
    }

    func rest(cleared: Bool) {
        guard !baked.isResting else { return }
        ghosted = cleared && !isCapsule
        change { $0.rest(cleared: cleared) }
    }

    /// A letter more in the field.
    func typed() {
        change { [field] in $0.type(textWidth: field.textWidth) }
    }

    /// Sinks it back the way it came, over `motion`, staying as solid as it is if `solid`.
    func leave(over motion: Motion, solid: Bool) {
        change(for: motion.duration) { $0.leave(over: FormTiming(motion), solid: solid) }
    }

    /// The same motion again, from now: the glass's tree was built again, losing what it played.
    func replay() {
        change { _ in }
    }

    /// Leaves everything where the motion last put it, no longer moving.
    func stop() {
        riders = nil
        glass.stopPlaying()
        pane.stopPlaying()
        ground.stopPlaying()
        shadow.stopPlaying()
        clip.stopKeyframes(["bounds", "position", "cornerRadius"])
        rows.stopKeyframes(["bounds", "position"])
        reveal.stopKeyframes(["bounds"])
        above.layer?.stopKeyframes(["transform"])
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
        if let loopsFrom, time >= loopsFrom {
            return FieldMotion.resting(form, field: fieldFrame.size, target: baked.target, at: time)
        }
        var motion = baked
        motion.advance(to: time)
        return motion
    }

    /// Applies `event` to the motion as it is now, then plays what follows: until it settles, or for `horizon`
    /// at most; resting, for long enough that what it rested from dies away, then its loop. Everything it plays
    /// reaches the screen at once.
    private func change(for horizon: Double? = nil, _ event: (inout FieldMotion) -> Void) {
        Motion.together { bake(for: horizon, event) }
    }

    private func bake(for horizon: Double?, _ event: (inout FieldMotion) -> Void) {
        let now = CACurrentMediaTime()
        var motion = self.motion(at: now)
        event(&motion)
        baked = motion
        let step = 1 / FieldMotion.sampleRate
        var frames = [motion.frame], time = now
        let end = now + (horizon ?? 4), calm = motion.isResting ? now + 3 : now
        while time < end, !motion.isSettled || time < calm {
            time += step
            motion.advance(to: time)
            frames.append(motion.frame)
        }
        // Only a form that has come to rest takes up the rest's loop; one waiting on the panel holds where it is.
        let loops = motion.hasRested && motion.loopsAtRest && horizon == nil
        loopsFrom = loops ? time : nil
        let loop = loops ? Keyframes<FormFrame>.Loop(values: restLoop(), step: 1 / FieldMotion.loopRate,
                                                     offset: time.truncatingRemainder(dividingBy: FieldMotion.period)) : nil
        play(Keyframes(values: frames, step: step, begin: now, loop: loop))
    }

    /// One period of each rest, from time zero, by form and field: the same for every showing, so worked out once.
    private static var loops: [String: [FormFrame]] = [:]

    private func restLoop() -> [FormFrame] {
        let key = "\(form) \(fieldFrame.size) \(baked.target)"
        if let loop = Self.loops[key] { return loop }
        var motion = FieldMotion.resting(form, field: fieldFrame.size, target: baked.target, at: 0)
        let count = Int(FieldMotion.period * FieldMotion.loopRate)
        let frames = (0..<count).map { index -> FormFrame in
            motion.advance(to: Double(index) / FieldMotion.loopRate)
            return motion.frame
        }
        Self.loops[key] = frames
        return frames
    }

    private func play(_ track: Keyframes<FormFrame>) {
        let origin = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        // The clear glass in the body's place, drawn in over the ground as it comes; the form's own shapes as they are.
        let layered = track.map { frame -> (body: GlassLayer.Shape, glass: [GlassLayer.Shape], layering: PanelMetrics.Layering) in
            let shapes = frame.shapes.map { Self.glassShape($0, from: origin) }
            let layering = PanelMetrics.layering(body: shapes[0].frame, radius: shapes[0].cornerRadius, fieldHeight: fieldFrame.height,
                                                 ground: frame.ground, head: frame.head)
            guard layering.ground > 0 else { return (shapes[0], shapes, layering) }
            let clear = GlassLayer.Shape(frame: layering.clear, cornerRadius: layering.clearRadius, curve: shapes[0].curve)
            return (shapes[0], [clear] + shapes.dropFirst(), layering)
        }
        let body = layered.map(\.body)
        let layering = layered.map(\.layering)
        glass.play(layered.map(\.glass))
        glass.playLens(track.map(\.lens))
        // Grown, the clear glass gives way to the ground, the field's strip of it bare, a bar apart from the pane.
        glass.playOpacity(layering.map { 1 - $0.ground })
        pane.play(layering.map { [GlassLayer.Shape(frame: $0.pane, cornerRadius: $0.paneRadius, curve: .continuous)] })
        pane.playOpacity(layering.map(\.ground))
        ground.play(body, solidity: layering.map(\.ground))
        results.playGround(layering.map(\.ground))
        shadow.play(body)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.bounds = CGRect(origin: .zero, size: body.last.frame.size)
        clip.position = CGPoint(x: body.last.frame.midX, y: body.last.frame.midY)
        clip.cornerRadius = min(body.last.cornerRadius, body.last.frame.height / 2)
        clip.cornerCurve = body.last.curve
        CATransaction.commit()
        // The rows sit on the pane, from its left edge grown; their bounds keep their own origin under the mask's left
        // edge, so what it holds stays put.
        let span = layering.map { (x: $0.pane.minX - fieldFrame.minX - PanelMetrics.paneInset, width: $0.pane.width) }
        Motion.perform(nil) {
            rows.bounds = CGRect(x: span.last.x, y: 0, width: span.last.width, height: RowsView.unbounded)
            rows.position = CGPoint(x: span.last.x, y: 0)
        }
        span.play(on: rows, "bounds") { NSValue(rect: CGRect(x: $0.x, y: 0, width: $0.width, height: RowsView.unbounded)) }
        span.play(on: rows, "position") { NSValue(point: CGPoint(x: $0.x, y: 0)) }
        // As wide as anything the mask lets through; as high as the pane reaches above the field.
        let covered = layering.map { CGRect(x: 0, y: 0, width: RowsView.unbounded, height: max(0, $0.pane.maxY - fieldFrame.maxY)) }
        Motion.perform(nil) { reveal.bounds = covered.last }
        covered.play(on: reveal, "bounds") { NSValue(rect: $0) }
        // Its frame where the glass's top comes to rest, so a confirmation's buttons are clicked there; its transform the way.
        let top = body.map { max(fieldFrame.maxY, $0.frame.maxY) }
        if let surface = above.superview {
            above.frame = CGRect(x: 0, y: top.last, width: surface.bounds.width, height: max(0, surface.bounds.height - top.last))
        }
        if let layer = above.layer {
            top.play(on: layer, "transform") { [rest = top.last] in NSValue(caTransform3D: CATransform3DMakeTranslation(0, $0 - rest, 0)) }
        }
        body.play(on: clip, "bounds") { NSValue(rect: CGRect(origin: .zero, size: $0.frame.size)) }
        body.play(on: clip, "position") { NSValue(point: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        body.play(on: clip, "cornerRadius") { NSNumber(value: Double(min($0.cornerRadius, $0.frame.height / 2))) }
        if let riders { ride(riders, on: track.map { (Self.glassShape($0.body, from: origin).frame, $0.head) }) }
        if let cut = riders?.scopeCut {
            var tops = layering.map { CGPoint(x: 0, y: $0.pane.maxY) }
            tops.values[tops.values.count - 1] = CGPoint(x: 0, y: fieldFrame.maxY)
            Motion.perform(nil) { cut.position = tops.last }
            tops.play(on: cut, "position") { NSValue(point: $0) }
        }
        if form == .gem { faces.play(track.map(\.faces), within: body, origin: origin) }
        field.play(glyph: track.map(\.glyph), text: track.map(\.text), trailing: track.map(\.trailing),
                   textWidth: field.textWidth, ghosted: ghosted)
        // At rest only the form takes clicks, not the rest of the field around it: the capsule's body, or a form's middle.
        let centre = CGPoint(x: fieldFrame.width / 2, y: fieldFrame.height / 2)
        let resting = isCapsule ? baked.frame.shapes.first.map { $0.frame.offsetBy(dx: centre.x, dy: centre.y) }
                                : CGRect(x: centre.x - 48, y: centre.y - 48, width: 96, height: 96)
        field.hitArea = baked.isResting ? resting : nil
    }

    /// Each part of the screen where the body and its scope's bar put it, moment by moment.
    private func ride(_ riders: ScreenRiders, on body: Keyframes<(frame: CGRect, head: Double)>) {
        let track = body.map { ScreenRide(body: $0.frame, rest: riders.rest, head: $0.head, restHead: riders.head) }
        let parts: [(CALayer?, (ScreenRide) -> CGPoint)] = [(riders.leading, \.leading), (riders.trailing, \.trailing), (riders.room, \.room),
                                                            (riders.pane, \.pane), (riders.contents, \.contents), (riders.scope, \.scope)]
        for (layer, offset) in parts {
            guard let layer else { continue }
            track.play(on: layer, "transform") {
                let at = offset($0)
                return NSValue(caTransform3D: CATransform3DMakeTranslation(at.x, at.y, 0))
            }
        }
    }

    private static func glassShape(_ shape: FormShape, from origin: CGPoint) -> GlassLayer.Shape {
        GlassLayer.Shape(frame: shape.frame.offsetBy(dx: origin.x, dy: origin.y), cornerRadius: shape.cornerRadius,
                         curve: shape.continuous ? .continuous : .circular)
    }
}

extension FormTiming {
    init(_ motion: Motion) {
        self.init(motion.duration, motion.curve)
    }
}
