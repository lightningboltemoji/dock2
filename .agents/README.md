# `.agents/`

| File                | Contents                                                       | Tense      |
| ------------------- | -------------------------------------------------------------- | ---------- |
| `product/`          | what dock2 is for and how it behaves, as designed              | present    |
| `IMPLEMENTATION.md` | the charter, module layout, the glass, the system Dock's guard | present    |
| `design/`           | the low-level plan for what `product/` asks and the code lacks | future     |
| `changes/<id>.md`   | what one change did and why                                    | past       |
| `DOCS.md`           | how the rest are written; the pass that ends a change          | imperative |
| `OBSERVING.md`      | how to drive the live dock2, record it, and read the recording | imperative |

## Ground truth

`IMPLEMENTATION.md` describes dock2 as it is now. No dated entries, no "corrected on", no description of
prior behaviour. A superseded decision has its text replaced; the previous reading stays in git and in the
change that replaced it.

`product/` describes dock2 as it is meant to be, under the same rules. Where the two differ, the difference
is work not yet done or a design to revise — never a reason to write `IMPLEMENTATION.md` ahead of the code.

`design/` is the bridge: how the code will meet `product/`, written before it is built. As a part lands,
its description moves into `IMPLEMENTATION.md` and `design/` keeps only what is still ahead.

## Changes

Feature work has a change id: the Unix epoch second it was made. The id names a file,
`.agents/changes/1792471296.md`.

How a comment, a change, or an edit to `IMPLEMENTATION.md` or `product/` is written — and the pass that
ends feature work — is `DOCS.md`.
