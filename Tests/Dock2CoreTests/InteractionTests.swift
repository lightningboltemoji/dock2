import Dock2Core
import Testing

@Suite struct InteractionTests {
    @Test func revealingTakesTheKeyboardAfterTheDwell() {
        var state = Interaction()
        #expect(state.handle(.pointerOnDock(true)) == [.startDwell(after: 0.15)])
        #expect(state.phase == .revealed)
        #expect(state.handle(.dwellFired(secondsSinceKeystroke: 3)) == [.takeKeyboard])
        #expect(state.hasKeyboard)
    }

    @Test func leavingBeforeTheDwellTakesNothing() {
        var state = Interaction()
        _ = state.handle(.pointerOnDock(true))
        #expect(state.handle(.pointerOnDock(false)) == [.cancelDwell])
        #expect(state.handle(.dwellFired(secondsSinceKeystroke: 3)) == [])
        #expect(!state.hasKeyboard && state.phase == .resting)
    }

    /// A pointer that drifts to the edge mid-sentence cannot hijack the typing; and it does not retry.
    @Test func theTypingGuardHoldsTheRevealBack() {
        var state = Interaction()
        _ = state.handle(.pointerOnDock(true))
        #expect(state.handle(.dwellFired(secondsSinceKeystroke: 0.2)) == [])
        #expect(!state.hasKeyboard)
        #expect(state.phase == .revealed)
        _ = state.handle(.pointerOnDock(false))
        #expect(state.handle(.pointerOnDock(true)) == [.startDwell(after: 0.15)])
    }

    @Test func revealedWithNothingTypedLetsGoWhenThePointerLeaves() {
        var state = Interaction()
        _ = state.handle(.pointerOnDock(true))
        _ = state.handle(.dwellFired(secondsSinceKeystroke: 3))
        #expect(state.handle(.pointerOnDock(false)) == [.releaseKeyboard])
        #expect(state.phase == .resting && !state.hasKeyboard)
    }

    /// Once engaged, a query is never lost to a movement of the mouse.
    @Test func aQueryKeepsDock2WhenThePointerLeaves() {
        var state = Interaction()
        _ = state.handle(.pointerOnDock(true))
        _ = state.handle(.dwellFired(secondsSinceKeystroke: 3))
        #expect(state.handle(.panelEngaged(true)) == [.holdDock(true)])
        #expect(state.handle(.pointerOnDock(false)) == [])
        #expect(state.hasKeyboard && state.phase == .engaged)
        // The query cleared with the pointer gone: the empty field stays, and Esc then dismisses.
        #expect(state.handle(.panelEngaged(false)) == [])
        #expect(state.hasKeyboard && state.phase == .engaged)
        #expect(state.handle(.dismiss).contains(.releaseKeyboard) && !state.hasKeyboard)
    }

    @Test func theShortcutSummonsAndThenDismisses() {
        var state = Interaction()
        #expect(state.handle(.summon) == [.takeKeyboard, .holdDock(true)])
        #expect(state.phase == .engaged)
        #expect(state.handle(.pointerOnDock(true)) == [])
        #expect(state.handle(.pointerOnDock(false)) == [])
        #expect(state.hasKeyboard)
        #expect(state.handle(.summon) == [.releaseKeyboard, .holdDock(false)])
        #expect(state.phase == .resting && !state.hasKeyboard)
    }

    /// Summoned, an empty field stays: Esc from a query only steps back to it.
    @Test func aSummonedEmptyFieldIsStillEngaged() {
        var state = Interaction()
        _ = state.handle(.summon)
        _ = state.handle(.panelEngaged(true))
        #expect(state.handle(.panelEngaged(false)) == [])
        #expect(state.isEngaged && state.hasKeyboard)
    }

    @Test func aRequestTakesTheKeyboardUnguardedEvenWhileRevealed() {
        var state = Interaction()
        _ = state.handle(.pointerOnDock(true))
        #expect(state.handle(.request) == [.cancelDwell, .takeKeyboard, .holdDock(true)])
        #expect(state.handle(.request) == [])
    }

    /// Dismissed with the pointer still on the dock: revealed, but the dwell does not take it again until
    /// the pointer leaves and comes back.
    @Test func dismissalSpendsTheReveal() {
        var state = Interaction()
        _ = state.handle(.pointerOnDock(true))
        _ = state.handle(.dwellFired(secondsSinceKeystroke: 3))
        _ = state.handle(.panelEngaged(true))
        #expect(state.handle(.dismiss) == [.releaseKeyboard, .holdDock(false)])
        #expect(state.phase == .revealed && !state.hasKeyboard)
        #expect(state.handle(.dwellFired(secondsSinceKeystroke: 3)) == [])
        _ = state.handle(.pointerOnDock(false))
        #expect(state.handle(.pointerOnDock(true)) == [.startDwell(after: 0.15)])
    }

    @Test func withRevealToTypeOffOnlyTheShortcutAndClicksTakeTheKeyboard() {
        var state = Interaction(revealToType: false)
        #expect(state.handle(.pointerOnDock(true)) == [])
        #expect(state.handle(.dwellFired(secondsSinceKeystroke: 3)) == [])
        #expect(state.handle(.request) == [.takeKeyboard, .holdDock(true)])
    }
}
