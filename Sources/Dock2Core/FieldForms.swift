import CoreGraphics
import Foundation

/// The rest's own slow motions repeat within `FieldMotion.period`: a whole number of cycles of this.
private let cycle = 2 * Double.pi / FieldMotion.period

// MARK: - The capsule

/// Spotlight's field, empty or not: the body is the panel's own, the magnifier in its place.
struct CapsuleSim: FormSim {
    var isResting: Bool { false }
    var isSettled: Bool { true }
    mutating func pour(space: FormSpace, time: Double) {}
    mutating func rest(space: FormSpace, time: Double) {}
    mutating func arrive() {}
    mutating func step(_ dt: Double, space: FormSpace, time: Double) {}

    func pose(band: CGRect, time: Double) -> FormPose {
        FormPose(body: band, glyph: CGPoint(x: band.minX + PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2, y: PanelMetrics.glyphLift))
    }

    func carried(space: FormSpace) -> Double { space.band.minX + space.glyphHome }
}

// MARK: - The drop

/// A bead of glass, breathing, two blobs in it wandering past its edge. Poured, the body's ends, two fronts
/// ahead of them and two lumps in its middle each have a spring, a front never more than its size ahead.
/// Each letter after the first throws a droplet up off the surface, which falls back in.
struct DropSim: FormSim {
    static let bead = 64.0
    static let gravity = 5200.0

    private(set) var isResting: Bool
    /// The body's ends, from the band's, and its height.
    private var left: Spring, right: Spring, tall: Spring
    /// The fronts' centres, from the band's ends; their diameter.
    private var leftFront: Spring, rightFront: Spring, front: Spring
    /// The lumps, from the band's middle; their diameter.
    private var lumpX: Spring, lump: Spring
    /// The magnifier, from the band's left end.
    private var glyphX: Spring, glyphScale: Spring
    /// 1 breathing at rest, 0 poured.
    private var restness: Spring
    private var splashes = [Splash](repeating: Splash(), count: 3)
    private var nextSplash = 0

    private struct Splash: Sendable {
        var x = Spring(0), y = 0.0, vy = 0.0, d = Spring(4), flying = false
    }

    init(space: FormSpace, resting: Bool) {
        isResting = resting
        let band = space.band, h = space.height, bead = Self.bead
        if resting {
            left = Spring(-bead / 2 - band.minX)
            right = Spring(bead / 2 - band.maxX)
            tall = Spring(bead)
            leftFront = Spring(-5 - band.minX)
            rightFront = Spring(5 - band.maxX)
            front = Spring(54)
            lumpX = Spring(0)
            lump = Spring(36)
            glyphX = Spring(band.midX - band.minX)
            glyphScale = Spring(1.15)
            restness = Spring(1)
        } else {
            left = Spring(0)
            right = Spring(0)
            tall = Spring(h)
            leftFront = Spring(h / 2)
            rightFront = Spring(-h / 2)
            front = Spring(32)
            lumpX = Spring(150)
            lump = Spring(22)
            glyphX = Spring(space.glyphHome, response: FormSpace.carry, damping: 1)
            glyphScale = Spring(1)
            restness = Spring(0)
        }
    }

    mutating func pour(space: FormSpace, time: Double) {
        isResting = false
        let h = space.height
        left.to(0, response: 0.42, damping: 1)
        right.to(0, response: 0.42, damping: 1)
        tall.to(h, response: 0.32, damping: 0.42)
        leftFront.to(h / 2, response: 0.4, damping: 0.85)
        rightFront.to(-h / 2, response: 0.4, damping: 0.85)
        lumpX.to(150, response: 0.5, damping: 0.55)
        glyphX.response = FormSpace.carry
        glyphX.damping = 1
        glyphScale.to(1, response: 0.4, damping: 0.7)
        restness.to(0, response: 0.25, damping: 1)
    }

