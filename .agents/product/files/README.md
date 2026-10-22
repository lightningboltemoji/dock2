# Files

dock2's file browser: a view in the panel that stands in for the Finder window. It comes and goes with the
dock, keeps its place while dock2 runs, and never leaves a window on the desktop.

## Ways in

- **The Finder tile.** A click opens Files; ⌥-click opens Finder itself. The tile keeps Finder's icon, and
  its label says Files.
- **A path in the field.** A query that starts with `~` or `/` is a path, and the panel becomes Files there.
- **"Show in Finder" from any app**, once the user has let dock2 take it over
  ([takeovers](../system/takeovers.md)): dock2 summons itself into Files with the items selected, and the
  app that asked stays in front.
- **Show in Files** (⌘↩) on a file or an app in search, and "Show all…" on the Files section, which lists
  the results in Files.

## Layout

```
   ╭───────────────────────────────────────────────────────────────────╮
   │  bario         › │  .agents         › │      ╭──────────────╮     │
   │ ▸dock2         › │ ▸Package.swift     │      │   preview    │     │
   │  fiber         › │  README.md         │      ╰──────────────╯     │
   │                  │  Sources         › │       Package.swift       │
   │                  │                    │      Swift · 1.8 KB       │
   │                  │                    │  Created   Oct 1, 9:14    │
   │ ───────────────────────────────────────────────────────────────── │
   │ ⌂ Home ⌃⌄ › Developer › dock2 › Package.swift (dock2)(Downloads) +│
   ╰───────────────────────────────────────────────────────────────────╯
```

Everything sits inset from the glass's edge, so nothing crowds its rounded corners, and nothing in it
appears before the glass has grown to hold it.

- **Columns**, as in Finder's column view: each folder's contents in a column, the selected folder opening
  in the next, the columns scrolling sideways to keep the current one in view. Folders come first, then
  names in Finder's order — numbers by value, case ignored. No scroller sits over the rows: a column
  scrolled out of sight shows as a fade at the left edge, and the path says where you are.
- **The preview column**, for a selected file: its Quick Look preview, its name, kind and size, then its
  dates beneath a rule, as Finder's preview lays them out; for a folder, how many items it holds. Space
  fills the view with the preview.
- **The path bar** is the field: the current folder as a breadcrumb. A click on a folder goes there. The
  first one is a pop-up of the places — Home, Desktop, Documents, Downloads, Applications, iCloud Drive,
  each with Finder's key; each mounted volume; Go to Folder… — the one you are in checked. A path too long
  to show whole folds its middle into "…", a menu of what it hides. There is no sidebar: the places are a
  click away and take no room the rest of the time. Typed letters jump within the current column, as in
  Finder; `~` or `/` starts a path instead, Tab completes it, and ↩ goes there.

## Tabs

Tabs are for copying between places: `~/Desktop/some/folder` in one, `~/Downloads` in the other.

- With one tab, the bar's end holds only New Tab (+, or ⌘T), which opens one at Home beside the current
  one. From two, every tab is a pill there — its folder's icon and name, the one showing tinted. Six at most: the bar has room for six pills and the path.
- A click shows a tab; ⌃⇥ and ⌃⇧⇥ (or ⇧⌘] and ⇧⌘[) step through them; ⌘W closes the one showing, and
  the close button that replaces a pill's icon under the pointer closes that one.
- Items dropped on a pill land in its folder; a drag held over a pill shows its tab, to drop deeper. ⌘K on
  a selection offers Copy to and Move to each other tab's folder.

## Size

Files has a size of its own, wider than search's, so that three columns and the preview fit (**Open:**
960 × 520 pt, judged against the dock in a prototype). It grows out of the field like every view.

## Where it opens

Where it was, for as long as dock2 runs: both tabs, their folders, their selections. After dock2 starts it
opens at Home, with one tab. ⇧⌘H goes Home at any time.

## Drag and drop

- **Out**: a selection dragged from Files into any app — a mail, a browser's upload, an editor — goes as
  files. dock2 stays up while the drag is in flight.
- **In**: files dragged from any app into a column, onto a folder in the path bar, or onto a tab's pill
  land there. Within one volume a drop moves and ⌥ makes it a copy; across volumes it copies and
  ⌘ makes it a move, as in Finder.
- **Spring-loading**: holding a drag over a folder opens it; holding it over the Finder tile opens Files.

## Search inside

⌘F turns the path bar into a search of the current folder and the folders inside it — the Files source,
scoped ([file search](../search/files.md)) — with the results as a list beside the preview. Esc goes back
to the columns.

## Actions

⌘K, or a right-click, lists what can be done: Open, Open With, Quick Look, Rename, Duplicate, Copy, Copy
Path, Copy Contents, Copy to and Move to each other tab, Move to Trash, New Folder and Open in Finder.

- **⌘K** acts on the selection.
- **A right-click** on an item acts on the selection when the item is part of it, and on that item alone
  otherwise — ringed while the menu is open, the selection left as it was. Between items it acts on that
  column's folder: New Folder, Open in Finder.
- **Open With** lists the apps Finder does: the default first, then the rest by name. Below them, "Remember
  for" pills — This File and All .png — change the default as the app is picked: for the file alone, or for
  every file with its extension, which macOS confirms itself. Neither is lit when the menu opens; the arrows
  reach them and ↩ lights one. A file with an app of its own lists it as "(this file)".
- **Copy Contents** is there for a single file that is text or a picture ([operations](operations.md#the-clipboard)).

## What stays Finder's

Finder keeps running: the desktop and its icons, emptying the Trash, Get Info, the AirDrop and Network
windows. A folder that another app *opens*, rather than reveals, opens in Finder, since macOS lets no other
app handle folders. ⌘K → Open in Finder is always there.

The keys are in [keyboard](../keyboard.md); copying, moving and deleting are in
[operations](operations.md); what Files needs from macOS's privacy rules is in [access](access.md).
