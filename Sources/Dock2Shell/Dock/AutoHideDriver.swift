import AppKit
import Dock2Core

/// Runs `AutoHide` against the real pointer, whose moves `PointerMonitor` reports, with its timers as
/// dispatch timers.
@MainActor
final class AutoHideDriver {
    private(set) var state: AutoHide
    /// The dock should slide in (true) or out.
    var onChange: ((_ shown: Bool) -> Void)?
    /// The screen the dock is on, and the platter's top above its bottom edge, when shown.
    var screen: NSScreen?
    var bandTop: CGFloat = 0

    private var timers: [AutoHide.Timer: DispatchSourceTimer] = [:]

    init(enabled: Bool, revealDelay: Double, hideDelay: Double) {
        state = AutoHide(enabled: enabled, revealDelay: revealDelay, hideDelay: hideDelay)
    }

    var isShown: Bool { state.isShown }

    func setEnabled(_ enabled: Bool) {
        apply(state.setEnabled(enabled))
    }

    func setDelays(reveal: Double, hide: Double) {
        state.revealDelay = reveal
        state.hideDelay = hide
    }

    func hold(_ hold: AutoHide.Hold, _ on: Bool) {
        apply(state.hold(hold, on))
    }

    func pointerMoved(to point: CGPoint) {
        guard state.isEnabled else { return }
        apply(state.pointer(zone(of: point)))
    }

    func zone(of point: CGPoint) -> AutoHide.Zone {
        guard let screen, screen.frame.minX <= point.x, point.x < screen.frame.maxX else { return .away }
        let height = point.y - screen.frame.minY
        if height < 1 { return .edge }
        return height <= bandTop ? .band : .away
    }

    private func apply(_ effects: [AutoHide.Effect]) {
        for effect in effects {
            switch effect {
            case .start(let timer, let delay):
                timers[timer]?.cancel()
                // A timer of its own with almost no leeway: `asyncAfter` may be coalesced by tens of
                // milliseconds, which shows against the system Dock's timing.
                let source = DispatchSource.makeTimerSource(queue: .main)
                source.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.timers.removeValue(forKey: timer)?.cancel()
                        self.apply(self.state.fired(timer))
                    }
                }
                timers[timer] = source
                source.resume()
            case .cancel(let timer):
                timers.removeValue(forKey: timer)?.cancel()
            case .show:
                onChange?(true)
            case .hide:
                onChange?(false)
            }
        }
    }

    isolated deinit {
        timers.values.forEach { $0.cancel() }
    }
}
