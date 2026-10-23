# Takeovers

A takeover is a system behaviour dock2 switches off or changes while it runs. Every one follows the rule the
system Dock's suppression set (`IMPLEMENTATION.md` §4): the user's own state is journaled before anything
changes; dock2 gives it back when it quits; the guard gives it back if dock2 crashes or is killed; the next
launch, or `dock2 --restore`, gives it back if both died. Each give-back is checked; one the system did not
take stays journaled and is tried again by the next of these.

## The takeovers

| Takeover | Through | When | |
| --- | --- | --- | --- |
| **The system Dock** | `com.apple.dock`: auto-hide on, a reveal delay of 1000.0625 s, minimised windows as items of their own, a restart | while dock2 runs | built |
| **Spotlight's shortcut**, ⌘space | the window server's live table of system hot keys (SkyLight, private): entry 64 | the user chose ⌘space | MVP |
| **"Show in Finder"** | the global `NSFileViewer` default, naming dock2 | the user chose it | MVP |
| **⌘⇥ and ⌘⇧⇥** | the same table: entries 1 and 2 | the user chose dock2's switcher | _Next_ |
| **⌥⌘D**, Dock hiding | the same table, entry 52, redirected to dock2's auto-hide | while dock2 runs | _Next_ |
| **⌃F3**, focus the Dock | the same table, entry 8, redirected to summoning with the ring | while dock2 runs | _Next_ |
| **⌥⌘space**, Finder's search window | the same table, entry 65, redirected to Files | with Files | _Next_ |

## The hot key table

Switching an entry off is live and session-wide — every process sees it at once — and writes no preference,
so System Settings still shows the user's own shortcut. It also outlives the process that switched it off:
after a `kill -9`, Spotlight's shortcut stays dead. That is why it goes through the journal and the guard, as
the Dock's keys do. With the entry off, dock2 registers the chord itself (`RegisterEventHotKey`) and is the
only one to receive it.

Whether the table resets at logout is unverified; the journal makes it not matter.

## Show in Finder

With `NSFileViewer` naming dock2, the system's reveal — AppKit's "Show in Finder" calls and `open -R` —
launches dock2 if it is not running and hands it the items as an open-documents event, and Finder draws
nothing. dock2 shows them selected in Files ([files](../files/README.md)). The key is normally absent, so
giving it back removes it.

It covers revealing, not opening: a folder another app opens, `open <folder>`, and a folder double-clicked
on the desktop still go to Finder, since macOS lets no app but Finder handle folders. A Finder window that
appears anyway does not say through Accessibility which folder it shows, so dock2 leaves it be.

dock2's own "Show in Finder" means Finder. While dock2 holds the takeover a reveal would come back to
Files, so it opens the item's folder in Finder instead, with the item not selected.

## Rules

- **What comes back is the user's prior state.** A shortcut that was off before dock2 stays off after it.
- **A takeover the user would notice is asked for.** ⌘space and ⌘⇥ are offered, never assumed.
- **dock2 never writes the user's shortcut preferences.** System Settings stays the record of what the user
  chose.
- **Every takeover is tested on the crash path** (`kill -9`) when it is added or changed, as the Dock's is.

## Known gaps

- The system Dock can still be brought back from under dock2 by switching its auto-hide off in System
  Settings (`IMPLEMENTATION.md` §6).
- **Open:** whether ⌃F3 and ⌥⌘D reach the hidden system Dock until they are taken over.
- Minimised windows still go into the hidden system Dock — the genie ends there, out of sight — and dock2
  draws them itself, read off its items through Accessibility ([dock](../dock.md#tiles)). So the hidden
  Dock's "Minimize windows into application icon" is held off, or it would have no items to read; dock2's
  own setting, copied from it at the first launch, decides where they show.
- With auto-hide off, windows can sit under the dock ([dock](../dock.md)).