    mutating func rest(space: FormSpace, time: Double) {
        isResting = true
        let band = space.band, bead = Self.bead
        left.to(-bead / 2 - band.minX, response: 0.5, damping: 0.48)
        right.to(bead / 2 - band.maxX, response: 0.5, damping: 0.48)
        tall.to(bead, response: 0.42, damping: 0.4)
        leftFront.to(-5 - band.minX, response: 0.45, damping: 0.5)
        rightFront.to(5 - band.maxX, response: 0.45, damping: 0.5)
        lumpX.to(0, response: 0.5, damping: 0.6)
        glyphX.to(band.midX - band.minX, response: 0.5, damping: 0.62)
        glyphScale.to(1.15, response: 0.5, damping: 0.62)
        restness.to(1, response: 1.2, damping: 1)
        for i in splashes.indices {
            splashes[i].x.to(0, response: 0.3, damping: 1)
            splashes[i].flying = false
            splashes[i].y = 0
        }
    }

    mutating func typed(caret: Double, time: Double) {
        var splash = Splash()
        splash.x = Spring(caret - 6)
        splash.y = 12
        splash.vy = 640
        splash.flying = true
        splash.d = Spring(6)
        splash.d.to(15, response: 0.08, damping: 1)
        splashes[nextSplash] = splash
        nextSplash = (nextSplash + 1) % splashes.count
    }

    mutating func arrive() {
        // Stretched tall as it comes up, it squashes as it stops.
        tall.velocity += 90
    }

    mutating func step(_ dt: Double, space: FormSpace, time: Double) {
        let rest = Self.bead / 2 - space.band.maxX
        let progress = max(0, min(1, 1 - right.value / rest))
        // The fronts lead fat and thin as the body reaches them; the lumps swell the middle and sink into it.
        front.to(isResting ? 54 : 32 + 26 * (1 - progress), response: 0.3, damping: 0.8)
        lump.to(isResting ? 36 : 22 + 46 * (1 - progress), response: 0.3, damping: 0.8)
        for spring in [\DropSim.left, \.right, \.tall, \.leftFront, \.rightFront, \.front, \.lumpX, \.lump, \.glyphScale,
                       \.restness] as [WritableKeyPath<DropSim, Spring>] {
            self[keyPath: spring].step(dt)
        }
        // Poured, the magnifier rides the body's left end.
        if !isResting { glyphX.to(carried(space: space) - space.band.minX) }
        glyphX.step(dt)
        // A front leads its end of the body by less than its size, and never passes the field's ends.
        let reach = front.value / 2 * 0.9
        if rightFront.value > right.value + reach {
            rightFront.value = right.value + reach
            rightFront.velocity = min(rightFront.velocity, right.velocity)
        }
        if leftFront.value < left.value - reach {
            leftFront.value = left.value - reach
            leftFront.velocity = max(leftFront.velocity, left.velocity)
        }
        if rightFront.value > -front.value / 2 {
            rightFront.value = -front.value / 2
            rightFront.velocity = min(rightFront.velocity, 0)
        }
        if leftFront.value < front.value / 2 {
            leftFront.value = front.value / 2
            leftFront.velocity = max(leftFront.velocity, 0)
        }
        for i in splashes.indices {
            if splashes[i].flying {
                splashes[i].vy -= Self.gravity * dt
                splashes[i].y += splashes[i].vy * dt
                if splashes[i].y <= 0, splashes[i].vy < 0 {
                    splashes[i].y = 0
                    splashes[i].flying = false
                    splashes[i].d.to(4, response: 0.25, damping: 1)
                }
            }
            splashes[i].x.step(dt)
            splashes[i].d.step(dt)
        }
    }

    func carried(space: FormSpace) -> Double {
        space.carried(left: space.band.minX + left.value, width: space.band.width + right.value - left.value)
    }

    var isSettled: Bool {
        [left, right, tall, leftFront, rightFront, front, lumpX, lump, glyphX, restness].allSatisfy { $0.isSettled() }
            && glyphScale.isSettled(0.002) && splashes.allSatisfy { !$0.flying && $0.d.isSettled() && $0.x.isSettled() }
    }

