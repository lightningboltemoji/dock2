# Writing it down

## Where an explanation goes

A comment says what a reader needs to understand the code in front of them. Everything else — the
investigation, the rejected alternatives, the bug that motivated a line, the numbers that proved it —
belongs in the change, and `git blame` reaches it.

- **Three lines is the working ceiling** for a declaration, and most need one. If it wants more, the
  surplus is history and the change file is where it goes.
- **Say the constraint, not the derivation.** "cfprefsd skips a write CFEqual calls equal" is the fact;
  how it was found is not.
- **Never date, attribute, or narrate.** No "previously", no "we changed this because", no bug ids.
- `IMPLEMENTATION.md` is the exception: prose _is_ its code, and an argument that belongs to the design as
  a whole lives there rather than above the line that happens to implement it.

## The change file

Three sections, normally a paragraph each:

```markdown
# <title>

> Change `<id>` — <date>

## Goal

The problem this addresses.

## Implementation

Pull-request altitude: what a reviewer needs to read the diff. Decisions and the reasons for them,
rejected alternatives and their failure modes. Not a restatement of the code.

## Observations

Known limits, untested areas, follow-up work.
```

## The pass

The change file is the last thing written, and writing it is the cue to run this. Four steps over the
diff, each with an output.

1. **Enumerate** every comment on a declaration that the diff added or touched and that runs past three
   lines. For each, cut it to the constraint or move the surplus into the change file.
2. **Grep** the diff's comments for `previously`, `used to`, `we changed`, `the bug`, dates, and issue
   ids. Delete what they introduce.
3. **Reconcile** the diff against `IMPLEMENTATION.md`. Behaviour it now describes wrongly is edited in
   place, present tense.
4. **Report** what the pass changed. "Nothing" is a valid result and worth saying out loud.
