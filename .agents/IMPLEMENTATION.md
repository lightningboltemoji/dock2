# dock2 — Implementation

The _what_, the _why_ and the _how_ of dock2 as it is now. The investigation, the rejected alternatives and
the numbers that settled an argument live in `changes/<id>.md`.

---

## 1. The charter

- **It looks like the Dock, measured, not remembered.** Every number in `Dock2Core` and in `GlassRecipe`
  came off this macOS's own Dock — Accessibility frames, screenshots, pixel profiles — and the tests pin the
  geometry to those measurements. A change to the look is validated the same way, against the real thing.
- **The Mac is never left changed.** dock2 replaces the system Dock by changing its preferences, and every
  other behaviour it takes over outlives it too. Whatever happens to dock2 — quit, signal, crash, SIGKILL,
  power loss — there is a path that puts the user's own state back (§4), and no path that loses it.
- **Private API on stated terms.** Three places use it, each because nothing public does the job: the glass
  (private Core Animation classes, confined to `Glass/`, degrading to `NSGlassEffectView`, §3), the hot key
  table (SkyLight's symbolic hot keys, confined to `HotKeyTable`, §6) and Now Playing (MediaRemote,
  confined to `NowPlaying.swift` and its helper, §11). Each is reached by name at runtime and checked
  before use; nothing that decides correctness depends on it.

---

## 2. Modules

```
Dock2Core    pure — the geometry, the motion, the tile model, auto-hide's rules, the takeover journal, the
    ▲        settings' schema. Foundation and CoreGraphics' geometry types only; all of it unit-tested.
Dock2System  the Mac without windows — takeovers and the guard, the instance lock, the settings' store,
    ▲        the running apps and their windows, the system Dock and what it shows. Tested against a temporary
    │        directory where it can be.
Dock2Plugins the plugin host: the engine (`DockWasm`, the Rust staticlib in `Engine/` that `make engine`
    ▲        wraps as an XCFramework), instances, the store, effects. Tested against `Plugins/test-guest`.
Dock2Shell   the windows — the stage, the glass, the dock; `AppController`, which wires the rest.
    ▲
dock2        executable — the app, `--restore`, and the guard (`--guard <pid>`): one binary.
```

The guard gives back takeovers from a process with no UI, so nothing it runs lives above `Dock2System`.

### Geometry (`DockMetrics`, `DockLayout`, `LabelMetrics`)

Everything derives from `com.apple.dock tilesize`, which dock2 reads and mirrors. Points, Cocoa coordinates.

| Quantity          | Value                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| icon inset        | `floor(tile / 48) + 1` either side                                     |
| tile width        | `tile + 2 × inset`                                                     |
| platter height    | `tileWidth + (tile < 48 ? 12 : 16)`; icons centred in it               |
| platter width     | `run + 2 × (inset + 6)`, rounded to even; centred on the screen        |
| platter bottom    | 5 above the screen's                                                   |
| corner radius     | `min(height / 3, 28)`, continuous                                      |
| running dot       | 4 across (3 below tile 24), centre 6 above the platter's bottom, pixel-snapped; black, or in dark mode +124 to what is behind (plus-lighter) |
| label             | 14pt system text, black 85% or white 95%; capsule 26 tall, `text + 26.5` wide; arrow 7.25 deep, tip radius 1.8; 9 above the platter |

The platter width is exact from tile size 48 up and within a few points below.

---

## 3. The glass

The Dock draws its platter and label in Liquid Glass, rendered by the window server from what is behind the
window. `NSGlassEffectView` reaches the same renderer — a `CABackdropLayer` running the `glassBackground`
filter over a signed-distance-field shape — but only with AppKit's fixed recipes, and in a window over the
desktop it also leaves the specular rims switched off. None of its recipes is the Dock's.

`GlassLayer` builds that tree itself:

- a `CABackdropLayer` (window-server aware, scale 0.5, its own group name) running `glassBackground`, whose
  `inputSourceSublayerName` names a `CASDFLayer` of `CASDFElementLayer`s — the shape;
- one more `CASDFLayer` per rim, each with a `CASDFKeyFillHighlightEffect`.

Shapes are rounded rects, optionally rotated, merged smoothly (`mergeElements`, `smoothness`): the label is a
circular capsule plus a rounded square turned 45°. They move two ways: `setShapes` animates each element from
its presentation to its new frame over one curve, and `play` gives every element a keyframe track
(`Keyframes`) — a stretch of motion sampled ahead, then, if it has one, a loop — for the window server to play
frame by frame. The tree is built at the layer's size, and a resize builds it again, ending whatever it was
playing; so `GlassView` sizes its glass as its own frame changes rather than at the next layout, and a motion
started straight after a resize plays on the tree that stays. A recipe's `lens` inputs, the gem's marble (blur 0.35, refraction −28 over 14 pt), are
animated by key path on the backdrop as the frost is; its `scale` is the backdrop's sampling, whole for the
gem so its facets read through. SDF layers keep `contentsScale` 1; the rim heights were
fitted at that scale. A highlight's angles are in the layer's flipped space: 0 lights the bottom edge, π the
top.

`GlassRecipe` carries the numbers, every one fitted against the real Dock in both appearances, over the
wallpaper and over a high-contrast pattern. The **platter**: blur 0.85, inner refraction −45 over 11.5pt, a
face matrix (light: white 0.8925, black 0.15, saturation 1.3; dark: 0.7812, 0.06, 1.2, with `MaxLuma` 0.8875
holding highlights down), and three rims — a soft top-and-bottom light (dimmer in dark mode), a sharp line on
the same edges, and a black hairline just outside the ends. The **label** is the same kind of glass blurred
more (4.5–5.25) and lightened further, under fainter rims; AppKit's "regular" recipe gets its fill right but
blurs too much.

Layering is load-bearing: anything below the backdrop in the window is refracted by it, so icons and dots
live in a view above the glass view, never beside it in the same layer.

The system's display settings (`DisplayOptions`) are followed as they change. Reduce Transparency hides the
glass for the union of its shapes filled with the window background; Increase Contrast strokes that union in
the secondary label colour, glass or not; the path follows a shape's motion. Under Reduce Motion
(`Motion.adjusted`) nothing slides, morphs, pops or rises: a reshape puts the tiles in place at once and
crossfades the dock to them, the hidden dock stays where it shows and fades out, Files' growth crossfades the
panel, and the field and its glass fade in and out where they stand. `DOCK2_REDUCE_MOTION`, `DOCK2_REDUCE_TRANSPARENCY`
and `DOCK2_INCREASE_CONTRAST` turn each on for development; all three were seen so.

---

## 4. Takeovers

A takeover is a system behaviour dock2 changes while it runs. Each one's state outlives dock2 — a
preference the Dock reads, a hot key the window server holds — so whatever happens to dock2 — quit,
signal, crash, SIGKILL, power loss — there is a path that puts the user's own state back, and none that
loses it.

### Suppressing the system Dock

The Dock reads its preferences when it starts, so `SystemDockTakeover` writes `autohide = true` and
`autohide-delay = 1000.0625` — not the 1000 a common tip has users type, so that it marks dock2's hiding
alone — and `minimize-to-application = false`, so that minimised windows stay items of the hidden Dock's
own for dock2 to read (dock2's own setting puts them in their apps' tiles), to `com.apple.dock` and
restarts the Dock (SIGTERM; launchd relaunches it). A journal an older dock2 wrote lacks the keys it did
not override; the Dock still holds the user's values for those, which are journaled before they are
written (`completed`). The keys
are written only if they differ, and the Dock restarted only if something changed; the Dock is found in
LaunchServices' list and the process table both, since one launchd has just started is in the table before
it checks in. A value is cleared before
it is set (`PreferenceDomain`): cfprefsd skips a write `CFEqual` calls equal, and `95` equals `95.0`.

### The journal