    func pose(band: CGRect, time: Double) -> FormPose {
        let r = restness.value
        let wave = { (period: Double, phase: Double) in sin(2 * Double.pi * time / period + phase) }
        let squash = 2.2 * wave(2.4, 0)
        let bob = r * 2 * wave(4, 0)
        let wander = (l: -3.5 * wave(3, 0.7), r: 3.5 * wave(4, 2.1))
        let rise = (l: 2.5 * wave(2.4, 1.3), r: 2.5 * wave(3, 0.2))
        let l = band.minX + left.value, rr = band.maxX + right.value
        let span = rr - l + r * squash
        let tallness = tall.value - r * squash + r * wave(2, 0)
        // Squeezed narrower than it is tall, it grows taller rather than to a spike.
        let width = max(span, tallness * 0.85), height = tallness + max(0, tallness - span) * 0.25
        let mid = band.midY + bob
        var extras: [FormShape] = [
            .circle(CGPoint(x: band.minX + leftFront.value + r * wander.l, y: mid + r * rise.l), front.value),
            .circle(CGPoint(x: band.maxX + rightFront.value + r * wander.r, y: mid + r * rise.r), front.value),
            .circle(CGPoint(x: band.midX - lumpX.value, y: band.midY + 6), lump.value),
            .circle(CGPoint(x: band.midX + lumpX.value, y: band.midY - 6), lump.value),
        ]
        extras += splashes.map { .circle(CGPoint(x: band.midX + $0.x.value, y: band.midY + $0.y), $0.d.value) }
        return FormPose(body: CGRect(x: (l + rr) / 2 - width / 2, y: mid - height / 2, width: width, height: height),
                        extras: extras,
                        glyph: CGPoint(x: band.minX + glyphX.value, y: band.midY + PanelMetrics.glyphLift + bob),
                        glyphScale: glyphScale.value)
    }
}

// MARK: - The gem

/// An icosahedron tumbling in a marble of glass, drawn beneath it so the glass bends it. Poured, its faces
/// fly toward a strip the field's length, fading as they go, as the glass pours out; rested, they come back
/// and fold into the still-turning gem as the glass draws in around them.
struct GemSim: FormSim {
    static let marble = 76.0
    static let radius = 26.0

    private(set) var isResting: Bool
    /// The body's ends, from the band's, and its height.
    private var left: Spring, right: Spring, tall: Spring
    private var restness: Spring
    private var glyphAlpha: Spring, glyphScale: Spring
    private var faces: [Face]

    private struct Face: Sendable {
        let corners: [Int]
        var u = Spring(0, response: 0.7, damping: 0.74)
        var alpha = Spring(1)
        /// Its place in the strip, from the band's middle, its corners matched by `order`; when it goes there.
        var slot: [CGPoint] = []
        var x = 0.0
        var order = [0, 1, 2]
        var at = 0.0
        var flat = false
    }

    init(space: FormSpace, resting: Bool, time: Double) {
        isResting = resting
        let band = space.band, marble = Self.marble
        left = Spring(resting ? -marble / 2 - band.minX : 0)
        right = Spring(resting ? marble / 2 - band.maxX : 0)
        tall = Spring(resting ? marble : space.height)
        restness = Spring(resting ? 1 : 0)
        glyphAlpha = Spring(resting ? 0 : 1)
        glyphScale = Spring(resting ? 0.6 : 1)
        faces = Icosahedron.faces.map { Face(corners: $0) }
        if !resting {
            for i in faces.indices { faces[i].alpha = Spring(0) }
            place(time: time)
            for i in faces.indices { faces[i].u = Spring(1, response: 0.7, damping: 0.74) }
        }
    }

    /// Two turns about one axis and three about another in each period, so the tumble loops with the rest.
    private static func turn(at time: Double) -> Matrix {
        let a = 3 * cycle * time + 0.4, b = 2 * cycle * time + 1.1
        let ry = Matrix(rows: (cos(a), 0, sin(a)), (0, 1, 0), (-sin(a), 0, cos(a)))
        let rx = Matrix(rows: (1, 0, 0), (0, cos(b), -sin(b)), (0, sin(b), cos(b)))
        return rx * ry
    }

