# File search

The Files source is the Spotlight index, through the public metadata query API (`NSMetadataQuery`). dock2
keeps no index of its own.

## What it covers

What the system indexes — files and folders, by name — and of that, what dock2 is allowed to see:

- **Desktop, Documents and Downloads need the user's consent.** Without it the index silently leaves their
  contents out of results, and a query aimed at one of them raises macOS's folder-access prompt. dock2 asks
  once, for search and Files together ([access](../files/access.md)); until it has access, the Files section
  ends with a row naming the places it cannot see.
- **What apps donate to Spotlight privately** — mail, messages, notes, contacts, events, Safari history — is
  invisible to other apps, with consent or without.
- **Apps** are left to [apps](apps.md): the query excludes `com.apple.application`.

## Matching

By display name, word by word (`kMDItemDisplayName == "query*"cdw`), as all of search matches
([search](README.md)).

A short query is costly: on a developer's Mac a single letter matches hundreds of thousands of items and
takes seconds to gather. So:

- **One or two characters** search only near places — the Desktop, Documents, Downloads, iCloud Drive — and
  what was opened in the last 90 days.
- **Three or more** search the whole index, gathered within the source's budget, ranked by dock2, and
  capped.

## Ranking

After how it matched:

- **Recency**: last opened (`kMDItemLastUsedDate`), then last modified. A file opened from a terminal or an
  editor gets no last-opened date, so modification counts for as much.
- **Place**: the home folders and any the user names come first; system and `Library` paths come last.
- **Depth**: shallower first.
- **Noise**: paths inside dependency, build and cache trees (`node_modules`, `.build`, `DerivedData`,
  `Library/Caches`, `.git`) and hidden folders sink below everything else.
- **Learned picks** outrank all of it ([search](README.md)).

## Exclusions

Settings → Search → Excluded folders takes folders out of dock2's results. Spotlight's own privacy list
takes them out of the index for every app; Settings links to it.

## Actions

Open (↩), Show in Files (⌘↩), Quick Look (⌘Y). In ⌘K: Open With… — Files' submenu, its "Remember for" pills
too ([Files](../files/README.md#actions)) — Copy Path, Copy, Move to Trash, Show in Finder.

## Later

Searching inside documents (`kMDItemTextContent`) — hundreds of milliseconds, and noisy — as a command of its
own rather than part of every query. Kinds ("pdf", "image") as filters in the query.