`Takeovers.engage(id)` records the user's state for that takeover in
`~/Library/Application Support/dock2/takeovers.plist` (`TakeoverJournal`: each takeover's original as a
property list) before it changes anything, and changes nothing if the journal cannot be written. **The
journal is the only record of the user's state.** A launch that finds one keeps it — the system by then
holds dock2's state — and gives back at once any entry the new run will not take over. A known takeover
the journal lacks whose **mark** the system shows — a state only dock2 leaves — is recovered from the
system's state (`recovered()`), so dock2's own is never journaled as the user's: a Dock whose reveal delay
is 1000.0625 (its other keys at dock2's values taken to have been unset), `NSFileViewer` naming dock2, a hot key
off in the window server's table while `com.apple.symbolichotkeys` — which the table is loaded from, and
the user's switch in Keyboard Shortcuts writes — leaves it on. An unreadable journal is set aside
(`takeovers-unreadable-<epoch>.plist`, since it may hold what recovery cannot know) and recovered the same
way; entries a newer dock2 wrote, under names this one does not know, are kept as they are. The first
dock2's `system-dock.plist` is read as the system Dock's entry and replaced. A give-back is read back:
`release` forgets only what the system took, keeping the rest for the guard, `--restore` (which then exits
1) or the next run to try again; nothing is taken over on a recovery that could not be written, and the
guard, as `--restore` does, recovers marks even with no journal on disk; `releaseAll()` gives everything back, the system Dock last since that
restarts it, and the journal goes once it holds nothing.

### Ownership: the instance lock

`InstanceLock` is a `flock` on `dock2.lock` beside the journal, close-on-exec. Whoever holds it owns the
journal: a running dock2 for its whole life, `dock2 --restore` while it runs, or the guard while it
gives back. A second dock2 waits two seconds for it, then exits.

### The guard

Before taking anything over, dock2 starts `dock2 --guard <pid>`: the same executable, in its own session
(`POSIX_SPAWN_SETSID`, so a terminal's Ctrl-C reaches dock2 alone), inheriting no descriptors but stdio and
a readiness pipe. It ignores SIGINT, SIGHUP and SIGTERM, waits on a kqueue for dock2's exit — which reports
every kind of exit, SIGKILL included — then takes the lock without waiting and gives everything back if the
journal is still there. If a new dock2 already holds the lock, the journal is that one's and the guard
leaves. `GuardKeeper` starts another guard if one dies, at most five times a minute.

### The paths back

| What happens to dock2                  | What gives everything back                      |
| -------------------------------------- | ----------------------------------------------- |
| Quit (menu), SIGINT, SIGTERM, SIGHUP   | dock2 itself, in `applicationWillTerminate`     |
| crash, SIGKILL                         | the guard                                       |
| dock2 and the guard both killed, power loss | the next launch keeps the journal and gives back on quit; or `dock2 --restore` |

## 5. The Dock itself

### The stage

Everything dock2 draws is in one window, `StageWindow`: a borderless, non-activating `NSPanel` at the
Dock's level, on every Space but not full screen ones (joining them while engaged), covering the screen.
A borderless, non-opaque window passes clicks, moves and scrolls through every fully transparent pixel and
catches them on anything with alpha above zero (on glass, to a point or two beyond its shape), so covering
the screen costs the apps beneath it nothing — and a stage that never resizes never rebuilds its glass in the
middle of a motion. That holds only while nothing sets `ignoresMouseEvents`: set at all, even to false, it
has the whole window catch the mouse, and nothing public puts it back. The window can become key but never asks to: no view in the dock
needs it. Layouts are computed in the stage's coordinates — the screen's, less its origin.

The stage holds the platter's `GlassView`; the panel and the label have glasses of their own. On it lies the glass's `overlay`, a layer in the same tree with Core Animation's private
`allowsGroupBlending` off: a compositing filter blends only with what its own group has drawn, so a dot's
plus-lighter in a sibling view, or under any ordinary container, blends with nothing and shows its plain
grey. Everything the dock draws lives in that overlay; `DockView` is the transparent view that takes the
clicks, menus and drags. The label is a view of its own above it, with its own glass, ignoring the mouse. Its
name is a `CATextLayer` with no `contents` action: the layer draws a new string as the run loop's transaction
commits, outside the one that moved the label, and would fade the last name into the next.

Hover comes from the mouse monitors, not a tracking area. dock2 is never the active app, so the window server
sends pointer moves to the frontmost app, and a tracking area on the stage hears only some of them. The
monitors hear every move, each with the window under the pointer (`mouseEventWindowUnderMousePointer`, the
window server's pick, passing over transparent pixels as a click does): over the stage, the tile under the
point is hovered; over anything else — a menu, another app's window above the dock — none is. The panel's
controls light the same way: `PanelController.pointerMoved` hit-tests the panel and lights the `Hoverable`
under the pointer, and only it.

### Tiles

`DockModel.compose` decides the tiles: Finder, the pinned apps, then a separator and the running apps that
are not pinned in launch order (`RunningApps`: regular apps, `launchDate` order, dock2 excluded), then a
separator and plugin tiles, then a separator and the minimised windows, in the order they were minimised. `DockLayout` places tiles and separators — a separator's slot is 0.45 of a
tile, its line a point wide from the slot's centre, `tile − 10` tall, centred. `AppDirectory` resolves an
app to its URL, name and icon once, and forgets one the catalog finds moved or at another build — its
Info.plist read from disk, since `Bundle` keeps the first it read — the dock redrawn. Icons are rendered at the tile's size: an `NSWorkspace` icon reports
32pt, and rasterised at that size it would be stretched.

`DockView.show` diffs by identity (`TileKind`, `DockGroup`): survivors slide to their new places, a new
tile grows in place from nothing (an explicit animation — implicit ones skip a layer added in the same
transaction) and a removed one shrinks away, while the platter's glass shape reshapes on the render
server, all on the measured reshape curve. Layers are moved by bounds and position, never `frame`, since a
growing tile carries a scale; and the container's implicit `sublayers` action is off, or adding a tile
would cross-fade the whole row.

A click opens the app with `NSWorkspace.openApplication`, which launches it or brings it forward and
reopens a window; Finder's tile opens Files, and with ⌥ Finder. An app starting — from dock2 or anywhere — hops until it
finishes launching (`isFinishedLaunching`, observed per app; launching is no change to
`runningApplications`). The separator takes 57 levels off the glass with a plus-darker blend, and in the dark
appearance adds 65 with a plus-lighter one, as the system Dock's does; the dot is black, or plus-lighter in
the dark appearance — 148 against the system Dock's 150 at its brightest.

The right-click menus come from closures (`MenuBuilder`): a tile's windows, if its app runs, then Open — for a
running app too, as a click does — Show in Files, Keep in Dock or Remove from Dock, Hide, Quit and, under ⌥,
Force Quit; a minimised window's Open “title”; Finder's places — `Places`, the path bar's too, volumes included — and Open in Finder; the platter's
Settings…, Auto-hide and Quit Dock2. A menu carries dock2's items alone: `allowsContextMenuPlugIns` is off, or a
right-click's opens with the system's Ask Siri above them.

### Badges and minimised windows

Both come through Accessibility; without it neither shows, and nothing asks for it.

**Badges** are the hidden system Dock's. An app tells only the Dock, whose application items say the label as
`AXStatusLabel`: digits, a word, or a space for a bare dot. `SystemDockItems` reads each item's subrole, URL,
label and title in one call, off the main thread. The Dock posts nothing when a badge changes, so it is read as the
dock starts to show and every second while it is on screen — about 0.2 ms a read for every item — and
otherwise only as minimised windows come and go. `TileLayer` draws it to the Dock's
measurements (`DockMetrics.badge*`, at tile sizes 64 and 128): a red circle `tile × 25/64` across, sRGB
(246, 68, 58), its top right on the icon's, widening leftward into a capsule that keeps 0.16 of its height
either side of the label; the label white, in the regular system font at half the badge's height, its
capitals centred; a soft shadow, mostly below. A Dock restart clears every badge until its app sets a
different one, since AppKit sends no label equal to the last; it also brings every minimised window back.

**Minimised windows** are the hidden system Dock's too: it keeps one `AXMinimizedWindowDockItem` per window,
in the order minimised, and a group of tabs is one — where AppKit says every tab is minimised, and so does
each tab's `AXMinimized`. The Dock posts `AXCreated` and `AXUIElementDestroyed` as items come and go, so
`SystemDockItems` observes it and reads its items again on each, on a thread of its own (`RunLoopThread`); a
Dock that quits is looked for again every half a second for ten. An item has only the title its window had
when minimised — the Dock does not follow a retitle — and nothing that says whose window it is.

So `MinimisedWindowMatch` matches each item once to an app window: among `AppWindows`' minimised windows,
the one of that title no other item has that was minimised last. `AppWindows` is an `AXObserver` per running
app, on a thread of its own, so an app that hangs holds up that thread alone (each app's messaging timeout is
a second); it hears windows created, destroyed, minimised, restored and retitled, and the main window
changing, keeps standard windows and minimised ones — which call themselves dialogs — and numbers each as it
is minimised. A group of tabs says its tabs are minimised one by one, the tab on show last, which is how the
match finds it. The Dock can show an item half a second before the app says the window is minimised; it is
matched once the app does.

The match gives the tile its app and shape. `WindowTileImage` lays it out as the system Dock does around a
blank window: the window's shape fitted into 15/16 of the tile and centred, its title bar and buttons at the
window's own scale, in the dock's appearance, and its app's icon, 3/8 of the tile, in the corner — a square
with a bare corner while unmatched. Its label is the Dock's title. A click presses the Dock's own item, which
restores the window and brings its app forward as a click on the Dock does, and the genie comes out of the
hidden Dock, where dock2 cannot reach it. With `minimizeToApp` they have no tiles; the hidden Dock keeps them
as items either way. A running app's menu lists its windows first, from `AppWindows`, as the Dock's does: the
Window menu's diamond (`NSMenuItemDiamond`) on a minimised one, a check on the main one; one of those raises
its window through Accessibility — restored, made main, raised, its app frontmost.

### Drag and drop

A tile is dragged with an `NSDraggingSession` carrying only `zip.tanner.dock2.tile`, so nothing else can
take it. While a drag is over the platter (or 12 pt above or below it), a gap opens among the pinned apps at
the pointer, measured against the row as drawn so it holds still until the pointer passes the next tile's
middle; what is carried, if pinned, leaves its place for it. Dropped there, the app is pinned at the gap — a
reorder, or a pin for a running app; ended away from the dock — a drag the dock did not take, judged by where it ended, since one Esc
cancels reports no operation either — a pinned app is unpinned. The dock draws, numbers and counts only the apps it
can draw: a pinned app not installed stays pinned, out of sight, for when it is again, and a press outlives a
relayout on the tile it began on. `.app` bundles dragged from elsewhere pin the same way. Other files
highlight the tile under them if its app is among `urlsForApplications(toOpen:)` for every one, and drop
into `open(_:withApplicationAt:)`.

### Auto-hide

dock2's own (`AutoHide`, a pure reducer, run by `AutoHideDriver`), measured off the system Dock: the pointer
touching the screen's bottom row anywhere along it reveals the dock 220 ms later; it stays while the pointer
is below the platter's top at any x, and slides away 57 ms after it rises above; the slide is 240 ms on a
cubic Bézier (0.35, 0.15, 0.65, 0.85) over the platter's height plus its 5pt gap. Global and local mouse
monitors (no permission) report the pointer; the delays (0.19 s and 0.045 s by default) allow for dock2's
own latency, on dispatch timers of their own since `asyncAfter`'s leeway showed. A menu, a drag or engagement
holds the dock up. Slid away, the glass clears to alpha 0, as Reduce Motion's hidden dock fades to it, so
nothing at the screen's edge is dock2's; it is drawn again before the slide in. Slid in from all the way
away, the tiles make an entrance of dock2's own (`EntryMotion`, tuned by eye against recordings, not
measured): halfway through the slide they pop onto the platter in a wave from the pointer, or from the middle
when the pointer is not on the dock — each icon growing from three quarters of its size past it on a spring and settling,
fading in from half its opacity with its dot, the separators fading in from half as the wave passes. The label ignores hover from
the moment the dock starts to slide away: until it is gone, the stage is still what lies under the pointer.

| Motion | Measured | |
| --- | --- | --- |
| reveal, hide | 240 ms, Bézier (0.35, 0.15, 0.65, 0.85) | `DockMotion.slide*` |
| tiles moving, platter reshaping | 360 ms, the same curve | `DockMotion.reshape*` |
| launch hop | parabolic, 700 ms a hop, `tile / 4` high, one after another | `DockMotion.hop*` |
| tiles' entrance | dock2's own: a spring of 0.45 s, bounce 0.45, from three quarters size (+3% at its peak), fading in from half its opacity over 0.5 s; the wave 0.12 s to the farthest tile, and 12 ms more a tile | `EntryMotion.pop*`, `wave*` |

### Settings

`SettingsStore` reads and writes dock2's own defaults domain, `zip.tanner.dock2`, named explicitly since a
run from `.build` has no bundle. Every setting is a typed `SettingKey` in `Settings` with its default; a
`Codable` value is stored as the property list it encodes to, so `defaults read` shows it. Observers hear
a change on the main actor, including one made by `defaults write`, through Key-Value Observing — which is
why setting names carry no dots. The dock reads only these. The first launch copies the system Dock's
pinned apps (once each), tile size, auto-hide, reveal delay, slide speed (`autohide-time-modifier`, which
scales auto-hide's slide; 0 is none), launch animation and where windows minimise to
(`minimize-to-application`) into them (`SystemDockSettings`), the keys dock2
overrides read from the journal when one exists (`usersDockPreference`).

## 6. The keyboard

### Taking it and giving it back

`Interaction` (Core) is a reducer over who has the keyboard — resting, revealed, engaged — and
`InteractionController` runs it. Taking the keyboard makes the stage key with the field first responder;
giving it back is `NSApp.deactivate()`, which returns key status to the app in front — that app keeps the
menu bar throughout, and its window resigns key meanwhile. The pointer on the dock (the band while auto-hide
shows it, else the platter) starts the dwell, 150 ms; it takes the keyboard unless a key went down anywhere
in the last 0.5 s (`CGEventSource.secondsSinceLastEventType`), and a refused or spent dwell waits for the
pointer to come back. Summoning — the shortcut, a click on the platter — takes it unguarded and holds the
dock up (`AutoHide.Hold.engaged`). Dismissal: Esc on an empty field, ⌘W, a click elsewhere (a global monitor),
another app activating, an app opened from the dock. Engaged, the stage joins full screen Spaces; at rest it
leaves them. Settings, however it is opened from the panel — ⌘,, the Settings command, the Files section's
note, the dock's menu — goes through `InteractionController.handOver`, which dismisses without the
deactivation, and comes forward with `activate(ignoringOtherApps:)`: cooperative activation refuses plain
`activate()` from a non-activating panel.

### The field

`PanelController` draws it in its own glass over the stage — Spotlight's measured field: a 640 × 57 circular
capsule, a 23 pt magnifier from 22.5 pt, 26 pt regular text from 63 pt on a baseline 19.5 pt up, centred 44 pt
above the platter so a label fits between. Its recipe is the label's, less saturated, with a sharp rim, and
once something grows from it, frosted by the filter's face fill — light 97% white, dark 11% grey, at 0.6,
from the same colour at 0 — enough for small text over a dark window or a white page while it still reads
as glass. `GlassLayer.setFrosted` animates that input from its presentation value, in the transaction that
sets it, over the slide whenever the panel grows from the field or shrinks back to it; and
a two-layer shadow stands in for the window shadow Spotlight's field has, cut away where the glass is (a
shadow under a backdrop is refracted by it). The recipe cannot merge with the platter's, so the field comes
in on an entrance of its own (`EntryMotion`): the glass, the shadow and the contents rise 32 pt into place
over 0.36 s on a Bézier (0.2, 0.8, 0.2, 1), growing from 94% about the field's centre, while the panel fades
in through a radial mask over 0.15 s, in a wave from the field's bottom centre at 1,800 pt/s — whole behind
its 160 pt soft front, half past it. The mask does the fading, Reduce Motion's in place too, since an alpha
set and animated in one transaction animates from the value it replaced. Summoned with the dock away, the
entrance waits 0.1 s and rises out of the dock coming in; anything that grows the panel meanwhile — typing
ahead — runs it at once and ends the fade. Dismissal plays it back in 0.18 s on (0.42, 0, 0.58, 1), the glass
fading as it sinks. Results grow the panel to them and back on springs of dock2's own, edge by edge
(`GrowthMotion`), started from Spotlight's measured 57→467 pt in about 235 ms and back in about 210: an edge
moving out has a response of 0.3 s at 0.78 of critical damping, a little past and back — 6–8 pt on a full
growth — and one moving in 0.22 s, critically damped and stopped at its place, so the panel never dips into
the field. A change that comes mid-flight carries on at the speed the panel has rather than from rest. The
rows are revealed from the field up as the glass covers them, the shadow moving with it. A screen — a view, Files —
lies in a container masked to the glass's shape as it moves (`setGlass`), so nothing of it shows outside
the glass, and fades in from a quarter of the way through the growth; the field fades out under a bar,
where it was, and is hidden once gone, so it takes no click meant for the bar. A hairline divides the
field from what grew, inside that container: as a bare layer on the panel's view it was ordered beneath the
glass. Glass shapes, the clip, the shadow and the reveal play from one track (`FormDriver`, below).

**The field's form** (`Settings.fieldForm`) is what it is while empty: Drop, Gem, Lava lamp, or the capsule
above, which is also what Reduce Motion, Reduce Transparency, Increase Contrast and a Mac without `GlassLayer`
get. `FieldMotion` (Dock2Core) simulates a form — every shape on springs of its own, stepped at 240 Hz — as a
deformation riding on the panel's own motion: the body as `PanelController` asks for it, rising in on a tween,
growing to its results on `Growth`'s springs. So the pour and the growth run at once, as they must, the
first letter nearly always bringing results. Every slow motion of a form at rest is a whole number of cycles
in 24 s (the gem tumbles two and three turns), so its rest loops. At each change — the field filling or
emptying, a letter, the target moving, the entrance, the dismissal — `FormDriver` takes the motion as it
stands, applies the change, samples it at 60 Hz until it settles (resting, for 3 s, until what it rested
from has died away), and plays the samples as keyframes on the glass's elements (a solid fill's or a
border's path too), the shadow's paths, the screen clip, the rows' mask (kept to the body's width as it
pours, so rows never show past the glass) and its reveal (as high as the body reaches above the field), the
gem's faces (`GemFaces`, beneath the glass so it bends them, masked to the body), and the field's magnifier,
text, spinner, and the ghost of a cleared text. A rest is then followed by its 24 s loop, sampled at 20 Hz
and phased to the media time; a change inside it starts again from `FieldMotion.resting(at:)`, the same
state. The main thread spends a few milliseconds a change and never drives a frame. Emptied with results
showing, the form waits for the panel to shrink back to the field before it collapses. `setGlass` goes
through the driver whatever the form: the capsule's has no shapes of its own (`CapsuleSim`), so the driver
plays the panel's motion alone and leaves the field to itself. At rest the field
takes clicks only within 48 pt of its centre, so the empty space around the form passes them through.

The field's `doCommandBy` delegate gets the text system's commands, after any input method: with nothing
typed, ← → walk the ring, fn← fn→ go to its ends, ↩ opens the ringed tile, ↑ opens its menu above it, Esc
dismisses; Esc with a query clears it; cleared — by Esc or by deleting — with the pointer
gone from the dock, the empty field stays dock2's as if summoned, so the next Esc dismisses and the next
letter is still the query's. ↩ on the ring and ⌘1–9 use a tile as a click does — Finder's opens
Files, a plugin's tells its plugin. The stage's `performKeyEquivalent` takes ⌘1–9 (tile n), ⌘W, ⌘,
and ⌘K, and swallows ⌘Q. ⌘ held alone 0.3 s shows number badges: label-glass capsules on the first nine
tiles' top edges.

**The ring** is how the system Dock draws keyboard focus on macOS 27 (⌃F3): the icon darkened to 48%, as a
press darkens it, and its label. The pressed shade is that same 52% black.

### ⌘space

`HotKeys` registers chords with Carbon (`RegisterEventHotKey`; no permission). With `summonShortcut` at
⌘space, Spotlight's entry 64 in the hot key table is a takeover (§4), engaged before ⌘space is registered and
released at once when the setting changes; the guard switches it back on after a `kill -9`.

## 7. Search

Every change to the field starts a `SearchSession` (Core): its sources are started together, and its first
frame — `freeze()`, which picks the top hit and fixes the order — comes when every source has answered or
50 ms after the keystroke, whichever is first. After it, a result only ever joins the far end of its section;
a first frame with nothing in it lets the first result to arrive be the top hit. Rows run upward from the
field: the top hit, then per section (Apps, Commands, Clipboard, Files, then plugins) its best three — five
for Files — then "Show all…" and its title. Selection follows a row's identity (`app:`, `file:`, `cmd:`…).

`Matcher` folds case, diacritics and width and splits names into words at spaces and punctuation, case
changes and letter–digit changes; a match is exact, a prefix, word prefixes in any order, initials, or — for
apps and commands — a subsequence, ranked in that order, then by the source's signal, name and identity.
`LearnedPicks` (`picks.json`) puts the result chosen for a query first for that query and longer ones still
matching it, the longest query's pick winning. `Usage` (`usage.json`) counts what dock2 opened, decayed by
recency: an app wherever dock2 opens it — a tile, ⌘1–9, the ring, search — and a command as it runs; no
other action counts. A result's `tiebreak` decides only between equal signals: for apps, the system's use
count, then its last use. A query that starts with `~` or `/` once trimmed, as search reads it, is a path.

| Source | Answers from | Signal |
| --- | --- | --- |
| Apps | `AppCatalog`: `/Applications`, `/System/Applications`, CoreServices' Applications, `~/Applications`, Finder, three folders deep, never inside a bundle, watched with FSEvents; and the running apps | running, then dock2's own use; `kMDItemUseCount` and the last use only between equals |
| Commands | dock2's own: Settings, Clipboard History, Toggle Auto-hide, Quit Dock2 | dock2's own use |
| Files | `MDQuery`, synchronous on a queue of its own, capped at 2,000: each word `kMDItemDisplayName == "w*"cdw`, apps excluded; one or two characters search the near places — the protected folders only where looking asks nothing (`FileAccess.isClosed`, the rule Files' locks and the preview's folder count use too: choosing Full Disk Access is not the grant) — and what was used in 90 days; "Show all…" lists the section's own results in Files, as search filtered and ranked them, until the query is changed there | `FileRanking`: near places, home and the folders Settings → Search ranks first, elsewhere, system; recency; depth; build and dependency trees and hidden folders last |

The catalog skips dot-files itself rather than with `skipsHiddenFiles`: Safari in `/Applications` is a
symlink flagged hidden. Spotlight takes no condition on `kMDItemPath`, so noise cannot be left out of a
query, only ranked down after it; a cold query takes up to a second, a warm one about 20 ms.

↑ and ↓ move the selection, ↩ runs a result's first action, ⌘↩ its second, ⌘K pops all of them at its
row (`ResultActions`) — a file's Open With a submenu filled as it opens, since asking which apps open a
file is slow, and Files' own, pills and all (§9); running one records the pick and the use and dismisses, unless it opens a view — Show in
Files, Quick Look — or another kind of view; Keep in Dock, Pin and Delete dismiss too, a clip's Delete
(⌘⇧D) without asking, as in the history. Copy Path,
Copy and Move to Trash leave a notice; Force Quit asks first. An action may answer to a ⌘-letter while its
result is selected: a file's Quick Look, ⌘Y, which pushes the file at Files' size onto the stack
(`QuickLookScreen`) for Esc to pop. While file results are shown their folders are watched, and one whose
file goes dims in place until the next keystroke. Titles are drawn in one weight: Spotlight, measured with
"calc", bolds no matched letters, and completes the field inline instead.
The selected app wears the echo: its tile's ring and label, or a temporary tile, dimmed, at the end of the
running apps while it is selected (`DockController.setEcho`); opened, the stand-in carries on in place as
the running app's tile.

The rows are Spotlight's: 56 pt, a 36 pt icon 18 pt in, the title 16.5 pt regular from 72 pt, a 13 pt
subtitle truncated in the middle, the selection a band 9.5% darker than the glass inset 10 pt; at most eight
rows' height before the far end scrolls. A list beside a preview has compact rows (`RowsView.Metrics`): 38 pt,
a 20 pt icon 22 pt in, the title 14 pt from 52 pt, an 11.5 pt subtitle, the band's radius 10. Grown, the
panel's glass is one rounded rect from the field up, the field's radius kept with continuous corners, a
hairline between the field and the rows.

A list's rows keep their views while they stay in it (`RowsView`, by id), so a list changing as the user types
never jumps: a row still there springs to its new place on the panel's outward spring; a new one fades in over
0.12 s, rising 4 pt; one gone fades where it was over 0.07 s, its selection band gone at once, so a selection
that stays in its slot never flickers. A row whose way would meet another's — text on clear glass would read
double — fades in at its place instead of moving. Search's rows view is always eight rows high, the glass's
reveal clipping it, so a row leaving fades where it was as the glass draws back over it; it takes the pointer
only within the rows' reach. From no rows, or unseen, rows show at once; under Reduce Motion they fade in
place.

## 8. Views

The panel's other screens are described rather than drawn: a `ViewNode` (Core) — a list, a detail, a form or
a grid — in the JSON a plugin sends, each node tagged by `type`, an icon one key naming what it is
(`{"symbol": …}`, `{"png": …}`, `{"file": …}`, `{"app": …}`). A tag is short text in a rounded pill, in one
of eight tints — the system's red to gray, the only colours a node names — drawn once (`TagImages`) as a
list row's accessory and inline in a detail's rows. A `ViewHost` owns each one — dock2's own code,
later the plugin host: the renderer draws its node, tells it what the user did, and redraws when it says
the node changed.

`ViewsController` keeps the stack over the search. A view fills the panel at its maximum, eight rows' height,
in place of the results; the field becomes its filter with "Search *title*" for a placeholder, or dims for a
form, whose own fields take the keys. Esc clears the filter, then pops; the last pop gives the search back
its query and, since a session for the same query is kept, its results and selection. A dismissal closes
every view.

| Component | Drawn as |
| --- | --- |
| List | `RowsView`, search's rows, every accessory drawn — the texts joined, the tags and icons side by side: views only for the rows in sight and a row either way, icons asked for as rows come into sight, so two thousand items scroll and filter at typing speed. dock2 filters by title and keywords with `Matcher`, subsequences included, best match first, sections kept; with `filtering: owner` the text goes to the host once typing pauses for 0.15 s, each `filter` event with an
id, and an update that names the filter it answers is dropped if a newer one has been shown. `preview` splits it, compact rows on the left 40% and the selected item's detail on the right, a hairline between them as between Files' columns. An item's ⌘⌫ action (`Chord.remove`) is also a × at its row's end while the pointer is over the row, lit by the panel's pointer monitor as every `Hoverable` is; only that row's names shorten for it. When the selected item goes, the selection passes to the one that takes its place. |
| Detail | an image above, the body's inline Markdown — 13 pt in a list's preview, 14 pt as a view — label and value rows beneath, links live; an image and its text, measured as drawn, are centred together in the room above the foot when they fit, while text alone starts at the top; the status, its facts joined by " · ", in an 11 pt secondary line along the foot under a rule, outside the scroll, so it stays as the body scrolls; the buttons above it, and a scrubber above them, its labels either side, which submits `[id: value]` once let go and keeps its knob while dragged, whatever the owner redraws |
| Form | labelled controls in a column; Tab and ⇧Tab walk them, ⌘↩ submits, an error sits under its field, and what was typed survives the redraw that shows it; a date is a date picker, submitted as ISO 8601's day, a folder a field with Choose… |
| Grid | images with titles in rows from the field up, as the list reads; it scrolls, with views only for the rows in sight and a row either way, the selection kept in view; the arrows walk it, a click selects and a double click runs |

An action is ↩ if first, ⌘↩ if second, its own chord ("cmd+shift+c") if it has one, and on the ⌘K menu at
its row — every action menu, a view's and search's, built by `MenuBuilder.actions`/`action` with the
action's icon, its chord as a menu shows one (`Chord`) and destructive ones red, an ⌥ alternate paired with
its item by that key; search runs a result's own ⌘ and ⌘⇧ chords; a plugin's chord is ⌘ or ⌘⇧ with a letter dock2 leaves it (`PluginChord`: not ⌘K ⌘W ⌘Q, nor the
text-editing ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z), any other taken off as its view arrives; a ⌘-letter, ⌘↩ or ⌘K no view
claims goes to the search only when the search is on top; one marked destructive asks first. `Feedback` is one capsule of glass, 36 pt high: a toast at the panel's far edge — over
the field when it is alone — for 2 s; a confirmation there, its question beside Cancel and the action's
button — the accent colour, red when it cannot be undone — each with its key, ↩ or esc, dimmed after its title,
which gives way to any other key; and after a dismissal, a notice where the field was for
1.2 s ("Copied"), longer for a sentence: a character's eighteenth of a second, six seconds at most. Its glass is
the dock's label's, over the panel's shadow; it
drops 6 pt into place as it fades in and lifts as it fades out, without the travel under Reduce Motion. Clicks
pass through it unless it has buttons (`ToastButton`, a `PillButton`). Each is announced to VoiceOver. The field's spinner, at its trailing edge as far in as
the magnifier is from the leading one, shows a search source still working after the first frame, or a
list loading; a query nothing answers says so in one row.

"Show all…" is dock2's own: the section's results as a list (`SectionHost`), each result's actions with
search's chords — an ⌥ alternate as an action of its own, a submenu, Open With…, as a list of its choices
pushed when chosen — run as search runs them: the pick and the use recorded, then the dismissal and its
notice.

## 9. Files

Files is a screen of its own over the search: 960 × 520 with its path bar in the field's place, the
panel's glass growing to it on its springs (`GrowthMotion`). Everything in it sits 10 pt in from the glass's edge
(`FilesLayout`), so what is rounded inside is concentric with the panel's 28.5 pt corners. One `FilesScreen` lives as long as dock2, so it
opens where it was. Ways in: Finder's tile (⌥ for Finder), a place from its menu, Show in Files (⌘↩ on a
result, an app tile's menu), a path typed in the field — the path bar takes the text over — and Files'
"Show all…", which opens its search across the Mac. Opened from a query, Esc goes back to it; from
nothing, Esc dismisses.

**Where it is** (`FilesState`, Core): up to six tabs, each a chain of columns from home, or from its
volume's root outside home, and the column with the keys; a new tab goes beside the current one, and
closing one shows the next, or the one before when it was last; selections; → into a folder's column, ← back
leaving it open and empty, ⌘↑ adding the parent before the first column; renames and removals followed.
Every URL has one spelling (`URL.canonical`): a folder's URL gains a trailing slash once it exists,
`deletingLastPathComponent` adds one, and a listing resolves `/tmp` to `/private/tmp`, and any of them
would make an item unequal to itself. `DirectoryListing` builds each item's URL from the folder's as
given, sorted by `FinderOrder` (`localizedStandardCompare`, folders first unless Settings says not), a
package a file and a link to a folder a folder. A kqueue vnode source on each folder shown relists it.

**The columns** are Finder's column view, its rows measured through Accessibility: 22 pt rows from 6 pt
down, a 16 pt icon 17 pt in, 13 pt names 20 pt past it, a › for folders, the selection a band inset 10.5
and 10 pt with radius 6 — the accent colour in the column with the keys, grey before it. Three 236 pt
columns and the preview fill the inset width; hairlines between them stop short of its top and bottom.
Each is an `NSTableView` for its keys, type-select, drags and accessibility; the strip scrolls sideways by
whole columns, never past the one with the keys, with no scroller — an overlay one sat over the rows —
and, scrolled, a 16 pt fade at its left edge (a gradient mask on `ColumnsView`). The preview takes the
last 232 pt: a Quick Look thumbnail, name, kind and size, then its dates beneath a rule as label and value,
or a folder's count; space fills the view with a `QLPreviewView`, inset with corners concentric with the
panel's.

**The path bar** (`PathBar`) shows the folder as a breadcrumb of `PillButton`s — a rounded fill lit by
hover, press, a drop held over it, tinted for the current tab — with chevrons between, and the selected item
after them, named but inert. The first crumb is the places' pop-up (`Places`, read as Files opens and as
volumes mount and unmount): each with Finder's key, the one holding the folder checked and positioned
over the crumb, as a pop-up button's menu is, then the volumes and Go to Folder…. Too long to fit, the
crumbs fold from the second on into "…", a menu of the folders folded; the last truncates. The tabs
(`TabStrip`) end it: with one tab only New Tab, from two a pill each, 84–176 pt, sharing up to half the
bar. `~`, `/` or ⇧⌘G turn it into a text field at the
field's size: Tab completes with `PathInput` (case ignored, a single folder taking its slash), the columns
follow the deepest folder typed, ↩ goes. ⌘F turns it into a search of the folder: Spotlight scoped to it,
and a walk of it for what Spotlight has not indexed, stopped after 50,000 items or 1.5 s and passing over
the folders looking in would ask about (`FileAccess.asks`, the grant probed once), the results beside the
preview with where each is; ⌘↩ shows one in the columns. While its field is edited — a path, ⌘F's query —
the text keys (⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z ⌘⌫) are the field's, not Files' commands.