    /// A vertex of the gem, turned, in perspective, from the band's middle; and its depth.
    private static func project(_ vertex: Vector, _ turn: Matrix) -> (CGPoint, Double) {
        let w = turn * vertex * radius
        let s = 220 / (220 - w.z)
        return (CGPoint(x: w.x * s, y: w.y * s), w.z)
    }

    private func corners(of face: Face, _ turn: Matrix) -> [CGPoint] {
        face.corners.map { Self.project(Icosahedron.vertices[$0], turn).0 }
    }

    /// Each face to the strip's slot nearest where it is now, its corners matched to the slot's with the least
    /// travel, and from the middle outward.
    private mutating func place(time: Double) {
        let s = 600 / 10.5, h = 48.0
        let turn = Self.turn(at: time)
        let centroids = faces.map { corners(of: $0, turn).reduce(0) { $0 + $1.x } / 3 }
        let order = faces.indices.sorted { centroids[$0] < centroids[$1] }
        let permutations = [[0, 1, 2], [1, 2, 0], [2, 0, 1], [0, 2, 1], [2, 1, 0], [1, 0, 2]]
        for (j, i) in order.enumerated() {
            let x = -300 + s / 2 + Double(j) * s / 2
            let slot = j % 2 == 0
                ? [CGPoint(x: x - s / 2, y: -h / 2), CGPoint(x: x + s / 2, y: -h / 2), CGPoint(x: x, y: h / 2)]
                : [CGPoint(x: x - s / 2, y: h / 2), CGPoint(x: x + s / 2, y: h / 2), CGPoint(x: x, y: -h / 2)]
            let here = corners(of: faces[i], turn)
            let travel = { (p: [Int]) in (0..<3).reduce(0) { $0 + hypot(here[$1].x - slot[p[$1]].x, here[$1].y - slot[p[$1]].y) } }
            faces[i].order = permutations.min { travel($0) < travel($1) }!
            faces[i].slot = slot
            faces[i].x = x
            faces[i].at = time + abs(x) / 300 * 0.12
            faces[i].flat = true
        }
    }

    mutating func pour(space: FormSpace, time: Double) {
        isResting = false
        tall.to(space.height, response: 0.4, damping: 0.5)
        restness.to(0, response: 0.25, damping: 1)
        place(time: time)
    }

    mutating func rest(space: FormSpace, time: Double) {
        isResting = true
        tall.to(Self.marble, response: 0.45, damping: 0.45)
        restness.to(1, response: 1.2, damping: 1)
        glyphAlpha.to(0, response: 0.15, damping: 1)
        glyphScale.to(0.6, response: 0.3, damping: 1)
        // Back in once they have faded in where they lie, the ends first so all arrive together.
        for i in faces.indices {
            faces[i].alpha.to(1, response: 0.2, damping: 1)
            faces[i].at = time + 0.1 + (1 - abs(faces[i].x) / 300) * 0.12
            faces[i].flat = false
        }
    }

    mutating func arrive() {
        tall.velocity += 90
    }

