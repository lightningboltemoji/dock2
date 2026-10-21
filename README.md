<h1>dock2</h1>

a replacement for the macOS Dock

## About

dock2 hides the system Dock and draws its own in its place, matched to the real one: the same Liquid
Glass platter, the same geometry at every tile size, the same name bubble and running dots.

For now it shows two apps, Safari and Ghostty. Click one to open it; right-click the platter to quit.

## Install

[Homebrew](https://brew.sh) is recommended:

```bash
brew install --cask lightningboltemoji/tap/dock2
```

or manually from the [releases page](https://github.com/lightningboltemoji/dock2/releases). Every push to
`main` is built as `lightningboltemoji/tap/dock2@tip`.

## The system Dock

macOS has no switch to turn the Dock off. dock2 turns auto-hide on with a reveal delay nobody will
wait out, and restarts the Dock. Before it changes anything it writes your own settings to
`~/Library/Application Support/dock2/takeovers.plist`, and it puts them back when it quits — or, if
it crashes or is killed, a guard process it started puts them back for it.

If your Dock is ever left hidden anyway (say, the machine lost power while dock2 ran), launching dock2
again recovers, or run:

```bash
dock2 --restore
```

## Build

```bash
make test   # the test suite
make run    # run from the terminal; Ctrl-C quits and restores the Dock
make app    # dist/Dock2.app
```

Requires macOS 26.
