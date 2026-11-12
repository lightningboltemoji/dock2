# dock2 — Implementation

The _what_, the _why_ and the _how_ of dock2 as it is now. The investigation, the rejected alternatives and
the numbers that settled an argument live in `changes/<id>.md`.

---

## 1. The charter

- **It looks like the Dock, measured, not remembered.** Every number in `Dock2Core` and in `GlassRecipe`
  came off this macOS's own Dock — Accessibility frames, screenshots, pixel profiles — or, for the Snow
  Leopard style, off a screenshot of Mac OS X 10.6's, and the tests pin the geometry to those measurements. A change to the look is validated the same way, against the real thing.
- **The Mac is never left changed.** dock2 replaces the system Dock by changing its preferences, and every
  other behaviour it takes over outlives it too. Whatever happens to dock2 — quit, signal, crash, SIGKILL,
  power loss — there is a path that puts the user's own state back (§4), and no path that loses it.
- **Private API on stated terms.** Six places use it, each because nothing public does the job: the glass
  and the shelf's mirrors (private Core Animation classes, confined to `Glass/`, a missing class degrading to
  `NSGlassEffectView` and to a shelf that reflects nothing, a missing key to going unwritten, §3), the hot key
  table (SkyLight's symbolic hot keys, confined to `HotKeyTable`, §6), Now Playing (MediaRemote,
  confined to `NowPlaying.swift` and its helper, §11) and minimised windows' pictures (SkyLight's window
  capture and HIServices' window number, confined to `WindowCapture`, degrading to a blank window, §5) and
  a permission never asked told from one answered (TCC's preflight, confined to `PromptedPermission`,
  degrading to asking, §12), and a plugin's program answering to macOS for itself
  (`responsibility_spawnattrs_setdisclaim`, confined to `Disclaim`, degrading to running nothing, §11).
  Each is reached by name at runtime and checked before use; nothing that decides correctness depends on it.

---

## 2. Modules

```
Dock2TOML    pure — TOML 1.0 read with every value's place in the text, and a document edited in place.
    ▲        Copied from emira, knows nothing of dock2.
Dock2Core    pure — the geometry, the motion, the tile model, auto-hide's rules, the takeover journal, the
    ▲        settings' schema. Foundation and CoreGraphics' geometry types only; all of it unit-tested.
Dock2System  the Mac without windows — takeovers and the guard, the instance lock, the settings' store,
    ▲        the running apps and their windows, the system Dock and what it shows, file servers. Tested
    │        against a temporary directory where it can be. `Dock2NetFS` beside it: a module map carrying
    │        `NetFSPlugin.h`, which `import NetFS` leaves out.
Dock2Plugins the plugin host: the engine (`DockWasm`, the Rust staticlib in `Engine/` that `make engine`
    ▲        wraps as an XCFramework), instances, the store, effects. Tested against `Plugins/test-guest`.
Dock2Shell   the windows — the stage, the glass, the dock; `AppController`, which wires the rest.
    ▲
dock2        executable — the app, `--restore`, and the guard (`--guard <pid>`): one binary.
```

`Dock2Calc` stands beside the line, pure as `Dock2TOML` is: fend, the Rust staticlib in `Calculator/` that
`make calc` wraps as `DockCalc`, a question in and an answer out. Knowing nothing of dock2, it is asked by
`Dock2Shell` alone.

The guard gives back takeovers from a process with no UI, so nothing it runs lives above `Dock2System`.

### Geometry (`DockMetrics`, `DockLayout`, `LabelMetrics`)

Everything derives from the tile size, `dock.tile-size`, 16–256, which the first launch copies from
`com.apple.dock tilesize`. Points, Cocoa coordinates.

| Quantity          | Value                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| icon inset        | `floor(tile / 48) + 1` either side                                     |
| tile width        | `tile + 2 × inset`                                                     |
| platter height    | `tileWidth + 2 × rim`, the rim 6 below tile 48 and 8 from it; icons centred in it |
| platter width     | `run + 2 × (inset + 6)`, rounded to even; centred on the screen unless the puck needs the room |
| platter bottom    | 5 above the screen's                                                   |
| corner radius     | `min(height / 3, 28)`, continuous                                      |
| running dot       | 4 across (3 below tile 24), centre 6 above the platter's bottom, pixel-snapped; black, or in dark mode +124 to what is behind (plus-lighter) |
| tile number       | dock2's own: 8pt below tile 24, 9 below 48, 10 below 96, then 11, semibold, in the dot's ink; digits centred 9 above the platter's bottom, on the flat of the band its rim refracts, 5 to 13 up, and lower where the icon's art leaves less room |
| label             | 14pt system text, black 85% or white 95%; capsule 26 tall, `text + 26.5` wide; arrow 7.25 deep, tip radius 1.8; 9 above the platter |

The platter width is exact from tile size 48 up and within a few points below.

The Dock's own range ends at 128, and its formulas were measured up to it; past it they no longer hold (the
corners stay 28 on a platter twice the height). So past 128 the dock is the Dock at 128 magnified
(`DockMetrics.magnification`, `size / 128`): every length in the table is its value at 128 times that, as are
the separator, the dot, the bottom gap, the hop and the puck's gap. The label stays 14pt at every size, as the
Dock's does.

**The sideline's puck** (`DockLayout.Puck`) is a second piece of glass right of the platter, `puckGap` (12,
magnified) across: wider than the glass's merge, so the two read as two. It stands on the platter's baseline
and hugs its cells — the platter's rims above and below them, its `inset + 6` either side — under the
platter's own corners, and is never smaller than they are, so a lone app on a dock of 80 or less sits in a
round puck. It grows where the top right cell's badge, the one nearest the corner, would come within
`puckBadgeClearance` (4pt, magnified) of its edge or of the corner's curve: sideways, and upward as far as the
platter's height allows, the cells centred in it. Below tile 25 it is already the platter's height, and a badge
there is as close to its top as the row's own are to the platter's: 2.1pt at tile 16. Its cells are squares, the tile's slot
cut into halves, thirds and so on (`SidelinePacking`), down to the finest cut whose icons are 24pt or more; an
icon is its cell less its own inset, as a tile's is. Two cuts are in play, the coarsest that holds every app
inside one tile's square and the next finer, so one empty cell is worth one step of size: the rule never
shrinks the icons far to fill a rectangle, which would stand a column of 25pt icons beside 128pt ones. Among their shapes — never taller than the platter,
never wider than a tile unless the finest cut cannot hold every app in one square — the fewest empty cells
win, then the bigger cells, then more rows. Rows fill from the bottom left, so empty cells fall at the top
right. Below tile 48 half a slot holds less than 24pt: one row of 24pt icons, or of the tiles' own size.

**Fitting the screen** (`DockLayout.fit`): the system Dock shrinks its tiles once its first and last tiles'
slots would come closer to the screen's edges than a slot less 6pt — room for one more tile at either end —
which leaves the platter's ends `screenMargin` (119pt at tile 128) in from them. dock2 keeps the platter's left
end and the puck's right end that far in. When they do not fit, the puck's cells go finer, a cut at a time,
each as narrow as that cut goes; then the dock slides left of centre, just enough, the puck at its finest; then
the tiles shrink, to the largest size at which the first two fit. The layout's `metrics` are the size it
fitted at, not the one asked for.

Under the Snow Leopard style (`DockStyle.snowLeopard`) the numbers are Mac OS X 10.6's at tile size 56,
grown in proportion:

- the shelf's back edge, 47.4 above the screen's edge, spans the run plus 4.5 either side;
- its ends lean out 0.59 for each point down, and its last 3 points are the lip;
- the icons' art stands on a line 20.5 up. A macOS icon's art is 824 of its 1024 square, so the square sits
  that margin lower (`iconArtMargin`), as Snow Leopard's full-bleed icons stood on the line itself;
- the floor mirrors the screen about a line 0.6 above the back edge, and a separator's slot is 31;
- the floor's two greys meet along the S in Leopard's floor picture, which is stretched end to end across the
  shelf at every height, so a short shelf squeezes the whole S (`Shelf.floorStep`);
- the platter is what is hit-tested, slid away and stood on by the label: here, the back edge's width from
  the screen's edge to the icons' squares' tops, 71.0.

`DockLayout.shelf` carries the trapezoid, the icon line, the mirror line and the lip. A separator's slot carries its lane's
eight dashes (`laneDashes`), and a tile's dot frame is its light's picture. A tile's number stands on the light's
white core, 8 up at tile size 56, in white.

---

## 3. The glass

The Dock draws its platter and label in Liquid Glass, rendered by the window server from what is behind the
window. `NSGlassEffectView` reaches the same renderer — a `CABackdropLayer` running the `glassBackground`
filter over a signed-distance-field shape — but only with AppKit's fixed recipes, and in a window over the
desktop it also leaves the specular rims switched off. None of its recipes is the Dock's.

`GlassLayer` builds that tree itself:

- a `CABackdropLayer` (window-server aware, scale 0.5, its own group name) running `glassBackground`, whose
  `inputSourceSublayerName` names a `CASDFLayer` of `CASDFElementLayer`s — the shape;
- beneath the backdrop, one more `CASDFLayer` for what it casts: a `CASDFShadowEffect` kept off the shape (`punchout`)
  and let down the screen by its `drop`, or, `inward`, cast inside a hole's top edge (`invert`), where it starts a
  point in from the shape, so it is grown by one;
- one more per rim, each with a `CASDFKeyFillHighlightEffect`.

