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

/// A bead of glass, breathing, two blobs in it wandering past its edge. Poured, the body's ends and two lumps in
/// its middle each have a spring, and the blobs ride the ends as fronts (`FormSpace.lead`). Each letter after the
/// first throws a droplet up off the surface, which falls back in.
struct DropSim: FormSim {
    static let bead = 64.0
    static let gravity = 5200.0

    private(set) var isResting: Bool
    /// The body's ends, from the band's, and its height.
    private var left: Spring, right: Spring, tall: Spring
    /// The blobs, become the fronts: their centres, from the band's ends, and their diameter.
    private var leftFront: Spring, rightFront: Spring, front: Spring
    /// The lumps, from the band's middle; their diameter.
    private var lumpX: Spring, lump: Spring
    /// Poured, how far past each end of the body its front rides, and since when.
    private var leftLead = Spring(0), rightLead = Spring(0)
    private var pouredAt = -Double.infinity
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
            leftFront = Spring(FormSpace.tucked(32))
            leftLead = Spring(-FormSpace.tucked(32))
            rightLead = Spring(-FormSpace.tucked(32))
            rightFront = Spring(-FormSpace.tucked(32))
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
        // Each front rides its end of the body, gathered onto it from where it was.
        pouredAt = time
        leftLead = Spring(left.value - leftFront.value, response: FormSpace.gather, damping: 1)
        rightLead = Spring(rightFront.value - right.value, response: FormSpace.gather, damping: 1)
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
        // Poured, the fronts thin as they ride the ends; the lumps swell the middle as it starts to open and sink into
        // it well before it is open.
        front.to(isResting ? 54 : 32, response: 0.3, damping: 1)
        lump.to(isResting ? 36 : 22 + 34 * (1 - progress) * (1 - progress), response: 0.15, damping: 1)
        for spring in [\DropSim.left, \.right, \.tall, \.leftFront, \.rightFront, \.front, \.lumpX, \.lump, \.glyphScale,
                       \.restness] as [WritableKeyPath<DropSim, Spring>] {
            self[keyPath: spring].step(dt)
        }
        if !isResting {
            let since = time - pouredAt
            leftLead.to(FormSpace.lead(front.value, since: since))
            rightLead.to(FormSpace.lead(front.value, since: since))
            leftLead.step(dt)
            rightLead.step(dt)
            leftFront.place(left.value - leftLead.value, velocity: left.velocity - leftLead.velocity)
            rightFront.place(right.value + rightLead.value, velocity: right.velocity + rightLead.velocity)
        }
        // Poured, the magnifier rides the body's left end.
        if !isResting { glyphX.to(carried(space: space) - space.band.minX) }
        glyphX.step(dt)
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
        [left, right, tall, leftFront, rightFront, front, lumpX, lump, glyphX, restness, leftLead, rightLead].allSatisfy { $0.isSettled() }
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

/// A rough-cut emerald (`Stone`) tumbling in a marble of glass, drawn beneath it so the glass bends it. Poured, its
/// faces fly toward a strip the field's length, fading as they go, as the glass pours out and lets go of its lens;
/// emptied, it all plays the other way, the glass carrying the faces home and showing them only near the gem.
struct GemSim: FormSim {
    static let marble = 76.0
    static let radius = 26.0

    private(set) var isResting: Bool
    /// The body's ends, from the band's, and its height.
    private var left: Spring, right: Spring, tall: Spring
    private var restness: Spring
    private var glyphAlpha: Spring, glyphScale: Spring
    /// How far the glass is its lens (`FormFrame.lens`).
    private var lens: Spring
    private var faces: [Face]

    private struct Face: Sendable {
        let corners: [Int]
        /// How far it is from its place in the gem toward its slot in the strip.
        var u = Spring(0, response: 0.7, damping: 0.74)
        var alpha = Spring(1)
        /// Its place in the strip, from the band's middle, its corners matched by `order`; when it goes there.
        var slot: [CGPoint] = []
        var x = 0.0
        var order = [0, 1, 2]
        var at = 0.0
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
        lens = Spring(resting ? 1 : 0)
        faces = Stone.faces.map { Face(corners: $0) }
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
        face.corners.map { Self.project(Stone.vertices[$0], turn).0 }
    }

    /// Each face to the strip's slot nearest where it is now, its corners matched to the slot's with the least
    /// travel, and from the middle outward.
    private mutating func place(time: Double) {
        let s = 600 / (Double(faces.count + 1) / 2), h = 48.0
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
        }
    }

