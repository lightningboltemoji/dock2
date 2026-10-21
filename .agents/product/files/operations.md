# Operations

What Files does to files, and how it keeps out of the way while it does it.

## The clipboard

- **⌘C** copies the selection as files: any app can paste them — Finder, Mail, a chat.
- **⌘V** pastes files copied anywhere into the current folder, as copies.
- **⌘⇧V**, or Finder's **⌥⌘V**, moves them here instead.
- Clipboard history keeps copied files, as references ([clipboard](../clipboard.md)).

## The operations

| Operation | Keys | |
| --- | --- | --- |
| copy | ⌘C then ⌘V; a drag, with ⌥ on one volume | on one APFS volume, a clone: instant, and taking no space until one of the copies changes |
| move | ⌘C then ⌘⇧V; a drag, with ⌘ across volumes | on one volume, a rename and instant; across volumes, a copy, the original removed once the copy is whole |
| duplicate | ⌘D | named as Finder names a copy |
| new folder | ⇧⌘N | made with its name ready to type |
| rename | ⌘K → Rename; a click on a selected name | |
| move to Trash | ⌘⌫ | the system's Trash. **Open:** whether Finder's Put Back works for what dock2 trashes |
| delete at once | ⌥⌘⌫ | after a confirmation |
| eject | ⌘E | a volume |

_Later_: Compress; tags; renaming many at once; operations that need an administrator's password — until
then Files says so, and offers Open in Finder.

## Conflicts

A name that already exists asks inline, in the panel — Replace, Keep Both or Skip, with "for all" when more
are coming — never in a window of its own. Keep Both numbers the newcomer, as Finder does. What Replace puts
aside goes to the Trash, so undo brings it back. A copy into the folder it is in is a duplicate.

## Progress

An operation that takes longer than a moment shows as a row at the top of the view, and as a ring on a
tab's pill when that tab's folder is where it is going. It carries on when dock2 is dismissed, and the Finder tile
shows its progress meanwhile. ⌘. or the row's button cancels it; a cancelled copy leaves nothing half-made.

## Undo

⌘Z undoes the last operation and ⇧⌘Z redoes it — a copy removed, a move moved back, a rename reverted, a
trashed item put back, an empty new folder removed — for as long as dock2 runs.

## Errors

A file that cannot be read, written or found says so on its row, in words, with what to do about it: allow
access ([access](access.md)), or open it in Finder.
