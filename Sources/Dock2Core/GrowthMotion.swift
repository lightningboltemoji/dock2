import CoreGraphics
import Foundation

/// How the panel grows to what it holds and shrinks back — results, a view, Files — and how its rows move
/// within it: dock2's own, on springs, so a change that comes mid-flight carries on at the speed it has.
/// Started from Spotlight's measured growth, about 235 ms out and 210 back.
public enum GrowthMotion {
    /// An edge moving out, as `Spring` takes it: a little past its place and back.
    public static let outResponse = 0.30
    public static let outDamping = 0.78
    /// An edge moving in: critically damped, and never past its place, so the panel never dips into the field.
    public static let inResponse = 0.22
    /// What the panel's rows fade over as they change in place (`RowsView`): out quicker than in, so two
    /// titles never read over each other.
    public static let rowFadeOut = 0.07
    public static let rowFadeIn = 0.12
    /// A row new to the panel rises this far into its place as it fades in.
    public static let rowRise = 4.0
    /// What a screen shows rides the glass from its first frame (`ScreenRide`), so it never waits for the glass to get
    /// there: its bar fades in at once, its contents just after, and both are gone before the glass is.
    public static let barFadeIn = 0.10
    public static let contentDelay = 0.05
    public static let contentFadeIn = 0.14
    public static let screenFadeOut = 0.10
    /// The ground coming in under the glass as the panel grows, and going as it shrinks back to the field: critically
    /// damped, on time of its own, so a long growth crossfades as slowly as a short one.
    public static let groundInResponse = 0.30
    public static let groundOutResponse = 0.22
}

/// How far what a screen shows stands from its place while the glass is at `body`, a scope's bar `head` past its rim, on
/// its way to or from `rest` and `restHead`. Each part keeps to the end of the glass it reads from: the bar's ends along
/// the foot, the contents from the pane's top left, coming out from behind its foot, and the scope from the top right.
public struct ScreenRide: Equatable, Sendable {
    public var leading, trailing: CGPoint
    /// What the leading end shows up to, within it: the trailing end, however near that has come.
    public var room: CGPoint
    /// The pane, down the screen: its foot stays on the field's top.
    public var pane: CGPoint
    /// The contents, within the pane.
    public var contents: CGPoint
    /// The scope, in its bar along the top.
    public var scope: CGPoint

    public init(body: CGRect, rest: CGRect, head: CGFloat = 0, restHead: CGFloat = 0) {
        let left = body.minX - rest.minX, foot = body.minY - rest.minY
        leading = CGPoint(x: left, y: foot)
        trailing = CGPoint(x: body.maxX - rest.maxX, y: foot)
        room = CGPoint(x: trailing.x - left, y: 0)
        pane = CGPoint(x: 0, y: foot)
        contents = CGPoint(x: left, y: (body.maxY - head) - (rest.maxY - restHead) - foot)
        scope = CGPoint(x: trailing.x, y: body.maxY - rest.maxY)
    }
}

/// The body as the panel asks for it, on its way there: each edge on a spring of its own (`GrowthMotion`), and a scope's
/// bar on the top edge's, so the pane beneath it holds still as the bar opens over it.
struct Growth: Sendable {
    private var left, bottom, right, top: Edge
    /// How far the pane's top stands below the ground's rim: a scope's bar past it, or none.
    private var head: Edge

    init(_ rect: CGRect, head: Double = 0) {
        left = Edge(rect.minX, out: -1)
        bottom = Edge(rect.minY, out: -1)
        right = Edge(rect.maxX, out: 1)
        top = Edge(rect.maxY, out: 1)
        self.head = Edge(head, out: 1)
    }

    var value: CGRect { Self.rect(left.spring.value, bottom.spring.value, right.spring.value, top.spring.value) }
    var target: CGRect { Self.rect(left.spring.target, bottom.spring.target, right.spring.target, top.spring.target) }
    var headValue: Double { max(0, head.spring.value) }
    var headTarget: Double { head.spring.target }
    private var edges: [Edge] { [left, bottom, right, top, head] }
    var isSettled: Bool { edges.allSatisfy { $0.spring.isSettled() } }

    /// Every edge within `tolerance` of its place.
    func isWithin(_ tolerance: Double) -> Bool {
        edges.allSatisfy { abs($0.spring.value - $0.spring.target) < tolerance }
    }

    /// Heads for `rect`, its scope's bar `head` past the rim, from where it is and as fast as it goes; there at once
    /// unless `animated`. The bar goes as the top edge goes, so a bar opening as the panel grows by it leaves the pane
    /// where it was.
    mutating func to(_ rect: CGRect, head: Double = 0, animated: Bool) {
        guard animated else { return self = Growth(rect, head: head) }
        left.to(rect.minX)
        bottom.to(rect.minY)
        right.to(rect.maxX)
        top.to(rect.maxY)
        self.head.to(head, outward: top.outward)
    }

    mutating func step(_ dt: Double) {
        left.step(dt)
        bottom.step(dt)
        right.step(dt)
        top.step(dt)
        head.step(dt)
    }

    private static func rect(_ minX: Double, _ minY: Double, _ maxX: Double, _ maxY: Double) -> CGRect {
        CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private struct Edge: Sendable {
        var spring: Spring
        /// Which way is out: -1 for the left and bottom edges, 1 for the right and top.
        let out: Double
        var outward = false

        init(_ value: Double, out: Double) {
            spring = Spring(value)
            self.out = out
        }

        mutating func to(_ target: Double) {
            to(target, outward: (target - spring.value) * out > 0)
        }

        mutating func to(_ target: Double, outward: Bool) {
            self.outward = outward
            spring.to(target, response: outward ? GrowthMotion.outResponse : GrowthMotion.inResponse,
                      damping: outward ? GrowthMotion.outDamping : 1)
        }

        mutating func step(_ dt: Double) {
            let before = spring.value - spring.target
            spring.step(dt)
            // Coming in fast enough to pass its place, it stops there instead.
            if !outward, before * (spring.value - spring.target) < 0 {
                spring.value = spring.target
                spring.velocity = 0
            }
        }
    }
}
