# Roadmap

The MVP's order of work, then what comes after it. Each step ends when it is built and measured, not on a
date.

## The MVP

1. **Dock parity.** Finder, pinned and running tiles, separators; the tile menu; dragging to reorder, pin
   and unpin; dropping files on tiles. dock2's own settings, copied from the system Dock at the first
   launch; its own auto-hide, with the reveal and hide measured off the system Dock.
2. **Settings and the first launch.** The Settings window, General and Dock first; the first-launch
   sequence ([onboarding](onboarding.md)).
3. **The keyboard.** Reveal-to-type, with the dwell and the typing guard; the field; the ring; ⌘1–9 and
   number badges; the ⌘space takeover, in the journal and the guard, tested on the crash path.
4. **Search.** The app catalog, the commands, the Files source and its folder grants; sections, the top
   hit, the stability rules, learned picks; the echo and temporary tiles; actions.
5. **Files.** The browser, its path bar and its two tabs; the operations, with conflicts, progress and undo;
   file access; the "Show in Finder" takeover, in the journal and the guard.
6. **Clipboard history.** Capture, the encrypted store, the view, pasting with Accessibility.
7. **Plugins.** The runtime, the components, tiles, the capabilities; Now Playing and Bitwarden built on
   them.
8. **Release.** Signing and notarization, a pass with VoiceOver, every measurement taken again on the
   release's macOS.

## Next

### ⌘⇥ on the dock

The app switcher becomes the dock, on the ⌘space takeover's machinery (hot key entries 1 and 2):

- **A quick ⌘⇥**, released at once, switches to the previous app and draws nothing — the system switcher's
  habit, kept.
- **Holding ⌘** reveals the dock with the ring on the previous app's tile. Each ⇥ moves the ring to the next
  app in recency order, wherever its tile sits, and the label names it; ⇧⇥ goes back; releasing ⌘
  switches. The ring jumps about the dock rather than walking it, so the switcher teaches where each app
  lives.
- **While ⌘ is held**, a digit picks tile 1–9 directly, and Q quits and H hides the ringed app, as in the
  system switcher.
- **↑ while ⌘ is held** lists the ringed app's windows in the panel above it; releasing ⌘ raises the chosen
  one. The system switcher has no answer to this, and it needs Accessibility.

With the system's entries off, the chord reaches dock2 alone, and ⌘'s release arrives in dock2's panel
because the panel has the keyboard: no Input Monitoring. **Open:** whether recency order on a spatial dock
reads well; a prototype decides.

### Windows

With Accessibility: an app's windows as results ("safari github" finds the window); ↑ on a tile lists its
windows first; minimised windows on their app's tile; ⌘` replaced by the same list.

### And

- Multiple displays: the dock on the display whose bottom edge the pointer pushes.
- The ⌥⌘D and ⌃F3 takeovers, and ⌥⌘space for Files ([takeovers](system/takeovers.md)).
- App badges and progress, read from the hidden system Dock.
- Trash, folders and stacks on the dock.
- Revealing by pointer over full-screen apps.
- A plugin registry, signed packages and updates; the TypeScript SDK; `dock2 plugin dev`.

## Later

Magnification; the left and right edges; a calculator, unit conversion and the dictionary; System Settings
panes and system actions as commands; searching inside documents; Contacts and Calendars as sources; a web
search only when asked for; window thumbnails; and in Files, Compress, tags, renaming many at once, and
operations that need an administrator.
