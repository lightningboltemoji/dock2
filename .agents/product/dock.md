# The dock

The Dock, redrawn: the same glass, geometry, label, dots and bounce, measured off the system Dock
(`IMPLEMENTATION.md` §1), or Snow Leopard's shelf in its place ([visual](visual.md#the-docks-style)). What dock2 adds — the ring, the echo, tile numbers, plugin tiles — is drawn in
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

Beside them, on a puck of their own, the **sidelined apps** while they run ([the sideline](#the-sideline)).

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
  Remove from Dock, Sideline, Hide, Quit — Force Quit with ⌥. On a minimised window: Open. On the Finder tile: the
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
- **The open tile**: while the panel shows what a tile opened — Files, from Finder's tile — that tile wears a
  caret in its label's place, a small capsule of the label's glass with a chevron pointing up at the panel. It
  shows no label meanwhile, hovered or ringed. Clicked again, or chosen again by its number, it closes what it
  opened, back to wherever that came from: the search with its query, or nothing.
- **Tile numbers**: 1–9 under the first nine tiles while ⌘ is held and dock2 has the keyboard, the only time
  ⌘1–9 reach them. Each digit comes up out of its tile's dot and replaces it; an app that is not running has
  one too. The sideline's tiles have none: the numbers are for apps one goes to.
- **Plugin tiles**: a plugin's live state — artwork, a badge, a progress ring, a short caption — at the
  dock's tile size, with a label and a click of its own ([views](plugins/views.md)).

## The sideline

Some apps have to run without being wanted: Outlook, Zoom. Zoom stays open to receive calls and is otherwise
never clicked; on a call, its window is already in front. **Sidelining** an app moves its tile off the dock
onto a small puck of glass at the dock's right end: on the team, not on the field. The dock keeps only the
apps that were chosen, and stays centred.

- **Choosing.** An app tile's menu has **Sideline**, a check beside Keep in Dock; unchecked, the app goes back
  among the running apps. The file has them too, `[dock] sidelined`, bundle identifiers or a path as
  `pinned` has, and its order is the puck's, whatever order the apps launch in. An app is pinned, sidelined or
  neither: sidelining a pinned app unpins it, and Keep in Dock on a sidelined app pins it. Nothing in the
  Settings window yet.
- **Only while running.** A sidelined app is on the puck while it runs and leaves it when it quits, so its
  tiles have no dots. Hiding the running apps does not hide it: sidelining is a choice of its own.
- **Still a tile.** Hover shows its label, a click opens its app, right-click its menu; it hops while
  launching, wears its badge, and search's echo rings it. It takes no number. The arrows walk on from the
  dock's last tile into the puck, in the order it fills. VoiceOver finds the puck as a group after the dock.
- **The puck.** A second piece of the platter's glass, across a gap to its right, standing on its baseline: as
  tall as its rows, never taller than the platter, under the platter's own corners — so a lone app on a small
  dock sits in a round puck — and with room enough that no badge touches its edge. The first app sidelined
  buds it out of the platter's end; the last one leaving draws it back in. A tile crossing between the dock
  and the puck hops over the tiles between, on springs of dock2's own ([visual](visual.md#motion)).
- **How it packs.** Its icons are cells: half a tile, a third, a quarter, never smaller than 24pt. A full
  rectangle first, empty glass only where it can't be avoided — at the top right — and icon sizes that never
  jump far from the dock's: the cells may go one size finer than the largest that holds every app in a
  tile's square, and no more. Then bigger cells, then more rows, so the puck fills the height before it grows
  sideways. Sizes go up and down as apps come and go; each count gets the shape that looks best.
- _Next_: an app asking for attention — a call coming in — which the system Dock bounces and dock2 does not
  yet show, on any tile; dragging into and out of the puck.
- _Later_: a full-height puck, the same packing with cells as large as the platter's height allows, if the
  fitted puck is missed.
- **Open:** what the sideline is on Snow Leopard's shelf, where icons in rows would not stand on a shelf. Until
  it is designed, the shelf ignores sidelining and sidelined apps stand among the running apps.

## Size

Tiles from 16pt to 256pt. The system Dock stops at 128; past it, dock2's dock is the Dock at 128, magnified —
its corners, its margins, its dots — but for the label, which is the Dock's size at every size.

A dock too wide for the screen fits it, its ends kept as far from the screen's edges as the system Dock keeps
its own: a tile's slot, less 6pt, beyond its first and last tiles. In order, the puck's cells go finer, down to
24pt; the dock slides left of centre, just enough; then the tiles shrink, as the system Dock's do.

## Displays and position

The bottom of the main display. _Next_: the dock moves to the display whose bottom edge the pointer pushes,
as the system Dock does. _Later_: magnification; the left and right edges.
