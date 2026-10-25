import AppKit

/// The shadow the window server would draw around the panel were it a window of its own, as Spotlight's
/// is: a tight dark ring and a broad blur beneath, fitted against Spotlight's. Both are cut away inside the
/// panel's shape — under the glass they would be refracted by it.
@MainActor
final class PanelShadow: NSView {
    private let layers: [CALayer] = [CALayer(), CALayer()]
    private let masks: [CAShapeLayer] = [CAShapeLayer(), CAShapeLayer()]

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        for (index, (opacity, radius, offset)) in [(0.6, 1.0, 0.0), (0.45, 14.4, -11.0)].enumerated() {
            let layer = layers[index]
            layer.shadowColor = .black
            layer.shadowOpacity = Float(opacity)
            layer.shadowRadius = radius
            layer.shadowOffset = CGSize(width: 0, height: offset)
            masks[index].fillRule = .evenOdd
            layer.mask = masks[index]
            self.layer!.addSublayer(layer)
        }
        layer!.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Around the capsule `rect`.
    func set(_ rect: CGRect) {
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(path)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, mask) in zip(layers, masks) {
            layer.frame = bounds
            mask.frame = bounds
            layer.shadowPath = path
            mask.path = outside
        }
        CATransaction.commit()
    }

    /// Around the rounded rects of `track`, as a field form's body moves (`FormDriver`).
    func play(_ track: Keyframes<GlassLayer.Shape>) {
        let paths = track.map { shape -> (CGPath, CGPath) in
            let radius = min(shape.cornerRadius, shape.frame.height / 2, shape.frame.width / 2)
            let path = CGPath(roundedRect: shape.frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            let outside = CGMutablePath()
            outside.addRect(bounds)
            outside.addPath(path)
            return (path, outside)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, mask) in zip(layers, masks) {
            layer.frame = bounds
            mask.frame = bounds
            layer.shadowPath = paths.last.0
            mask.path = paths.last.1
            paths.play(on: layer, "shadowPath") { $0.0 }
            paths.play(on: mask, "path") { $0.1 }
        }
        CATransaction.commit()
    }

    func stopPlaying() {
        for (layer, mask) in zip(layers, masks) {
            layer.stopKeyframes(["shadowPath"])
            mask.stopKeyframes(["path"])
        }
    }

    func fade(in visible: Bool, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let layer = self.layer!
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = visible ? 1 : 0
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = layer.opacity
        animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        layer.add(animation, forKey: "fade")
    }
}
