import Foundation

/// Who has the keyboard ([interaction](../../.agents/product/interaction.md)): the moves between resting,
/// revealed and engaged as a pure reducer. The dwell is a timer effect, coming back as `dwellFired`.
public struct Interaction: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The dock is on screen or hidden; dock2 does not have the keyboard.
        case resting
        /// The pointer is on the dock; dock2 may have the keyboard, with nothing typed.
        case revealed
        /// Summoned, or a query typed, or a view open: dock2 stays until dismissed.
        case engaged
    }

    public enum Event: Equatable, Sendable {
        /// The pointer is over the shown dock, or has left it.
        case pointerOnDock(Bool)
        case dwellFired(secondsSinceKeystroke: Double)
        /// The summon shortcut: summons, or dismisses if dock2 has the keyboard.
        case summon
        /// A request to take the keyboard, unguarded: a click on the platter, "Show in Finder".
        case request
        /// The panel left its empty field (a query typed, a view opened), or came back to it.
        case panelEngaged(Bool)
        /// Esc on an empty field, ⌘W, a click elsewhere, an action that opens something, another app forward.
        case dismiss
    }

    public enum Effect: Equatable, Sendable {
        case startDwell(after: Double)
        case cancelDwell
        case takeKeyboard
        case releaseKeyboard
        /// Whether auto-hide must keep the dock up.
        case holdDock(Bool)
    }

    public private(set) var phase: Phase = .resting
    public private(set) var hasKeyboard = false
    public private(set) var pointerOnDock = false
    /// Summoned by shortcut or request, as opposed to revealed by the pointer.
    public private(set) var summoned = false
    public private(set) var panelEngaged = false
    /// A reveal that was refused — the typing guard held it back — or already used, which only a fresh
    /// entry of the pointer can try again.
    private var dwellSpent = false
    private var dwellPending = false

    /// Reveal-to-type: off, only the shortcut and a click take the keyboard.
    public var revealToType: Bool
    public var dwell: Double
    public var typingGuard: Double

    public init(revealToType: Bool = true, dwell: Double = 0.15, typingGuard: Double = 0.5) {
        self.revealToType = revealToType
        self.dwell = dwell
        self.typingGuard = typingGuard
    }

    public var isEngaged: Bool { summoned || panelEngaged }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .pointerOnDock(let on):
            guard on != pointerOnDock else { return [] }
            pointerOnDock = on
            if on {
                dwellSpent = false
                guard phase == .resting else { return [] }
                phase = .revealed
                return startDwell()
            }
            var effects = cancelDwell()
            if phase == .revealed {
                phase = .resting
                if hasKeyboard {
                    hasKeyboard = false
                    effects.append(.releaseKeyboard)
                }
            }
            return effects

        case .dwellFired(let sinceKeystroke):
            guard dwellPending else { return [] }
            dwellPending = false
            dwellSpent = true
            guard phase == .revealed, pointerOnDock, !hasKeyboard, sinceKeystroke >= typingGuard else { return [] }
            hasKeyboard = true
            return [.takeKeyboard]

        case .summon:
            if hasKeyboard { return dismiss() }
            return engage()

        case .request:
            return hasKeyboard && isEngaged ? [] : engage()

        case .panelEngaged(let engaged):
            guard engaged != panelEngaged, hasKeyboard else { return [] }
            let was = isEngaged
            panelEngaged = engaged
            if isEngaged, !was {
                phase = .engaged
                return cancelDwell() + [.holdDock(true)]
            }
            if !isEngaged, was {
                // Back to an empty field with the pointer still on the dock: a reveal again, which the pointer
                // leaving ends. With it gone, the field stays the user's — Esc dismisses — since a query is never
                // lost to a movement of the mouse, nor the next letter typed to the app in front.
                guard pointerOnDock else {
                    summoned = true
                    return []
                }
                phase = .revealed
                return [.holdDock(false)]
            }
            return []

        case .dismiss:
            return dismiss()
        }
    }

    private mutating func engage() -> [Effect] {
        var effects = cancelDwell()
        let wasEngaged = isEngaged
        summoned = true
        phase = .engaged
        if !hasKeyboard {
            hasKeyboard = true
            effects.append(.takeKeyboard)
        }
        if !wasEngaged { effects.append(.holdDock(true)) }
        return effects
    }

    private mutating func dismiss() -> [Effect] {
        var effects = cancelDwell()
        if hasKeyboard {
            hasKeyboard = false
            effects.append(.releaseKeyboard)
        }
        if isEngaged { effects.append(.holdDock(false)) }
        summoned = false
        panelEngaged = false
        // Still on the dock, it stays revealed, but the dwell is spent until the pointer comes back.
        phase = pointerOnDock ? .revealed : .resting
        dwellSpent = true
        return effects
    }

    private mutating func startDwell() -> [Effect] {
        guard revealToType, !dwellSpent, !hasKeyboard else { return [] }
        dwellPending = true
        return [.startDwell(after: dwell)]
    }

    private mutating func cancelDwell() -> [Effect] {
        guard dwellPending else { return [] }
        dwellPending = false
        return [.cancelDwell]
    }
}
