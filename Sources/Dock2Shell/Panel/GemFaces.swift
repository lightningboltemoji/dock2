import AppKit
import Dock2Core

/// The gem's faces, beneath the panel's glass so the glass bends them, and shown only within its body.
@MainActor
final class GemFaces: NSView {
    private var faces: [CAShapeLayer] = []
    private let clip = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer!.mask = clip
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Plays `track`, from the field's centre at `origin`, within the body's shapes of `body`.
    func play(_ track: Keyframes<[FormFace]>, within body: Keyframes<GlassLayer.Shape>, origin: CGPoint) {
        guard let count = track.values.first?.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while faces.count < count {
            let face = CAShapeLayer()
            face.lineWidth = 0.75
            face.lineJoin = .round
            layer!.addSublayer(face)
            faces.append(face)
        }
        clip.frame = bounds
        let outline = body.map { shape -> CGPath in
            let radius = min(shape.cornerRadius, shape.frame.height / 2, shape.frame.width / 2)
            return CGPath(roundedRect: shape.frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        clip.path = outline.last
        outline.play(on: clip, "path") { $0 }
        for (index, face) in faces.enumerated() {
            face.frame = bounds
            let one = track.map { $0[index] }
            let path = one.map { face -> CGPath in
                let path = CGMutablePath()
                path.addLines(between: face.corners.map { CGPoint(x: origin.x + $0.x, y: origin.y + $0.y) })
                path.closeSubpath()
                return path
            }
            let fill = one.map { NSColor(colorSpace: .sRGB, hue: $0.hue, saturation: $0.saturation, brightness: $0.brightness, alpha: $0.alpha).cgColor }
            let edge = one.map { CGColor(gray: 1, alpha: $0.edge) }
            face.path = path.last
            face.fillColor = fill.last
            face.strokeColor = edge.last
            face.zPosition = one.last.depth
            path.play(on: face, "path") { $0 }
            fill.play(on: face, "fillColor") { $0 }
            edge.play(on: face, "strokeColor") { $0 }
            one.play(on: face, "zPosition") { NSNumber(value: $0.depth) }
        }
        CATransaction.commit()
    }

    func stop() {
        faces.forEach { $0.removeFromSuperlayer() }
        faces = []
        clip.stopKeyframes(["path"])
        clip.path = nil
    }
}