    mutating func pour(space: FormSpace, time: Double) {
        isResting = false
        tall.to(space.height, response: 0.4, damping: 0.5)
        restness.to(0, response: 0.25, damping: 1)
        lens.to(0, response: 0.25, damping: 1)
        place(time: time)
    }

    mutating func rest(space: FormSpace, time: Double) {
        isResting = true
        // Drawn in as it poured out, critically damped: it neither passes the marble nor springs back.
        tall.to(Self.marble, response: 0.42, damping: 1)
        restness.to(1, response: 1.2, damping: 1)
        glyphAlpha.to(0, response: 0.15, damping: 1)
        glyphScale.to(0.6, response: 0.3, damping: 1)
    }

    mutating func arrive() {
        tall.velocity += 90
    }

    mutating func step(_ dt: Double, space: FormSpace, time: Double) {
        let band = space.band, marble = Self.marble
        if isResting {
            left.to(-marble / 2 - band.minX, response: 0.42, damping: 1)
            right.to(marble / 2 - band.maxX, response: 0.42, damping: 1)
        } else {
            // The faces fade as they go, so the glass pours out ahead of them.
            left.to(0, response: 0.42, damping: 1)
            right.to(0, response: 0.42, damping: 1)
        }
        // Emptied, the faces ride in with the glass: as far out as it is still open, and nearer, so that what shows
        // of them is inside it.
        let open = max(0, min(1, ((band.width + right.value - left.value) / 2 - marble / 2) / (band.width / 2 - marble / 2)))
        for i in faces.indices {
            if isResting {
                faces[i].u.to(open * open, response: 0.06, damping: 1)
                // Near the gem again, a face shows: the pour's fading, the other way.
                if faces[i].u.value < 0.55 { faces[i].alpha.to(1, response: 0.18, damping: 1) }
            } else {
                if time >= faces[i].at { faces[i].u.to(1, response: 0.7, damping: 0.74) }
                // Opening, a face fades as it flies: the strip it makes is never seen whole.
                if faces[i].u.value > 0.55 { faces[i].alpha.to(0, response: 0.18, damping: 1) }
            }
            faces[i].u.step(dt)
            faces[i].alpha.step(dt)
        }
        // A lens again once the gem is whole in it.
        if isResting, faces.allSatisfy({ $0.u.value < 0.55 }) { lens.to(1, response: 0.25, damping: 1) }
        if !isResting, band.minX + left.value < band.minX + space.glyphHome - 16 {
            glyphAlpha.to(1, response: 0.3, damping: 1)
            glyphScale.to(1, response: 0.4, damping: 0.55)
        }
        for spring in [\GemSim.left, \.right, \.tall, \.restness, \.glyphAlpha, \.glyphScale, \.lens] as [WritableKeyPath<GemSim, Spring>] {
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
            && lens.isSettled(0.002)
            && faces.allSatisfy { $0.u.isSettled(0.002) && $0.alpha.isSettled(0.002) }
    }

    func pose(band: CGRect, time: Double) -> FormPose {
        let bob = restness.value * 2 * sin(2 * Double.pi * time / 4)
        let turn = Self.turn(at: time)
        let light = Vector(-0.4, 0.6, 0.75).normalized, eye = Vector(0, 0, 1)
        let drawn = faces.enumerated().map { index, face -> FormFace in
            let lift = bob * (1 - max(0, min(1, face.u.value)))
            let corners = pointsOf(face, turn).map { CGPoint(x: band.midX + $0.x, y: band.midY + $0.y + lift) }
            // An emerald's deep green, each facet a little its own, lit by its turned normal and glinting toward white as
            // it turns the light to the eye; flattened, toward one even tint.
            let v = face.corners.map { Stone.vertices[$0] }
            let normal = (turn * (v[1] - v[0]).cross(v[2] - v[0])).normalized
            let facing = normal.z > 0
            let flatness = max(0, min(1, face.u.value))
            let glint = pow(max(0, (normal * (2 * normal.dot(light)) - light).dot(eye)), 12)
            let tint = Stone.tints[index]
            let lit = max(0, min(1, (facing ? 0.1 : 0.06) + 0.62 * max(0, normal.dot(light)) + 0.7 * glint + 0.14 * tint.brightness))
            let alpha = facing ? 0.96 : 0.3
            let depth = face.corners.reduce(0) { $0 + Self.project(Stone.vertices[$1], turn).1 } / 3
            return FormFace(corners: corners, hue: 0.425 + 0.04 * tint.hue + 0.03 * normal.y,
                            saturation: max(0, min(1, 0.95 + 0.14 * tint.saturation - 0.55 * glint)),
                            brightness: lit + (0.8 - lit) * flatness,
                            alpha: (alpha + (0.5 - alpha) * flatness) * max(0, min(1, face.alpha.value)),
                            edge: 0.24 * max(0, min(1, face.alpha.value)) * (facing || flatness > 0.5 ? 1 : 0.4),
                            depth: facing ? 100 + depth : depth)
        }
        let l = band.minX + left.value, r = band.maxX + right.value
        // The magnifier shows only where the glass covers it: whole 12 pt inside the body's left end, gone at it.
        let covered = max(0, min(1, (band.minX + PanelMetrics.glyphLeft - l) / 12))
        return FormPose(body: CGRect(x: l, y: band.midY + bob - tall.value / 2, width: r - l, height: tall.value),
                        glyph: CGPoint(x: band.minX + PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2,
                                       y: band.midY + PanelMetrics.glyphLift),
                        glyphScale: glyphScale.value, glyphAlpha: max(0, min(1, glyphAlpha.value)) * covered, faces: drawn,
                        lens: max(0, min(1, lens.value)))
    }
}

/// A rough-cut stone: twelve corners about a slightly long ellipsoid, each a little off where an icosahedron's would be,
/// and the twenty faces of their hull, wound outward — facets of uneven size, as a gem's are.
private enum Stone {
    static let vertices = [
        Vector(-0.2396, -0.6060, -0.6856), Vector(-0.2345, -0.9520, -0.1966), Vector(-0.5184, 0.1200, -0.4659),
        Vector(0.1901, -0.6905, 0.6278), Vector(-0.3866, 0.8911, 0.0536), Vector(0.5891, -0.1791, -0.2851),
        Vector(-0.1406, 0.4178, -0.7129), Vector(0.3531, -0.8644, -0.1452), Vector(-0.6102, 0.0999, 0.5245),
        Vector(-0.1667, 0.4078, 0.5876), Vector(0.3296, 0.8561, -0.1561), Vector(0.5466, 0.0981, 0.6383),
    ]

