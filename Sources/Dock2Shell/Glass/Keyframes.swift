import QuartzCore

/// Values `step` apart from `begin`, the last held — then, if there is one, a loop from where they end,
/// repeating for good, `offset` into itself. Added to a layer, the window server plays them frame by frame,
/// whatever the main thread is doing.
struct Keyframes<Value> {
    var values: [Value]
    var step: CFTimeInterval
    /// In media time.
    var begin: CFTimeInterval
    var loop: Loop?

    struct Loop {
        var values: [Value]
        var step: CFTimeInterval
        var offset: CFTimeInterval
    }

    var last: Value { values[values.count - 1] }

    func map<T>(_ transform: (Value) -> T) -> Keyframes<T> {
        Keyframes<T>(values: values.map(transform), step: step, begin: begin,
                     loop: loop.map { .init(values: $0.values.map(transform), step: $0.step, offset: $0.offset) })
    }

    /// Plays them on `layer`'s `keyPath`, `convert` making each value what Core Animation takes. Keyed apart
    /// from any other motion on the layer, and replacing what was played there before.
    func play(on layer: CALayer, _ keyPath: String, _ convert: (Value) -> Any) {
        let begin = layer.convertTime(self.begin, from: nil)
        let segment = CAKeyframeAnimation(keyPath: keyPath)
        segment.values = values.map(convert)
        segment.beginTime = begin
        segment.duration = max(step * Double(values.count - 1), 1e-3)
        segment.fillMode = .both
        segment.isRemovedOnCompletion = false
        layer.add(segment, forKey: CALayer.keyframesKey + keyPath)
        guard let loop, let first = loop.values.first else {
            layer.removeAnimation(forKey: CALayer.loopKey + keyPath)
            return
        }
        // Added after the segment, it takes over as the segment ends.
        let repeating = CAKeyframeAnimation(keyPath: keyPath)
        repeating.values = (loop.values + [first]).map(convert)
        repeating.beginTime = begin + segment.duration
        repeating.duration = loop.step * Double(loop.values.count)
        repeating.timeOffset = loop.offset
        repeating.repeatCount = .infinity
        layer.add(repeating, forKey: CALayer.loopKey + keyPath)
    }
}

extension CALayer {
    fileprivate static let keyframesKey = "keyframes."
    fileprivate static let loopKey = "keyframes.loop."

    /// Ends what `Keyframes` played on these key paths, leaving the model values.
    func stopKeyframes(_ keyPaths: [String]) {
        for keyPath in keyPaths {
            removeAnimation(forKey: Self.keyframesKey + keyPath)
            removeAnimation(forKey: Self.loopKey + keyPath)
        }
    }
}