Shapes are rounded rects, optionally rotated, merged smoothly (`mergeElements`, `smoothness`): the label is a
circular capsule plus a rounded square turned 45°. They move two ways: `setShapes` animates each element from
its presentation to its new frame over one curve, or on the motion's springs (`Motion.animation`), and `play` gives every element a keyframe track
(`Keyframes`) — a stretch of motion sampled ahead, then, if it has one, a loop — for the window server to play
frame by frame. A played shape never turns: Core Animation takes an element's transform between keyframes by its
angle but a path's points in straight lines, so a shadow or a fill following a turning shape would take another
in-between than the glass. The tree is built at the layer's size, and a resize builds it again, ending whatever it was
playing; so `GlassView` sizes its glass as its own frame changes rather than at the next layout, and a motion
started straight after a resize plays on the tree that stays. A recipe's `lens` inputs, the gem's marble (blur 0.35,
refraction −28 over 14 pt, and a colour matrix from black 0.06 to white 0.96 under a luma cap of 0.92, so the glass
lifts an emerald's darks no more than it must), are played by key path on the backdrop from the same track as the shapes, each input as far
from the recipe's own value toward the lens's as the track says (`playLens`); its `scale` is the backdrop's sampling,
whole for the gem so its facets read through. SDF layers keep `contentsScale` 1; the rim heights were
fitted at that scale. A highlight's angles are in the layer's flipped space: 0 lights the bottom edge, π the
top. Its `curvature`, 1 by default, sets how gently it tapers where the edge turns a corner; below 1 it saturates
along a straight edge. Amount barely moves a line near saturation, so a black line stays near black: a soft shade
is a cast, never a rim. Its diffuse halo (`diffuse*Scale`, off unless a rim's `halo` sets it) is the soft
light falling inward from the line, and what gives an edge its thickness. A vibrant rim (`isVibrant`) is drawn
through `vibrantColorMatrix`, with the system's own matrix, which holds white back: without it the dark pane's line
burns out to 255.

`GlassRecipe` carries the numbers, the Dock's fitted against the real Dock in both appearances, over the
wallpaper and over a high-contrast pattern. The **platter**: blur 0.85, inner refraction −45 over 11.5pt, a
face matrix (light: white 0.8925, black 0.15, saturation 1.3; dark: 0.7812, 0.06, 1.2, with `MaxLuma` 0.8875
holding highlights down), and three rims — a soft top-and-bottom light (dimmer in dark mode), a sharp line on
the same edges, and a black hairline just outside the ends. The **label** is the same kind of glass blurred
more (4.5–5.25) and lightened further, under fainter rims; AppKit's "regular" recipe gets its fill right but
blurs too much. A recipe without a face (`hasFace`) builds no backdrop: it is its rims and cast alone, drawn over
whatever lies beneath, as a selection's edge is on the panel's ground (§7).

The **pane** is not fitted. It is the system's own glass for a control, read off the tree AppKit builds for a sidebar's
`.searchable` field ([observing](OBSERVING.md#reading-the-systems-own-glass)), where that recipe drawn by `GlassLayer`
comes within a few levels of AppKit's field. What gives that glass its body is at its edge: a face capped under
white (light's `MaxLumaSDR` 0.94), which leaves the rim room to show; a rim saturated by `curvature` 0.75, with a halo
of 8, 0.15 and 0.65 times its height, amount and spread; the filter's ring shadow, which darkens the face just inside its
top edge and nothing beyond it; and its in-filter highlight, angled to the sides with a negative colour bias, which darkens
the ends. The rest is where the pane differs from a field:

- **The ring shadow's offset is negated.** AppKit's tree is flipped and this one is not, so it would fall up the screen.
- **The dark face is lower**, black 0.07 for the system's 0.125 and no vibrant tint: 57 of 255 on a ground of 40. A
  field's 89 is too bright across a whole panel.
- **The rim is 0.7**, for the system's 0.5, which comes out dimmer in this tree than in AppKit's.
- **The light ground is shaded 13%**, to 222: a selection has to read as going down to it from a face of 239.
- **What it casts is its own**, `paneCast`, and the filter's shadow is off. The selection throws the same one, inward,
  so a cut goes exactly as deep as the pane stands high: 8.5% black in light and 20% in dark, softened over 3 pt and let
  down 3 pt. The filter's shadow could not carry it: the margin below ends it in a hard edge about 8 pt past the foot.
- **The backdrop stops at the ground's edge.** The ground's rim is only `paneInset` wide, so `marginWidth`, which the
  glass needs to draw anything outside its shape, is `paneInset` for the system's 16, and the blur fill, which reaches
  8 pt, is off. Past the rim the glass would sample the desktop: a top edge that follows what is behind the panel.

Layering is load-bearing: anything below the backdrop in the window is refracted by it, so icons and dots
live in a view above the glass view, never beside it in the same layer.

The Snow Leopard style's shelf reflects through two more pieces of private API, in `Mirrors.swift`:

- `ScreenMirror` is a `CABackdropLayer` from the screen's edge up to the mirror line's reflection of it,
  filtered by `displacementMap` with a ramp. Green over `inputAmount` shifts a row up twice its distance
  below the line, so each row of the floor shows the row as far above it.
  - The map is drawn in the window's colour space. Converted, its green leaks into red and the reflection
    leans sideways.
  - The map is 16 bits at four rows a point. At 8 bits and a row a point, the shift came in steps of about
    0.4 pt.
  - The backdrop is never inside a masked layer: that layer is drawn apart at its own size, which scales the
    shift.
- `LayerMirror` is a `CAPortalLayer` onto the tiles' container, flipped about the icon line. The render
  server draws it from the tiles themselves, a hop or a pop included. It draws only if it comes after them in
  the tree. Once on screen, it stops drawing when its frame or transform is set again, so a move puts a new
  portal in its place.

Without either class, the shelf reflects nothing.

Everything private the glass and the mirrors use is named once, in `PrivateSurface.swift`: a `PrivateType` for each
class and `CAFilter` type, a `PrivateKey` enum of the keys dock2 writes on it, each case named for its key, and
`Private`, an instance that only those cases can write. `GlassRecipe` is keyed by the same enum (`GlassInput`). A
missing type is what `isAvailable` asks after, and a missing key goes unwritten. A `CASDFEffect` throws on a key it does
not know, where a layer or a filter takes any key and does nothing with it, so whether one exists is read from a setter
or from `inputKeys`, never by writing it: the crash is the rare failure, and a glass quietly drawn without an input the
common one. `PrivateType.keys` is an exhaustive switch over the types and a write can only name a case, so
`dock2 debug audit` (§14) reports on what the code uses, with no list of its own.

A backdrop is held to its shapes only by `sourceSublayerDefinesBounds`. Where that is missing, on Tahoe, it has the whole of
its frame, which is the stage, and catches the mouse across the screen (§5). So there `GlassLayer` keeps the backdrop's bounds
to the shapes (`keepsExtent`), in the glass's own coordinates so the source within stays put: over the whole way of a motion
until it ends, then over the shapes where they rest. Keyframes say where a shape will go; on a spring it is both ends and the
first swing (`Motion.overshoot`). A count of changes stops a motion's end from shrinking what a later one set. It branches on
the key, not a version: macOS 27 takes none of this, since a rectangle would lose the hit area that follows the shape.

The system's display settings (`DisplayOptions`) are followed as they change. Reduce Transparency hides the
glass for the union of its shapes filled with the window background; Increase Contrast strokes that union in
the secondary label colour, glass or not; the path follows a shape's motion. On Snow Leopard's shelf, Reduce
Transparency hides the screen's reflection, and Increase Contrast strokes the trapezoid. Under Reduce Motion
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

Under the Snow Leopard style the platter has no glass. `DockView` draws the shelf (`Shelf`) in the overlay
instead:

- beneath the tiles, the floor's picture cut to its trapezoid, and the screen's reflection;
- above them, the tiles' reflection.

Both reflections are added with `plusL`, under a mask of the floor's reflectance: 0.32 at the back edge,
0.19 from 0.8 of the way to the lip, then 0.14 on the lip's seam and 0.03 on its light edge. A layer of black at 1/255 over the footprint keeps the pointer on the stage between icons.

Hover comes from the mouse monitors, not a tracking area. dock2 is never the active app, so the window server
sends pointer moves to the frontmost app, and a tracking area on the stage hears only some of them. A system menu
tracks the pointer from those same moves, so while one is up `PointerMonitor` posts each move it hears into dock2's own
event queue, or its highlight waits for the next move that happens to arrive. The
monitors hear every move, each with the window under the pointer (`mouseEventWindowUnderMousePointer`, the
window server's pick, passing over transparent pixels as a click does): over the stage, the tile under the
point is hovered; over anything else — a menu, another app's window above the dock — none is. The panel's
controls light the same way: `PanelController.pointerMoved` hit-tests the panel and lights the `Hoverable`
under the pointer, and only it.

### Tiles

`DockModel.compose` decides the tiles: Finder, the pinned apps, then the running apps that are not pinned
in launch order (`RunningApps`: regular apps, `launchDate` order, dock2 excluded) with no separator between,
as on the system Dock, then a separator and plugin tiles, then a separator and the minimised windows, in the order they were minimised.
The sidelined apps (`Settings.sidelined`) leave the row, pinned or not, for the puck (`DockModel.sideline`):
those running, in the list's order, whether or not the running apps show. An app is pinned, sidelined or
neither: `DockChoices` moves it from one list to the other, the dock's menu and search's Keep in Dock alike,
through `SettingsStore.dockChoices`, which writes both keys. Snow Leopard's shelf has no puck, and there
sidelined apps stand among the running apps. `DockLayout` places tiles and separators — a separator's slot is 0.45 of a
tile, its line a point wide from the slot's centre, `tile − 10` tall, centred. `AppDirectory` resolves an
app to its URL, name and icon once, and forgets one the catalog finds moved or at another build — its
Info.plist read from disk, since `Bundle` keeps the first it read — the dock redrawn. Icons are rendered at the tile's size: an `NSWorkspace` icon reports
32pt, and rasterised at that size it would be stretched. A new size renders the icon again (`TileLayer`), and
its layer lies on whole device pixels, origin and size (`pixelSnapped`): slots fall at fractions of a point,
and a bitmap off the grid is resampled.

Finder's tile wears the user's own icon when `Settings.finderIcon` names one of Cairo's pictures
(`FinderIcon`): `FinderTileImage` draws it on `IconPlate` at whatever pixel size it is asked for. The plate —
the Finder tile's, and every icon dock2 draws among apps' (below) — is a blend of two of Icon Composer's,
filled black and filled white (`Resources/Plates`, §15): `black + (white − black) × colour`, channel by
channel in Display P3's encoded values, premultiplied, since the two share their alpha. That is within about
a level in 255 of Icon Composer's own plate, but for the rim, where Icon Composer lightens in the colour's own
hue and the blend reads duller. The picture
(`CairoPicture`: Cairo's pictures as rows of `#` and `.`, parsed into `PixelArt`) is filled: its ink black
and `PixelArt.inside` white, the paper that cannot reach the edge through a side, so a line that steps
diagonally still closes. With `FinderIcon.filled` off its ink is white. Either is one layer with a soft
shadow fitted by eye to Icon Composer's, its longer side near 0.62 of the plate, and the plate 412/512 of
the image, as `NSWorkspace`'s icons are. `PixelArt.placement` gives each of its pixels a whole number of the
screen's, on whole pixels; with less than 3/4 of a screen pixel apiece it scales down smoothly instead. The
colour is kept while Finder's own icon shows, for the next picture.

The icons dock2 draws among apps' ([visual](product/visual.md#icons-among-apps)) — search's commands and
plugins' rows, plugins' tiles, Settings → Plugins — stand on the same plate, through `IconImages.plated`, drawn in a
row's icon box (`PanelMetrics.Row.iconBox`) so the plate is the app icons' beside it: 32 pt in search's rows. A symbol is white, its `.fill` where it has one, at 0.6 of
the plate in points for every symbol so SF Symbols' optical balance holds, and at a smaller size only where
its image would pass 0.86 of the plate (play/pause). It is tinted as a template is: a one-colour palette paints
a fill's cut-outs — the clipboard's lines — the same white. A picture is clipped to the plate's rect, then cut
to its shape by the plate drawn over it `destinationIn`; a blend reaches only where its source is drawn, so
without the clip the picture keeps the margin. A plugin's `Tint` is a plate through `IconColor(_:)`, the
system colour's components read as Display P3's; dock2's own commands carry an `IconColor`, violet among them,
which no `Tint` names. In a view's list a symbol or a picture is a glyph rather than a plate, fitted to the plate's
size so it shows as large as an app icon's plate beside it (`IconImages.row`); an app's or a file's icon is as it is.

`DockView.show` diffs by identity (`TileKind`, `DockGroup`): survivors slide to their new places, a new tile
grows in place from nothing and a removed one shrinks away, while the platter's glass shape reshapes on the
render server, all on the measured reshape curve. Every move is an explicit animation from where the layer
shows now: implicit ones skip a layer added in the same transaction, jump when another is in flight, and cannot
spring. A move to where a layer already is leaves the one in flight alone. Layers are moved by bounds and
position, never `frame`, since a growing tile carries a scale. A tile changing size — from the row to the puck,
or as the puck's cells change — takes its new bounds at once, drawn for them, and shows the change as a scale,
so its badge, shade and bar scale with it rather than stay where its final size puts them. One shrinking keeps
a picture drawn at its old size until the motion ends (`TileLayer.drawnAt`), so it never starts as a small
picture stretched. The badge's text has no `contents` action, since the commit that moves a tile redraws it and
would cross-fade it from the size before; and the container's implicit `sublayers` action is off, or adding a
tile would cross-fade the whole row.

The puck's tiles follow the row's in `DockLayout.slots`, each in its cell, hit-tested by frame. A puck tile is a
tile at its icon's size (`DockLayout.Puck.metrics`), so its badge, hop and inset follow; it has no dot, since
everything on the puck runs, and no number, and it is not picked up. Its label and menu stand on the puck's top
(`DockLayout.top(of:)`). Hover, clicks between tiles, the platter's menu, drops and the pointer on the dock count
the puck (`DockLayout.contains`, `extent`). Its glass is a third shape of the stage's (`Stage.Shape.puck`), set
with the platter's in one change. The glass builds its tree again when the number of shapes changes, ending
what it was playing, so the puck's shape is always there: with nothing on it, a 2pt speck half the platter's
height in from its right end, further from the outline than the merge reaches, so the outline is the platter's
alone. An app sidelined grows it from there, and the merge buds it out of the platter's end; the last leaving
draws it back in.

A change to the puck's apps — sidelined, unsidelined, or a sidelined app launching or quitting — moves the whole
dock on the sideline's springs (`SidelineMotion`, `Motion.sideline`) instead of the Dock's curve, since the
sideline is dock2's own. What moves or grows goes a little past its place and back; what shrinks is critically
damped, so the puck never passes its size as it draws back into the platter, and every key of one glass shape
takes the same spring, so its edges move together. A tile crossing between the row and the puck flies over the
others (`zPosition`) and hops a launch's hop high on the way: a parabola in the move's own progress
(`SidelineMotion.lift`), played as an additive keyframe track on its position over the move's spring. A move
that takes over mid-flight starts from where the tile shows, lift and all. The springs are `Spring`'s, handed to
Core Animation as mass, stiffness and damping (`CASpringAnimation(_:)`), so the hop's track and the move agree.
Implicit animations, which cannot spring, keep to the reshape's curve.

A click opens the app with `NSWorkspace.openApplication`, which launches it or brings it forward and
reopens a window; Finder's tile opens Files, and with ⌥ Finder. That app, like anything dock2 opens, starts in
the session's environment, as from the Dock, however dock2 itself was started: LaunchServices gives a launched
app its caller's environment over launchd's, so dock2 empties its own before anything runs and reads the
`DOCK2_*` switches and the control socket's `TMPDIR` from what it set aside (`LaunchEnvironment`). An app starting — from dock2 or anywhere — hops until it
finishes launching (`isFinishedLaunching`, read a turn after `didLaunchApplicationNotification`, since
finishing is no change to `runningApplications`). No `NSRunningApplication` is observed by KVO: one freed while
observed takes dock2 down. The separator takes 57 levels off the glass with a plus-darker blend, and in the dark
appearance adds 65 with a plus-lighter one, as the system Dock's does; the dot is black, or plus-lighter in
the dark appearance — 148 against the system Dock's 150 at its brightest. On the shelf, in either appearance,
the dot is Snow Leopard's light, added, and the separator a lane of dashes, white at 0.33 (`ShelfArt`).

The right-click menus come from closures (`MenuBuilder`): a tile's windows, if its app runs, then Open — for a
running app too, as a click does — Show in Files, Keep in Dock or Remove from Dock, Sideline (a check, on the glass), Hide, Quit and, under ⌥,
Force Quit; a minimised window's Open “title”; Finder's places — `Places`, the path bar's too, disks, servers and Network included — and Open in Finder; the platter's
Settings…, Auto-hide and Quit Dock2. A menu carries dock2's items alone: `allowsContextMenuPlugIns` is off, or a
right-click's opens with the system's Ask Siri above them.

### Badges and minimised windows

Both come through Accessibility; without it neither shows, and the dock never asks for it: Settings →
Permissions offers it (§12).

**Badges** are the hidden system Dock's. An app tells only the Dock, whose application items say the label as
`AXStatusLabel`: digits, a word, or a space for a bare dot. `SystemDockItems` reads each item's subrole, URL,
label and title in one call, off the main thread. The Dock posts nothing when a badge changes, and nor does
LaunchServices, which holds it as the app's `StatusLabel`, so it is read as the dock starts to show and four
times a second while it is on screen — about 0.2 ms a read for every item — and otherwise only as minimised
windows come and go. `TileLayer` draws it to the Dock's
measurements (`DockMetrics.badge*`, at tile sizes 16 to 128): a red circle `tile × 25/64` across, sRGB
(246, 68, 58), its top right on the icon's — but never under 16pt across, where the Dock's goes down to 6 at
tile 16, a floored badge centred where the Dock's would be and spilling past the icon's corner — widening leftward into a capsule that keeps 0.16 of its height
either side of the label; the label white, in the regular system font at half the badge's height, its
capitals centred; a soft shadow, mostly below. A Dock restart clears every badge until its app sets a
different one, since AppKit sends no label equal to the last; it also brings every minimised window back.

**Minimised windows** are the hidden system Dock's too: it keeps one `AXMinimizedWindowDockItem` per window,
in the order minimised, and a group of tabs is one — where AppKit says every tab is minimised, and so does
each tab's `AXMinimized`. The Dock lists an item, posting `AXCreated`, as the genie ends — about half a second
in, within a millisecond or two of the app saying the window is minimised, either first — or, for Minimize
All, as the genies start; it posts `AXUIElementDestroyed` once the window is back, its own gap already open or
closed. So `SystemDockItems` observes it and reads its items again on each, on a thread of its own
(`RunLoopThread`); a Dock that quits is looked for again every half a second for ten. An item has only its
window's title — the Dock takes up a retitle made during the genie, at times only after its `AXCreated`, but not
one made later, and `SystemDockItems` takes the title again at each read, keeping the item's id — and nothing
that says whose window it is.

So `MinimisedWindowMatch` matches each item once, in the Dock's order, to an app window: among `AppWindows`'
minimised windows of that title that no other item has and that were minimised within two seconds of the
item's first showing, the one minimised first. The Dock lists items in the order the app says their windows
are minimised — Minimize All's too, since one app's loop drives both — so windows of one title minimised
together take their items in turn; two apps' windows of one title minimised within about 50 ms of each other
can swap. A window minimised long before is never taken: that is a group's hidden tab, still minimised, or a
window whose item is gone.

`AppWindows` is an `AXObserver` per running app, on a thread of its own, so an app that hangs holds up that
thread alone (each app's messaging timeout is a second); it hears windows created, destroyed, minimised,
restored, retitled and resized, and the main window changing, keeps standard windows and minimised ones —
which call themselves dialogs — and numbers each as it is minimised, with the time it heard it and the window
server's number for it. A group of tabs minimises every tab, hidden ones first, and the Dock has one item, for
the tab on show; `kAXWindows` lists only that tab until the group is minimised, when it lists them all. So
`AppWindows` keeps the windows the app's list says are on show — read again when a window is created, the
main window changes, a window it does not list is resized (a tab coming on show, the only sign some switches
give), a window is restored, or the Space changes — and a window minimised that was not among them is a hidden
tab, which the match never takes. The list is read while a group is minimising when the group was the main
window, and then has every tab, so a minimised window keeps the place the last reading gave it.

The app says a window is minimised only as the genie ends, so an item is not shown until it is matched — the
tile arrives in its window's shape — or until it has waited `MinimisedWindowMatch.patience`, two seconds, for a
window that is not coming. An item whose window the app says is restored leaves at once, before the Dock lets
it go.

The match gives the tile its app, its shape and its picture. `WindowCapture` takes the window as it is when
matched, once — the Dock's picture is of the window as it was minimised and does not follow it — off the main
thread, about 10 ms, with SkyLight's capture (`SLSHWCaptureWindowList`), since ScreenCaptureKit refuses a
minimised window (SCStreamError −3811) and `CGWindowListCreateImage` returns none; it is scaled to the largest
tile's window at the screen's scale, 240 pixels at 2×. The window's number is HIServices'
`_AXUIElementGetWindow` on its Accessibility element. The tile waits for its picture, a quarter of a second at
most, a late one still arriving. Without Screen Recording there is none: the first item matched without it
in a run asks, and macOS prompts while the answer is undecided — again after a reinstall, since an ad-hoc
signature is a new app to it. Matching needs Accessibility, so without it only Settings → Permissions asks. `WindowTileImage` lays it out as the system Dock does: the picture fitted
into 15/16 of the tile and centred, its own corners and edges, no outline or shadow; or, with no picture, a
blank window in its shape, its title bar and buttons at the window's own scale, in the dock's appearance — and
its app's icon, 3/8 of the tile, in the corner; a square with a bare corner for an item shown unmatched. Its
label is the Dock's title. A click presses the Dock's own item, which
restores the window and brings its app forward as a click on the Dock does, and the genie comes out of the
hidden Dock, where dock2 cannot reach it. The tile leaves at the press, as the Dock's gap starts closing; the
Dock lets the item go only once the window is back, and one it still has two seconds on is shown again. With `minimizeToApp` they have no tiles; the hidden Dock keeps them
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
A screen names the tile it belongs to (`Screen.tile`: Files' is Finder's), and `ViewsController` tells the
dock whichever is on top (`onTop`). While one shows, that tile wears the caret (`CaretView`) in its label's
place, a 30 × 18 pt capsule of the label's glass with a chevron drawn over it in the label's ink, fading in
over 0.15 s and out over 0.12 s. It follows the tile through a relayout and leaves with the dock, and the
tile shows no label, hovered or ringed. Chosen again without ⌥ — a click, its number — the open tile pops its
screen whole (`DockController.onCloseOpen`), where Esc would first close what is open inside it.

| Motion | Measured | |
| --- | --- | --- |
| reveal, hide | 240 ms, Bézier (0.35, 0.15, 0.65, 0.85) | `DockMotion.slide*` |
| tiles moving, platter reshaping | 360 ms, the same curve | `DockMotion.reshape*` |
| launch hop | parabolic, 700 ms a hop, `tile / 4` high, one after another | `DockMotion.hop*` |
| tiles' entrance | dock2's own: a spring of 0.45 s, bounce 0.45, from three quarters size (+3% at its peak), fading in from half its opacity over 0.5 s; the wave 0.12 s to the farthest tile, and 12 ms more a tile | `EntryMotion.pop*`, `wave*` |
| the sideline's changes | dock2's own: what moves or grows on a spring of response 0.5 s at 0.75 of critical (3% past, there in 0.29 s), what shrinks on 0.4 s critically damped; the crossing tile hops `tile / 4` | `SidelineMotion` |
| a tile's number | dock2's own: up out of the dot from 0.3 of its size on a spring of response 0.32 s at 0.5 of critical, the dot gone in 0.08 s; back on 0.2 s critically damped, fading out in 0.2 s | `NumberMotion` |

### Settings

**The settings are a TOML file**, `~/.config/dock2/config.toml` (`DOCK2_CONFIG` overrides it), which a person
may keep in a dotfiles repo and share between Macs. `XDG_CONFIG_HOME` is not consulted: an app opened at login
never sees a shell's environment. Every setting is a typed `SettingKey` in `Settings`, with its default, the
key or keys it is written under and a codec: what a legal value is, how one is read, how it is written.
`FinderIcon` is one setting under three keys. A key is written only while it differs from its default, so
setting one back takes its line out. `Settings.all` is the table the reader walks, `config.example.toml` is
generated from (pinned by a golden test; `make example`), and `dock2 config explain` prints.

`Dock2TOML` is emira's reader and writer, copied: TOML 1.0, which emira measured against `toml-test` (703 of
709, the rest malformed UTF-8 no `String` holds), and a document that holds the text beside its parse.
`TOMLDocument` splices one value over the text it occupies, or adds one line at the end of its table's run, so
comments, order and spelling survive every write. Keys are paths of segments, since a plugin id has dots.
An array past 80 columns is written a line an element.

`SettingsStore` reads the file, watches it — the file and its folder, and through a link the file it leads
to, from emira's watcher — and writes it. A change is applied to the document in memory and heard at once;
the write follows 250 ms after the first change, so a slider dragged writes once. Edits are kept as edits
until written: the file is read again under a lock (`config.lock`) first, and whatever someone else wrote
meanwhile — an editor, another Mac's sync, `dock2 config` — keeps, with dock2's applied over it. The write
goes through a link to the file it names, since an atomic write at a link replaces the link and the dotfiles
copy never hears of it. Observers hear a key's change on the main queue after it, as Key-Value Observing
delivered it; the store is `@Observable` for SwiftUI.

**Mistakes are said, not fatal**, unlike emira, since a file shared between Macs meets older and newer dock2s.
A key the file gets wrong — unknown, the wrong type, out of range — reads as its default (or as it was, on a
reload), is a diagnostic with its line in the log and in Settings, and its line is never removed. Text that
isn't TOML changes nothing on a reload; at launch dock2 runs on a copy of the last text it could read
(`config.last-good.toml`, not kept for `DOCK2_CONFIG`), and refuses writes until the file is fixed: Settings
says so, the panel says so, and a write already waiting is dropped.

Two settings describe one Mac and never reach the file: `fileAccess` and `askedToPaste`, macOS's answers being
per Mac, kept in `state.json` (`SettingKey(machine:)`), behind the same subscript. `SettingsImport` carries the
old defaults domain, `zip.tanner.dock2`, into the file and `state.json` once — only while each doesn't exist,
so a file another Mac wrote wins — with open at login from `SMAppService`, and leaves the domain as it was.
Every process that opens the standard store runs it first (`SettingsStore.standard`), so `dock2 plugin` before
the app's first run can't preempt it.

The dock reads only these. The first launch copies the system Dock's pinned apps (once each), tile size,
auto-hide, reveal delay, slide speed (`autohide-time-modifier`, which scales auto-hide's slide; 0 is none),
launch animation and where windows minimise to (`minimize-to-application`) into them (`SystemDockSettings`),
each only where the file doesn't already say, the keys dock2 overrides read from the journal when one exists
(`usersDockPreference`).

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
another app activating, an app opened from the dock. The activation of the app that was in front as the
keyboard was taken is no dismissal (`frontWhenTaken`): heard after, it is the one that brought that app
forward — as when Files comes back once macOS's sign-in window has closed. Engaged, the stage joins full screen Spaces; at rest it
leaves them. Settings, however it is opened from the panel — ⌘,, the Settings command, the Files section's
note, the dock's menu — goes through `InteractionController.handOver`, which dismisses without the
deactivation, and comes forward with `activate(ignoringOtherApps:)`: cooperative activation refuses plain
`activate()` from a non-activating panel.

### The field

`PanelController` draws it in its own glass over the stage, on the panel's grid (`PanelMetrics`,
[visual](product/visual.md#layout)): a 640 × 56 circular capsule, a row tall, centred 44 pt above the platter so a
label fits between. `FieldLine` lays out its line, and the path bar's: SF Symbols' magnifying glass at the field's
22 pt, regular, at its own size, its ink centred on the glyph line and the midline; 22 pt regular text from the
text line, its capitals centred on the midline. A text field's cell starts its text 2 pt in from its frame and its
baseline 2.5 pt above its font's descender (`NSTextField.textInset`, `FieldLine.cellInset`, both measured), and the
frames take both off. Its recipe is the label's, less saturated, with a sharp rim. Grown,
the panel is glass on solid (`PanelMetrics.layering`): a ground of the window's own material in the body's
shape (`PanelGround`), the field's strip of it bare, and a pane of glass (`GlassRecipe.pane`) over what grew,
`paneInset` (6 pt) in from the ground's edge, its foot on the field's top. The ground is `.windowBackground`
behind the window. In the light appearance, where that is white and a selection would have nothing to be let down
to, it is shaded 13% toward black. Its 1 pt rim is the secondary label colour under Increase Contrast, as a glass's
border is. The pane has nothing behind it to blur, so it reads by its edge, the same way in both appearances (§3). Reduce
Transparency fills the pane as it fills any glass, and the ground's material turns solid itself. The clear glass gives way to them on a
spring of its own in `FieldMotion`, critically damped, 0.30 s in and 0.22 s back (`GrowthMotion.groundInResponse`),
not on the body's growth, which crosses the first few points in a frame. A panel grown by eight rows therefore
crossfades as gradually as one grown by one. The clear glass, the body inset by the ground's progress, fades as
the ground and the pane fade in. The pane draws in from the body's edge by the same inset, and search's selection,
let down to the ground (`GroundInset`), is as solid as the ground (`RowsView.playGround`). A form rests only once the
ground has gone. Under Reduce Motion the body is there at once and the ground still fades. A panel grown in the
turn its entrance began, or while it waits — a screen opened from nothing — is solid at once, never having been
the clear field on screen; and
a two-layer shadow stands in for the window shadow Spotlight's field has, cut away where the glass is (a
shadow under a backdrop is refracted by it). The recipe cannot merge with the platter's, so the field comes
in on an entrance of its own (`EntryMotion`): the glass, the shadow and the contents rise 32 pt into place
over 0.36 s on a Bézier (0.2, 0.8, 0.2, 1), growing from 94% about the field's centre, while the panel fades
in through a radial mask over 0.15 s — a mask on a container of everything but its feedback, which outlasts a
dismissal — in a wave from the field's bottom centre at 1,800 pt/s — whole behind
its 160 pt soft front, half past it. The mask does the fading, Reduce Motion's in place too, since an alpha
set and animated in one transaction animates from the value it replaced. Summoned with the dock away, the
entrance waits 0.1 s and rises out of the dock coming in; anything that grows the panel meanwhile — typing
ahead — runs it at once and ends the fade. Dismissal plays it back in 0.18 s on (0.42, 0, 0.58, 1), fading that
container as it sinks through a plain mask, so the gem beneath the glass goes with it. The entrance, the dismissal
and every change the driver plays commit in one transaction (`Motion.together`): one with none around it reaches the
screen as it commits, and a glass built a frame ahead of its motion, mask and faces shows bare. Results grow the panel to them and back on springs of dock2's own, edge by edge
(`GrowthMotion`), started from Spotlight's measured 57→467 pt in about 235 ms and back in about 210: an edge
moving out has a response of 0.3 s at 0.78 of critical damping, a little past and back — 6–8 pt on a full
growth — and one moving in 0.22 s, critically damped and stopped at its place, so the panel never dips into
the field. A change that comes mid-flight carries on at the speed the panel has rather than from rest. The
rows are revealed from the field up as the glass covers them, the shadow moving with it. A screen — a view, Files —
lies in a container masked to the glass's shape as it moves (`setGlass`), so nothing of it shows outside
the glass, and it never waits for the glass. Laid out at its own size, it rides it from the first frame (`ScreenRide`), each
part keeping to the end of the glass it reads from. A bar's two ends (`ScreenBar`) ride the body's ends along its foot, and
the leading end's mask rides the gap between them, so a long path fades out before the tabs rather than running under them.
The pane's slot rides the foot and the contents the top left corner, coming out from behind the slot's foot: the top rows,
read first, show first, where glass that uncovered them in place would reach them last. All the glass still cuts is the
contents' right side, for about 0.1 s. The bar fades in over 0.1 s from the start, the contents over 0.14 s from 0.05 s.
A screen going back to nothing or to the results stays where it is, riding the glass as it draws back, fading out over 0.1 s
and taking no clicks (`leave`), the results fading in under it; one giving way to another screen goes at once. A panel that
leaves with a screen on it draws back to the field as it sinks, and stays solid, as it arrives (`FieldMotion.leave`).
Opened from nothing, the form was never on screen, so it starts over as the field with nothing to pour, and the panel
grows from the field's width. The field fades out under a bar, where it was, and is hidden once gone, so it takes no click
meant for the bar; opened from nothing it never shows. Glass shapes, the clip, the shadow, the reveal and what rides the
glass play from one track (`FormDriver`, below).

**The field's form** (`Settings.fieldForm`) is what it is while empty: Drop, Gem, Lava lamp, or the capsule
above, which is also what Reduce Motion, Reduce Transparency, Increase Contrast and a Mac without `GlassLayer`
get. `FieldMotion` (Dock2Core) simulates a form — every shape on springs of its own, stepped at 240 Hz — as a
deformation riding on the panel's own motion: the body as `PanelController` asks for it, rising in on a tween,
growing to its results on `Growth`'s springs. So the pour and the growth run at once, as they must, the
first letter nearly always bringing results. A form steps and is drawn against one band, the field's height
where the growth has it now (`FieldMotion.space`), so what rides the body's ends rides them as drawn even as the
panel widens to Files. A pour's ends come out critically damped, so the glass meets the
field's ends without passing them. The lava lamp's droplets and the drop's fronts ride the body's ends: each
is placed at a distance past its end (`Spring.place`), a spring that gathers it from where it was onto a
schedule of the time since the letter (`FormSpace.lead`). The schedule has it standing out of the end while
the body starts to open, then sunk to `FormSpace.tucked` by 0.1 s, deeper than the glass's smoothness, so it
leaves no trace on the outline. Riding the end rather than chasing it, a droplet shows at both ends of every
pour, whatever the rest was doing. The drop's lumps swell only as it starts to open. The magnifier and the
text ride the body's left end: each form says where it carries the magnifier (`FormSim.carried`), and the
drop's and the lava lamp's magnifier and `FieldMotion`'s text follow that place, the text at its gap from it,
on critically damped springs of one response (`FormSpace.carry`), so the two move as one and never lead the
glass. The gem's magnifier never travels, and shows only where the glass covers its place. Every slow motion of a form at rest is a whole number of cycles
in 24 s (the gem tumbles two and three turns), so its rest loops. The gem is a rough-cut emerald (`Stone`): twelve
fixed corners about a slightly long ellipsoid, each off where an icosahedron's would be, and the twenty triangles of
their hull, up to three times one another's area. A facet is lit by its turned normal, glints toward white as it
turns the light to the eye, and keeps a small tint of its own in hue, saturation and brightness. At each change — the field filling or
emptying, a letter, the target moving, the entrance, the dismissal — `FormDriver` takes the motion as it
stands, applies the change, samples it at 60 Hz until it settles (resting, for 3 s, until what it rested
from has died away), and plays the samples as keyframes on the glass's elements and its lens (a solid fill's or a
border's path too), the shadow's paths, the screen clip, the rows' mask (kept to the body's width as it
pours, so rows never show past the glass) and its reveal (as high as the body reaches above the field), the
gem's faces (`GemFaces`, beneath the glass so it bends them, masked to the body), what rides the glass of a
screen (`ScreenRiders`), and the field's magnifier, text, spinner, and the ghost of a cleared text. A rest is then
followed by its 24 s loop, sampled at 20 Hz and phased to the media time, and worked out once for each form and field;
a change inside it starts again from `FieldMotion.resting(at:)`, the same state. What a form draws is unturned rounded rects alone, placed by where its
springs are and never by how fast they go, so the keyframes' straight-line in-between of two samples is the form's
own on the glass, the shadow's paths and the clip alike. A lava droplet is drawn longer along its way as three discs
on a line toward a point trailing it on a critically damped spring, the glass melting them into one. The main thread spends a few milliseconds a change and
never drives a frame. Emptied with results
showing, the form waits for the panel to shrink back to the field before it collapses: for the panel asked to
be the field and there, since the field empties a moment before its results go. Emptied as the field alone, it
rests at once. The driver takes up the rest's loop only once the form has rested (`FieldMotion.hasRested`).
Cleared at once, the text plays as a ghost of what was cleared through every change until a letter comes,
the field itself hidden so its placeholder never shows. The lava lamp draws
in as it poured out: its body critically damped at the pour's response, so it neither passes its size at rest
nor springs back, its two droplets riding the ends in at their tucked depth. Carried to the body's middle as it
arrives, they are let go onto the rest's springs and bud off it. The gem comes back as it broke apart, the
other way: its glass draws in to the marble, round and 76 across, as the lava lamp's does, and carries the faces home,
each as far out as the glass is still open, squared, so what shows of them is inside it. A face shows again once it is
past 55% of the way home, as one fades on the way out, and the glass is a lens again once all are. `setGlass` goes
through the driver whatever the form. The capsule (`CapsuleSim`) rests at 70% of the field's width, centred
and still, its magnifier concentric with its left end and its placeholder beside it at the field's gap, so its
text shows at rest and rides out rather than landing. The first letter pours its ends out to the field's,
critically damped (0.42 s), the magnifier sliding from the end's centre to the glyph line on the way, where the
motion hides it; emptied, it draws back in once the panel is the field. Under Reduce Motion it changes at once,
its text with it (`FormSim.isInstant`), and `PanelController` crossfades the panel over the slide: the magnifier
and the text, placed by keyframes, move at once beneath the fade while the glass and the text's content
dissolve. At rest the field takes clicks only within its form, the capsule's body or 48 pt about a form's
centre, so the empty space around it passes them through.

The field's `doCommandBy` delegate gets the text system's commands, after any input method: with nothing
typed, ← → walk the ring — the platter's tiles, then the puck's in the order its apps fill it — fn← fn→ go to its ends, ↩ opens the ringed tile, ↑ opens its menu above it, Esc
dismisses; Esc with a query clears it; cleared — by Esc or by deleting — with the pointer
gone from the dock, the empty field stays dock2's as if summoned, so the next Esc dismisses and the next
letter is still the query's. ↩ on the ring and ⌘1–9 use a tile as a click does — Finder's opens
Files, a plugin's tells its plugin. The stage's `performKeyEquivalent` takes ⌘1–9 (tile n, the puck's left out), ⌘W, ⌘,
and ⌘K, and swallows ⌘Q.

**The tile numbers** are a condition rather than a sequence: ⌘ alone is down, dock2 has the keyboard, no menu is
up and no block is on. Each of those changing looks again, and nothing is waited for otherwise. ⌘ can go down
before dock2 has the keyboard, as in ⌘space, and sends it no event, so `InteractionController` reads
`NSEvent.modifierFlags`, which needs no permission and answers whichever window the press went to; a `flagsChanged`
says itself what is down. Taking the keyboard and any key start a 0.3 s block, so a quick ⌘space or a chord shows
nothing, and its end looks again, in case ⌘ was let go while the keyboard was changing hands. A key is heard in
both `performKeyEquivalent` and `sendEvent`, since a chord dock2 handles never reaches the second. A menu rules
the numbers out for as long as `NSMenu`'s tracking notifications say one is up: it has the keys, and hears ⌘ let
go in the stage's place.

`DockView.showsNumbers` draws them as part of a tile: a `CATextLayer` for each, in `content` beside the dots, so
it blends with the glass as they do, slides with the dock and moves with its tile through a relayout. A number's
layer holds where it is going, its place or down at the dot, so a change of mind starts from what is on screen
(`raise`, `lower`). It goes up from inside the dot, at 0.3 of its size, on `NumberMotion.rise`, as the dot fades in
0.08 s, and comes back on the critically damped `fall`, the dot returning as it lands. Reduce Motion keeps
the fades and drops the rest. A tile with no room to rise, below 48 or on the shelf, only grows.

**The ring** is how the system Dock draws keyboard focus on macOS 27 (⌃F3): the icon darkened to 48%, as a
press darkens it, and its label. The pressed shade is that same 52% black.

### Global shortcuts

`HotKeys` registers chords with Carbon (`RegisterEventHotKey`; no permission). `GlobalShortcuts` owns every
registration: the summon shortcut, Clipboard History's, Files', and one for each plugin command the user bound
(`[plugins."<id>".shortcuts]`, §11) while its plugin runs. Carbon refuses a process's second registration
of a chord (`eventHotKeyExistsErr`), yet registers one another process holds, and the system's own — ⌘⇥,
⇧⌘3, ⌃↑ — so dock2 settles its own clashes first (`ShortcutAction.resolve`): a chord asked for twice goes to
the summon shortcut, then Clipboard History's, then Files', then the plugins in the order they are installed,
each command in its manifest's order, and the rest are reported taken. Each change to the summon shortcut, the
clipboard's, Files', the open tables or the plugin store registers again, keeping every registration whose chord
did not change. With the summon shortcut at ⌘space, Spotlight's entry 64 in the hot key table is a takeover
(§4), engaged before ⌘space is registered — only while the journal holds it — and released at once when the
setting changes; the guard switches it back on after a `kill -9`. A plugin's shortcut sends its `command`
event, an action, so a view it answers with brings dock2 up (§11). Files' is `DockController.useFinderTile`:
the tile's own rule decides, the open tile closing what it opened, so the shortcut toggles as ⌘1 does.
Clipboard History has no tile, so `toggleClipboardHistory` states the same rule itself: on top it pops, and
otherwise it shows.

## 7. Search

Every change to the field starts a `SearchSession` (Core): its sources are started together, and its first
frame — `freeze()`, which picks the top hit and fixes the order — comes when every source has answered or
50 ms after the keystroke, whichever is first. After it, a result only ever joins the far end of its section;
a first frame with nothing in it lets the first result to arrive be the top hit. Rows run upward from the
field: the top hit, then per section (Calculator, Apps, Commands, Clipboard, Files, then plugins) its best
three — five for Files — then its title, which counts what the section holds when that is more than it shows,
the top hit among them. Such a title is a row like any other, and "Show all" is what ↩ does on it. Selection follows a row's identity (`app:`, `file:`,
`cmd:`…; the calculator's is `calc`, whatever it answers, so its row holds its place as the query changes).

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
| Calculator | `Calculator` (`Dock2Calc`): fend's live preview, on a queue of its own, cut off at the 50 ms budget | none: its section is first and its one answer matches exactly, so it is the top hit unless a learned pick is |
| Apps | `AppCatalog`: `/Applications`, `/System/Applications`, CoreServices' Applications, `~/Applications`, Finder, three folders deep, never inside a bundle, watched with FSEvents; and the running apps | running, then dock2's own use; `kMDItemUseCount` and the last use only between equals |
| Commands | dock2's own: Settings, Clipboard History, Toggle Auto-hide, Quit Dock2 | dock2's own use |
| Files | `MDQuery`, synchronous on a queue of its own, capped at 2,000: each word `kMDItemDisplayName == "w*"cdw`, apps excluded; one or two characters search the near places — the protected folders only where looking asks nothing (`FileAccess.isClosed`, the rule Files' locks and the preview's folder count use too: choosing Full Disk Access is not the grant) — and what was used in 90 days; "Show all" lists the section's own results in Files, as search filtered and ranked them, until the query is changed there | `FileRanking`: near places, home and the folders Settings → Search ranks first, elsewhere, system; recency; depth; build and dependency trees and hidden folders last |

The catalog skips dot-files itself rather than with `skipsHiddenFiles`: Safari in `/Applications` is a
symlink flagged hidden. Spotlight takes no condition on `kMDItemPath`, so noise cannot be left out of a
query, only ranked down after it; a cold query takes up to a second, a warm one about 20 ms.

The calculator asks fend only what `Calculator.asks` reads as a question: a digit, and more than a number
with a word on it, since fend takes a lone letter for a unit and "4k" for 4000. fend's preview
(`evaluate_preview_with_interrupt`) then drops errors, the question restated, unit types and more than a
line. `dc_answer` is safe for any input: it refuses a question past 256 bytes, runs fend on a thread of its
own with an 8 MiB stack, since fend parses by recursion and a dispatch queue's 512 KiB overflows within a
hundred parentheses, interrupts it at the budget, since its exact arithmetic never finishes 9^9^9, and turns a
panic into no answer: the calculator unwinds where the engine aborts. Decimals follow `Locale.current`'s
separator, the one locale setting fend has. ↩ copies the answer, "approx." left off; choosing it records no
learned pick (`ResultPayload.isLearned`).

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
The selected app wears the echo, its tile's ring and label (`DockController.setEcho`), only if it has a tile:
the dock never changes shape for a selection.

The rows stand on the panel's grid (`PanelMetrics.Row`), on the pane: 56 pt, the selection's band 8 pt in from the
pane's side and the row's full height, its corners 20 pt (`Row.bandRadius`), concentric with the pane's and with the
plate's, which are 0.26 of it as Icon Composer draws it. The icon's plate is 32 pt in
a square as tall as the row, 12 pt from the band's side and from the title as from the band's top and bottom,
centred on the glyph line; its box is `plate / IconPlate.fraction`, 40 pt, so a plated icon's plate is an app
icon's. The title is 16 pt regular from the text line over a 13 pt subtitle truncated in the middle, a section's
title 12 pt semibold over the icons' leading edge, in a row of 32 pt: it is centred in the 24 pt beside its section,
the rest the gap that keeps it with the rows it heads. Its "Show all 8" is 12 pt regular, and ↩ comes after it on
selection, stopping on the margin with every row's trailing text and marks. The words hold ↩'s room at rest, so
they do not move as it comes and goes. Its band is those 24 pt, a capsule. Each text field's frame starts `NSTextField.textInset` before its line. At most eight
rows' height before the far end scrolls. A list beside a preview has compact rows: 36 pt, a 20 pt plate, a 13 pt
title, an 11 pt subtitle, and a band of 13 pt corners, concentric with the plate and short of the pane's. Grown, the
ground is one rounded rect from the field up, with continuous corners of 34 pt, the field's radius and its rim. The rim
opens as the ground comes (`FieldMotion.frame`), so the clear glass and the pane keep the field's radius throughout, and
a body too low for all of it keeps its round ends. The rows sit on the pane, which reaches `paneInset` above them, the
ground's rim (`PanelController.extent(of:)`).

Every selection on the pane is let down to the ground (`GroundInset`): search's and a list's rows, a grid's items,
Files' columns. It is the ground's own material and light shade, clipped to the band's corners, and edged by a
faceless glass (`GlassRecipe.inset`), clipped with it: the pane's edge seen from the other side, the pane's own cast
thrown in from its top wall (§3) and a plain line of light along its foot. Where the list holds the keys among others (`isFocused`, Files' column with the keys) it goes
past the ground, 24% toward black in dark and 11% in light.

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
(`{"symbol": …}` with its `tint` beside it, `{"png": …}`, `{"file": …}`, `{"app": …}`; `{"image": …}`, a
PNG in the plugin's folder, in a manifest alone). A tag is short text in a rounded pill, in one
of eight tints — the system's red to gray, the only colours a node names — drawn once (`TagImages`) as a
list row's accessory and inline in a detail's rows: one line, 240 pt at most with an ellipsis past that, and
nothing at all for a tag with no text. In a view a symbol is a glyph (`IconImages.image`), in
its tint's system colour, else a template the row tints. A `ViewHost` owns each one — dock2's own code,
later the plugin host: the renderer draws its node, tells it what the user did, and redraws when it says
the node changed. A node of another kind in an update — a sign-in form becoming the list it opens — brings
that kind's component (`NodeScreen`), which the stack mounts in place.

`ViewsController` keeps the stack over the search, each screen on it once: `push` of one already there closes
what is over it and keeps where it came from, and one on top is only focused. That is how Files, one object, is
asked for while a view covers it, and Clipboard History, found on the stack by its host. A view fills the panel at its maximum, eight rows' height,
in place of the results, on the pane, in the panel's `ScreenSlot`.

Every screen sits on the pane, as search's rows do. The slot draws nothing of its own: it is the pane's frame
(`PanelMetrics.pane`), `paneInset` in from the ground's sides and top — a scope's bar further at the top — with its foot on the field's top, and its
corners, 28 pt and continuous. It holds the screen's view at its own bounds, so a screen lays out within it.
Inside `content`, it is clipped by the glass's shape and revealed with the rest of the screen, and it fades in over
`contentFadeIn` as it appears, so a view pushed over a panel already its size does not cut in. While a screen shows,
the field and its bar sit on the ground's bare strip; the field becomes its filter with "Search *title*" for a placeholder, or — for a form
or a detail, whose own controls take the keys — goes blank, its magnifier hidden, since nothing typed there searches. The field's trailing end is the view's bar (`ActionsBubble`, a `BarMenu`, over
everything in the panel's stack, the field leaving it `trailingReserve`): one capsule of the label's glass,
28 pt high, under a `PillButton` saying its title and its key dimmed after it — "Actions ⌘K", or a
form's submit with ⌘↩, which a click runs. The pill stands on the field's midline, its end on the panel's margin
under the rows' trailing ends; the spinner sits 8 pt before it and the field's text 8 pt before the spinner.
Clicked, or on ⌘K, Actions opens into the menu of the screen's
`ViewActions`: the capsule growing up and to the left on the panel's opening spring (`GrowthMotion`, sampled at 120 Hz
into the `Keyframes` its glass, its shadow and the rows' cut all play, so they never part), nested in the
panel's corner and concentric with it wherever the pill stands: its corners 19 pt, its right and bottom edges
15 pt in from the field's, the panel's radius less its own; the
pill's label fades as it grows, the rows fill all of it, and the screen fades to 0.58 behind it. The rows — the item's actions, a
hairline, the view's — say each key as a menu would (`Chord.glyphs`), destructive ones red, the first two
↩ and ⌘↩ unless they have chords, measured whole (`sizeThatFits`: a truncating label's intrinsic width is a few points
short); taller than its room, the panel grown, it stops as far from its far edge as from the corner and scrolls, the
arrows keeping the selection in view; it draws back into the capsule on the closing spring, critically damped,
the label returning as it nears the pill's size; Reduce Motion crossfades the two sizes. While open it takes each key first
(`InteractionController.keyActivity`, as a confirmation does): the arrows, ↩, an action's chord, Esc and ⌘K
are its, and any other closes it and goes on, so typing reaches the field; the pointer moves its selection,
a click on a row runs it and one anywhere else closes it. dock2 says every key, so a view never describes
its own; search's field has no bar. Esc clears the filter, then pops; the last pop gives the search back
its query and, since a session for the same query is kept, its results and selection. A dismissal closes
every view.

A list or a grid with a `scope` (`ScopeNode`: options in sections, `value` the chosen one's id, else its first) has a
bar of bare ground along the panel's top, a row tall as the field's (`PanelMetrics.scopeBarHeight`), and at its trailing
end `ScopeMenu`, the same `BarMenu` as Actions: the option chosen, its icon before it and ⌘P after, opening down and to
the left into the panel's top corner, by section, titled and a hairline apart, a check on the chosen one, which takes the
selection as it opens. ⌘P is dock2's (`PluginChord`), and either menu opening closes the other. The panel grows by the
bar past the rim (`scopeHead`), so the pane keeps a view's size and a scoped list stands as tall as Files. The bar is part
of the panel's motion beside its edges (`Growth`, `FormFrame.head`), on the top edge's spring, so the pane's top — the
clear glass's less the bar (`PanelMetrics.layering`) — holds still as the panel grows by a bar opening over it, and as
it gives one back. The pill rides the glass's top right corner (`ScreenRide.scope`) in a view cut at the pane's top while the
glass moves (`ScreenRiders.scopeCut`), so it comes out from behind the pane as its bar opens, and at the pane's foot at
rest, for its menu; it fades in with a screen's bar, and out as its bar closes over it. The menu stops 15 pt above the pane's foot. A choice shows at once (`NodeScreen.chosen`, until the owner's next
update) and goes to the owner as `scope`, its id counted with the view's filters, so an answer names it as a filter's
does (`PluginViewHost`); the owner answers with the items the option leaves. A list or a grid given another scope selects
its first item, as a new query does.

| Component | Drawn as |
| --- | --- |
| List | `RowsView`, search's rows read from the top (`fromTop`: a flipped document, given to the clip view again as it flips, since a clip view takes its document's flippedness as it is given one), section titles above their rows, every accessory drawn — the texts joined, the tags and icons side by side, ↩'s action left to the bar; a row's end is measured before its words are placed, so the two never meet: its marks take all the words leave and half the row whatever they take (`marksRoom`), the title cut to make way, and past that they stop at what fits and a count of the rest (`PanelMetrics.marks`), one too wide alone being cut. The marks are drawn as the row is shown, for its width, as one image, a template icon in the secondary label colour since a composite loses the image view's tint: views only for the rows in sight and a row either way, icons asked for as rows come into sight, so two thousand items scroll and filter at typing speed. dock2 filters by title and keywords with `Matcher`, subsequences included, best match first, sections kept; with `filtering: owner` the text goes to the host once typing pauses for 0.15 s, each `filter` event with an
id, and an update that names the filter it answers is dropped if a newer one has been shown. A new query selects its best match, the first row; the same list redrawn keeps the selection. A node's `selected` is taken when it differs from the last one given: held until its item is among the rows, unless the user types or moves first, then selected and, out of sight, brought to the middle once the rows have a height (`RowsView`'s `centring`), so a redraw naming the same item never moves the user's selection. A screen closed tells its host what was selected (`closed(selected:)`), and a plugin hears it in `viewClosed`. Items with `children` make the list a tree, its rows `ListNode.rows` (Core): those under the open items, each stood in a level's `PanelMetrics.Row.indent` after a column for its chevron, which turns as it opens; with a query, every match under its ancestors, opened for it, in the tree's order, and `best` selected rather than the first row. What is open is the component's, an item's `expanded` taken as `selected` is. While the field is empty → and ← open, close, go in and go up (`step`); a click before an item's icon opens or closes it, ↩ does on one with no actions of its own, and one closing takes a selection from under it. A filter cleared keeps what it found, as `pending`, so the way to it opens and it comes to the middle. A list with `layout: flow` draws its items with `FlowView` instead of `RowsView`, the two behind `ItemsView`, everything above them shared: pills placed by `FlowLayout` (Core) between the rows' margins, 28 pt high and 8 pt apart, a section's title as a row's is, drawn by one canvas over what is in sight with one `GroundInset` beneath it for the selection; a pill is a 13 pt title, its icon at 16 pt before it, and a hairline edge in the separator colour. ← → step through the items, and ↑ ↓ take `FlowLayout.vertical`'s nearest pill on the next line. A flow is never `isTree`; one whose items hold items is drawn flat, and the host warns (`flowHidesChildren`). `preview` splits it, compact rows on the left 40% and the selected item's detail on the right, a hairline between them, edge to edge, as between Files' columns. An item's ⌘⌫ action (`Chord.remove`) is also a × at its row's end while the pointer is over the row, lit by the panel's pointer monitor as every `Hoverable` is; only that row's names shorten for it. When the selected item goes, the selection passes to the one that takes its place. |
| Detail | an image above, the body's inline Markdown — 13 pt in a list's preview, 14 pt as a view — label and value rows beneath, links live, a masked row's value eight dots whatever its length, and tags inline after a value, 6 pt apart either way: a space widened with `.kern`, free of the value's link, and clear space under each pill, which leaves the text beside them as set; an image and its text, measured as drawn, are centred together in the room above the foot when they fit, while text alone starts at the top; the status, its facts joined by " · ", in an 11 pt secondary line along the foot under a rule across the detail's width, outside the scroll, so it stays as the body scrolls; the buttons above it, and a scrubber above them, its labels either side, which submits `[id: value]` once let go and keeps its knob while dragged, whatever the owner redraws |
| Form | labelled controls in a column, as tall as they are and scrolling past the fold, text and folders as wide as the pane; Tab and ⇧Tab walk them, the field with the keys scrolled into view (a text field scrolls its editor only within itself), ⌘↩ submits, as the bar's submit does, an error sits under its field, and what was typed survives the redraw that shows it; a date is a date picker, submitted as ISO 8601's day, a folder a field with Choose… |
| Grid | images with titles in rows from the top, as the list reads; it scrolls, with views only for the rows in sight and a row either way, the selection kept in view; the arrows walk it, a click selects and a double click runs; `selected` is taken as a list's |

An action is ↩ if first, ⌘↩ if second, its own chord ("cmd+shift+c") if it has one, and on the bar's menu in
a view; search's and the dock's menus are built by `MenuBuilder.actions`/`action` with the
action's icon, its chord as a menu shows one (`Chord`) and destructive ones red, an ⌥ alternate paired with
its item by that key; search runs a result's own ⌘ and ⌘⇧ chords; a plugin's chord is ⌘ or ⌘⇧ with a letter dock2 leaves it (`PluginChord`: not ⌘K ⌘P ⌘W ⌘Q, nor the
text-editing ⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z), any other taken off as its view arrives; a ⌘-letter, ⌘↩ or ⌘K no view
claims goes to the search only when the search is on top; one marked destructive asks first. `Feedback` is one capsule, 36 pt high: a toast `Feedback.gap` (6 pt, `paneInset`) above the
glass's top edge, never below the field's, for 2 s; a confirmation there, its question beside Cancel and the action's
button — the accent colour, red when it cannot be undone — each with its key, ↩ or esc, dimmed after its title,
which gives way to any other key; and after a dismissal, a notice where the field was for
1.2 s ("Copied"), longer for a sentence: a character's eighteenth of a second, six seconds at most. A toast and a
confirmation ride the glass's top edge in an anchor view (`Feedback.anchor`) that `FormDriver` plays from the body's
own track. The anchor's frame is where the edge comes to rest, so a button is clicked where it will stop, and its
transform plays the way there, overshoot included. A dismissal takes them with it. A notice is placed in the anchor
where the field was. The capsule is
the grown panel in small, a `PanelGround` with the pane's glass laid on it in the capsule's shape, over the panel's
shadow, so above the panel it reads as the panel's own; it drops 6 pt into place as it fades in and lifts as it fades out, without the travel under Reduce Motion. Clicks
pass through it unless it has buttons (`ToastButton`, a `PillButton`). Each is announced to VoiceOver. The field's spinner, at its trailing edge as far in as
the magnifier is from the leading one, shows a search source still working after the first frame, or a
list loading; a query nothing answers says so in one row.

"Show all" is dock2's own: the section's results as a list (`SectionHost`), each result's actions with
search's chords — an ⌥ alternate as an action of its own, a submenu, Open With…, as a list of its choices
pushed when chosen — run as search runs them: the pick and the use recorded, then the dismissal and its
notice. Its rows wear search's icons, from the one place both ask (`ResultActions.icon(for:)`), through the
host's `icon(for:)`, which a list asks before drawing the icon an item names.

## 9. Files

Files is a screen of its own over the search: 960 × 520 with its path bar in the field's place, the
panel's glass growing to it on its springs (`GrowthMotion`). Everything but the bar sits on the pane (§8), the
columns filling it in four slots (`FilesLayout`), the banner a card `PanelMetrics.cornerInset` in. One `FilesScreen` lives as long as dock2, so it
opens where it was. Ways in: Finder's tile (⌥ for Finder), a place from its menu, Show in Files (⌘↩ on a
result, an app tile's menu), a path typed in the field — the path bar takes the text over — and Files'
"Show all", which opens its search across the Mac. Opened from a query, Esc goes back to it; from
nothing, Esc dismisses.

**Where it is** (`FilesState`, Core): up to six tabs, each a chain of columns from home, or from its
volume's root outside home — a network share's server's column before it — and the column with the keys; a new tab goes beside the current one, and
closing one shows the next, or the one before when it was last; selections; → into a folder's column, ← back
leaving it open and empty, ⌘↑ adding the parent before the first column; renames and removals followed. A tab has two
folders that differ while a folder is selected, since the selection opens a column and the keys stay behind: `folder`, the
column with the keys, which the path bar shows and a paste lands in, and `deepest`, the last open, which is where the tab
is to anything outside it: its pill's name and plate, a drop on it, its ring, and ⌘K's Copy to and Move to.
Every URL has one spelling (`URL.canonical`): a folder's URL gains a trailing slash once it exists,
`deletingLastPathComponent` adds one, and a listing resolves `/tmp` to `/private/tmp`, and any of them
would make an item unequal to itself. `DirectoryListing` builds each item's URL from the folder's as
given, sorted by `FinderOrder` (`localizedStandardCompare`, folders first unless Settings says not), a
package a file and a link to a folder a folder. A kqueue vnode source on each folder shown relists it.

Listing runs off the main thread (`FolderListings`, System), since it takes as long as the folder has items and nothing else about a
column does: rows are built as they scroll in. What a folder last held stands until a new read lands, so one read again neither
empties nor loses its selection. A read waits 10 ms, so a small folder is there on the frame that asked and shows no empty frame. One
read runs at a time for a folder, and changes during it come to one more. A folder no longer shown has its read cancelled between
items (`DirectoryListing.list`'s `isCancelled`), since reads left running queue ahead of the one wanted. A first read out for 0.25 s
says Loading… in its column. What needs an item only the listing holds waits for it (`whenListed`): a new folder's rename, the first
item selected on going into a folder, and pruning what vanished from a selection, which must not run on what a refresh hasn't read yet.

**The columns** are Finder's column view on the pane's grid rather than at Finder's measured density and insets, which
suit a far tighter corner: 28 pt rows, an 18 pt icon on the panel's margin, a 13 pt name 24 pt past the icon's edge, and
a folder's quiet › ending on the margin at the far side, in the tertiary label colour so that a column of them stays
out of the way. The band, of radius 10, stands `cornerInset`, 12 pt, in from the column's sides and the pane's top and foot, let down to the ground and past it in the
column with the keys (§7), what is on it drawn as on the pane rather than inverted. Four 237 pt slots fill the pane's
width, three columns and the preview or four columns; hairlines between them run its full height, and a column the
pane's own edge ends has none. Rows scrolled towards the pane's top and foot fade inside the inset (a gradient mask
on each column's scroll view), so its corners never cut one, and the scroller stops on the margin, short of them.
Every scroll view with a scroller is an `OverlayScrollView`: AppKit writes `legacy` over a set style, and a legacy track
stands down the content's side whether anything scrolls or not. A
folder opened beside the last column slides out from it on a spring as it fades up (`ColumnView.arrive`), and only fades
under Reduce Motion; a tab or a path arrives whole.
Each is an `NSTableView` for its keys, type-select, drags and accessibility; the strip scrolls sideways by
whole columns, never past the one with the keys, with no scroller — an overlay one sat over the rows —
and, scrolled, a fade at its left edge as far as the icons (a gradient mask on `ColumnsView`). The preview takes the
last 237 pt: a Quick Look thumbnail, name, kind and size, then its dates beneath a rule across its width as label and value,
or a folder's count, in the panel's type sizes. A thumbnail fits a frame of its own, for corners and a shadow that make it
a page lying on the pane, and fades in over the icon; a date this year is given to the minute, an older one to the day. Space lays a `QuickLookCard` over the columns, as search's ⌘Y does: a `QLPreviewView` `cornerInset`
in from the pane and concentric with it, since Quick Look draws up to its own edges. The columns go transparent under
it rather than hidden: hiding the column with the keys takes them from it, and they are what closes the card.

**The path bar** (`PathBar`) is laid out as a search result is. `PlaceButton` is the place holding the folder
(`Place.holding`) as one pill from the margin, as tall as the crumbs. Its 18 pt plate, in that place's colour (`Place.color`), stands in a
square the pill's height centred on the glyph line, and lands on a spring when the place changes; its name, 16 pt, starts where the square ends.
After it the folders inside that place (`Place.start`) are a breadcrumb of `PillButton`s — a
rounded fill lit by hover, press and a drop held over it — every one a way there, with chevrons between, and the selected
item after them, named but inert, a file's icon beside it. The bar's last mark ends on the margin. A drop on `PlaceButton` goes into the place, and a click lists the
places (`Places`, read as Files opens and as volumes mount and unmount), each on a small plate with Finder's key, the one
holding the folder checked, then the disks, the servers connected to and Network, and Go to Folder…. The bar's menus rise
from it over the pane, as a tile's does from the dock, the pill that raised one lit until it closes. A place that ejects is a row of its own (`PlaceMenuRow`) with ⏏ where
an item's key would be: an item with a view draws nothing, so the row draws the selection material, the check, the plate and
the title at the insets measured off the items beside it, and its item keeps a state so the check column stays for all. Too
long to fit, the crumbs fold from the first on into "…", a menu of the folders folded; the place stays and the last truncates. The tabs
(`TabStrip`) end it: with one tab only New Tab, from two a pill each on its place's plate, as wide as its name up to
176 pt. They share up to half the bar: past that the widest give way evenly (`PanelMetrics.fit`), down to 84 pt, while a
short name keeps its width and what it leaves goes to the long. `~`, `/` or ⇧⌘G turn it into a text field at the
field's size: Tab completes with `PathInput` (case ignored, a single folder taking its slash), the columns
follow the deepest folder typed, ↩ goes. ⌘F turns it into a search of the folder: Spotlight scoped to it,
and a walk of it for what Spotlight has not indexed, stopped after 50,000 items or 1.5 s and passing over
the folders looking in would ask about (`FileAccess.asks`, the grant probed once), the results beside the
preview with where each is; ⌘↩ shows one in the columns. While its field is edited — a path, ⌘F's query —
the text keys (⌘A ⌘C ⌘V ⌘X ⌘Z ⇧⌘Z ⌘⌫) are the field's, not Files' commands.

**Servers** ([servers](product/files/README.md#servers)). `Servers` (System) groups the mounted volumes by
`volumeURLForRemounting` into `smb://<host>` places, the host a Bonjour-found server's too, named as Finder
names one (`Synology._smb._tcp.local` is Synology); `Places` lists a server in place of its shares. A column's
folder may be a URL that is no file's — Network (`network:`), a server, a share not mounted
(`smb://<host>/<share>`) — which `canonical` leaves as it is and `FilesState.relative` keeps apart from the
folder of its path on this disk. `Servers.parent(of:)` is what ⌘↑ and a column's holder ask: a share's root
leads to its server, a server to Network. Their listings are no folder's: Network's is `NetworkBrowser`
(`NWBrowser` on `_smb._tcp`, started while it shows) and the servers connected to; a server's is fetched once
through the SMB NetFS plugin (`ShareListing`: `OpenSession` without UI — as the user its shares were mounted
as, else a guest — then `EnumerateShares`, `Cancel` at 15 s), its mounted shares read from the mount table on
each render. A share not mounted mounts as it is selected, as in Finder's columns (`NetFSMountURLAsync`, macOS
asking when it must), its column saying Connecting…; mounted, `FilesState.moved` takes its columns to the mount
point. Connecting…, can't reach, Not Connected and a mount's failure are column messages over a button (Try
Again, Connect, Connect As…). ⏏ is a button on a row that `ejects`; ⌘E ejects the selection, the server whose
column it is, or the volume the folder is on, all off the main thread (`Eject`): a share by `unmount(2)` alone,
since `FileManager.unmountVolume` on one share unmounts its server's every share; a server share by share; a
disk, the whole device. The columns in a volume gone close, and a tab that started in one shows its server, or
Home. Network's and a server's columns hold no files: copying, pasting, making, renaming, trashing and Quick
Look do nothing there, a row there drags out only once mounted, and nothing drops in. macOS's sign-in window
(`NetAuthAgent`) activating dismisses dock2, whose window sits above it at the Dock's level; a mount it asked
for done, Files comes back (`onReturn`), unless it was cancelled. `smb://` in the field, the path bar or
`dock2 files` goes to that server.

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
Duplicate, Copy, Copy Path, Copy Contents, Copy to and Move to each other tab's folder, Eject for a volume,
Move to Trash, New Folder, Open in Finder — each action taking its items rather than reading the selection.
In Network's column and a server's it is `networkActions`: Open, Eject or Disconnect, Connect As…. ⌘K's is for the
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
global shortcut) is a list with preview, newest at the top; a `ViewHost` may give an item's
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
(`PluginProtocol`, Core; the Rust SDK in `Plugins/sdk` is the same shapes from the other side). A manifest is
read by `PluginStore.manifest(in:)`, which validates it and reads each `image` its icons name — a relative
`.png` path that never climbs out of the folder — into `png`, so nothing past loading sees a path. Its
`capabilities` are an object keyed by capability (`PluginManifest.Capabilities`), each with what it names —
hosts, sockets, folder settings, schemes and apps, services, commands — and the plugin's `reason`, which
install refuses to do without; so too a scope naming what it cannot reach, the list form, or a folder setting
with a default, since the folder is the user's to pick. Its `reach` is the scopes alone, as sets, a `$setting`
with its default: an update asks again for what `beyond` says it reaches past what was agreed to — a default
changed included — never for a reason reworded. dock2's own line for each (`lines`) names what it enforces, a program by its full
path. A plugin hears what it holds in `started` and again in `granted` as Settings changes it, and every
effect names the capability it needs in a switch with no `default`. The scopes' guards are Core's:
`PathGuard` (links resolved, no `..`, inside a granted folder, a dangling link at the first missing step
refused), `CommandGuard` (a declared command's slots to its argv: one argument each, never starting with `-`,
a path inside a folder setting's folder) and `HostPort` (what is on this Mac or the local network).

**The engine** is wasmtime 49's Pulley interpreter behind a C ABI of dock2's own (`Engine/`): no
executable memory, so nothing the hardened runtime refuses; the Cranelift JIT needed
`allow-unsigned-executable-memory`, and `allow-jit` alone was killed. The guest exports `dock2_alloc`,
`dock2_free` and `dock2_handle` and imports `dock2.log`, `now_ms` and `random`, calls that hand nothing
back into the guest mid-call. Nothing it imports reaches out: every capability is effects dock2 performs and
events it sends, checked in the host, since WASI's filesystem and sockets would block inside a call, past its
budget, and reach around the one place a grant is checked. A 1 ms epoch ticker and a deadline callback that checks the wall clock end
a call within a tick of its budget: 50 ms for an interactive event, 1 s for background work. The ticker
waits on a condition while no call runs, so idle dock2 wakes about twice in five seconds. Memory is
capped at 64 MiB. A compiled module is cached by the module's hash and the engine's version
(`PluginCache/`), since compiling takes 17 ms and reading back 0.06.

**An instance** (`PluginInstance`) runs on a queue of its own and starts at its first event with
`started` and the plugin's settings. A call that traps, overruns or runs out of memory discards the
instance — the next event starts a fresh one, its storage intact — and five in a minute suspend the plugin
with a notice: stopped until dock2 quits, Settings tries it again, or new code is installed. Its choice is
left alone (`PluginStore.suspended`, never written down), since failing is not the person switching it off. Unloaded by the host when idle (below), it hears `stopped` and goes; what a stopped instance answers is not
acted on, since everything it held has ended.

**The host** (`PluginHost`) checks every effect against the manifest's capabilities and the user's
grants (`PluginStore`). It holds what each plugin keeps open — a timer, a subscription, an answer it waits on —
under the capability that allowed it (`PluginResources`): revoking a capability ends what it holds at once, a
request it was answering hears that it was revoked, and an answer is delivered only while its request is held.
The choices are the settings file's, `[plugins."<id>"]` (`PluginChoices`), so they
follow the person between Macs, and a key not written there is what the installed manifest says: a
first-party plugin starts off, one installed from a folder on, since installing it was their choice, and a
development one on, since running a debug build was (`PluginOrigin`). Grants
are kept as what was revoked, so installing again — an update, `dev` after a rebuild, the same plugin on
another Mac — keeps what the user revoked revoked. What was last agreed to is this Mac's:
`PluginData/<id>/agreed.json`, the reach the person last said yes to, which an update's sheet asks beyond and
whose absence makes a first-party plugin ask the first time it is switched on here. `query` goes with the
results switch: switching results on grants it, off revokes it, and a plugin first seen holds it only if its
results start on; `run` starts revoked while a command takes any arguments. Only the keys a change touches are written.
A table for a plugin not installed here is carried untouched, and removing a plugin leaves its table: taking
it out would put a copy still installed on another Mac back on its defaults, every capability granted. A
change the file brings — an editor, another Mac — restarts the plugins it touches, unless it touches only
their commands' shortcuts (`shortcuts`, by command id), which a plugin never hears of. `plugins.json`, where the
choices were kept before, is carried in once a Mac (`pluginChoicesImported`), for each installed plugin the
file says nothing of, one dock2 had switched off for failing back on. Results' action chords pass the same rule as a
view's, so search's field keeps its text keys. An instance with nothing to do — no tile on the dock, view open,
timer, subscription or unanswered request — unloads after three minutes without an event
(`idleAfter`, the spec's open "a few minutes"), and its next event starts it again; a refused one comes
back as an `error` event under its request id. HTTP goes over HTTPS to the hosts the manifest names, a
`$setting` standing for a self-hosted server and `*` for any; a redirect is followed only within them, else
the redirect is the answer (`RedirectGuard`); a setting's value counts only if it names a host. Each plugin has
an ephemeral `URLSession` of its own, so no cookie, cache or credential of one goes with another's requests;
it outlives an idle unload, not new code. A method and a header's name must be HTTP tokens and a value break no
line (`HTTPSyntax`). An answer is read by a task delegate (`ResponseReader`): whole, up to 16 MiB; marked
`stream`, its status and headers, then its body, as `httpPart`s, then the `http` event without a body. A WebSocket (`PluginWebSocket`), `wss` alone and eight to a plugin, opens, sends and closes by
effect, its news as events; both are held under `network`. Plain HTTP, or HTTP over a socket, is
`local-network`'s (`needs` reads the scheme): to a `host:port` the manifest names, local by its spelling and by
the address reached once connected, or to a socket it names — through dock2's own client (`LocalHTTP`, over
Network.framework, read by Core's `HTTPResponseParser`), since `URLSession` has no Unix sockets: one request a
connection, a redirect the answer, a whole body capped at 16 MiB, thirty seconds of silence the end. A view brings dock2 up only in answer to the user — a command, an action, a
form or a tile, or the answer to a request one made, within 10 s (`answerWindow`) and unless the user has
dismissed dock2 or gone to another app since (`userMovedOn`); any other shows only while dock2 has the
keyboard. A URL opens only in answer to the user too — never to typing — and a file only if it is content — text, pictures, documents — by allowlist: Terminal
settings, Finder's location files, workflows, installers and apps are not content, and scripts, profiles
and shortcuts, which are, are refused too, since opening one runs something, as are profiles to install and
Java launch files; nor does a document open in an app that runs what it opens. Which app does
(`runsWhatItOpens`) is read from its own `CFBundleDocumentTypes` — the Shell role, as Terminal and Ghostty
declare, or a program, app or script it views rather than edits, as JavaLauncher does a jar — beside the list
install refuses by name (`Apps.runners`). With `apps` (`PluginHost.opening`), a link of a scheme the manifest
names opens unless its app runs what it opens, and a file opens in an app it names, by bundle id, under the
same rule. Secrets are Keychain items under
`zip.tanner.dock2.plugin.<id>` inside the bundle and a 0600 file outside it, read and written on a queue
of their own, since the Keychain may block on a prompt. A secure setting is one of those secrets, under
`dock2.setting.`, a prefix the plugin's own secret effects are refused; the store reads them once, on a queue
of its own, and keeps them, since settings go with every event — a plugin already running hears them as they
come — and moves one found in the clear in the settings file into the secrets, and out of the file. A number setting is saved as a
plugin parses one: "5", not "5.0". A copy or a paste marked concealed carries
nspasteboard.org's marker, so clipboard history never keeps it, and is cleared after 30 s if nothing was
copied since. A toast shows in the panel, or, the panel gone — a plugin that dismissed — as the notice where
the field was. Installing from Settings stops a running older version first. `derive` runs PBKDF2-SHA256 or Argon2id natively, in the
engine's crate, off the main thread: a key derivation is slow by design — 600,000 rounds, or 64 MiB — and
past any call's budget or memory in the interpreter. Timers fire at a tenth of a second at the least,
thirty-two at most.

**Services** (`PluginXPC`): a plugin's first message to a service its manifest names opens a connection by
the Mach name, privileged for a daemon, held to `anchor apple generic and certificate leaf[subject.OU] =
"<team>"` (`xpc_connection_set_peer_code_signing_requirement`), since any LaunchAgent can claim a name in the
user's domain; Apple's names are refused at install. It is held under `xpc`, so a revoke cancels it. A message
is a dictionary, `dock2.plugin` set to the plugin's id over whatever the plugin put there; with a request id
its reply comes back as `xpcReply`, or an `error` after 30 s (`xpcReplyWindow`). What the service sends
unasked is `xpcMessage`; `xpcClosed` says `interrupted`, for the plugin to send its state again, or `invalid`,
after which the next send connects afresh. Values (`XPCValue`, Core) are JSON's own — a whole number an int64
— and `{"$int"}`, `{"$uint"}`, `{"$double"}`, `{"$data"}`, `{"$date"}` (milliseconds since 1970) and `{"$uuid"}`
where JSON cannot say which; every number comes back tagged, and a reply holding a descriptor, shared memory
or an endpoint is refused whole. The SDK's `XpcValue` hides the tags.

**Commands** (`PluginProcess`): `run` names a command the manifest declares and its slots' values, filled by
`CommandGuard` off the main thread — a path or a folder inside a folder one of its folder settings holds — its
program checked against its `team` with `SecStaticCode` before each spawn. `posix_spawn`, never a shell,
disclaimed (`Disclaim`) so the program answers to macOS for itself, never with dock2's grants; with
`POSIX_SPAWN_CLOEXEC_DEFAULT`, so it holds no descriptor of dock2's but its pipes; in a process group of its own;
with `PATH`, `HOME`, `LANG` and `TMPDIR` from the environment dock2 was started with and nothing else; in its
`{folder}`, else home; reading the plugin's bytes on stdin, written with `F_SETNOSIGPIPE`, else `/dev/null`.
stdout and stderr come back as `output` as they are read, up to 4 MiB (`outputLimit`), the rest read and
dropped; `exited` follows both pipes' end with the status or the signal, `truncated` and `timedOut`. A revoke, a
stop, `cancelRun` or the time limit — the command's `timeout` within 60 s (`runLimit`) — sends the group SIGTERM,
then SIGKILL two seconds on; a program that exits on its own takes what it left in its group with it, killed
while it is still a zombie, and no signal is sent once it is reaped. Held under `run` from the moment it is asked
for, a command keeps its instance loaded; eight run at once at most (`processLimit`), and a revoke tells the
plugin under each one's request.

**Files** (`PluginFiles`): `files` reaches the folders the folder settings it names hold now, a setting left
empty granting nothing. Every path is resolved by `PathGuard` on a queue of the host's own — a folder macOS
guards may prompt, for Dock2, and wait — and comes back resolved. `fileRead` carries up to 8 MiB (`readLimit`)
from an offset and says the whole size; `fileList` up to 10,000 entries, a link as a link; `fileStat` one, or
none; `fileWrite`, with `"write": true`, makes the folders it lacks and replaces the file through one beside it
renamed over it, or appends — the last step opened `O_NOFOLLOW`, so a link swapped in is never written
through, and `O_NONBLOCK`, so a FIFO is refused rather than waited on by every plugin's files; work that waited
its turn past a revoke does nothing. `watch`, held from the moment it is asked for, hears a granted folder's file-level changes through FSEvents (`FolderWatcher`), 0.3 s at a
time, eight to a plugin, held under `files`; a folder setting moving elsewhere ends what it no longer grants
(`PluginHost.setSetting`).

**Storage** (`PluginStorage`): SQLite through the system's `SQLite3`, `PluginData/<id>/storage.db`, one `WITHOUT
ROWID` table of string keys to string values, the values kept as bytes so their length is known unread. Keys
order by their UTF-8 bytes (`BINARY`), so a prefix is a range of the index: from the prefix, or past `after`, to
the prefix with its last scalar stepped up one (`end(of:)`), stepping over the surrogates and dropping a last
U+10FFFF; "" is every key. Bounds are bound parameters, one a side, so the index is searched from where a page
starts rather than scanned to it. A plugin never names SQL: no `ATTACH` or pragma for it to reach past its file,
no dialect in the versioned interface, and it needs atomicity rather than isolation, being its store's one
writer. `storageWrite` is one `BEGIN IMMEDIATE` transaction of sets, deletes and prefix deletes in order, all or
none; `storageRead` answers each key holding a value, in the order named, as a list, since a dictionary would take
"é" and "e\u{301}" for one key; `storageList` a page, forward or reversed, with values or keys alone, `more` when
the range goes on. `storageGet`, `storageSet` and `storageDelete` are the one-step cases, on the wire as before.
An index is the plugin's own keys, written in the batch it indexes. Each plugin's store works on a queue of its
own, opened at first use: its effects apply in the order sent, a read after a write in one answer seeing it, and
off the main thread, since a value may be a whole vault. An answer is delivered as a request's is, holding the
instance against unloading, dropped by a stop; a write already asked lands. WAL with `synchronous = NORMAL`: a
write that fails, or a process killed mid-batch, leaves the store as it was. Limits (`Limits`): 1 KiB a key,
24 MiB a value, 256 MiB a plugin, each entry costing its key, its value and 16 bytes (`entryCost`, about what
SQLite spends on one); a page ends before 1,000 entries or 4 MiB, holding one at the least. Past a limit the
batch is refused whole, as an `error` under its request, or, with none, to the plugin while it runs; one already
past the quota may still shrink. `storage.json`, where storage was kept before, is carried in as the database
first opens, its keys over the database's, then removed. The database closes as its plugin stops or unloads —
its WAL checkpointed, the system's SQLite leaving `-wal` empty and `-shm` beside it — and as dock2 quits, once what was
asked is written; removing a plugin waits for it to close before its data folder goes, the three files with it.

**In dock2's surfaces** (`PluginsController`): a plugin's commands sit in Commands under its name — those it
last listed with `setCommands`, kept in `PluginData/<id>/commands.json` so Commands is right before it runs,
or, before it has listed any, those its manifest does not mark `hidden` — running one dismisses unless the
manifest says it opens a view; its results, if it answers search and they are on,
have a section of their own and arrive when they arrive, at its end; a result's action leaves dock2 up for
the plugin to decide what follows — a view, a copy that lets go, an app coming forward. A view is a `NodeScreen` on the
panel's stack whose actions, filtering, scope and submissions go back as events, named by its id; `updateView`
redraws the open view of the node's id in place, whatever kind the node now is, and one naming no open view is
refused, the plugin's log saying so. Tiles follow a separator at the dock's end, drawn by `PluginTileImage` from a `TileNode` — its
icon on the plate in its plugin's tint (§5), a ring, a badge, a caption — and redrawn alone when they change, so a
hovered tile keeps its label; a click is a `tile` event. Settings → Plugins switches each one and its grants,
each with dock2's lines and, under them, what the plugin says; its results, its tiles and its settings.
Installing from a folder, or switching a first-party plugin on for the first time here, shows a SwiftUI sheet
(`PluginAsk`): the plugin, and a switch per capability it reaches beyond what was agreed to — all of them the
first time — with the rest as they stand; what it switches off is written as revoked before the plugin first
runs. Search's sources follow the store as plugins come and go. `dock2 plugin list | install | dev | remove` does
the same from a terminal, printing the sheet's rows and asking once, what starts off left off — `dev` installs
again each time the module or manifest is rewritten and has settled, asks again only if it reaches beyond what
was agreed to, and streams the unified log's lines about the plugin —
and tells a running dock2 the plugin's id by a
distributed notification: what ran of it stops, the store is read again, its tiles start on the new code.
The store is `@Observable`, so Settings shows what the terminal changed. A compiled module is named by its
hash and replaces the plugin's last; removing a plugin removes its code, storage, secrets and compiled
modules, and keeps its choices.

**Development plugins** are what `make plugins` builds into `.build/dev-plugins`, which `make app` never
copies: the demo. `PluginStore` reads that folder, after the first-party plugins and before the user's, only
under `DOCK2_DEBUG=1` (`LaunchEnvironment.isDebug`), and never inside the bundle. Like a first-party plugin,
one is neither removed nor installed over; `dock2 plugin`, which runs without the switch, never lists it.

**The demo** (`Plugins/demo`) is every view dock2 draws, in every variation it knows, over made-up data.
Demo Gallery lists its screens by kind — lists, details, forms, grids, actions and feedback, and maximal — each
with a preview of what it is there to show, and Demo List, Detail, Form, Grid, Feedback and Maximal open each kind's
first. The maximal screens fill a view past its room, where the others show each variation alone: one table of rows
with tags, wide and beside a preview, tags in every place a metadata row holds them, and a detail, a form and a grid
each at its longest.
A screen (`Screen`) is made fresh as it opens and dropped as it closes, so every visit starts from the same
state — but for the selection a screen that opens where it was left (`resume`) is handed, from its last
`viewClosed`, and Kept Notes' notes, which live in its storage — and what it pushes, times, lists or writes is named
`<screen>/<name>` so the answer finds it. Its pictures are PNGs
it draws as it starts, under the start's budget rather than an action's, since a plugin reads no files: stored
deflate, and a `pHYs` chunk that tells AppKit a 2× picture's size in points. It holds `clipboard.write` and
nothing else, so one of its rows can show a refusal.

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
(open at login, the file's `open-at-login`, which dock2 applies to `SMAppService.mainApp` at every launch
and on every change, both ways, from the bundle only; the summon shortcut: ⌘space, a recorded chord, or
none), Dock (style, size, auto-hide and its delays, type to search, tile numbers, bounce,
running apps), Search (the field's form; each built-in source on or off, which the search controller then skips; the
plugins' sections in order; folders ranked first, with the home folders; excluded folders, whose files
the file source drops — one `FolderList` for both; the learned picks, each
kept with the title it was picked under, to forget one or all), Clipboard, Files (folders first, hidden
files, the preview column, the global shortcut, the Finder tile's icon — a grid of every picture drawn by `FinderTileImage` in the
chosen colour and fill, Finder's first, a `ColorPicker` read back in Display P3, and the fill — "Show in Finder" opens Files), Shortcuts (every global shortcut in one tree, a `Section(isExpanded:)` per node that its header opens and
closes: Dock2's Open Dock2, whose recorder reads ⌘space as Spotlight's taken over, Clipboard History's, Files',
wearing the tile's icon, then each plugin with every command its manifest declares, hidden ones too, a plugin that is off saying so at its
header's end),
Plugins (every grant shown, a plugin on or off), Permissions (Full Disk Access with its state and its
pane — macOS has no prompt for it, and dock2 is listed there from its first refused look into
`~/Library/Safari` — and a button for the three folders alone — once chosen, each folder with its state, opened rather
than listed, and Files and Folders' pane, `Privacy_FilesAndFolders`, checked like the others; Accessibility, Screen Recording and Paste from Other Apps through
`PromptedPermission` — allowed, off, asking at each read (the pasteboard's `.ask`) or not asked, which TCC's
preflight tells from off and the pasteboard's `.default` says — each with Request Access…, enabled while macOS
would prompt (Accessibility's comes back until allowed, the others' once; only a prompt lists dock2 in the
pane), and its pane, `Privacy_Accessibility`, `Privacy_ScreenCapture`, `Privacy_Pasteboard`, the last's anchor
checked in System Settings) and About (version, the settings
file, opened — created first with its starter comments if there is none — the first launch again, logs,
Quit). Above every section, what the file gets wrong, line by line, and a button to open it; and, while it
can't be read, that nothing changed is saved. `SettingsNavigation` opens the window at a
section. `SettingsModel` gives SwiftUI a binding per key over the observable store; the picks
and the plugins are `@Observable` stores of their own. A picker shows a value the file was given by hand, as
"14 days", rather than nothing chosen. `ShortcutRecorder` takes only chords that type
nothing: with ⌘ or ⌃, or a function key — and that the file can spell, by emira's key names (`KeyName`). It
keeps a control's size and tells SwiftUI where its text's baseline is, since SwiftUI reads none from an
`NSView`: a representable left to size itself takes a Form row's whole width, and `LabeledContent` puts it under
its label, row by row as the window narrows. Under a global shortcut's title, as the row's subtitle, Settings says which of
dock2's own keys it takes, from `ReservedKeys` (⇧⌘V: "moving here in Files"), or, in red, why it does nothing:
another action holds its chord, or macOS refused it (`ShortcutStatus`, set as `GlobalShortcuts` registers). Open System Settings, from Files' ask,
Settings or the first launch, then watches for Full Disk Access every two seconds for ten minutes, and dock2
says when it lands.

**The first launch** runs when `onboarded` is unset, before the guard or any takeover: a journal a dead
run left is given back first, and nothing else is touched until the last page, which writes the choices —
the system Dock's settings copied where the file doesn't say, the summon shortcut, file access, "Show in
Finder", clipboard history, open at login — sets `onboarded`, and starts dock2. Its choices start as the file
has them, and its preview shows the file's dock where it says one. `onboarded` is in the file, so a Mac
reading another's skips it: Files asks for access the first time it opens, as it does for `.notAsked`. Closing the window earlier quits with the Mac as it
was. Its dock preview is the platter's glass and the copied tiles over a gradient: AppKit's
`desktopImageURL` reports a fallback picture for the system's own wallpapers, not the one showing. Run
again from Settings, it shows dock2's own dock and copies nothing.

`dock2 config path | open | check | explain | get <key> | set <key> <value>` works on the file directly,
not through a running dock2, which hears the change as it hears an editor's: `check` prints each mistake as
`path:line: message` and exits 1 if there are any, and `set` validates through the same codecs and takes a
line out where the value is the default.

## 13. Accessibility

The dock is what VoiceOver finds in the system Dock: a list named "Dock" of `AXDockItem`s — application
items, plugin tiles as URL items, minimised windows as minimised-window items — each with its name, "running" when its app is, and Press and Show
Menu (`DockItemElement`); the puck's items are a group of their own, "Sideline", after them. Search's results are a list of rows that say their title, subtitle and state,
section titles as headings, or as buttons where they open their section; VoiceOver stays in the field — a search field, by subrole — while the arrows
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
as the field's text; `files` and `clipboard` open what the Finder tile and the clipboard shortcut open, and
never close it.
`quit` terminates on the main loop's next turn, after its reply is queued, which `ControlServer.stop` sends
before closing. The CLI then waits up to 15 s for the `InstanceLock` to be free (`awaitFree`): dock2 and its
guard have let go, so a dock2 started next claims it at once.

`debug` commands are answered only when `DOCK2_DEBUG=1` was set at launch, the switch that also loads the
development plugins (§11). `audit` alone is not a request: the CLI answers it, with no dock2 running, so it works where
dock2 won't, and exits 1 if `PrivateAudit.missing` names anything. In a VM (`kern.hv_vmm_present`), whose window leaves
⌘space to the host, a debugging dock2 also shows `SummonButton`: a tab on the screen's right edge, a window of its own above
the stage, that calls what the summon shortcut calls. `type` and `key` build key
events with US-layout key codes and post them into dock2's own queue (`NSApp.postEvent`), so they take the
path a key press does: key equivalents (`cmd+k`, `cmd+1`), an open menu's tracking, then the stage window's
own look and its first responder. `type` is refused unless dock2 has the keyboard. `hold` posts a
flags-changed event alone. `reveal` is an auto-hide hold of its own (`.control`). `state` is a `DebugState`:
the interaction's phase, the panel's text, form and selectable rows with their frames, the tiles with their
names, kinds, badges, frames and — a minimised window's — how it is drawn (`picture`, `shape`, `square`), and
whether each is on the puck (`sidelined`), and the field's, the body's, the reach's, the platter's and the puck's frames, in screen points
from the main display's top left. The CLI (`ControlCommandLine`) composes `capture`, `record` and
`type --every` from those requests and `screencapture`. It also composes `move`, `click` and `drag`, which
post to the HID stream at a `PointerTarget` resolved in that state, a move every 8 ms. dock2 reads the real
cursor and AppKit's drag sessions follow it, so nothing but the real pointer would be the same. A target
not showing is refused. The CLI exits 69 when no dock2 is listening.

## 15. Build and release

`make build` · `make test` · `make app` (`dist/Dock2.app`) · `make dist` · `make notarize` · `make install`.

- **The bundle is `Dock2.app`, and Dock2 is the name people see**: `CFBundleName` and `CFBundleDisplayName`,
  which Finder, Spotlight, the menu bar and the privacy lists show, and every string in the GUI. The
  executable, the CLI, the archive, paths and identifiers stay `dock2`. `make app` copies in the first-party plugins — not the demo (§11) — and the Now Playing helper, and signs the
  helper before the bundle, since notarization wants every Mach-O signed.
- **The icon is `Resources/dock2.icon`**, an Icon Composer document that `make app` compiles with actool into
  `Assets.car` and `dock2.icns`. actool is in Xcode only, so a Command Line Tools build has no icon. The
  document is written by `Resources/icon.py` (`make icon-source`, uv), which fits Inter's 2 to the Dock's
  proportions (§1) and fetches the font at a fixed commit. `ictool`, inside Icon Composer.app, renders the
  document in every appearance without a build; `xcrun ictool` is another tool, of actool's.
- **The plates are `Resources/Plates`** (`IconPlate`, §5): Icon Composer's plate for an empty icon, filled
  black and filled white, 512 px, which `Resources/plates.py` renders with that `ictool` (`make
  plates-source`, uv). Xcode alone has it, so the PNGs are committed. `make build` copies them beside the
  executable (`.build/plates`), `make app` into `Resources/Plates`. `ictool` writes Display P3, and tags a
  render holding only neutrals sRGB.
- **Two Rust static libraries**, the engine (`make engine`, `Engine/`) and the calculator (`make calc`,
  `Calculator/`), each an XCFramework that `Package.swift` names as a binary target. The calculator's headers
  sit in `include/DockCalc/`, since SwiftPM copies every XCFramework's headers into one folder and two module
  maps at its top collide. Both are built with LTO, which leaves only their C functions and two identical
  symbols of std's external, so the two link into one binary.
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

- On Tahoe a backdrop's hit area is a rectangle around its shapes (§3), so a rounded corner or the gap between the platter and
  the puck takes a click macOS 27 would pass, and for the length of a motion so does the whole of its way.
- Tahoe runs without 22 of the 93 private names (26.6.2): the rim's halo, `sourceSublayerDefinesBounds`, and
  `glassBackground`'s `MaxLuma` caps, in-filter highlight, ring shadow and blur fill. No recipe is fitted to it, every
  number in `GlassRecipe` having come off macOS 27, and no other 26.x has been audited. Without its cap the dark platter
  takes white behind it to 199 of 255 where macOS 27 gives 179 in the same VM; light glass, and dark over black, match.
- With auto-hide off, dock2 covers the bottom of windows that reach the screen's edge, since nothing public
  reserves screen space.
- Bottom orientation only, magnification off, the main display only.
- The system Dock's rule for shrinking its tiles was measured on this Mac's 1800pt-wide screen alone, asking for
  tile sizes 128, 112 and 96; it held to a hundredth of a point at every count from 12 tiles to 39. The puck's
  bud, its corners and the fitting at 192 and 256 were seen on the glass; a launching sidelined app's hop was
  not, nor the onboarding preview, which fits its tiles to its own bounds.
- Reduce Transparency's fill and Increase Contrast's border are the shapes' union as one path, which cannot
  interpolate from one subpath to two: the puck's outline grows where it ends rather than budding with the glass.
- Snow Leopard's shelf was measured from one screenshot at one tile size: it scales in proportion, and its
  label and badges are the glass's. Its icons are the apps' own, whose art fills 80% of the tile where Snow
  Leopard's filled 86–96%. Its floor reflects by depth alone, where Leopard's floor picture suggests the dark
  side of its S reflected more. Its mirror's colour space following the window to another screen is untried.
- No Trash, folders or stacks on the dock. No app's progress: the system Dock's `AXProgressValue` is unread.
- The Finder tile's own icon is drawn in the Default style only: which of Dark, Clear and Tinted the system
  shows is read from nowhere yet. Its picker was seen in the Settings window and its fill pressed through
  Accessibility; no driven run has clicked a picture or the colour well.
- A minimised window's picture is taken as its genie ends, where the system Dock's is taken as it starts, the
  window still active: dock2's shows its buttons grey. Granting Screen Recording while dock2 runs, and running
  without it, are unseen: this session's terminal holds the grant the debug build inherits. Badges and windows
  were measured in the dark appearance only, and a label too long for the icon is truncated by dock2's own
  rule. Windows on another Space when dock2 starts are missing from their app's menu until they change.
- Files: the locks were seen without the grant itself in the built app, launched as its own privacy identity,
  with the user's choice "declined"; the ask's other answers — Full Disk Access granted, the three folders
  allowed — were seen through `DOCK2_FULL_DISK_ACCESS=off`. A move across volumes is tested on a RAM disk when `DOCK2_SECOND_VOLUME` names a folder on one; a
  file dragged from Finder and held over Finder's tile, the dock revealed mid-drag, opened Files.
- Servers: SMB alone, the one file system this Mac had a server of; NFS has a plugin of the same interface,
  unlisted. Seen against one Synology already connected: a server not connected — its guest listing, Not
  Connected, a first sign-in — and one that does not answer were not; nor a server with a space in its name.
  Local Network was never asked: the debug build browses and mounts as the terminal it runs from.
- The calculator answers no currency: fend asks its host for exchange rates, and dock2 gives none. Its row
  was not measured against Spotlight's answer.
- Plugins: Bitwarden's sign-in against its own servers is untried, the flow tested against answers sealed
  with real keys instead; plugin commands have no shortcuts of their own. No XPC service signed by a real team
  was reached, nor a daemon's: the requirement's passing case is `codesign -R` against a Developer ID app. A
  streamed HTTPS answer and a `wss` WebSocket were tested through their delegates against plain loopback
  servers, and `local-network` against the loopback and a Unix socket: no LAN device, and no Local Network
  prompt, which the debug build never raises, running as its terminal.
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