**Operations** (`FileOperations`, System) run one at a time on a queue of their own. A copy is
`copyfile` with `COPYFILE_CLONE | COPYFILE_RECURSIVE`, a clone on one volume (300 MB in 1 ms against
124 ms copied), written under a hidden name and renamed when whole, so a cancelled one leaves nothing.
A clone reports no bytes as it goes, so progress counts each file's size as it finishes. Its callback stops at the first file it cannot read: told to carry on, copyfile skips the file — and a
move across volumes, a copy then a removal, would remove it with its source — or, on a data error, retries
for as long as the job runs. A name already taken stops the operation for the banner's question — Skip,
Replace, Keep Both (↩), for all — answered on the main actor while the queue waits. What a Replace puts
aside goes to the Trash once the newcomer is ready to take its place, and the move keeps where; where
there is no Trash it is deleted, as Finder replaces. A copy into its own folder is a duplicate, as Finder
makes one; a move there does nothing. Undo and redo replay the records: copies are trashed, moves moved
back, what was replaced put back, the trashed put back from where the Trash took them, an empty new folder
removed. A job that fails partway is recorded as far as it went.

**Problems** (`FileProblem`) name the item an operation failed on and what would help: a privacy denial
(EPERM) without Full Disk Access offers Allow Access…, a file's own permissions (EACCES), a locked file
(EPERM too, under `uchg` — "“frozen.txt” is locked.") and anything else Show in Finder, a missing item
nothing. On an item in view the problem goes beneath its name — up to two
lines in a 246pt column, "“locked.txt” can't be read." — with the remedy as a button under it and first in
its menu, the row as tall as they need; otherwise it is a toast. A new job — a copy, a
move, a trash — or Files closing clears them. dock2's own "Show in Finder" goes through `FileViewerTakeover.showInFinder`:
a reveal when dock2 is not the file viewer, else the item's folder opened in Finder; Open in Finder with
nothing selected opens the folder itself (`openInFinder`). Jobs that outlast half a second show a row with progress and a stop button, the Finder tile a bar
across its foot, and — going into a tab's folder — a ring filling on its pill in place of its icon. Delete at once asks first. ⌘C writes file URLs for any app; ⌘V copies them here,
⌘⇧V and ⌥⌘V move them.