    /// Every three corners with all the others on one side.
    static let faces: [[Int]] = {
        var faces: [[Int]] = []
        for i in vertices.indices {
            for j in (i + 1)..<vertices.count {
                for k in (j + 1)..<vertices.count {
                    let normal = (vertices[j] - vertices[i]).cross(vertices[k] - vertices[i])
                    let sides = vertices.indices.filter { ![i, j, k].contains($0) }.map { normal.dot(vertices[$0] - vertices[i]) }
                    if sides.allSatisfy({ $0 < 0 }) { faces.append([i, j, k]) }
                    if sides.allSatisfy({ $0 > 0 }) { faces.append([i, k, j]) }
                }
            }
        }
        return faces
    }()

    /// Each facet's own small departure from the stone's colour, from -0.5 to 0.5: in hue, saturation and brightness.
    static let tints: [(hue: Double, saturation: Double, brightness: Double)] = faces.indices.map { (scatter($0, 0), scatter($0, 1), scatter($0, 2)) }

    private static func scatter(_ face: Int, _ channel: Int) -> Double {
        let x = sin(Double(face * 3 + channel) * 12.9898 + 78.233) * 43758.5453
        return x - x.rounded(.down) - 0.5
    }
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

/// Three droplets drifting about one another, each chasing a point on a wandering path of its own and drawn longer
/// along the way it moves; near enough, they melt together and part again. The magnifier floats in the biggest.
/// Poured, the biggest stretches into the field and the other two are drawn into its ends, melting into it.
struct LavaSim: FormSim {
    private struct Blob: Sendable {
        /// From the band's middle.
        var x: Spring, y: Spring
        /// Its height; the body's width, too, as a difference from the band's.
        var d: Spring
        var w = Spring(0)
        /// A point following it, critically damped, that falls behind it as it moves: about its size behind at
        /// 900 pt/s.
        var trailX: Spring, trailY: Spring

