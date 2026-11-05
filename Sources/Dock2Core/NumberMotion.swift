import Foundation

/// How a tile's number comes out of its dot and goes back: dock2's own, tuned by eye against recordings.
public enum NumberMotion {
    /// Up out of the dot, a little past its place and its size and back.
    public static let rise = SidelineMotion.Spring(response: 0.32, damping: 0.5)
    /// Back into the dot: critically damped, so it goes straight in.
    public static let fall = SidelineMotion.Spring(response: 0.2, damping: 1)
    /// Its size at the dot, of its own: shorter than the dot, so it starts inside it.
    public static let dotScale = 0.3
    /// How fast the number shows as it leaves the dot, and the dot goes.
    public static let leave = 0.08
    /// How long the number takes to go as it lands on the dot, and the dot to come back, late in the fade.
    public static let land = 0.2
    public static let landCurve = DockMotion.Curve(x1: 0.7, y1: 0, x2: 1, y2: 0.6)
}
