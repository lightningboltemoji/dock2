import CoreGraphics
import Dock2Core
import Dock2TOML
import Testing

@Suite struct FieldFormTests {
    static let field = CGSize(width: 640, height: 57)
    static let capsule = CGRect(x: -320, y: -28.5, width: 640, height: 57)
    static let forms: [FieldForm] = [.drop, .gem, .lavaLamp]

    private func resting(_ form: FieldForm, at time: Double) -> FieldMotion {
        FieldMotion.resting(form, field: Self.field, target: Self.capsule, at: time)
    }

    private func close(_ a: CGRect, _ b: CGRect, within tolerance: Double = 0.5) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    /// The capsule is the panel's own motion alone: the field, emptied or not.
    @Test func theCapsuleStaysTheField() {
        var motion = FieldMotion(form: .capsule, field: Self.field, target: Self.capsule, time: 0, resting: true)
        #expect(!motion.isResting && motion.isSettled)
        motion.rest(cleared: true)
        motion.advance(to: 1)
        let frame = motion.frame
        #expect(!motion.isResting && frame.shapes.count == 1 && close(frame.body.frame, Self.capsule))
        #expect(frame.text.offset == .zero && frame.text.alpha == 1 && frame.glyph.offset == .zero)
    }

    /// The top of a capsule's body, `grown` from it at time 0, at each of `times`.
    private func tops(growing grown: CGRect, at times: [Double], retarget: (time: Double, rect: CGRect)? = nil) -> [Double] {
        var motion = FieldMotion(form: .capsule, field: Self.field, target: Self.capsule, time: 0, resting: false)
        motion.setTarget(grown, animated: true)
        var retarget = retarget
        return times.map { time in
            if let change = retarget, time >= change.time {
                motion.advance(to: change.time)
                motion.setTarget(change.rect, animated: true)
                retarget = nil
            }
            motion.advance(to: time)
            return motion.frame.body.frame.maxY
        }
    }

    private static func grown(by extent: Double) -> CGRect {
        CGRect(x: -320, y: -28.5, width: 640, height: 57 + extent)
    }

    /// Growing, the panel goes a little past what it holds and settles back.
    @Test func itGrowsALittlePast() {
        let times = stride(from: 0.0, through: 1, by: 1.0 / 240).map { $0 }
        let target = Self.grown(by: 410).maxY
        let peak = tops(growing: Self.grown(by: 410), at: times).max()!
        #expect(peak > target + 2 && peak < target + 12)
        let at = tops(growing: Self.grown(by: 410), at: [0.05, 0.1, 0.24, 1])
        // Quicker off the mark than the Dock's slide, there by Spotlight's 235 ms, and settled.
        #expect(at[0] - 28.5 > 0.3 * 410 && at[1] - 28.5 > 0.6 * 410)
        #expect(abs(at[2] - target) < 12 && abs(at[3] - target) < 0.1)
    }

    /// A row more mid-flight carries on at the speed the panel has rather than starting again from rest.
    @Test func aChangeMidFlightKeepsItsSpeed() {
        let step = 1.0 / 240, at = 0.06
        let times = [at - step, at, at + step]
        let straight = tops(growing: Self.grown(by: 300), at: times)
        let changed = tops(growing: Self.grown(by: 300), at: times, retarget: (at, Self.grown(by: 356)))
        let before = (straight[1] - straight[0]) / step, after = (changed[2] - changed[1]) / step
        #expect(before > 1000)
        #expect(abs(after - before) / before < 0.1)
    }

    /// Shrinking, it comes to the field and stops there, even turned back mid-flight.
    @Test func itNeverShrinksIntoTheField() {
        var motion = FieldMotion(form: .capsule, field: Self.field, target: Self.capsule, time: 0, resting: false)
        motion.setTarget(Self.grown(by: 410), animated: true)
        motion.advance(to: 0.1)
        motion.setTarget(Self.grown(by: 56), animated: true)
        var lowest = Double.infinity
        for (index, time) in stride(from: 0.1, through: 1.5, by: 1.0 / 240).enumerated() {
            if index == 20 { motion.setTarget(Self.capsule, animated: true) }
            motion.advance(to: time)
            lowest = min(lowest, motion.frame.body.frame.height)
        }
        #expect(lowest >= 57 - 1e-9)
        #expect(close(motion.frame.body.frame, Self.capsule, within: 0.1))
    }

    @Test(arguments: forms) func pouredItSettlesIntoTheField(_ form: FieldForm) {
        var motion = resting(form, at: 3)
        motion.pour(textWidth: 14)
        var time = 3.0
        while !motion.isSettled, time < 8 {
            time += 1.0 / 60
            motion.advance(to: time)
        }
        #expect(motion.isSettled)
        let frame = motion.frame
        #expect(close(frame.body.frame, Self.capsule))
        // Whatever else there is has sunk inside the field, clear of its edge.
        for shape in frame.shapes.dropFirst() {
            #expect(frame.body.frame.insetBy(dx: -0.5, dy: -0.5).contains(shape.frame))
        }
        #expect(abs(frame.text.offset.x) < 0.5 && abs(frame.text.alpha - 1) < 0.01)
        #expect(abs(frame.glyph.offset.x) < 0.5 && abs(frame.glyph.alpha - 1) < 0.01)
        #expect(frame.faces.allSatisfy { $0.alpha < 0.01 })
    }

    @Test(arguments: forms) func atRestItIsSmallAndInTheMiddle(_ form: FieldForm) {
        for time in stride(from: 0.0, to: 24, by: 0.7) {
            let frame = resting(form, at: time).frame
            for shape in frame.shapes {
                #expect(CGRect(x: -80, y: -80, width: 160, height: 160).contains(shape.frame))
            }
            #expect(frame.text.alpha < 0.01)
        }
    }

