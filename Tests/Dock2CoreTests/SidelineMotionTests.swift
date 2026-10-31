import Dock2Core
import Foundation
import Testing

@Suite struct SidelineMotionTests {
    /// The closed form against the equation `Spring` steps and Core Animation's springs solve, stepped finely.
    @Test(arguments: [0.4, 0.75, 1, 1.6])
    func progressIsTheDampedSpringsStepResponse(_ damping: Double) {
        let spring = SidelineMotion.Spring(response: 0.5, damping: damping)
        let omega = 2 * Double.pi / spring.response, dt = 1e-5
        var value = 0.0, velocity = 0.0
        for step in 1...100_000 {
            velocity += (-omega * omega * (value - 1) - 2 * damping * omega * velocity) * dt
            value += velocity * dt
            if step % 5_000 == 0 { #expect(abs(spring.progress(at: Double(step) * dt) - value) < 1e-3, "at \(Double(step) * dt) s") }
        }
    }

    @Test func eachSpringStartsAtRestAndSettles() {
        for spring in [SidelineMotion.out, SidelineMotion.in] {
            #expect(spring.progress(at: 0) == 0)
            #expect(spring.progress(at: 0.001) < 1e-3)
            #expect(abs(spring.progress(at: 3) - 1) < 1e-4)
        }
    }

    /// What grows goes a little past and back; what shrinks never passes its place.
    @Test func outPassesALittleAndInNever() {
        let times = stride(from: 0.0, through: 2, by: 0.002)
        let outPeak = times.map(SidelineMotion.out.progress).max()!
        let inPeak = times.map(SidelineMotion.in.progress).max()!
        #expect(outPeak > 1.01 && outPeak < 1.08)
        #expect(inPeak <= 1)
    }

    /// The hop: from the row and back down to it, rising then falling, as high as it goes halfway across.
    @Test func theLiftIsOneHopOverTheWayAcross() throws {
        let lift = SidelineMotion.lift(on: SidelineMotion.out, rate: 120)
        let peak = try #require(lift.indices.max { lift[$0] < lift[$1] })
        #expect(lift.first == 0 && lift.last == 0)
        #expect(lift.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(lift[peak] > 0.99)
        #expect(zip(lift[..<peak], lift[1...peak]).allSatisfy { $0 <= $1 })
        #expect(zip(lift[peak...], lift[(peak + 1)...]).allSatisfy { $0 >= $1 })
        // Down by the time it first reaches its place, well before the spring settles.
        let arrival = Double(lift.count - 1) / 120
        #expect(SidelineMotion.out.progress(at: arrival) >= 0.999)
        #expect(arrival < SidelineMotion.out.response)
    }
}
