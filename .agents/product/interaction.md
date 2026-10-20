# Interaction

dock2 is a state machine around one question: who has the keyboard. This file names the states and the
moves between them; [keyboard](keyboard.md) lists what each key does in each.

## States

| State | On screen | The keyboard |
| --- | --- | --- |
| **Resting** | the dock, or nothing under auto-hide | the app in front |
| **Revealed** | the dock, and the field once dock2 has the keyboard | dock2, unless the typing guard held it back |
| **Summoned** | the dock, and the field with a caret | dock2 |
| **Searching** | the dock, the field, and results above it | dock2 |
| **Viewing** | the dock, the field, and a view above it | dock2 |

The field is on screen exactly when dock2 has the keyboard. Seeing it means typing goes to dock2; not seeing
it means typing goes where it went before.

## Moves

- **Resting → revealed**: the pointer reaches the dock — under auto-hide, the bottom edge, for the reveal
  delay; otherwise the dock itself. dock2 takes the keyboard once the pointer has stayed for the dwell
  (**Open:** 150 ms), unless the typing guard holds it back.
- **Revealed → resting**: the pointer leaves while dock2 is not engaged. The keyboard goes back by itself
  (below).
- **Any → summoned**: the summon shortcut. It reveals the dock whatever auto-hide says, and takes the
  keyboard unguarded: a shortcut is a request, not an accident.
- **Revealed or summoned → searching**: a key that types a character. The character starts the query.
- **Into a view**: ↩ on a command or on "Show all…"; a shortcut bound to a view; for Files, a path typed in
  the field or a click on the Finder tile ([files](files/README.md)).
- **Any → Files**: "Show in Finder" from another app, once dock2 has taken it over. Like the summon shortcut
  it is a request, and takes the keyboard unguarded; the app that asked stays in front.
- **Back**: Esc steps down one level — a view to the search it came from, a query to an empty field, an
  empty field to resting.
- **Dismissal**, from any state to resting: Esc on an empty field; the summon shortcut again; ⌘W; a click
  outside dock2; an action that opens or switches to something; another app coming forward.

Once engaged, dock2 stays when the pointer leaves: a query is never lost to a movement of the mouse. A drag
that starts in dock2 keeps it up until the drop.

## The keyboard

- **dock2 never comes forward.** Its windows are non-activating panels: while dock2 has the keyboard, the
  app in front keeps the menu bar and stays in front, and when dock2 lets go, that app's window has the
  keyboard again without dock2 restoring anything.
- **The app in front notices.** Its window loses key status while dock2 has the keyboard — the caret stops,
  a selection greys — as under Spotlight. An app that pauses or validates on losing focus does so on every
  reveal that takes the keyboard.
- **The typing guard.** A reveal within a moment of a keystroke anywhere (**Open:** 0.5 s) does not take the
  keyboard: the dock appears, the field does not, and typing carries on where it was. A pointer that drifts
  to the edge mid-sentence cannot hijack it. The summon shortcut and a click on the dock are not guarded.
- **Reveal-to-type can be switched off** (Settings → Dock). Then only the summon shortcut and a click give
  dock2 the keyboard.
- **Full screen.** Summoning works over a full-screen app, as Spotlight does. Revealing there by pointer is
  _Next_.