**Actions**: ⌘K and a right-click show one menu (`actions(for:in:)`) — Open, Open With, Quick Look, Rename,
Duplicate, Copy, Copy Path, Copy Contents, Copy to and Move to each other tab's folder, Move to Trash, New
Folder, Open in Finder — each action taking its items rather than reading the selection. ⌘K's is for the
selection where the keys are, beside it. A right-click's is for the selection when the item clicked is in it,
otherwise for that item alone with the selection left as it was, so a folder right-clicked opens no column;
between items, for the column's folder. The table's own outline of the row is a square box its full width,
so `ColumnTable` hands back the menu without the table's handling and the row draws a ring where its band
would be. Rename is left off search's results, which are no column's to edit in. Open With (`OpenWith`,
search's too) is LaunchServices' list, as Finder's is: the first item's default app, then the apps that open
every item by name, one copy of each by bundle identifier. Its submenu (`OpenWithMenu`, search's ⌘K's too)
ends in a "Remember for" row of pills (`MenuPills`), at most one lit and none when it opens: This File (These
Files), offered when dock2 can write to them all, and All .ext, when they share a type and its extension —
a file without one is typed as broadly as data. An app picked with one lit is remembered before the files
open in it (`OpenWith.remember`): on each file, silently, or for the type, which macOS asks about in its own
alert. Its refusal arrives as a generic error, so the type's default is read back instead, and a yes drops
each file's own app — an extended attribute no API clears — which would otherwise outrank the type's. The
default is labelled "(this file)" when it is the file's own. The row is a view in the menu: highlighted, it
becomes the menu window's first responder and takes ← → ↩ and space, passing the rest to the menu, so ↑ ↓
leave it and ← past its first pill closes the submenu; a key moving onto it rings the first pill, a pointer
does not. Copy Contents (`FileContents`) is offered for one
file macOS reads as an image, or as text — by its type, else by its first 8 KB being UTF-8 with no NUL, since
`.gitignore`, `.env` and TypeScript's `.ts` (to macOS, video) have no text type; a file only in iCloud is
judged by type alone, and rich text not at all. Text goes as a string (UTF-16 by its byte order mark, UTF-8's
mark dropped), an image as its own bytes and a PNG. It is read off the main thread, and past 10 MB a confirmation
asks first, not red: copying it destroys nothing.

**Drag and drop**: a selection drags out as file URLs; a column, a folder's row, a crumb and a tab's pill
take drops — a move on one volume, a copy across, ⌥ and ⌘ flipping it — and a pill held over shows its
tab after the system's spring-loading delay. ⌘K offers Copy to and Move to each other tab's folder. A drag held over a folder
opens it after the system's spring-loading delay, timed by the column, since a table's own drag handling
never asks `NSSpringLoadingDestination`; held over Finder's tile it opens Files. A slow second click on a
selected name renames it in place, as ⇧⌘N's new folder does; a listing that adds or removes items waits
for the rename to end.

**Access**: without Full Disk Access (`~/Library/Safari` readable, which fails silently otherwise), the
three folders — unless the user chose them — and other apps' containers show locked rather than raise a
prompt by looking: a lock in place of the chevron, and inside, "Dock2 can't see in here." over Allow
Access…. The first time Files opens without the grant, unless the first launch asked, the banner asks, as
onboarding does: ↩ opens System Settings, Esc is Not now; Allow Access… asks again, and never with the grant.
Only dock2's own lock (`ClosedForAccess`) offers it: a folder macOS or its owner refuses says what refused
it. The grant is probed once a second at most, since a listing asks it of every folder. A path is judged by its spelling — case ignored, the Data
volume's firmlinks undone (`FileAccess.isClosed`), cheap enough for every item in a listing — and the one
folder about to be listed, watched or completed also where its links lead (`isClosedReached`, each link
read on its own, never inside a closed folder); a listed link into a closed folder is taken for a folder,
what it leads to unread.
Nothing inside a closed folder is looked at — what an item is needs only its folder open, so a reveal, a typed path, Tab's completion and search's
results inside one go to the closed folder holding them, shown locked — nor is a closed
folder watched — `DirectoryWatch` refuses it, for Files' columns and search's results alike — since opening
one to watch raises the prompt and waits on it, the main thread with it. One function records
an answer from Files or Settings (`FileAccess.answer`). Search's Files section ends with a row naming what it cannot see,
which opens Settings → Permissions — alone, after "No results", when nothing at all was found; asked about
each folder, it names the ones macOS refused, which Files shows locked too (`FileAccess.refused`, learned
off the main thread at most once a second, from launch, all three closed until known, while macOS is
still asking, or while the learner itself waits on an ask; `foldersChanged` — on a change, and after a learner slow enough to have had all three closed meanwhile —
has Files read its listings again, Settings its rows and search, when on top, its query, so a folder allowed
in System Settings opens in Files). Once the user chose
to be asked about each, a lock's Allow Access… opens Files and Folders for a refused folder and Full Disk
Access for other apps' data, the choice standing. `DOCK2_FULL_DISK_ACCESS=off` has dock2 behave as if without the grant,
for a terminal that has it. "Show in Finder" is taken over only by the app bundle: `NSFileViewer` names a
bundle identifier, and a build run from a terminal is no bundle LaunchServices can send items to. Items
sent before dock2 has started — the reveal launched it, and AppKit sends them first — wait for it. Handing
the items over, LaunchServices brings dock2 forward; dock2 gives the front back to the app that asked —
explicitly, since under cooperative activation deactivating leaves it nowhere — and only once it has
resigned does Files take the keyboard, because a panel made key while dock2 is active loses it as dock2
resigns. Within that second, the asking app coming back is no dismissal.

## 10. Clipboard history

`PasteboardWatcher` looks at the general pasteboard's change count four times a second and reads it when
the count moves — unless the change is one of dock2's own writes, or `accessBehavior` is `.ask` or
`.alwaysDeny`, when the history pauses rather than raise an alert at every copy, checked every tick. Every
write dock2 makes — a put-back, Copy, Copy Path, Files' ⌘C, a plugin's copy — goes through `OwnWrite`,
which marks it with nspasteboard.org's `org.nspasteboard.source` naming dock2: a put-back is the history's
own and is not kept again, but what dock2 copies for the user is kept as dock2's; and a copy another app so
marks is credited to that app, for the ignored apps too, rather than to the one in front. Starting, it touches what
is there already, so any alert macOS raises answers the user's choice rather than a later copy, and keeps
none of it: who copied it is no longer known, and an ignored app's copy must not go down under whatever
app is in front. An image is kept compact — its PNG, JPEG or HEIC if the copy has one, else its TIFF, which
macOS hands over uncompressed (13 MB for 600 × 400), as a PNG, unless past 40 megapixels — so the cap
measures the picture; and with a 72-pixel thumbnail, ImageIO's, its row's icon. Both are made off the main
thread, the capture handed back to it. `ClipboardPolicy`
(Core) decides from the types and the app in front, never the contents: nspasteboard.org's concealed,
transient and generated markers and the ignored apps — password managers out of the box — are left out,
and so is anything over 10 MB; otherwise the first kind present wins, files to plain text, and every type
of that kind's family is kept, rich text with its plain text. One copy is one entry, by a digest of its
alphabetically first kept type's bytes with its kind; copying it again moves it to the top. `ClipHistory` prunes unpinned entries past
the retention (30 days by default) and the oldest past 5,000.

`ClipboardStore` keeps `Clipboard/index.sealed` and an `<id>.sealed` per entry, each an AES-GCM box,
written atomically on a queue of its own and read on demand. Its key is a generic password in the login
keychain inside the bundle; outside it, and with `DOCK2_KEY_STORE=file`, a file only the user can read —
the Keychain trusts only the build that made the item, and would ask every rebuild. Key calls never run on
the main thread, nor does it wait on one: an entry's data, read synchronously for a paste or a preview, is
opened only with the key the history opened with. A key withheld — a locked keychain, a refusal — is no empty history: the store says so,
dock2 writes nothing over it, keeps new copies' data in memory, tries again at each copy and merges once
it opens, and Settings → Clipboard says the history is not being saved meanwhile. An index the key does
not open is set aside under another name before a fresh one starts.

Search's Clipboard section matches titles, files' names and the copy's text: each entry keeps its first
2,000 characters folded, punctuation as spaces (`ClipEntry.searchText`), in the sealed index, and a query
whose words all start words there matches as a words match with nothing in the title to bold. The history
view filters by the same `ClipHistory.matches`, as its owner. Clipboard History (a command, and an optional
global shortcut) is a list with preview, newest nearest the field; a `ViewHost` may give an item's
preview when it is selected, so the history's text, images and file lists are opened one at a time.
The text preview escapes Markdown, so a copied asterisk stays one. ↩ pastes — the entry written, dock2
letting go, and ⌘V posted at the HID tap 0.15 s later, once the app in front has its window's keys back —
or, without Accessibility, copies and says "Copied — ⌘V to paste", the system asked once, and that first
time why ("With Accessibility, Dock2 pastes for you") — a plugin's paste the same way; ⌘↩ copies;
⌥↩ pastes plain text; ⌘K pins — a pinned entry wears a pin — deletes, opens, and Quick Looks a copied file;
nothing else gets a file on disk for it. ⌘⌫ deletes, and so does the row's × under the pointer, without
asking. ⌘Z puts it back: the delete keeps the entry, its place and its data (`ClipboardController.Deletion`),
registered with the stage window's undo manager — the one the field's typing uses, so ⌘Z undoes whichever came
last — and the restore registers the delete again for ⇧⌘Z. An entry copied again meanwhile is not put back
twice. The host drops what it registered when it closes, so the undo lasts while the history is open. The history's rows are a title alone; the preview's status line says where an entry came from, how
long ago, and how much of it there is — characters, pixels, or files when there are several. Search's
Clipboard rows have the same set, with the same chords — except Delete, ⌘⇧D there, since ⌘⌫ edits the
query — and Show in Files for a copied file besides. A copied colour's preview is a swatch, with its hex and
its `rgb()`. Settings → Clipboard says when it is
paused — reading macOS's answer as it comes forward: asking, or refusing — with Paste from Other Apps' pane,
and turns it on and off,
sets how long entries stay, what ↩ does, the shortcut and the ignored apps, and clears it all.

## 11. Plugins

A plugin is a `.dock2plugin` folder — `manifest.json` and a WebAssembly module — that dock2 runs in an
actor ([runtime](product/plugins/runtime.md)): one event in, effects out, as JSON tagged by `type`
(`PluginProtocol`, Core; the Rust SDK in `Plugins/sdk` is the same shapes from the other side).

**The engine** is wasmtime 49's Pulley interpreter behind a C ABI of dock2's own (`Engine/`): no
executable memory, so nothing the hardened runtime refuses; the Cranelift JIT needed
`allow-unsigned-executable-memory`, and `allow-jit` alone was killed. The guest exports `dock2_alloc`,
`dock2_free` and `dock2_handle` and imports `dock2.log`, `now_ms` and `random`, calls that hand nothing
back into the guest mid-call. A 1 ms epoch ticker and a deadline callback that checks the wall clock end
a call within a tick of its budget: 50 ms for an interactive event, 1 s for background work. The ticker
waits on a condition while no call runs, so idle dock2 wakes about twice in five seconds. Memory is
capped at 64 MiB. A compiled module is cached by the module's hash and the engine's version
(`PluginCache/`), since compiling takes 17 ms and reading back 0.06.

**An instance** (`PluginInstance`) runs on a queue of its own and starts at its first event with
`started` and the plugin's settings. A call that traps, overruns or runs out of memory discards the
instance — the next event starts a fresh one, its storage intact — and five in a minute switch the plugin
off with a notice. Unloaded by the host when idle (below), it hears `stopped` and goes.

**The host** (`PluginHost`) checks every effect against the manifest's capabilities and the user's
grants (`PluginStore`, `plugins.json`). A first-party plugin starts off, holding what it declares, until
the user switches it on; one installed from a folder starts on, since installing it was their choice. A plugin's choices remember what its manifest declared when last
agreed to, so installing again — an update, `dev` after a rebuild — grants only what it newly declares,
keeps what the user revoked revoked and one they switched off off (one dock2 switched off for failing
gets its new code's chance), and a first-party plugin gets what a dock2 update adds the same way. `query`
goes with the results switch: switching results on grants it, off revokes it, and a plugin first seen
holds it only if its results start on. Installing reads the choices from disk first, since another dock2
process may have changed them, and writes them all back. Results' action chords pass the same rule as a
view's, so search's field keeps its text keys. An instance with nothing to do — no tile on the dock, view open,
timer, subscription or unanswered request — unloads after three minutes without an event
(`idleAfter`, the spec's open "a few minutes"), and its next event starts it again; a refused one comes
back as an `error` event under its request id. HTTP goes over HTTPS to the hosts the manifest names, a
`$setting` standing for a self-hosted server; a redirect is followed only within them, else the redirect
is the answer (`RedirectGuard`). A view brings dock2 up only in answer to the user — a command, an action, a
form or a tile, or the answer to a request one made, within 10 s (`answerWindow`) and unless the user has
dismissed dock2 or gone to another app since (`userMovedOn`); any other shows only while dock2 has the
keyboard. A URL opens only in answer to the user too — never to typing — and a file only if it is content — text, pictures, documents — by allowlist: Terminal
settings, Finder's location files, workflows, installers and apps are not content, and scripts, profiles
and shortcuts, which are, are refused too, since opening one runs something. Storage is `PluginData/<id>/storage.json`; secrets are Keychain items under
`zip.tanner.dock2.plugin.<id>` inside the bundle and a 0600 file outside it, read and written on a queue
of their own, since the Keychain may block on a prompt. A secure setting is one of those secrets, under
`dock2.setting.`, a prefix the plugin's own secret effects are refused; the store reads them once, on a queue
of its own, and keeps them, since settings go with every event — a plugin already running hears them as they
come — and moves one found in the clear in `plugins.json` into the secrets. A number setting is saved as a
plugin parses one: "5", not "5.0". A copy or a paste marked concealed carries
nspasteboard.org's marker, so clipboard history never keeps it, and is cleared after 30 s if nothing was
copied since. A toast shows in the panel, or, the panel gone — a plugin that dismissed — as the notice where
the field was. Installing from Settings stops a running older version first. `derive` runs PBKDF2-SHA256 or Argon2id natively, in the
engine's crate, off the main thread: a key derivation is slow by design — 600,000 rounds, or 64 MiB — and
past any call's budget or memory in the interpreter. Timers fire at a tenth of a second at the least,
thirty-two at most.

**In dock2's surfaces** (`PluginsController`): a plugin's commands sit in Commands under its name — those it
last listed with `setCommands`, kept in `PluginData/<id>/commands.json` so Commands is right before it runs,
or, before it has listed any, those its manifest does not mark `hidden` — running one dismisses unless the
manifest says it opens a view; its results, if it answers search and they are on,
have a section of their own and arrive when they arrive, at its end; a result's action leaves dock2 up for
the plugin to decide what follows — a view, a copy that lets go, an app coming forward. A view is a `NodeScreen` on the
panel's stack whose actions, filtering and submissions go back as events; `updateView` redraws it in
place. Tiles follow a separator at the dock's end, drawn by `PluginTileImage` from a `TileNode` — its
picture in an app icon's shape, a ring, a badge, a caption — and redrawn alone when they change, so a
hovered tile keeps its label; a click is a `tile` event. Settings → Plugins switches each one, its grants,
its results, its tiles and its settings, and installs from a folder after showing what it would reach;
search's sources follow the store as plugins come and go. `dock2 plugin list | install | dev | remove` does
the same from a terminal — `dev` installs again each time the module or manifest is rewritten and has
settled, asks again only if what it reaches grew, and streams the unified log's lines about the plugin —
and tells a running dock2 the plugin's id by a
distributed notification: what ran of it stops, the store is read again, its tiles start on the new code.
The store is `@Observable`, so Settings shows what the terminal changed. A compiled module is named by its
hash and replaces the plugin's last; removing a plugin removes its code, storage, secrets and compiled
modules.

**Now Playing** (`NowPlaying`, System): macOS answers MediaRemote's reads only for entitled processes
and platform binaries, so a small library `/usr/bin/perl` loads (`Helpers/now-playing`) streams the state
as JSON lines, artwork only when it changes, and exits when dock2 closes its stdin; commands — play, pause,
next, seek — need no entitlement and are sent from dock2. It runs while a plugin subscribes; the app playing
is named by its running instance, then LaunchServices. The plugin draws the tile (artwork, a ring,
"Paused") and a view with a scrubber and the controls, and puts Play/Pause, Next and Previous in search.
Seen with a probe app publishing silence: the view, and a seek set on the scrubber reaching the player.

**Bitwarden** (`Plugins/bitwarden`): prelogin for the KDF, the master key derived by dock2, the server's
hash (one more PBKDF2 round), the password grant — with an authenticator's or an email's second factor,
or a new device's emailed code — then sync, the user key opened with the stretched master key (HKDF-Expand
"enc" and "mac"), each organization's key with the account's RSA private key (OAEP), and each item with its
own key when it has one: AES-256-CBC under HMAC-SHA256. RSA costs a fifth of a second in the interpreter and
an item 0.4 ms, so the vault opens a slice an event — the organizations' keys in one, three hundred items
in each after, a timer between — and 3,001 items took 13 events, the longest 228 ms. The master
password and key are dropped as soon as they have served; the session — tokens, the KDF, the user key
still sealed — is a secret, and the opened user key one too, until the lock timeout; one whose timeout
passed while nothing ran is deleted as the plugin starts. Only a refused refresh token signs out: offline,
or the server failing, the session and the last sync stay. Every copy is concealed and dismisses dock2;
TOTP codes are computed in the plugin. Its commands follow the session, listed after every event that
changes it: Sign In alone while signed out, then Search Vault and Sign Out, and Lock while unlocked.

## 12. Settings and the first launch

The two ordinary windows dock2 has, in SwiftUI; everything on the stage stays AppKit. While either is open
dock2 is a regular app — a menu bar, a place in ⌘⇥ — and an accessory again when both are closed; its own
dock never shows it. The menu bar's Quit has no ⌘Q.

**Settings** (`SettingsWindowController`) is a `NavigationSplitView` of the sections that exist: General
(open at login through `SMAppService.mainApp`, whose status is the truth; the summon shortcut: ⌘space, a
recorded chord, or none), Dock (size, auto-hide and its delays, type to search, number badges, bounce,
running apps), Search (the field's form; each built-in source on or off, which the search controller then skips; the
plugins' sections in order; folders ranked first, with the home folders; excluded folders, whose files
the file source drops — one `FolderList` for both; the learned picks, each
kept with the title it was picked under, to forget one or all), Clipboard, Files (folders first, hidden
files, the preview column, "Show in Finder" opens Files), Shortcuts (every global shortcut in one list),
Plugins (every grant shown, a plugin on or off), Permissions (Full Disk Access with its state and its
pane, and a button for the three folders alone — once chosen, each folder with its state, opened rather
than listed, and Files and Folders' pane, `Privacy_FilesAndFolders`, checked like the others; Accessibility; Paste from Other Apps — `NSPasteboard.accessBehavior`, `Privacy_Pasteboard`, the
pane's anchor checked in System Settings — each with its state and its pane) and About (version, the first launch again, logs, Quit). `SettingsNavigation` opens the window at a
section. `SettingsModel` gives SwiftUI a binding per key and redraws on any change to the domain; the picks
and the plugins are `@Observable` stores of their own. `ShortcutRecorder` takes only chords that type
nothing: with ⌘ or ⌃, or a function key; beneath a global shortcut's recorder, Settings says which of
dock2's own keys it takes, from `ReservedKeys` (⇧⌘V: "moving here in Files"), or, in red, that macOS
refused it (`ShortcutStatus`, set as each shortcut registers). Open System Settings, from Files' ask,
Settings or the first launch, then watches for Full Disk Access every two seconds for ten minutes, and dock2
says when it lands.

**The first launch** runs when `onboarded` is unset, before the guard or any takeover: a journal a dead
run left is given back first, and nothing else is touched until the last page, which writes the choices —
the system Dock's settings copied, the summon shortcut, file access, "Show in Finder", clipboard history,
open at login — sets `onboarded`, and starts dock2. Closing the window earlier quits with the Mac as it
was. Its dock preview is the platter's glass and the copied tiles over a gradient: AppKit's
`desktopImageURL` reports a fallback picture for the system's own wallpapers, not the one showing. Run
again from Settings, it shows dock2's own dock and copies nothing.

Inside the bundle dock2's defaults are the standard ones: `UserDefaults(suiteName:)` returns nil for the
app's own identifier.

## 13. Accessibility

The dock is what VoiceOver finds in the system Dock: a list named "Dock" of `AXDockItem`s — application
items, plugin tiles as URL items, minimised windows as minimised-window items — each with its name, "running" when its app is, and Press and Show
Menu (`DockItemElement`). Search's results are a list of rows that say their title, subtitle and state,
section titles as headings; VoiceOver stays in the field — a search field, by subrole — while the arrows
move the selection, so the row selected is announced, and while they walk the ring, so the tile ringed is. Toasts, notices, confirmations, Files' conflicts and its access ask are announced
too — a question once, as it is put, though its row is rebuilt with every progress tick; forms'
fields say their names and errors; the magnifier and icons are left out. Files' columns are tables and
Settings is SwiftUI, accessible as they come. `DOCK2_APPEARANCE=dark` (or `light`) draws dock2 alone in
one appearance, to check the other without changing the Mac's.

## 14. Control

`dock2 <verb>` ([control](product/control.md)) is one binary's two ends. The running dock2 serves a unix
socket (`ControlServer`, Dock2System) at `ControlWire.socketPath`: `DOCK2_SOCKET`, else `$TMPDIR/dock2.sock`,
else `/tmp/dock2-<user>.sock`, bound `0600`. It takes over a stale socket of the user's that nobody answers
at, and refuses anything else at the path without touching it. Each connection carries one line of JSON
— `ControlWire.Request`, the version first so another build is named rather than misread — and gets one
line back, then closes. The sockets live on a queue of their own, and a connection silent for 5 s is dropped.
Connections are kept by a count, since a descriptor is reused as soon as it closes.
Only `ControlRouter.reply` runs on the main thread, so a stuck peer never reaches it. The router does what
the keys and tiles do: `summon` is the interaction's `request`, which never dismisses, with a query set
as the field's text; `files` and `clipboard` are the Finder tile's and the clipboard shortcut's paths.

`debug` commands are answered only when `DOCK2_DEBUG=1` was set at launch. `type` and `key` build key
events with US-layout key codes and post them into dock2's own queue (`NSApp.postEvent`), so they take the
path a key press does: key equivalents (`cmd+k`, `cmd+1`), an open menu's tracking, then the stage window's
own look and its first responder. `type` is refused unless dock2 has the keyboard. `hold` posts a
flags-changed event alone. `reveal` is an auto-hide hold of its own (`.control`). `state` is a `DebugState`:
the interaction's phase, the panel's text, form and selectable rows with their frames, the tiles with their
names, kinds, badges and frames, and the field's, the body's, the reach's and the platter's frames, in screen points
from the main display's top left. The CLI (`ControlCommandLine`) composes `capture`, `record` and
`type --every` from those requests and `screencapture`. It also composes `move`, `click` and `drag`, which
post to the HID stream at a `PointerTarget` resolved in that state, a move every 8 ms. dock2 reads the real
cursor and AppKit's drag sessions follow it, so nothing but the real pointer would be the same. A target
not showing is refused. The CLI exits 69 when no dock2 is listening.

## 15. Build and release

`make build` · `make test` · `make app` (`dist/Dock2.app`) · `make dist` · `make notarize` · `make install`.

- **The bundle is `Dock2.app`, and Dock2 is the name people see**: `CFBundleName` and `CFBundleDisplayName`,
  which Finder, Spotlight, the menu bar and the privacy lists show, and every string in the GUI. The
  executable, the CLI, the archive, paths and identifiers stay `dock2`. `make app` copies in the plugins and the Now Playing helper, and signs the
  helper before the bundle, since notarization wants every Mach-O signed.
- **The icon is `Resources/dock2.icon`**, an Icon Composer document that `make app` compiles with actool into
  `Assets.car` and `dock2.icns`. actool is in Xcode only, so a Command Line Tools build has no icon. The
  document is written by `Resources/icon.py` (`make icon-source`, uv), which fits Inter's 2 to the Dock's
  proportions (§1) and fetches the font at a fixed commit. `ictool`, inside Icon Composer.app, renders the
  document in every appearance without a build.
- **The git tag is the only version authority.** `make app` stamps `git describe` into the bundle's copy of
  `Info.plist`, never the source, whose `0.0.0` is what a build from a tarball is. Out of `.build`,
  `dock2 --version` says `dev`.
- **Two channels** (`.github/workflows/release.yml`), both tested first. A push to `main` force-moves the
  `tip` tag and replaces `dock2-tip.zip` on one long-lived prerelease, so its URL is a permalink. A `v*` tag,
  pushed by a human, is that version, published once, and bumps the `dock2` cask in
  `lightningboltemoji/homebrew-tap` with a token minted for the tap alone; `dock2@tip` pins nothing, so
  `main` never touches the tap. Pull requests are built and tested (`ci.yml`).
- **Every credential is in the `production` environment**, which only `main` and `v*` deploy from. Without
  the signing secrets a release is ad-hoc and not notarized. With them, the job imports the certificate and
  stores the notary credentials in a keychain of its own, then runs `make notarize`: one path, local or not.
- **On `$PATH`, the CLI is the bundle's executable through a link** (the cask's `binary`). `Bundle.main`
  does not follow a link, and the settings' domain, the plugins and the key store are chosen by it, so a
  dock2 run through a link into its own bundle first execs the real path (`Dock2Identity.bundledExecutable`).
- **Uninstalling gives the Mac back first**: the cask quits dock2, which releases every takeover, then runs
  `dock2 --restore` for whatever a dock2 that died left; `zap` removes the journal only after both.
- Archives are `ditto -c -k --keepParent`, never `zip`, which mangles symlinks, xattrs and the signature.
  Builds are arm64 only.

## 16. Not yet

- With auto-hide off, dock2 covers the bottom of windows that reach the screen's edge, since nothing public
  reserves screen space.
- Bottom orientation only, magnification off, the main display only.
- No Trash, folders or stacks on the dock. No app's progress: the system Dock's `AXProgressValue` is unread.
- A minimised window's tile is blank where the system Dock's shows the window. Badges and windows were
  measured in the dark appearance only, and a label too long for the icon is truncated by dock2's own rule.
  Windows on another Space when dock2 starts are missing from their app's menu until they change.
- Files: the locks were seen without the grant itself in the built app, launched as its own privacy identity,
  with the user's choice "declined"; the ask's other answers — Full Disk Access granted, the three folders
  allowed — were seen through `DOCK2_FULL_DISK_ACCESS=off`. A move across volumes is tested on a RAM disk when `DOCK2_SECOND_VOLUME` names a folder on one; a
  file dragged from Finder and held over Finder's tile, the dock revealed mid-drag, opened Files.
- Plugins: Bitwarden's sign-in against its own servers is untried, the flow tested against answers sealed
  with real keys instead; plugin commands have no shortcuts of their own.
- Clipboard: the bundle's Keychain key and its prompt are unseen: run from this session's sandboxed shell,
  every Keychain call is refused (-25308), which is how the withheld-key case above was found.
- In the dark appearance the dot and the separator were measured against the system Dock (the Mac switched
  to dark for the purpose); search, Files, Clipboard History and Settings were seen dark through
  `DOCK2_APPEARANCE`, not beside a dark system's own apps.
- VoiceOver was audited through the accessibility tree, not heard: it was never switched on.
- Signing and notarization are set up (`make app`, `make notarize`) but never run with a Developer ID: this
  Mac's keychain holds no code-signing identity, and the `production` environment no certificate, so CI
  publishes ad-hoc builds.
- The release workflow is unrun: a clean checkout was built, tested and bundled here, not on the runner.
  The cask's uninstall, quit then `--restore`, is untried against a running `Dock2.app`.
- Dark mode was measured on an SDR display; on an HDR one `MaxLuma`, not `MaxLumaSDR`, applies, and it is
  set to the same value as AppKit's own dark recipes do, unverified.
- The Dock can still be brought back from under dock2 by turning auto-hide off (⌥⌘D, System Settings).
- A Dock recovered without its journal comes back with auto-hide unset: dock2's mark says the Dock was
  hidden, not whether auto-hide was the user's own before it.
