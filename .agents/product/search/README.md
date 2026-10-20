# Search

One field, five kinds of source, and the rules that keep the results still.

## The query

The field's text, trimmed. Matching ignores case and diacritics and works on words: each word of the query
must begin a word of the name, where spaces, punctuation and changes of case divide words — "ss" finds
**S**creen **S**haring, and "vsc" finds **V**isual **S**tudio **C**ode by its initials. Apps and commands
also match a looser subsequence, ranked below every word match.

A query that starts with `~` or `/` is a path, not a search: the panel becomes Files there
([files](../files/README.md)).

## Sources

| Source | Answers from | |
| --- | --- | --- |
| **Apps** | dock2's app catalog, and the running apps | [apps](apps.md) |
| **Commands** | dock2's commands, and the plugins' | below |
| **Clipboard** | the clipboard history | [clipboard](../clipboard.md) |
| **Files** | the Spotlight index | [files](files.md) |
| **Plugins** | each plugin whose results are switched on | [plugins](../plugins/README.md) |

Each source has a budget. The first frame is drawn when it runs out (**Open:** 50 ms after the keystroke),
with whatever has answered; apps, commands and the clipboard are in memory and always make it.

## Order

- **The top hit** is the best result in the first frame. It sits nearest the field, selected, and is not
  replaced while the query stands.
- **The sections** follow in a fixed order — Apps, Commands, Clipboard, Files, then plugins in the order the
  user sets — each with its best few (**Open:** three; five for Files) and a last row, "Show all…", that
  opens the whole section as a view; the Files section's opens in Files.
- **Within a section**, results order by how they matched — the whole name, its start, the start of a word,
  the initials, a subsequence — then by the source's own signal: running and recently opened apps, recently
  used files, newer clipboard entries, more-used commands.
- **Ties** break by name, then by path. The same query and the same history give the same order.

## Stability

- A result that arrives after the first frame goes to the far end of its section.
- Nothing moves under the selection.
- A result that vanishes while shown — a file deleted — dims in place until the next keystroke.

## Learned picks

When a result is chosen for a query, dock2 remembers the pair and ranks that result first the next time the
query, or a longer one that still matches it, is typed. It is all that search learns. The picks stay on this
Mac; Settings → Search lists and clears them.

## Actions

Every result has a primary action (↩), a secondary one (⌘↩) and a list of all of them (⌘K). Running one
dismisses dock2, unless it opens a view.

| Result | ↩ | ⌘↩ | ⌘K also |
| --- | --- | --- | --- |
| app | open | Show in Files | Keep in Dock or Remove from Dock, Hide, Quit, Force Quit |
| file or folder | open | Show in Files | Quick Look, Open With…, Copy Path, Move to Trash, Show in Finder |
| clipboard entry | paste (copy, without Accessibility) | copy | Paste as Plain Text, Pin, Delete |
| command | run | — | its own |
| plugin result | the plugin's | the plugin's | the plugin's |

## Commands

dock2's own: **Clipboard History**, **Settings**, **Toggle Auto-hide**, and **Quit dock2**, which gives the
system Dock back. Each plugin adds the commands its manifest declares ([packaging](../plugins/packaging.md));
a command runs at once or opens a view.

_Later_: System Settings panes; system actions (Lock Screen, Sleep, Empty Trash); a calculator and unit
conversion; the dictionary; a web search that appears only when asked for.
