import CoreGraphics
import Dock2Core
import Testing

@Suite struct EntryMotionTests {
    @Test func theWaveStartsAtTheNearestTileAndSpreadsBothWays() {
        let delays = EntryMotion.waveDelays([50, 150, 250, 350, 450], from: 260, step: 100)
        #expect(delays[2] == 0)
        #expect(delays[1] < delays[0] && delays[3] < delays[4])
        // 140 and 160 from the origin: the nearer starts first, whichever side it is on.
        #expect(delays[3] < delays[1])
    }

    @Test func aLongerRowTakesLongerThoughLessATile() {
        let short = EntryMotion.waveDelays([0, 100, 200, 300], from: 0, step: 100).last!
        let long = EntryMotion.waveDelays(Array(stride(from: 0.0, through: 1500, by: 100)), from: 0, step: 100).last!
        #expect(long > short)
        #expect(long / 15 < short / 3)
    }

    @Test func oneTileStartsAtOnce() {
        #expect(EntryMotion.waveDelays([120], from: 900, step: 100) == [0])
        #expect(EntryMotion.waveDelays([], from: 0, step: 100) == [])
    }

    @Test func theFieldRisesFromBelowAndSmaller() {
        let field = CGRect(x: 100, y: 200, width: 640, height: 57)
        let start = EntryMotion.riseStart(of: field)
        #expect(start.midX == field.midX)
        #expect(abs(start.midY - (field.midY - EntryMotion.riseDistance)) < 1e-9)
        #expect(start.width < field.width && start.height < field.height)
    }
}
