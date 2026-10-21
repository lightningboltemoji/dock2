# Control

Other tools can drive dock2: a launcher that opens its search, a script that opens Files at a folder, an
agent that watches what it shows. Each request goes to the running dock2 and gets one answer.

## What anyone can ask

`dock2 <verb>`, from a terminal or any program that can run one.

| Verb | Does |
| --- | --- |
| `summon [query]` | what the summon shortcut does, but never dismisses; with a query, typed into the field |
| `dismiss` | lets go of the keyboard, as Esc on an empty field does |
| `files [folder]` | Files, at the folder if given |
| `clipboard` | Clipboard History |
| `status` | the version, and whether dock2 has the keyboard |

None of them reaches more than a keypress or a click on the dock does. None opens a result or reads what
is shown.

## What only a debugging dock2 answers

Typing, pressing keys and chords, holding modifiers, holding the dock up, moving and clicking and dragging
the pointer, and reading everything shown — the field's text, the rows, the tiles, where each part is on
screen — are `dock2 debug …`. A dock2 answers them only if it was started with
`DOCK2_DEBUG=1`; any other refuses them and says why. They are for observing dock2 while building it
([observing](../OBSERVING.md)), never for another app to drive it with.

## The socket

The requests go over a socket only this user can open, in the user's temporary folder (`DOCK2_SOCKET`
names another). A dock2 that crashed leaves it behind, and the next one takes it over. A
running dock2 keeps its own, and anything else at the path is left alone. A dock2 from another build
says so rather than misreading the request.

`dock2 <verb>` exits 0 when done, 1 when refused, 2 for something that is not a command, and 69 when no dock2
is running to ask.
