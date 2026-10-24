# dock2 — Product

What dock2 is for and how it behaves, as designed. How it is built, and how much of this already is, is
`../IMPLEMENTATION.md`'s to say.

---

## The idea

macOS splits one job — get me to the thing — across three tools. The **Dock** launches apps and shows what
is running. **Spotlight** finds apps and files by name. **⌘⇥** switches between running apps. Each knows
part of the picture: Spotlight cannot tell an open app from a closed one, ⌘⇥ knows nothing that is not
running, and the Dock knows only what is pinned or running. A fourth, **Finder**, opens a window to fetch
one file and leaves it floating on the desktop.

The Dock is also the one the keyboard barely reaches: ⌃F3 gives it focus, and the arrow keys walk its tiles
one at a time. Spotlight, the keyboard's way in, is noisy: three letters of "Safari" bring back the app, a
bookmark, and five System Settings entries, one of them twice.

dock2 is one surface for all of it: a dock that looks and behaves like the Dock; a search field that grows
out of it the moment you type; a file browser in the same place; and plugins that put their own content in
all three.

## Principles

1. **The dock is where apps are.** An app found by search is shown on the dock, at its tile, as well as in
   the list. Spatial memory is the one advantage nothing else on the Mac has.
2. **Nothing floats.** What dock2 shows lives on the dock or in the panel above it, and comes and goes with
   them. Settings is the one window dock2 leaves on the desktop. A feature dock2 offers is done there too,
   never by opening a Finder window for it, such as Get Info; a confirmation macOS draws itself is allowed.
3. **Keyboard first, mouse unchanged.** Everything has a key. The mouse does what it does on the Dock.
4. **Results hold still.** The same query gives the same order. Nothing moves under the selection; a result
   that arrives late goes to the far end of its section.
5. **Nothing waits for the slowest source.** The first results are drawn within one budget; slower sources
   add to the list and never reorder it.
6. **It looks like macOS, measured.** The dock is the Dock's geometry and glass, taken off the real one;
   every new surface starts from the system's nearest ([visual](visual.md)).
7. **The Mac is never left changed.** Every system behaviour dock2 takes over is journaled and given back,
   whatever happens to dock2 ([takeovers](system/takeovers.md)).
8. **No permission before its feature.** The core asks for nothing. A feature that needs a permission asks
   when it is offered or first used, says why, and still works, in a lesser way, without it
   ([permissions](system/permissions.md)).
9. **Plugins are guests.** They draw nothing themselves, reach nothing they were not granted, and cannot
   slow dock2 down ([plugins](plugins/README.md)).

## At a glance

```
            ╭─────────────────────────────────────╮
            │  each plugin's results              │
            │  Files                              │   sections, in a fixed order
            │  Clipboard                          │
            │  Commands                           │
            │  Apps                               │
            │ ▸top hit                            │   selected, nearest the field
            ├─────────────────────────────────────┤
            │  sa▏                                │   the field: it never moves
            ╰─────────────────────────────────────╯
   ╭───────────────────────────────────────────────────────╮
   │  Finder   pinned … (Safari) …   running apps …        │   the dock: the selected app
   ╰───────────────────────────────────────────────────────╯   wears the ring
```

- **Resting**, the dock is on screen or, under auto-hide, off it, and dock2 does not have the keyboard.
- **Reveal** the dock with the pointer, or **summon** it with ⌘space: dock2 takes the keyboard and the field
  rises over the dock. Typing goes to dock2; the app in front stays in front.
- **Type**, and results grow upward from the field. An app among them lights up on the dock.
- **↩** opens the selection, **Esc** steps back, and **⌘1–⌘9** open the first nine tiles whenever dock2 has
  the keyboard.
- **Views** — the clipboard history, a plugin's screen — open in the same panel, at a fixed size.
- **Files** — the Finder tile, a path typed in the field, "Show in Finder" in any app — is the same panel,
  grown into a column browser with tabs.

## Scope

Everything here is the MVP unless marked _Next_ (designed, for after the MVP) or _Later_ (a direction, not
yet a design). **Open:** marks a decision waiting on a prototype or a measurement; the value it names is
what to build until then.

**The MVP** is the dock at parity with the Dock's everyday behaviour, with its own auto-hide and a Settings
window; reveal-to-type and ⌘space; search over apps, commands, files, the clipboard and plugins, and a
calculator; clipboard history; Files, a column browser that stands in for Finder's windows; and plugins, Now Playing and
Bitwarden first. The order of work, and what comes after, is [roadmap](roadmap.md).

## Files

| File | Contents |
| --- | --- |
| [glossary](glossary.md) | the words these files use |
| [interaction](interaction.md) | the states, and how dock2 takes the keyboard and gives it back |
| [keyboard](keyboard.md) | every key, in every state |
| [dock](dock.md) | tiles, the pointer, auto-hide, what dock2 adds to the Dock |
| [panel](panel.md) | the field and what grows from it: sizes, geometry, layout, motion |
| [search](search/README.md) | sources, order, stability, learned picks, actions, commands |
| [search/apps](search/apps.md) | the app catalog |
| [search/files](search/files.md) | file search, from the Spotlight index |
| [clipboard](clipboard.md) | clipboard history |
| [files](files/README.md) | the file browser: ways in, columns, the path bar, tabs |
| [files/operations](files/operations.md) | copying, moving, deleting: the clipboard, conflicts, progress, undo |
| [files/access](files/access.md) | Full Disk Access, the three folders, locked places |
| [files/icon](files/icon.md) | the Finder tile's own icon: Cairo's pictures, as Liquid Glass, on any colour |
| [settings](settings.md) | dock2's own settings, and the window that edits them |
| [control](control.md) | what other tools can ask a running dock2, and what only a debugging one answers |
| [onboarding](onboarding.md) | the first launch |
| [visual](visual.md) | where every number comes from; the glass; dock2's own marks; motion |
| [plugins](plugins/README.md) | what a plugin can add, and how it fits |
| [plugins/views](plugins/views.md) | the components plugins build UI from |
| [plugins/runtime](plugins/runtime.md) | events in, effects out, within budgets; engine, interface, languages |
| [plugins/permissions](plugins/permissions.md) | capabilities, grants, and what a plugin can never do |
| [plugins/packaging](plugins/packaging.md) | the manifest, installing, removing |
| [plugins/first-party](plugins/first-party.md) | Now Playing and Bitwarden |
| [system/takeovers](system/takeovers.md) | what dock2 switches off while it runs, and how it is given back |
| [system/permissions](system/permissions.md) | the macOS permission each feature needs |
| [system/platform](system/platform.md) | macOS versions, displays, Spaces, full screen, VoiceOver |
| [roadmap](roadmap.md) | the MVP's order of work; _Next_, including ⌘⇥; _Later_ |
