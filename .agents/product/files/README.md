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
   ╭───────────────────────────────────────────────────────────────╮
   │  bario         › │  .agents         › │  ╭──────────────────╮ │
   │ ▸dock2         › │ ▸Package.swift     │  │ Package.swift    │ │
   │  fiber         › │  README.md         │  │ Swift · 1.8 KB   │ │
   │                  │  Sources         › │  ╰──────────────────╯ │
   ├───────────────────────────────────────────────────────────────┤
   │ ~ › Developer › dock2 › Package.swift▏          ⇥ ~/Downloads │
   ╰───────────────────────────────────────────────────────────────╯
```

- **Columns**, as in Finder's column view: each folder's contents in a column, the selected folder opening
  in the next, the columns scrolling sideways to keep the current one in view. Folders come first, then
  names in Finder's order — numbers by value, case ignored.
- **The preview column**, for a selected file: its Quick Look preview, its kind, size and dates; for a
  folder, how many items it holds. Space fills the view with the preview.
- **The path bar** is the field: the current folder as segments. A click on a segment goes there. The first
  segment's menu lists the places — Home, Desktop, Documents, Downloads, Applications, iCloud Drive, each
  mounted volume. Typed letters jump within the current column, as in Finder; `~` or `/` starts a path
  instead, Tab completes it, and ↩ goes there.
- **Two tabs**, and no more. The other tab is the chip at the path bar's end, naming its folder; ⌘T opens
  it and ⌃⇥ switches. There is no tab strip and no third tab: two places to copy between is the point.

## Size

Files has a size of its own, wider than search's, so that three columns and the preview fit (**Open:**
960 × 520 pt, judged against the dock in a prototype). It grows out of the field like every view.

## Where it opens

Where it was, for as long as dock2 runs: both tabs, their folders, their selections. After dock2 starts it
opens at Home, with one tab. ⇧⌘H goes Home at any time.

## Drag and drop

- **Out**: a selection dragged from Files into any app — a mail, a browser's upload, an editor — goes as
  files. dock2 stays up while the drag is in flight.
- **In**: files dragged from any app into a column, onto a segment of the path bar, or onto the other
  tab's chip land there. Within one volume a drop moves and ⌥ makes it a copy; across volumes it copies and
  ⌘ makes it a move, as in Finder.
- **Spring-loading**: holding a drag over a folder opens it; holding it over the Finder tile opens Files.

## Search inside

⌘F turns the path bar into a search of the current folder and the folders inside it — the Files source,
scoped ([file search](../search/files.md)) — with the results as a list beside the preview. Esc goes back
to the columns.

## What stays Finder's

Finder keeps running: the desktop and its icons, emptying the Trash, Get Info, the AirDrop and Network
windows. A folder that another app *opens*, rather than reveals, opens in Finder, since macOS lets no other
app handle folders. ⌘K → Open in Finder is always there.

The keys are in [keyboard](../keyboard.md); copying, moving and deleting are in
[operations](operations.md); what Files needs from macOS's privacy rules is in [access](access.md).
