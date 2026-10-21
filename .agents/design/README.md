# dock2 — Design

The low-level plan for building `product/` on top of what `IMPLEMENTATION.md` describes. Future tense where
nothing is built yet; as each part lands, its description moves into `IMPLEMENTATION.md` in the present tense
and the plan here is cut back to what is still ahead. Where this disagrees with `product/`, `product/` wins
or is edited — never silently.

| File | Plans |
| --- | --- |
| [stage](stage.md) | the one window: dock, labels and panel as glass in one tree; motion; hit-testing |
| [dock](dock.md) | the tile model, separators, the pointer, drag and drop, auto-hide, the ring and badges |
| [keyboard](keyboard.md) | the interaction state machine, taking the keyboard, the field, hot keys |
| [takeovers](takeovers.md) | the journal generalised past the system Dock; the hot key table; `NSFileViewer` |
| [search](search.md) | matching, the session that keeps results still, sources, learned picks, actions |
| [views](views.md) | the component tree, its renderer, dock2's own views built from it |
| [files](files.md) | the browser, the path bar, operations, undo, access, "Show in Finder" |
| [clipboard](clipboard.md) | capture, the encrypted store, paste |
| [plugins](plugins.md) | the engine, the ABI, the protocol, capabilities, the SDK, the first-party plugins |
| [settings](settings.md) | the settings model and store, the window, the first launch |

---

## Modules

```
Dock2Core     pure — Foundation and CoreGraphics' geometry only; everything unit-tested.
    ▲           geometry · the tile model · the interaction state machine · matching, sessions, picks ·
    │           the journal · settings schema · clipboard policy and history · file naming and paths ·
    │           the plugin protocol (manifest, events, effects, view tree)
Dock2System   the Mac, without windows — takeovers and the guard, the instance lock, running apps and the
    ▲           app catalog, Spotlight queries, the pasteboard, the Keychain, posting a paste, file
    │           operations, hot keys, the settings store
Dock2Plugins  the plugin host — the engine (a Rust staticlib around wasmtime), one actor per instance,
    ▲           capability checks, install and remove
Dock2Shell    the windows — the stage, the glass, the dock, the panel and its views, Files, Settings, the
    ▲           first launch; `AppController`, which wires the rest together
dock2         executable — the app, `--restore`, `--guard <pid>`, `plugin install`
```

`Dock2System` is new: today's `Dock2Shell/System/` moves there. The split keeps the guard — which must
restore every takeover from a process with no UI — free of everything that draws.

## The object graph

```
AppController (Shell, @MainActor)
├── SettingsStore            UserDefaults `zip.tanner.dock2`, typed keys, change callbacks
├── Takeovers + GuardKeeper  the journal; engage/release per takeover; the guard process
├── RunningApps              NSWorkspace → [RunningApp] in launch order, activation order
├── AppCatalog               the folders, watched; names; dock2's own use counts
├── Interaction              pure state machine; its effects run here
├── Stage                    the one window — DockView, LabelLayer, PanelView, glass
│   ├── DockController       DockModel → DockLayout → DockView; menus; drag and drop; auto-hide
│   └── PanelController      the field, results, the view stack, Files
├── Search                   sources → SearchSession → rows
├── ClipboardHistory         watcher, policy, encrypted store
├── PluginHost               instances, tiles, commands, results
├── HotKeys                  Carbon hot keys → summon, clipboard history
└── windows                  SettingsWindow, Onboarding (SwiftUI, the only normal windows)
```

Ownership is a tree; communication upward is by closures set by the owner, never by singletons or
notifications of our own. AppKit's notifications are translated once, at the edge, into calls.

## Cross-cutting decisions

- **Concurrency.** Swift 6 language mode. UI and models on the main actor. Background work — Spotlight
  gathering, file operations, encryption, plugin calls — on its own queue or actor and delivered back to
  the main actor as values. Nothing blocks the main thread on the Keychain, a TCC prompt, or a plugin.
- **Persistence.** Settings in defaults. Everything else in `~/Library/Application Support/dock2/`:
  `system-dock.plist` → `takeovers.plist` (the journal), `dock2.lock`, `picks.json`, `usage.json`,
  `Clipboard/` (sealed), `Plugins/`, `PluginData/`. Every write is atomic.
- **Private API.** Each use is named, looked up at runtime, confined to one file, and has a stated
  degradation: the glass (`Glass/`), the hot key table (`HotKeyTable.swift`), now-playing (`NowPlaying`).
- **Testing.** `Dock2Core` is unit-tested exhaustively. `Dock2System` gets tests where a temp directory
  stands in for the real place (the journal, the clipboard store, file operations). The windows are
  validated against the real system: Accessibility frames, screenshots, and synthetic input that is
  interlocked on dock2 holding the keyboard.
- **Measured, not recalled.** Every new number that imitates the system — the ring, the separator,
  auto-hide's timing, Spotlight's rows — is measured on this Mac and recorded in the change that took it.

## Order of work

The roadmap's MVP order, each step committed with its change file and the docs pass.

1. ~~Foundations~~ — built (`changes/1792482670.md`).
2. ~~Dock parity~~ — built (`changes/1792485673.md`).
3. ~~Settings window and the first launch~~ — built (`changes/1792486518.md`).
4. ~~The keyboard~~ — built (`changes/1792490900.md`).
5. ~~Search~~ — built (`changes/1792496911.md`); Quick Look and its Settings since (`changes/1792520818.md`).
6. ~~Views~~ — built (`changes/1792498303.md`); grid scrolling, tags and tints since (`changes/1792520818.md`).
7. ~~Files~~ — built (`changes/1792500989.md`); problems on rows and the chip's ring since (`changes/1792520818.md`).
8. ~~Clipboard history~~ — built (`changes/1792501806.md`); thumbnails, and matching by a copy's text, since
    (`changes/1792533136.md`).
9. ~~Plugins~~ — built (`changes/1792504326.md`); organizations, installs at runtime and the CLI since
    (`changes/1792516937.md`). The product audited against the code, and its gaps closed:
    `changes/1792520818.md`.
10. **Release pass** — begun (`changes/1792514794.md`): the accessibility tree, the bundle, notarize, Show in Finder from
    the bundle; the dark appearance measured against the system Dock. Five audits of the product against
    the code since (`changes/1792520818.md` to `changes/1792538835.md`). Left: VoiceOver heard, a Developer
    ID build notarized — see IMPLEMENTATION.md's "Not yet".