    mutating func step(_ dt: Double, space: FormSpace, time: Double) {
        let band = space.band, marble = Self.marble
        let turn = Self.turn(at: time)
        var low = -marble / 2, high = marble / 2
        for i in faces.indices {
            if time >= faces[i].at { faces[i].u.to(faces[i].flat ? 1 : 0) }
            // Opening, a face fades as it flies: the strip it makes is never seen whole.
            if !isResting, faces[i].u.value > 0.55 { faces[i].alpha.to(0, response: 0.18, damping: 1) }
            faces[i].u.step(dt)
            faces[i].alpha.step(dt)
            for point in pointsOf(faces[i], turn) {
                low = min(low, point.x)
                high = max(high, point.x)
            }
        }
        if isResting {
            // The glass hugs the gem, and the faces as they fold back into it.
            left.to(max(band.minX, min(-marble / 2, low - 8)) - band.minX, response: 0.16, damping: 0.7)
            right.to(min(band.maxX, max(marble / 2, high + 8)) - band.maxX, response: 0.16, damping: 0.7)
        } else {
            // The faces fade as they go, so the glass pours out ahead of them.
            left.to(0, response: 0.42, damping: 1)
            right.to(0, response: 0.42, damping: 1)
        }
        if !isResting, band.minX + left.value < band.minX + space.glyphHome - 16 {
            glyphAlpha.to(1, response: 0.3, damping: 1)
            glyphScale.to(1, response: 0.4, damping: 0.55)
        }
        for spring in [\GemSim.left, \.right, \.tall, \.restness, \.glyphAlpha, \.glyphScale] as [WritableKeyPath<GemSim, Spring>] {
            self[keyPath: spring].step(dt)
        }
    }

    private func pointsOf(_ face: Face, _ turn: Matrix) -> [CGPoint] {
        let here = corners(of: face, turn), u = face.u.value
        return (0..<3).map { k in
            guard !face.slot.isEmpty else { return here[k] }
            let to = face.slot[face.order[k]]
            return CGPoint(x: here[k].x + (to.x - here[k].x) * u, y: here[k].y + (to.y - here[k].y) * u)
        }
    }

    func carried(space: FormSpace) -> Double {
        space.carried(left: space.band.minX + left.value, width: space.band.width + right.value - left.value)
    }

    var isSettled: Bool {
        [left, right, tall, restness].allSatisfy { $0.isSettled() } && glyphAlpha.isSettled(0.002) && glyphScale.isSettled(0.002)
            && faces.allSatisfy { $0.u.isSettled(0.002) && $0.alpha.isSettled(0.002) }
    }

    func pose(band: CGRect, time: Double) -> FormPose {
        let bob = restness.value * 2 * sin(2 * Double.pi * time / 4)
        let turn = Self.turn(at: time)
        let light = Vector(-0.4, 0.6, 0.75).normalized
        let drawn = faces.map { face -> FormFace in
            let lift = bob * (1 - max(0, min(1, face.u.value)))
            let corners = pointsOf(face, turn).map { CGPoint(x: band.midX + $0.x, y: band.midY + $0.y + lift) }
            // Lit by its turned normal, iridescent across the gem; flattened, toward one even tint.
            let v = face.corners.map { Icosahedron.vertices[$0] }
            let normal = (turn * (v[1] - v[0]).cross(v[2] - v[0])).normalized
            let facing = normal.z > 0
            let flatness = max(0, min(1, face.u.value))
            let lit = 0.35 + 0.65 * max(0, normal.dot(light))
            let alpha = facing ? 0.88 : 0.26
            let depth = face.corners.reduce(0) { $0 + Self.project(Icosahedron.vertices[$1], turn).1 } / 3
            let hue = (0.56 + 0.1 * normal.x + 0.06 * normal.y).truncatingRemainder(dividingBy: 1)
            return FormFace(corners: corners, hue: hue < 0 ? hue + 1 : hue, saturation: 0.42,
                            brightness: lit + (0.8 - lit) * flatness,
                            alpha: (alpha + (0.5 - alpha) * flatness) * max(0, min(1, face.alpha.value)),
                            edge: 0.6 * max(0, min(1, face.alpha.value)) * (facing || flatness > 0.5 ? 1 : 0.4),
                            depth: facing ? 100 + depth : depth)
        }
        let l = band.minX + left.value, r = band.maxX + right.value
        return FormPose(body: CGRect(x: l, y: band.midY + bob - tall.value / 2, width: r - l, height: tall.value),
                        glyph: CGPoint(x: band.minX + PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2,
                                       y: band.midY + PanelMetrics.glyphLift),
                        glyphScale: glyphScale.value, glyphAlpha: max(0, min(1, glyphAlpha.value)), faces: drawn)
    }
}

