# Apps

The Apps source answers from a catalog dock2 keeps, not from the Spotlight index. The index lists hundreds
of helper apps inside the system and every app a build leaves in the home folder; the catalog is exact, and
in memory.

## The catalog

- `/Applications` and `/Applications/Utilities`; `/System/Applications` and its `Utilities`;
  `/System/Library/CoreServices/Applications` (Keychain Access, Archive Utility, Ticket Viewer…); Finder;
  `~/Applications`.
- Any app that runs, wherever it lives, joins the catalog when it does.
- The folders are watched: an app installed or removed is in or out of results at once.
- Apps inside other bundles — helpers, login items — are left out.

An app answers to its localised display name and to its bundle name. _Later_: aliases the user sets.

## Ranking

After how it matched: running apps first, then the apps dock2 has opened most and most recently, then the
system's own use counts (`kMDItemUseCount`, `kMDItemUsedDates`) as the tiebreak.

## Running apps

The regular apps `NSWorkspace` reports. A running app's row says so, and its tile — pinned, running or
temporary — wears the echo when it is selected.

## Actions

Open (↩) launches the app, or brings it forward and reopens a window, as a click on its tile does. Show in
Files (⌘↩). In ⌘K: Keep in Dock or Remove from Dock; Hide and Quit, if it is running; Force Quit, with ⌥.

_Next_: its windows, as results of their own and first under its tile's ↑ ([roadmap](../roadmap.md)).
