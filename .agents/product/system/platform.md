# Platform

## macOS

macOS 26 and later, as dock2 is built. The look is measured per release ([visual](../visual.md)): a release
that redraws the Dock or Spotlight is measured again before dock2 claims to support it.

## Displays

The main display. _Next_: the display whose bottom edge the pointer pushes, as the system Dock does, with
the panel opening on the dock's display.

## Spaces and full screen

The dock is on every Space. Over a full-screen app the pointer does not reveal it (_Next_), but summoning
works there, as Spotlight does.

## What stays the system's

The hidden system Dock keeps running, and with it Mission Control, Spaces, and the system's app switcher
until ⌘⇥ is taken over. dock2 replaces none of them.

Finder keeps running too: the desktop and its icons, emptying the Trash, Get Info, and every folder another
app opens ([files](../files/README.md)).

**Open:** how dock2 and Stage Manager share the edges of the screen.

## VoiceOver

Tiles, the field and results are accessible elements with labels and roles — a list of buttons, a search
field, a list — and the ring and the selection are VoiceOver's focus.

## Distribution

Developer ID, notarized. Installed with Homebrew — `lightningboltemoji/tap/dock2` for a version,
`dock2@tip` for every push to `main` — or from the releases page; uninstalling gives the system Dock back
first. _Later_: updates from inside dock2.