/// The twenty faces of a unit icosahedron, each wound outward.
private enum Icosahedron {
    static let vertices: [Vector] = {
        let phi = (1 + sqrt(5)) / 2
        var vertices: [Vector] = []
        for a in [-1.0, 1] {
            for b in [-phi, phi] {
                vertices += [Vector(0, a, b), Vector(a, b, 0), Vector(b, 0, a)]
            }
        }
        return vertices.map(\.normalized)
    }()

    static let faces: [[Int]] = {
        let edge = (1..<vertices.count).map { (vertices[0] - vertices[$0]).length }.min()!
        let adjacent = { (i: Int, j: Int) in abs((vertices[i] - vertices[j]).length - edge) < 1e-6 }
        var faces: [[Int]] = []
        for i in 0..<12 {
            for j in (i + 1)..<12 where adjacent(i, j) {
                for k in (j + 1)..<12 where adjacent(i, k) && adjacent(j, k) {
                    let (a, b, c) = (vertices[i], vertices[j], vertices[k])
                    faces.append((b - a).cross(c - a).dot(a + b + c) > 0 ? [i, j, k] : [i, k, j])
                }
            }
        }
        return faces
    }()
}

struct Vector: Sendable {
    var x, y, z: Double
    init(_ x: Double, _ y: Double, _ z: Double) { (self.x, self.y, self.z) = (x, y, z) }
    static func - (a: Vector, b: Vector) -> Vector { Vector(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func + (a: Vector, b: Vector) -> Vector { Vector(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func * (a: Vector, s: Double) -> Vector { Vector(a.x * s, a.y * s, a.z * s) }
    func dot(_ b: Vector) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Vector) -> Vector { Vector(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var length: Double { dot(self).squareRoot() }
    var normalized: Vector { self * (1 / length) }
}

struct Matrix: Sendable {
    var rows: (Vector, Vector, Vector)
    init(rows a: (Double, Double, Double), _ b: (Double, Double, Double), _ c: (Double, Double, Double)) {
        rows = (Vector(a.0, a.1, a.2), Vector(b.0, b.1, b.2), Vector(c.0, c.1, c.2))
    }
    private init(_ rows: (Vector, Vector, Vector)) { self.rows = rows }
    static func * (m: Matrix, v: Vector) -> Vector { Vector(m.rows.0.dot(v), m.rows.1.dot(v), m.rows.2.dot(v)) }
    static func * (a: Matrix, b: Matrix) -> Matrix {
        let columns = (Vector(b.rows.0.x, b.rows.1.x, b.rows.2.x), Vector(b.rows.0.y, b.rows.1.y, b.rows.2.y),
                       Vector(b.rows.0.z, b.rows.1.z, b.rows.2.z))
        let row = { (r: Vector) in Vector(r.dot(columns.0), r.dot(columns.1), r.dot(columns.2)) }
        return Matrix((row(a.rows.0), row(a.rows.1), row(a.rows.2)))
    }
}

// MARK: - The lava lamp

/// Three droplets drifting about one another, each chasing a point on a wandering path of its own and stretched
/// along the way it moves; near enough, they melt together and part again. The magnifier floats in the biggest.
/// Poured, the biggest stretches into the field and the other two streak out to its ends, never far ahead of it.
struct LavaSim: FormSim {
    private struct Blob: Sendable {
        /// From the band's middle.
        var x: Spring, y: Spring
        /// Its height; the body's width, too, as a difference from the band's.
        var d: Spring
        var w = Spring(0)

        init(x: Double, y: Double, d: Double) {
            self.x = Spring(x, response: 0.8, damping: 0.6)
            self.y = Spring(y, response: 0.8, damping: 0.6)
            self.d = Spring(d, response: 0.4, damping: 0.8)
        }

        mutating func step(_ dt: Double) {
            x.step(dt)
            y.step(dt)
            d.step(dt)
            w.step(dt)
        }

        var isSettled: Bool { x.isSettled() && y.isSettled() && d.isSettled() && w.isSettled() }

        /// How much longer than its size it is drawn, along the way it moves.
        var stretch: Double { min(hypot(x.velocity, y.velocity) / 900, 0.55) }
    }

    private(set) var isResting: Bool
    private var big: Blob, mid: Blob, small: Blob
    /// The magnifier, from the band's middle.
    private var glyphX = Spring(0, response: 0.15, damping: 1), glyphY = Spring(0, response: 0.15, damping: 1)
    private var glyphScale = Spring(0.85)
    /// Which of the two goes left.
    private var midLeft = true

    /// Where each chases at rest, and its size: whole cycles of the period, so the rest loops.
    private static func anchors(_ t: Double) -> (big: CGPoint, mid: CGPoint, small: CGPoint, midD: Double, smallD: Double) {
        (CGPoint(x: 14 * sin(4 * cycle * t), y: 8 * sin(6 * cycle * t + 1)),
         CGPoint(x: 40 * cos(5 * cycle * t + 2), y: 22 * sin(3 * cycle * t)),
         CGPoint(x: 44 * cos(3 * cycle * t + 4), y: 24 * sin(4 * cycle * t + 3)),
         28 + 2 * sin(8 * cycle * t + 1), 22 + 2 * sin(7 * cycle * t + 2))
    }

    init(space: FormSpace, resting: Bool, time: Double) {
        isResting = resting
        let a = Self.anchors(time), band = space.band, h = space.height
        if resting {
            big = Blob(x: a.big.x, y: a.big.y, d: 40)
            big.w = Spring(40 - band.width)
            mid = Blob(x: a.mid.x, y: a.mid.y, d: a.midD)
            small = Blob(x: a.small.x, y: a.small.y, d: a.smallD)
            glyphX = Spring(a.big.x, response: 0.15, damping: 1)
            glyphY = Spring(a.big.y + PanelMetrics.glyphLift, response: 0.15, damping: 1)
        } else {
            let end = band.width / 2 - h / 2
            big = Blob(x: 0, y: 0, d: h)
            mid = Blob(x: -end, y: 0, d: 32)
            small = Blob(x: end, y: 0, d: 32)
            glyphX = Spring(-end + PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2 - h / 2, response: FormSpace.carry, damping: 1)
            glyphY = Spring(PanelMetrics.glyphLift, response: FormSpace.carry, damping: 1)
            glyphScale = Spring(1)
        }
    }

    mutating func pour(space: FormSpace, time: Double) {
        isResting = false
        midLeft = mid.x.value < small.x.value
        let end = space.band.width / 2 - space.height / 2
        big.x.to(0, response: 0.45, damping: 0.75)
        big.y.to(0, response: 0.45, damping: 0.75)
        big.w.to(0, response: 0.42, damping: 1)
        big.d.to(space.height, response: 0.35, damping: 0.45)
        mid.x.to(midLeft ? -end : end, response: 0.4, damping: 0.85)
        mid.y.to(0, response: 0.4, damping: 0.85)
        small.x.to(midLeft ? end : -end, response: 0.4, damping: 0.85)
        small.y.to(0, response: 0.4, damping: 0.85)
        glyphX.response = FormSpace.carry
        glyphY.response = FormSpace.carry
        glyphScale.to(1, response: 0.4, damping: 0.7)
    }

    mutating func rest(space: FormSpace, time: Double) {
        isResting = true
        big.w.to(40 - space.band.width, response: 0.5, damping: 0.45)
        big.d.to(40, response: 0.42, damping: 0.4)
        for blob in [\LavaSim.big, \.mid, \.small] as [WritableKeyPath<LavaSim, Blob>] {
            self[keyPath: blob].x.response = 0.8
            self[keyPath: blob].y.response = 0.8
            self[keyPath: blob].x.damping = 0.6
            self[keyPath: blob].y.damping = 0.6
        }
        glyphScale.to(0.85, response: 0.5, damping: 0.62)
        glyphX.response = 0.15
        glyphY.response = 0.15
    }

    mutating func arrive() {
        for blob in [\LavaSim.big, \.mid, \.small] as [WritableKeyPath<LavaSim, Blob>] { self[keyPath: blob].y.velocity += 60 }
    }

    mutating func step(_ dt: Double, space: FormSpace, time: Double) {
        let width = space.band.width
        if isResting {
            let a = Self.anchors(time)
            big.x.to(a.big.x)
            big.y.to(a.big.y)
            mid.x.to(a.mid.x)
            mid.y.to(a.mid.y)
            small.x.to(a.small.x)
            small.y.to(a.small.y)
            mid.d.to(a.midD, response: 0.4, damping: 0.8)
            small.d.to(a.smallD, response: 0.4, damping: 0.8)
            glyphX.to(big.x.value)
            glyphY.to(big.y.value + PanelMetrics.glyphLift)
        } else {
            // Fat as they fly, then sinking into the field's ends as it reaches them.
            let progress = max(0, min(1, 1 - big.w.value / (40 - width)))
            mid.d.to(32 + 26 * (1 - progress), response: 0.3, damping: 0.8)
            small.d.to(32 + 26 * (1 - progress), response: 0.3, damping: 0.8)
        }
        big.step(dt)
        mid.step(dt)
        small.step(dt)
        if !isResting {
            // A flung droplet may part from the body, but only just, and never passes the field's ends.
            let edge = (width + big.w.value) / 2
            for blob in [\LavaSim.mid, \.small] as [WritableKeyPath<LavaSim, Blob>] {
                let d = self[keyPath: blob].d.value
                let reach = min(edge + d / 2 + 14, width / 2 - d * (1 + self[keyPath: blob].stretch) / 2)
                if abs(self[keyPath: blob].x.value) > reach {
                    self[keyPath: blob].x.value = reach * (self[keyPath: blob].x.value < 0 ? -1 : 1)
                    self[keyPath: blob].x.velocity *= 0.5
                }
            }
            // The magnifier rides the body's left end.
            glyphX.to(carried(space: space) - space.band.midX)
            glyphY.to(big.y.value + PanelMetrics.glyphLift)
        }
        glyphX.step(dt)
        glyphY.step(dt)
        glyphScale.step(dt)
    }

    func carried(space: FormSpace) -> Double {
        let edge = (space.band.width + big.w.value) / 2
        return space.carried(left: space.band.midX + big.x.value - edge, width: 2 * edge)
    }

    var isSettled: Bool {
        big.isSettled && mid.isSettled && small.isSettled && glyphX.isSettled() && glyphY.isSettled() && glyphScale.isSettled(0.002)
    }

    /// A droplet as drawn: stretched along the way it moves, the faster the more.
    private static func streak(_ blob: Blob, around center: CGPoint) -> FormShape {
        let vx = blob.x.velocity, vy = blob.y.velocity
        let s = blob.stretch
        return .capsule(CGPoint(x: center.x + blob.x.value, y: center.y + blob.y.value), width: blob.d.value * (1 + s),
                        height: blob.d.value * (1 - 0.35 * s), rotation: s > 0.01 ? atan2(vy, vx) : 0)
    }

    func pose(band: CGRect, time: Double) -> FormPose {
        let center = CGPoint(x: band.midX, y: band.midY)
        let width = band.width + big.w.value
        // The biggest is the body: a droplet like the others at rest, poured the field.
        let body = width > big.d.value + 1
            ? FormShape.capsule(CGPoint(x: center.x + big.x.value, y: center.y + big.y.value), width: width, height: big.d.value)
            : Self.streak(big, around: center)
        return FormPose(body: body.frame, bodyRotation: body.rotation,
                        extras: [Self.streak(mid, around: center), Self.streak(small, around: center)],
                        glyph: CGPoint(x: center.x + glyphX.value, y: center.y + glyphY.value), glyphScale: glyphScale.value)
    }
}
