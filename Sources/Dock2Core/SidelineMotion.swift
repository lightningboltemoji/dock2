import Foundation

/// How an app crosses between the row and the puck, and how the puck buds, reflows and draws back: dock2's own,
/// on springs as the panel's growth is (`GrowthMotion`), where the row alone keeps the system Dock's reshape. Tuned
/// by eye against recordings.
public enum SidelineMotion {
    /// A damped spring, as `Spring` takes it: its undamped period, and its damping as a fraction of critical.
    public struct Spring: Sendable, Equatable {
        public var response: Double
        public var damping: Double

        public init(response: Double, damping: Double) {
            self.response = response
            self.damping = damping
        }

        /// How far a step from 0 to 1 has come `time` seconds after it starts from rest.
        public func progress(at time: Double) -> Double {
            guard time > 0 else { return 0 }
            let omega = 2 * .pi / response, zeta = damping
            if zeta < 1 {
                let damped = omega * (1 - zeta * zeta).squareRoot()
                return 1 - exp(-zeta * omega * time) * (cos(damped * time) + zeta * omega / damped * sin(damped * time))
            }
            if zeta == 1 { return 1 - exp(-omega * time) * (1 + omega * time) }
            let root = (zeta * zeta - 1).squareRoot(), fast = -omega * (zeta + root), slow = -omega * (zeta - root)
            return 1 + (fast * exp(slow * time) - slow * exp(fast * time)) / (slow - fast)
        }
    }

    /// Every move, and whatever grows — the puck budding, the platter widening, a tile flying back to the row: a
    /// little past its place and back.
    public static let out = Spring(response: 0.5, damping: 0.75)
    /// Whatever shrinks: critically damped, so nothing passes its size and the puck draws back into the platter whole.
    public static let `in` = Spring(response: 0.4, damping: 1)

    /// The crossing tile's lift as a share of a launch's hop, sampled `rate` times a second along its way on `spring`:
    /// a parabola over the way across, so it hops over the tiles between, down by the time it first reaches its place.
    public static func lift(on spring: Spring, rate: Double) -> [Double] {
        var lift: [Double] = []
        for sample in 0... {
            let progress = spring.progress(at: Double(sample) / rate)
            guard progress < 0.999 else { break }
            lift.append(4 * progress * (1 - progress))
        }
        return lift + [0]
    }
}