        init(x: Double, y: Double, d: Double) {
            self.x = Spring(x, response: 0.8, damping: 0.6)
            self.y = Spring(y, response: 0.8, damping: 0.6)
            self.d = Spring(d, response: 0.4, damping: 0.8)
            trailX = Spring(x, response: .pi * d / 900, damping: 1)
            trailY = Spring(y, response: .pi * d / 900, damping: 1)
        }

        mutating func step(_ dt: Double) {
            x.step(dt)
            y.step(dt)
            d.step(dt)
            w.step(dt)
        }

        /// Its trail follows where it now is, placed or stepped.
        mutating func stepTrail(_ dt: Double) {
            trailX.to(x.value)
            trailY.to(y.value)
            trailX.step(dt)
            trailY.step(dt)
        }

        var isSettled: Bool { x.isSettled() && y.isSettled() && d.isSettled() && w.isSettled() && trailX.isSettled() && trailY.isSettled() }

        /// How closely it follows where it is headed, across and up.
        mutating func follow(response: Double, damping: Double) {
            x.response = response
            x.damping = damping
            y.response = response
            y.damping = damping
        }

        /// Placed `lead` past the end of `body` on `side` (-1 its left), `edge` from its middle, moving with it.
        mutating func ride(_ body: Blob, side: Double, edge: Double, lead: Spring) {
            x.place(body.x.value + side * (edge + lead.value), velocity: body.x.velocity + side * (body.w.velocity / 2 + lead.velocity))
        }

        /// As drawn: three discs the glass melts into one, on a line through it toward its trail, so it is longer the
        /// further its trail lags (up to `stretchMost` of its size longer) and a little thinner. Two would pinch.
        func discs(around center: CGPoint) -> [FormShape] {
            var lag = (x: x.value - trailX.value, y: y.value - trailY.value)
            let length = hypot(lag.x, lag.y), most = Self.stretchMost * d.value
            if length > most { lag = (lag.x * most / length, lag.y * most / length) }
            let stretch = min(length, most) / max(d.value, 1), size = d.value * (1 - 0.35 * stretch)
            // The ends 1.35 times the lag apart span its size longer by the stretch.
            let at = CGPoint(x: center.x + x.value, y: center.y + y.value), apart = 0.675
            return [-apart, 0, apart].map { .circle(CGPoint(x: at.x + $0 * lag.x, y: at.y + $0 * lag.y), size) }
        }

        static let stretchMost = 0.55
    }

    private(set) var isResting: Bool
    private var big: Blob, mid: Blob, small: Blob
    /// The magnifier, from the band's middle.
    private var glyphX = Spring(0, response: 0.15, damping: 1), glyphY = Spring(0, response: 0.15, damping: 1)
    private var glyphScale = Spring(0.85)
    /// Which of the two goes left.
    private var midLeft = true
    /// Poured, how far past its end of the body each of the two rides (`FormSpace.lead`), and since when.
    private var midLead = Spring(0), smallLead = Spring(0)
    private var pouredAt = -Double.infinity
    /// Emptied, the body is still drawing in, the two coming in with it.
    private var drawingIn = false

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
            mid = Blob(x: FormSpace.tucked(28) - band.width / 2, y: 0, d: 28)
            small = Blob(x: band.width / 2 - FormSpace.tucked(22), y: 0, d: 22)
            midLead = Spring(-FormSpace.tucked(28))
            smallLead = Spring(-FormSpace.tucked(22))
            glyphX = Spring(-end + PanelMetrics.glyphLeft + PanelMetrics.glyphSize / 2 - h / 2, response: FormSpace.carry, damping: 1)
            glyphY = Spring(PanelMetrics.glyphLift, response: FormSpace.carry, damping: 1)
            glyphScale = Spring(1)
        }
    }

    mutating func pour(space: FormSpace, time: Double) {
        isResting = false
        drawingIn = false
        midLeft = mid.x.value < small.x.value
        big.x.to(0, response: 0.45, damping: 0.75)
        big.y.to(0, response: 0.45, damping: 0.75)
        big.w.to(0, response: 0.42, damping: 1)
        big.d.to(space.height, response: 0.35, damping: 0.45)
        // Each of the two rides its end of the body, gathered onto it from where it was.
        pouredAt = time
        let edge = (space.band.width + big.w.value) / 2, side = midLeft ? -1.0 : 1
        midLead = Spring(side * (mid.x.value - big.x.value) - edge, response: FormSpace.gather, damping: 1)
        smallLead = Spring(-side * (small.x.value - big.x.value) - edge, response: FormSpace.gather, damping: 1)
        mid.y.response = 0.2
        small.y.response = 0.2
        mid.y.damping = 1
        small.y.damping = 1
        glyphX.response = FormSpace.carry
        glyphY.response = FormSpace.carry
        glyphScale.to(1, response: 0.4, damping: 0.7)
    }

