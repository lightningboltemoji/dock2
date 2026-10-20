# Access

A file browser runs straight into macOS's privacy rules: Desktop, Documents and Downloads are closed to an
app until the user lets it in, one prompt per folder, and so is other apps' data. Files asks for Full Disk
Access, which opens all of it, and falls back to the three folders.

## The ask

The first time Files opens, or at the files step of the first launch ([onboarding](../onboarding.md)),
whichever comes first:

> **dock2 needs Full Disk Access to show all your files.** macOS has no prompt for it; the switch is in
> System Settings. _Open System Settings_ · _Just Desktop, Documents and Downloads_ · _Not now_

- **Open System Settings** goes to Privacy & Security → Full Disk Access. dock2 knows the grant has landed
  when a path only Full Disk Access can read becomes readable, and says so. **Open:** whether macOS has
  dock2 reopen before the grant takes effect.
- **Just Desktop, Documents and Downloads** raises macOS's prompts, one for each.
- **Not now** leaves it there; Settings → Permissions offers the same choice later.

The one answer covers search too: file search sees what Files sees ([file search](../search/files.md)).

## Without it

A protected place shows a lock in Files, and one row inside it: "dock2 can't see in here — Allow access…".
The Files section of search ends with a row naming the places it cannot see.

## Other places

- **iCloud Drive and other cloud providers** browse like any folder. A file kept only in the cloud shows a
  cloud, and opening or copying it downloads it.
- **External and network volumes**: **Open:** whether they prompt, as the home folders do, without Full
  Disk Access.

## Never

Files changes no permissions or owners, and asks for no administrator's password.
