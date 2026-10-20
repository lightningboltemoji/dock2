# Keyboard

Every key, in every state ([interaction](interaction.md)). dock2 sees keys only while it has the keyboard —
no event tap, no Input Monitoring — so nothing is global but the shortcuts in the first table.

## Global

| Keys | Does |
| --- | --- |
| ⌘space | Summons dock2, or dismisses it. Taken over from Spotlight when the user agrees ([takeovers](system/takeovers.md)); otherwise a shortcut the user picks, or none. |
| one the user sets | Opens the clipboard history ([clipboard](clipboard.md)). None by default. |

A global shortcut is a system hot key (`RegisterEventHotKey`): it needs no permission, and it takes its
chord away from every app. So none is ever a chord that types something: ⌥ and a digit types `[ ] | { }` or
`#` on many layouts, and ⌥ with a letter starts an accent.

## Whenever dock2 has the keyboard

| Keys | Does |
| --- | --- |
| ⌘1 – ⌘9 | Opens tile 1–9, counted from the left. The same in every state, so it is learned once. |
| ⌘ held alone | After 0.3 s, number badges on tiles 1–9, until ⌘ is released. |
| ⌘K | The actions for the selection: the ringed tile, or the selected result. |
| ⌘, | Settings. |
| ⌘W | Dismisses. |
| Esc | Steps back: a view to search, a query to an empty field, an empty field to dismissed. |

⌘Q quits nothing. The app in front still looks focused, and a ⌘Q meant for it must not quit the dock.

## Empty field

| Keys | Does |
| --- | --- |
| ← → | Moves the ring along the tiles, starting from the front app's tile. |
| fn← fn→ | The first tile; the last. |
| ↩ | Opens the ringed tile's app, as a click does. |
| ↑ | The ringed tile's actions, as its right-click menu. _Next_: its windows, first. |
| a character | Starts a query with it. |

## Searching

| Keys | Does |
| --- | --- |
| typing | Edits the query, with the usual text keys (⌥⌫, ⌘⌫, ⌘A, ⌘Z). |
| ↑ ↓ | Moves the selection away from the field, and back toward it. |
| ↩ | The selection's primary action. |
| ⌘↩ | Its secondary action. |
| ⌘Y | Quick Look, for a file or an image. |

Digits are text: "1Password" is a query, so a bare digit never selects. While an input method is composing
— Japanese, Chinese, an accent — ↩ and the arrows belong to it.

## Views

| Keys | Does |
| --- | --- |
| ↑ ↓ | Moves the selection in a list; the arrows do, in a grid. |
| ↩, ⌘↩, ⌘K | As in searching. In a form, ⌘↩ submits. |
| typing | Filters, in a view with a list. |
| Tab, ⇧Tab | The next field and the previous one, in a form. |
| Esc | Back where the view came from: search, or dismissed. |

A plugin binds its actions only to shortcuts dock2 has not reserved ([views](plugins/views.md)).

## Files

Finder's keys, wherever Finder has one ([files](files/README.md)).

| Keys | Does |
| --- | --- |
| ↑ ↓ | Moves within a column. |
| ← → | The enclosing folder's column; into the selected folder. |
| ↩, ⌘↓ | Opens: a folder in place, a file in its app — which dismisses dock2. |
| ⌘↑ | The enclosing folder. |
| space | Quick Look, filling the view; space or Esc closes it. |
| letters | Jumps to the first name in the column that starts with them. |
| `~` or `/` | Starts a path in the path bar: Tab completes, ↩ goes there, Esc abandons it. |
| ⇧⌘G | The path bar, to type a path. |
| ⌘C | Copies the selection as files, for any app to paste. |
| ⌘V | Pastes files copied anywhere into this folder, as copies. |
| ⌘⇧V, ⌥⌘V | Moves them here instead. |
| ⌘D | Duplicates the selection. |
| ⇧⌘N | A new folder. |
| ⌘⌫ | Moves the selection to the Trash. |
| ⌥⌘⌫ | Deletes it at once, after a confirmation. |
| ⌘Z, ⇧⌘Z | Undo, redo ([operations](files/operations.md)). |
| ⌘T | Opens the other tab, at Home; with both open, switches to it. |
| ⌃⇥ | Switches between the two tabs. |
| ⌘W | Closes the tab; with only one, dismisses. |
| ⌘F | Searches this folder and the folders inside it. |
| ⇧⌘H, ⇧⌘D, ⇧⌘O, ⌥⌘L, ⇧⌘A | Home, Desktop, Documents, Downloads, Applications. |
| ⇧⌘. | Shows or hides hidden files. |
| ⌘E | Ejects the selected volume. |
| ⌘. | Cancels the running operation. |

Renaming and the rest are in ⌘K. A global shortcut the user sets on one of these keys — ⌘⇧V for the
clipboard history, say — takes it from Files too, and Settings says so when it is set.