    @Test(arguments: forms) func theRestRepeatsEveryPeriod(_ form: FieldForm) {
        for time in [1.3, 9.0, 17.25] {
            let a = resting(form, at: time).frame, b = resting(form, at: time + FieldMotion.period).frame
            for (x, y) in zip(a.shapes, b.shapes) { #expect(close(x.frame, y.frame, within: 0.01)) }
            for (x, y) in zip(a.faces, b.faces) {
                for (p, q) in zip(x.corners, y.corners) { #expect(hypot(p.x - q.x, p.y - q.y) < 0.01) }
            }
        }
    }

    /// What the loop shows is what the motion comes to: emptied, it rests into the loop without a seam.
    @Test(arguments: forms) func emptiedItComesToRestAsTheLoopDoes(_ form: FieldForm) {
        var motion = resting(form, at: 2)
        motion.pour(textWidth: 30)
        motion.advance(to: 3.5)
        motion.rest(cleared: true)
        motion.advance(to: 8)
        let loop = resting(form, at: 8).frame
        for (x, y) in zip(motion.frame.shapes, loop.shapes) { #expect(close(x.frame, y.frame, within: 0.05)) }
    }

    @Test(arguments: forms) func nothingJumpsWhenTheFieldFillsOrEmpties(_ form: FieldForm) {
        var motion = resting(form, at: 5)
        let before = motion.frame
        motion.pour(textWidth: 10)
        for (x, y) in zip(before.shapes, motion.frame.shapes) { #expect(close(x.frame, y.frame, within: 1e-6)) }
        motion.advance(to: 5.2)
        let poured = motion.frame
        motion.rest(cleared: false)
        for (x, y) in zip(poured.shapes, motion.frame.shapes) { #expect(close(x.frame, y.frame, within: 1e-6)) }
    }

    /// Poured from any moment of its rest, the glass fills the field and stops at its ends, and carries what the
    /// field holds inside it: the magnifier never ahead of the body's left end, heading only to its place and never
    /// past it, the text beside it.
    @Test(arguments: forms) func itPoursWithinTheField(_ form: FieldForm) {
        let glyphHome = Self.capsule.minX + PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2
        let gap = PanelMetrics.textLeft - PanelMetrics.glyphLeft - PanelMetrics.glyphSize / 2
        for phase in stride(from: 1.0, to: 24, by: 1.3) {
            var motion = resting(form, at: phase)
            motion.pour(textWidth: 14)
            var last = glyphHome + motion.frame.glyph.offset.x, rightward = 0.0
            for step in 1...360 {
                motion.advance(to: phase + Double(step) / 240)
                let frame = motion.frame, body = frame.body.frame
                for shape in frame.shapes {
                    #expect(shape.frame.minX >= Self.capsule.minX - 0.5 && shape.frame.maxX <= Self.capsule.maxX + 0.5)
                }
                let glyph = glyphHome + frame.glyph.offset.x, text = Self.capsule.minX + PanelMetrics.textLeft + frame.text.offset.x
                #expect(glyph >= glyphHome - 0.5)
                if frame.glyph.alpha > 0.01 {
                    #expect(glyph - PanelMetrics.glyphSize / 2 * frame.glyph.scale >= body.minX)
                    #expect(text >= glyph + gap - 1)
                }
                #expect(text >= body.minX + 24)
                rightward += max(0, glyph - last)
                last = glyph
            }
            #expect(rightward < 1)
        }
    }

    @Test(arguments: forms) func itGrowsWithThePanel(_ form: FieldForm) {
        var motion = resting(form, at: 0)
        motion.pour(textWidth: 12)
        motion.advance(to: 4)
        let grown = CGRect(x: -320, y: -28.5, width: 640, height: 357)
        motion.setTarget(grown, animated: true)
        motion.advance(to: 4.12)
        let midway = motion.frame.body
        #expect(midway.frame.height > 57 && midway.frame.height < 357)
        #expect(midway.continuous)
        motion.advance(to: 6)
        #expect(close(motion.frame.body.frame, grown))
    }

    /// Emptied with results showing, the panel shrinks back to the field before the field becomes the form.
    @Test(arguments: forms) func emptiedItShrinksBackFirst(_ form: FieldForm) {
        var motion = resting(form, at: 0)
        motion.pour(textWidth: 12)
        motion.setTarget(CGRect(x: -320, y: -28.5, width: 640, height: 357), animated: false)
        motion.advance(to: 4)
        motion.rest(cleared: true)
        motion.setTarget(Self.capsule, animated: true)
        #expect(motion.isResting)
        motion.advance(to: 4.2)
        #expect(motion.frame.body.frame.width > 630)
        motion.advance(to: 7)
        #expect(motion.frame.body.frame.width < 100)
    }

    @Test func theDropSplashesAsLettersLand() {
        var motion = resting(.drop, at: 0)
        motion.pour(textWidth: 12)
        motion.advance(to: 2)
        motion.type(textWidth: 26)
        motion.advance(to: 2.1)
        // A droplet clear above the field's top.
        #expect(motion.frame.shapes.contains { $0.frame.minY > 28.5 })
        motion.advance(to: 3)
        #expect(motion.frame.shapes.allSatisfy { $0.frame.maxY <= 28.5 + 0.5 })
    }

    @Test func itIsASetting() throws {
        for form in FieldForm.allCases {
            var document = try TOMLDocument("")
            for edit in Settings.fieldForm.edits(for: form) { try document.apply(edit) }
            #expect(Settings.read(document.table)[Settings.fieldForm] == form)
        }
        #expect(Settings.fieldForm.defaultValue == .drop)
    }
}
