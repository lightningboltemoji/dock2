# Files

dock2's file browser: a view in the panel that stands in for the Finder window. It comes and goes with the
dock, keeps its place while dock2 runs, and never leaves a window on the desktop.

## Ways in

- **The Finder tile.** A click opens Files, and another closes it; ⌥-click opens Finder itself. The tile wears Finder's icon, or one
  the user makes ([icon](icon.md)), and its label says Files.
- **A global shortcut**, if the user sets one ([keyboard](../keyboard.md#global)): the Finder tile chosen from
  anywhere, so it opens Files, and pressed again closes it. None by default.
- **A path in the field.** A query that starts with `~` or `/` is a path, and the panel becomes Files there;
  one that starts `smb://` is a server's address ([servers](#servers)).
- **"Show in Finder" from any app**, once the user has let dock2 take it over
  ([takeovers](../system/takeovers.md)): dock2 summons itself into Files with the items selected, and the
  app that asked stays in front.
- **Show in Files** (⌘↩) on a file or an app in search, and "Show all" on the Files section, which lists
  the results in Files.

There is one Files. Asked for while another view covers it, it comes back to the top and that view closes.

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
   │ ▣ Home › Developer › dock2 › Package.swift    (dock2)(Downloads) +│
   ╰───────────────────────────────────────────────────────────────────╯
```

Everything but the path bar sits on the [pane](../visual.md#glass-on-solid), as Finder's columns sit in
its window, and all of it rides the glass in as it grows ([panel](../panel.md#motion)).

- **Columns**, as in Finder's column view: each folder's contents in a column, the selected folder opening
  in the next, the columns scrolling sideways to keep the current one in view. Folders come first, then
  names in Finder's order — numbers by value, case ignored. No scroller sits over the rows: a column
  scrolled out of sight shows as a fade at the left edge, and the path says where you are. Rows scrolled up or down
  fade before they reach the pane's corners ([layout](../visual.md#layout)), and a folder's column slides out from
  the one that opened it. Nothing waits on a folder: Files opens at once, a large folder fills its column once it is read, saying
  Loading… if that takes a moment, and one that changes keeps showing what it held, selection and all, until the new list is in.
- **The preview column**, for a selected file: its Quick Look preview, a page lying on the pane, its name, kind and
  size, then its dates beneath a rule, as Finder's preview lays them out; for a folder, how many items it holds. Space
  lays the preview over the view, a card clear of the pane's corners.
- **The path bar** is the field, laid out as a search result is: on a plate centred where the magnifier stands, the place
  holding the folder, its colour saying which, with its name beside it; then the folders inside that
  place as a breadcrumb. Plate and name are one control, a pill no taller than the crumbs. A click on it raises a menu
  of the places over the pane — Home, Desktop, Documents, Downloads, Applications, iCloud Drive,
  each on its plate with Finder's key; each disk, and each server you are connected to ([servers](#servers)), with ⏏
  where it ejects; Network; Go to Folder… — the one you are in checked. A click on a folder goes there. A path too long
  to show whole folds its middle into "…", a menu of what it hides. There is no sidebar: the places are a
  click away and take no room the rest of the time. Typed letters jump within the current column, as in
  Finder; `~` or `/` starts a path instead, Tab completes it, and ↩ goes there.
- **⏏** sits on a row that ejects — a disk, a mounted share, a server you are connected to — beside its
  ›, as in Finder's columns. ⌘E ejects the selection, or the volume the folder is on.

## Servers

A file server is one place, as in Finder's sidebar: the shares mounted from it are not places of their own.

- **The places pop-up** lists each server you are connected to, and its ⏏ disconnects it — every share
  mounted from it unmounted. Network follows the disks and servers.
- **A server's column** lists every share it offers you, mounted or not, as Finder's server window does,
  in Finder's order. A mounted share has ⏏. A share not mounted is mounted as it is selected, as in Finder:
  its column says Connecting… until its items come. The path reads `Synology › Media › Movies`, and the
  pop-up checks Synology anywhere inside it.
- **Network** lists the servers the local network announces, as Finder's Network does, and the ones you are
  connected to; a connected one has ⏏. A server not connected lists what it shares with a guest, or says
  Not Connected over Connect As…. `smb://` typed in the field goes to that server, as Connect to Server does.
- **Signing in** is macOS's own: its window asks for a name and password when a server needs them, and
  offers the Keychain. dock2 steps aside for it, and once the share it asked for is mounted Files comes back
  to it. **Connect As…** — in ⌘K on a server or between its shares — asks it for another name.
- **A server that does not answer** in 15 seconds: its column says so, over Try Again. A share that will not
  mount says why in its column, over Try Again.

## Tabs

Tabs are for copying between places: `~/Desktop/some/folder` in one, `~/Downloads` in the other.

- With one tab, the bar's end holds only New Tab (+, or ⌘T), which opens one at Home beside the current
  one. From two, every tab is a pill there — its place's plate and its folder's name, the one showing tinted. Six at most: the bar has room for six pills and the path.
- A click shows a tab; ⌃⇥ and ⌃⇧⇥ (or ⇧⌘] and ⇧⌘[) step through them; ⌘W closes the one showing, and
  the close button that replaces a pill's plate under the pointer closes that one.
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
- **In**: files dragged from any app into a column, onto the place or a folder in the path bar, or onto a tab's pill
  land there. Within one volume a drop moves and ⌥ makes it a copy; across volumes it copies and
  ⌘ makes it a move, as in Finder.
- **Spring-loading**: holding a drag over a folder opens it; holding it over the Finder tile opens Files.

## Search inside

⌘F turns the path bar into a search of the current folder and the folders inside it — the Files source,
scoped ([file search](../search/files.md)) — with the results as a list beside the preview. Esc goes back
to the columns.

## Actions

⌘K, or a right-click, lists what can be done: Open, Open With, Quick Look, Rename, Duplicate, Copy, Copy
Path, Copy Contents, Copy to and Move to each other tab, Move to Trash, Eject, New Folder and Open in Finder;
on a server or between its shares, Connect As… and Disconnect.

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

Finder keeps running: the desktop and its icons, emptying the Trash, Get Info, the AirDrop window. A folder that another app *opens*, rather than reveals, opens in Finder, since macOS lets no other
app handle folders. ⌘K → Open in Finder is always there.

The keys are in [keyboard](../keyboard.md); copying, moving and deleting are in
[operations](operations.md); what Files needs from macOS's privacy rules is in [access](access.md).
