# Dock2

## About

Dock2 combines the Dock, Spotlight and Finder.

It looks and behaves like the Dock, with the same glass and geometry. Start typing and a search field rises out of it. Apps, files and your clipboard show up there, and an app you find lights up on its own tile. Click Finder and the same panel becomes a file browser.

## Features

- Everything the Dock does: pinned and running apps, menus, drag to reorder, auto-hide
- Search: hover the dock or press ⌘space, then type
- Keyboard-first: ⌘1–9 open the first nine tiles, the arrow keys walk the rest
- Files: a column browser with tabs in place of Finder windows, "Show in Finder" included
- Clipboard history: encrypted, on this Mac only, passwords never kept
- Plugins: sandboxed WebAssembly, with Now Playing and Bitwarden included
- Scriptable: `dock2 summon`, `dock2 files ~/Downloads`, `dock2 clipboard`

## Install

[Homebrew](https://brew.sh) is recommended:

```bash
brew install --cask lightningboltemoji/tap/dock2
```

or manually from the [releases page](https://github.com/lightningboltemoji/dock2/releases). Requires macOS 26.

## The system Dock

macOS has no way to turn the Dock off, so Dock2 hides it: auto-hide on, with a reveal delay nobody will wait out. Your own settings are saved first and put back when Dock2 quits, even if it crashes or is killed.

If your Dock is ever left hidden anyway (say, the Mac lost power while Dock2 ran), launching Dock2 again fixes it, or run:

```bash
dock2 --restore
```
