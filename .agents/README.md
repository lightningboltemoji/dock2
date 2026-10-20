# `.agents/`

| File                | Contents                                                       | Tense      |
| ------------------- | -------------------------------------------------------------- | ---------- |
| `IMPLEMENTATION.md` | the charter, module layout, the glass, the system Dock's guard | present    |
| `changes/<id>.md`   | what one change did and why                                    | past       |
| `DOCS.md`           | how the rest are written; the pass that ends a change          | imperative |

## Ground truth

`IMPLEMENTATION.md` describes dock2 as it is now. No dated entries, no "corrected on", no description of
prior behaviour. A superseded decision has its text replaced; the previous reading stays in git and in the
change that replaced it.

## Changes

Feature work has a change id: the Unix epoch second it was made. The id names a file,
`.agents/changes/1792471296.md`.

How a comment, a change, or an edit to `IMPLEMENTATION.md` is written — and the pass that ends feature
work — is `DOCS.md`.