    mutating func rest(space: FormSpace, time: Double) {
        isResting = true
        // Drawn in as it poured out, critically damped: it neither passes its resting size nor springs back.
        big.w.to(40 - space.band.width, response: 0.42, damping: 1)
        big.d.to(40, response: 0.42, damping: 1)
        big.follow(response: 0.8, damping: 0.6)
        // The two ride its ends in, melted into it, until they meet in its middle (`step`).
        drawingIn = true
        glyphScale.to(0.85, response: 0.5, damping: 0.62)
        glyphX.response = 0.15
        glyphY.response = 0.15
    }

    mutating func arrive() {
        for blob in [\LavaSim.big, \.mid, \.small] as [WritableKeyPath<LavaSim, Blob>] { self[keyPath: blob].y.velocity += 60 }
    }

    mutating func step(_ dt: Double, space: FormSpace, time: Double) {
        let width = space.band.width
        // Poured, and emptied while the body draws in, the two ride its ends.
        let riding = !isResting || drawingIn
        if isResting {
            let a = Self.anchors(time)
            big.x.to(a.big.x)
            big.y.to(a.big.y)
            if !riding {
                mid.x.to(a.mid.x)
                mid.y.to(a.mid.y)
                small.x.to(a.small.x)
                small.y.to(a.small.y)
            }
            mid.d.to(a.midD, response: 0.4, damping: 0.8)
            small.d.to(a.smallD, response: 0.4, damping: 0.8)
            glyphX.to(big.x.value)
            glyphY.to(big.y.value + PanelMetrics.glyphLift)
        }
        if riding {
            mid.y.to(big.y.value)
            small.y.to(big.y.value)
        }
        big.step(dt)
        mid.step(dt)
        small.step(dt)
        if riding {
            let edge = (width + big.w.value) / 2, since = time - pouredAt, side = midLeft ? -1.0 : 1
            midLead.to(FormSpace.lead(mid.d.value * (1 + Blob.stretchMost), since: since))
            smallLead.to(FormSpace.lead(small.d.value * (1 + Blob.stretchMost), since: since))
            midLead.step(dt)
            smallLead.step(dt)
            mid.ride(big, side: side, edge: edge, lead: midLead)
            small.ride(big, side: -side, edge: edge, lead: smallLead)
            if !isResting {
                // The magnifier rides the body's left end.
                glyphX.to(carried(space: space) - space.band.midX)
                glyphY.to(big.y.value + PanelMetrics.glyphLift)
            } else if edge + midLead.value <= 0 {
                // Met in the middle of the body as it arrives, the two drift out of it as at rest.
                mid.follow(response: 0.8, damping: 0.6)
                small.follow(response: 0.8, damping: 0.6)
                drawingIn = false
            }
        }
        // The two are drawn longer as they move; the body is drawn as it is.
        mid.stepTrail(dt)
        small.stepTrail(dt)
        glyphX.step(dt)
        glyphY.step(dt)
        glyphScale.step(dt)
    }

    func carried(space: FormSpace) -> Double {
        let edge = (space.band.width + big.w.value) / 2
        return space.carried(left: space.band.midX + big.x.value - edge, width: 2 * edge)
    }

    var isSettled: Bool {
        big.isSettled && mid.isSettled && small.isSettled && midLead.isSettled() && smallLead.isSettled() && glyphX.isSettled() && glyphY.isSettled() && glyphScale.isSettled(0.002)
    }

    func pose(band: CGRect, time: Double) -> FormPose {
        let center = CGPoint(x: band.midX, y: band.midY)
        // The biggest is the body: a disc at rest, poured the field, never narrower than it is tall.
        let body = FormShape.capsule(CGPoint(x: center.x + big.x.value, y: center.y + big.y.value),
                                     width: max(band.width + big.w.value, big.d.value), height: big.d.value)
        return FormPose(body: body.frame, extras: mid.discs(around: center) + small.discs(around: center),
                        glyph: CGPoint(x: center.x + glyphX.value, y: center.y + glyphY.value), glyphScale: glyphScale.value)
    }
}
