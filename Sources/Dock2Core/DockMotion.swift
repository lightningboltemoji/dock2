import Foundation

/// The system Dock's motion, measured off recordings of it at 60 frames a second.
public enum DockMotion {
    /// A cubic Bézier timing curve's control points, as `CAMediaTimingFunction` takes them.
    public struct Curve: Sendable, Equatable {
        public var x1, y1, x2, y2: Double
    }

    /// Auto-hide's slide, in and out alike: a gentle ease at both ends.
    public static let slideDuration = 0.24
    public static let slideCurve = Curve(x1: 0.35, y1: 0.15, x2: 0.65, y2: 0.85)

    /// The platter widening or narrowing as tiles come and go, and tiles moving along it.
    public static let reshapeDuration = 0.36
    public static let reshapeCurve = slideCurve

    /// One launch hop, up and down: a parabola, the next one starting as the last lands.
    public static let hopPeriod = 0.7
    /// The hop's halves as Bézier curves: exact quadratic ease-out going up, ease-in coming down.
    public static let hopRise = Curve(x1: 1.0 / 3, y1: 2.0 / 3, x2: 2.0 / 3, y2: 1)
    public static let hopFall = Curve(x1: 1.0 / 3, y1: 0, x2: 2.0 / 3, y2: 1.0 / 3)

    /// From the pointer reaching the screen's bottom edge to the slide starting: 220 ms on screen for the
    /// system Dock, which these produce once dock2's own latency is added.
    public static let revealDelay = 0.19
    /// From the pointer leaving the dock's band to the slide out starting: 57 ms on screen.
    public static let hideDelay = 0.045
}
