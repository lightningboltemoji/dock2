import CoreGraphics
import Foundation

/// How dock2 comes on screen, its own rather than the system Dock's, and tuned by eye against recordings:
/// the tiles pop onto the platter as it slides in, in a wave along the row, and the field rises into place.
public enum EntryMotion {
    /// A spring, as `CASpringAnimation(perceptualDuration:bounce:)` takes it.
    public struct Spring: Sendable, Equatable {
        public var duration: Double
        public var bounce: Double
    }

    // MARK: - The tiles

    /// A tile grows from `popScale` of its size past it and settles, fading in over `popFade`.
    public static let popScale = 0.85
    public static let popSpring = Spring(duration: 0.45, bounce: 0.45)
    public static let popFade = 0.15
    /// The wave starts this share of the way through the platter's slide in, so the tiles pop as it lands
    /// rather than below the screen's edge.
    public static let popLead = 0.5

    /// How long the wave takes along the row: `waveBase`, and `waveStep` more for each tile it passes, so
    /// longer the more there are, though less from each to the next.
    static let waveBase = 0.12
    static let waveStep = 0.012

    /// When each item centred at `centres` starts to pop, for a wave from `origin` along a row of tiles
    /// `step` apart: the nearest at once, the farthest after `waveBase` and `waveStep` a tile.
    public static func waveDelays(_ centres: [Double], from origin: Double, step: Double) -> [Double] {
        let distances = centres.map { abs($0 - origin) }
        guard let nearest = distances.min(), let farthest = distances.max(), farthest > nearest, step > 0 else {
            return distances.map { _ in 0 }
        }
        let reach = farthest - nearest
        let duration = waveBase + waveStep * reach / step
        return distances.map { ($0 - nearest) / reach * duration }
    }

    // MARK: - The field

    /// The field starts `riseDistance` below its place at `riseScale` of its size.
    public static let riseDistance = 32.0
    public static let riseScale = 0.94
    public static let riseDuration = 0.36
    public static let riseCurve = DockMotion.Curve(x1: 0.2, y1: 0.8, x2: 0.2, y2: 1)
    /// Summoned with the dock away, the field rises this long after the dock starts in, out of it.
    public static let fieldLag = 0.1
    /// Dismissal plays the rise back, quicker, fading as it goes.
    public static let sinkDuration = 0.18
    public static let sinkCurve = DockMotion.Curve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)

    /// The field fades in over `fadeIn` while a wave spreads from its bottom centre, `fadeSpeed` points a
    /// second: whole behind the wave's front, `fadeEdge` soft, and `fadeFloor` of itself past it.
    public static let fadeIn = 0.15
    public static let fadeEdge = 160.0
    public static let fadeSpeed = 1800.0
    public static let fadeFloor = 0.5

    /// Where the field rises from: lower than `field`, and smaller about its centre.
    public static func riseStart(of field: CGRect) -> CGRect {
        let width = field.width * riseScale, height = field.height * riseScale
        return CGRect(x: field.midX - width / 2, y: field.midY - riseDistance - height / 2, width: width, height: height)
    }
}
