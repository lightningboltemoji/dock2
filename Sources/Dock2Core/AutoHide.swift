import Foundation

/// Whether the dock is on screen under auto-hide, by the system Dock's rules (IMPLEMENTATION.md §5). A pure
/// reducer: timers are effects, and come back as `fired`.
public struct AutoHide: Equatable, Sendable {
    /// Where the pointer is, relative to the dock's screen.
    public enum Zone: Sendable, Equatable {
        /// The screen's bottom row of pixels.
        case edge
        /// Below the platter's top, anywhere across the screen.
        case band
        case away
    }

    /// What keeps the dock up whatever the pointer does.
    public enum Hold: Hashable, Sendable {
        /// dock2 has the keyboard, a query or a view.
        case engaged
        case menu
        case drag
        /// Another process asked (`dock2 debug reveal on`).
        case control
    }

    public enum Timer: Hashable, Sendable {
        case reveal, hide
    }

    public enum Effect: Equatable, Sendable {
        case start(Timer, after: Double)
        case cancel(Timer)
        case show
        case hide
    }

    public private(set) var isEnabled: Bool
    public private(set) var isShown: Bool
    public var revealDelay: Double
    public var hideDelay: Double
    public private(set) var zone: Zone = .away
    public private(set) var holds: Set<Hold> = []
    /// The timers started and neither fired nor cancelled.
    public private(set) var pending: Set<Timer> = []

    public init(enabled: Bool, revealDelay: Double = DockMotion.revealDelay, hideDelay: Double = DockMotion.hideDelay) {
        isEnabled = enabled
        isShown = !enabled
        self.revealDelay = revealDelay
        self.hideDelay = hideDelay
    }

    public mutating func pointer(_ zone: Zone) -> [Effect] {
        let previous = self.zone
        self.zone = zone
        guard isEnabled, zone != previous else { return [] }
        if !isShown {
            if zone == .edge { return start(.reveal, after: revealDelay) }
            return zone == .away ? cancel(.reveal) : []
        }
        if zone == .away { return holds.isEmpty ? start(.hide, after: hideDelay) : [] }
        return cancel(.hide)
    }

    public mutating func fired(_ timer: Timer) -> [Effect] {
        guard pending.remove(timer) != nil, isEnabled else { return [] }
        switch timer {
        case .reveal:
            guard !isShown, zone != .away else { return [] }
            isShown = true
            return [.show]
        case .hide:
            guard isShown, zone == .away, holds.isEmpty else { return [] }
            isShown = false
            return [.hide]
        }
    }

    public mutating func hold(_ hold: Hold, _ on: Bool) -> [Effect] {
        if on {
            guard holds.insert(hold).inserted, isEnabled else { return [] }
            if !isShown {
                isShown = true
                return cancel(.reveal) + [.show]
            }
            return cancel(.hide)
        }
        guard holds.remove(hold) != nil, isEnabled, isShown, holds.isEmpty, zone == .away else { return [] }
        return start(.hide, after: hideDelay)
    }

    public mutating func setEnabled(_ enabled: Bool) -> [Effect] {
        guard enabled != isEnabled else { return [] }
        isEnabled = enabled
        if !enabled {
            let wasShown = isShown
            isShown = true
            return cancel(.reveal) + cancel(.hide) + (wasShown ? [] : [.show])
        }
        // Turned on with the pointer elsewhere: the dock goes, as if the pointer had just left it.
        guard zone == .away, holds.isEmpty else { return [] }
        return start(.hide, after: hideDelay)
    }

    private mutating func start(_ timer: Timer, after delay: Double) -> [Effect] {
        pending.insert(timer)
        return [.start(timer, after: delay)]
    }

    private mutating func cancel(_ timer: Timer) -> [Effect] {
        pending.remove(timer) == nil ? [] : [.cancel(timer)]
    }
}
