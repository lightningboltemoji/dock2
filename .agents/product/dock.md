# The dock

The Dock, redrawn: the same glass, geometry, label, dots and bounce, measured off the system Dock
(`IMPLEMENTATION.md` §1). What dock2 adds — the ring, the echo, number badges, plugin tiles — is drawn in
the Dock's own language.

## Tiles

Left to right:

1. **Finder**, always first; it cannot be removed. A click opens Files ([files](files/README.md)), ⌥-click
   opens Finder itself, and its label says Files.
2. **Pinned apps**, in the user's order. The first launch copies them from the system Dock
   ([settings](settings.md)).
3. A separator, then **running apps that are not pinned**, in the order they started.
4. A separator, then **plugin tiles**, if there are any ([plugins](plugins/README.md)).
5. _Next_: **Trash**; folders and stacks.

A **temporary tile** stands in for a selected search result that is not on the dock. It appears at the end
of the running apps while the result is selected and goes when the selection moves on — unless the app was
opened, in which case it is a running app like any other.

A running app has a dot; an app that is starting bounces until it has. While Files copies or moves, the
Finder tile shows the progress. _Next_: an app's badge and progress, which the hidden system Dock still
exposes through Accessibility (`AXStatusLabel`, `AXProgressValue`).

## The pointer

- **Hover** shows the label. Under auto-hide, reaching the dock is what reveals it.
- **Click** opens the app: launches it, or brings it forward and reopens a window.
- **Right-click** shows the tile's actions: Open, Show in Files, Keep in Dock or Remove from Dock, Hide,
  Quit — Force Quit with ⌥. On the Finder tile: the places Files opens at, and Open in Finder. On the
  platter: Settings, Auto-hide, Quit Dock2.
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
- **The echo**: when the selected result is an app, its tile wears the ring and shows its label.
- **Number badges**: 1–9 over the first nine tiles while ⌘ is held.
- **Plugin tiles**: a plugin's live state — artwork, a badge, a progress ring, a short caption — at the
  dock's tile size, with a label and a click of its own ([views](plugins/views.md)).

## Displays and position

The bottom of the main display. _Next_: the dock moves to the display whose bottom edge the pointer pushes,
as the system Dock does. _Later_: magnification; the left and right edges.
