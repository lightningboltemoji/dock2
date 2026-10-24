# Plugins

A plugin adds what dock2 cannot know on its own: a player's state, a password vault, a service's API. It is
a WebAssembly module with a manifest, and it never draws: it describes, and dock2 renders.

## What a plugin can add

| Surface | What it is | For example |
| --- | --- | --- |
| **Commands** | entries in search that run, or open a view; the plugin lists those its state calls for | Bitwarden's Sign In, then Search Vault |
| **Results** | rows in search, in the plugin's own section | vault items matching the query |
| **Views** | screens in the panel, built from dock2's components | the vault; the player |
| **Tiles** | live tiles on the dock | Now Playing's artwork and progress |
| **Background work** | timers and system events that keep tiles and caches current | refreshing the vault |

## How it fits

- **Events in, effects out.** dock2 sends a plugin events — a command run, a query typed, an action chosen,
  a timer fired, a network response — and the plugin answers with effects: a view, a tile, a request, a
  write to its storage. It never blocks, and nothing calls back into it ([runtime](runtime.md)).
- **dock2 renders everything**, from a fixed vocabulary — lists, details, forms, grids, actions, tiles — so
  a plugin looks like dock2 and works from the keyboard without trying ([views](views.md)).
- **It reaches only what it was granted**: network to named hosts, its own storage and secrets, the
  clipboard — each a capability the user approves ([permissions](permissions.md)).
- **It cannot slow dock2 down.** Every call has a budget and is interrupted past it; late results go to the
  end of their section; a plugin that keeps failing is stopped until it is tried again, with a notice. It
  stays switched on: whether it is on is the person's to say.

## Lifecycle

Installed, then switched on, then loaded at its first need — a command, a query its results are on for, a
tile to draw — and unloaded when idle (**Open:** after a few minutes). Its storage outlives the instance;
its memory does not.

## In this folder

[views](views.md) · [runtime](runtime.md) · [permissions](permissions.md) · [packaging](packaging.md) ·
[first-party](first-party.md)
