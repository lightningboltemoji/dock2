import CoreGraphics
import Dock2Core
import Testing

@Suite struct FieldFormTests {
    static let field = CGSize(width: 640, height: 57)
    static let capsule = CGRect(x: -320, y: -28.5, width: 640, height: 57)
    static let forms: [FieldForm] = [.drop, .gem, .lavaLamp]

    private func resting(_ form: FieldForm, at time: Double) -> FieldMotion {
        FieldMotion.resting(form, field: Self.field, target: Self.capsule, at: time)!
    }

    private func close(_ a: CGRect, _ b: CGRect, within tolerance: Double = 0.5) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance
            && abs(a.height - b.height) < tolerance
    }

    @Test func theCapsuleHasNoForm() {
        #expect(FieldMotion(form: .capsule, field: Self.field, target: Self.capsule, time: 0, resting: true) == nil)
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

    @Test(arguments: forms) func theTextNeverLeadsTheGlass(_ form: FieldForm) {
        var motion = resting(form, at: 1)
        motion.pour(textWidth: 12)
        for step in 1...90 {
            motion.advance(to: 1 + Double(step) / 60)
            let frame = motion.frame
            let left = frame.shapes.map(\.frame.minX).min()!
            let text = Self.capsule.minX + PanelMetrics.textLeft + frame.text.offset.x
            #expect(text >= left + 24 - 1e-6)
        }
    }

    @Test(arguments: forms) func itGrowsWithThePanel(_ form: FieldForm) {
        var motion = resting(form, at: 0)
        motion.pour(textWidth: 12)
        motion.advance(to: 4)
        let grown = CGRect(x: -320, y: -28.5, width: 640, height: 357)
        motion.setTarget(grown, over: FormTiming(0.24, DockMotion.slideCurve))
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
        motion.setTarget(CGRect(x: -320, y: -28.5, width: 640, height: 357), over: nil)
        motion.advance(to: 4)
        motion.rest(cleared: true)
        motion.setTarget(Self.capsule, over: FormTiming(0.24, DockMotion.slideCurve))
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

    @Test func itIsASetting() {
        for form in FieldForm.allCases { #expect(FieldForm(propertyList: form.propertyList) == form) }
        #expect(Settings.fieldForm.defaultValue == .drop)
    }
}
