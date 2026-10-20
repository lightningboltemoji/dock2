# dock2 — Implementation

The _what_, the _why_ and the _how_ of dock2 as it is now. The investigation, the rejected alternatives and
the numbers that settled an argument live in `changes/<id>.md`.

---

## 1. The charter

- **It looks like the Dock, measured, not remembered.** Every number in `Dock2Core` and in `GlassRecipe`
  came off this macOS's own Dock — Accessibility frames, screenshots, pixel profiles — and the tests pin the
  geometry to those measurements. A change to the look is validated the same way, against the real thing.
- **The user's Dock is never stranded.** dock2 replaces the system Dock by changing its preferences, which
  outlive dock2. Whatever happens to dock2 — quit, signal, crash, SIGKILL, power loss — there is a path that
  puts the user's own settings back (§4), and no path that loses them.
- **Private API on stated terms.** The glass uses private Core Animation classes because no public API
  draws the Dock's material (§3). It is reached by name at runtime, confined to `Glass/`, and degrades to
  `NSGlassEffectView` when missing. Nothing that decides correctness depends on it.

---

## 2. Modules

```
Dock2Core    pure — DockMetrics, DockLayout, LabelMetrics, DockItem, the suppression journal.
    ▲        Foundation and CoreGraphics' geometry types only; everything here is unit-tested.
Dock2Shell   imperative — the panels and views, the glass, the system Dock's preferences, the guard.
    ▲
dock2        executable — the app, `--restore`, and the guard (`--guard <pid>`): one binary.
```

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
circular capsule plus a rounded square turned 45°. SDF layers keep `contentsScale` 1; the rim heights were
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

---

## 4. The system Dock

### Suppression

The Dock reads its preferences when it starts, so `Suppressor.suppress()` writes `autohide = true` and
`autohide-delay = 1000` to `com.apple.dock` and restarts the Dock (SIGTERM; launchd relaunches it). The keys
are written only if they differ, and the Dock restarted only if something changed. A value is cleared before
it is set: cfprefsd skips a write `CFEqual` calls equal, and `95` equals `95.0`.

### The journal

Before touching a key, `suppress()` records the user's values for every overridden key in
`~/Library/Application Support/dock2/system-dock.plist` (`SuppressionJournal`; an entry without `value`
means the key was unset). **The journal is the only record of the user's settings.** A launch that finds
one keeps it — the keys by then hold dock2's values — and an unreadable one is replaced by
`SuppressionJournal.recovered`, which treats a key still holding dock2's value as unset. `restore()` writes
the journal's values back (removing keys that were unset), restarts the Dock if anything changed, and
deletes the journal.

### Ownership: the instance lock

`InstanceLock` is a `flock` on `dock2.lock` beside the journal, close-on-exec. Whoever holds it owns the
journal: a running dock2 for its whole life, `dock2 --restore` while it runs, or the guard while it
restores. A second dock2 waits two seconds for it, then exits.

### The guard

Before suppressing, dock2 starts `dock2 --guard <pid>`: the same executable, in its own session
(`POSIX_SPAWN_SETSID`, so a terminal's Ctrl-C reaches dock2 alone), inheriting no descriptors but stdio and
a readiness pipe. It ignores SIGINT, SIGHUP and SIGTERM, waits on a kqueue for dock2's exit — which reports
every kind of exit, SIGKILL included — then takes the lock without waiting and restores if the journal is
still there. If a new dock2 already holds the lock, the journal is that one's and the guard leaves. dock2
watches the guard and starts another if it dies, at most five times a minute.

### The paths back

| What happens to dock2                  | What restores the Dock                          |
| -------------------------------------- | ----------------------------------------------- |
| Quit (menu), SIGINT, SIGTERM, SIGHUP   | dock2 itself, in `applicationWillTerminate`     |
| crash, SIGKILL                         | the guard                                       |
| dock2 and the guard both killed, power loss | the next launch keeps the journal and restores on quit; or `dock2 --restore` |

---

## 5. The Dock itself

`DockController` owns the lifecycle and turns AppKit's notifications into calls on `DockView`. The panel is a
borderless, non-activating `NSPanel` at the Dock's window level, on every Space but not full screen ones,
never key. Its frame spans the platter plus room above for a launch hop. The label is a separate panel one
level up, ignoring the mouse.

Tiles come from `DockItem.pinned` (or `DOCK2_ITEMS`, comma-separated bundle identifiers, for development).
A click opens the app with `NSWorkspace.openApplication`, which launches it or brings it forward and reopens
a window. An app starting — from dock2 or anywhere — hops until it finishes launching; the dot follows
`NSWorkspace`'s launch and terminate notifications. Icons are rendered from `NSWorkspace` at the tile's
size: an `NSWorkspace` icon reports 32pt, and rasterised at that size it would be stretched.

---

## 6. Not yet

- dock2 never hides; it does not mirror the user's auto-hide, and it covers the bottom of windows that reach
  the screen's edge, since nothing public reserves screen space.
- Bottom orientation only, magnification off, the main display only.
- Hovering and clicking only: no drag, no context menus per app, no Finder, Trash or separator.
- The launch hop's height and timing are not measured.
- Dark mode was measured on an SDR display; on an HDR one `MaxLuma`, not `MaxLumaSDR`, applies, and it is
  set to the same value as AppKit's own dark recipes do, unverified.
- The Dock can still be brought back from under dock2 by turning auto-hide off (⌥⌘D, System Settings).
