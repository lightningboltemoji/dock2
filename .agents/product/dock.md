# The dock

The Dock, redrawn: the same glass, geometry, label, dots and bounce, measured off the system Dock
(`IMPLEMENTATION.md` §1), or Snow Leopard's shelf in its place ([visual](visual.md#the-docks-style)). What dock2 adds — the ring, the echo, number badges, plugin tiles — is drawn in
the Dock's own language.

## Tiles

Left to right:

1. **Finder**, always first; it cannot be removed. A click opens Files ([files](files/README.md)), ⌥-click
   opens Finder itself, and its label says Files.
2. **Pinned apps**, in the user's order. The first launch copies them from the system Dock
   ([settings](settings.md)).
3. **Running apps that are not pinned**, in the order they started, straight after the pinned ones: the
   system Dock puts no separator between them.
4. A separator, then **plugin tiles**, if there are any ([plugins](plugins/README.md)).
5. A separator, then **minimised windows**, in the order they were minimised — unless the user's setting puts
   them into their apps' tiles, as the system Dock's "Minimize windows into application icon" does
   ([settings](settings.md)).
6. _Next_: **Trash**; folders and stacks.

A running app has a dot; an app that is starting bounces until it has. An app's badge is the system Dock's,
read off the hidden system Dock through Accessibility (`AXStatusLabel`). While Files copies or moves, the
Finder tile shows the progress. _Next_: an app's progress, which the hidden system Dock exposes the same way
(`AXProgressValue`).

A minimised window's tile is laid out as the system Dock's is — the window as it was minimised, fitted to the
tile, its app's icon in the corner. It arrives as the window finishes minimising, already in its shape, where the
system Dock opens its gap as the window starts to go. The minimised windows are the hidden system Dock's — which,
where it shows, and with what title — so a group of tabs is one tile, as there, of the tab that was on show.
Badges and minimised windows need Accessibility; without it the dock shows neither. The window's picture needs
Screen Recording; without it the tile is a blank window in the window's shape.

## The pointer

- **Hover** shows the label. Under auto-hide, reaching the dock is what reveals it.
- **Click** opens the app: launches it, or brings it forward and reopens a window. On a minimised window, it
  brings the window back.
- **Right-click** shows the tile's actions: a running app's windows, as the system Dock lists them —
  minimised ones marked with a diamond, the main one checked — then Open, Show in Files, Keep in Dock or
  Remove from Dock, Hide, Quit — Force Quit with ⌥. On a minimised window: Open. On the Finder tile: the
  places Files opens at, and Open in Finder. On the platter: Settings, Auto-hide, Quit Dock2.
- **Drag** a tile to reorder it; off the dock to unpin it (a running app moves to the running apps); an app
  from Finder onto the dock to pin it.
- **Drop** a file on an app's tile to open it with that app. Hold a drag over the Finder tile and Files
  opens, for the drag to carry on into a folder.

## Auto-hide

dock2's own setting. The first launch copies the user's value from the system Dock; after that the two
never touch ([settings](settings.md)).

- **On**: the dock is off screen until the pointer reaches the bottom edge and stays for the reveal delay.
  It slides in, and slides out after the hide delay once the pointer leaves — unless dock2 is engaged
  ([interaction](interaction.md)). The delays and the slide are the system Dock's, measured. Coming in, its
  tiles pop onto the platter in a wave from the pointer: dock2's own entrance ([visual](visual.md#motion)).
- **Off**: the dock stays on screen. **Open:** only the system Dock can reserve screen space, so a window
  that reaches the bottom edge sits under dock2's dock. Keeping the hidden system Dock's footprint the size
  of dock2's might reserve it; untried.
- The summon shortcut reveals the dock either way.
- _Next_: ⌥⌘D toggles dock2's auto-hide ([takeovers](system/takeovers.md)).

## What dock2 adds

- **The ring**: keyboard focus on a tile. It looks like the system Dock's own keyboard focus, the one ⌃F3
  shows: the icon darkened as a press darkens it, and its label.
- **The echo**: when the selected result is an app on the dock, its tile wears the ring and shows its label.
  An app with no tile has no echo: a selection moving through the results never grows or shrinks the dock.
- **Number badges**: 1–9 over the first nine tiles while ⌘ is held.
- **Plugin tiles**: a plugin's live state — artwork, a badge, a progress ring, a short caption — at the
  dock's tile size, with a label and a click of its own ([views](plugins/views.md)).

## Displays and position

The bottom of the main display. _Next_: the dock moves to the display whose bottom edge the pointer pushes,
as the system Dock does. _Later_: magnification; the left and right edges.
