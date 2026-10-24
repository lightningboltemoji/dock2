# Plan: settings to TOML in `~/.config`

> Implemented in change `1792831255` (`.agents/changes/1792831255.md`), phases 1–7. Not yet run live. One
> departure: there is no `MachineStore`. A setting has a scope instead (`SettingKey(machine:)`), and
> `SettingsStore` keeps per-Mac values in `state.json` behind the same subscript, so no call site changed.

Move dock2's settings and plugin choices out of the defaults domain `zip.tanner.dock2` and `plugins.json`
into `~/.config/dock2/config.toml`, read and written with emira's TOML 1.0 reader and its splicing writer
(`ConfigDocument`). The file can be kept in a dotfiles repo and shared between Macs. The Settings window, the
dock and the CLI keep writing it. Comments, ordering and hand-written spellings survive every write.

The fit is good. The settings are flat, every caller already goes through one typed API
(`settings[Settings.x]`, `observe`), and nothing outside the store touches the domain (`isSet` and `reset`
have no callers). Most of the migration happens behind `SettingsStore` and `PluginStore`.

---

## Decided

1. **What syncs.** Everything goes in the file, `onboarded` included, except two values that describe one
   Mac: `askedToPaste` and `fileAccess`. Those go in `MachineState`, a `Codable` struct in
   `~/Library/Application Support/dock2/state.json` (`JSONFile`), next to the journal and the usage counts.
2. **Unknown keys and bad values (differs from emira).** A **grammar** error refuses the whole file, because
   text of unknown meaning can't be spliced. A **schema** problem (an unknown key, or a known key with a bad
   value) is handled per key. The key reads as its default, or keeps its current value on a reload, and it is
   reported with `path:line` in Settings and the log. dock2 never removes a line it doesn't understand, so an
   older build writing the file keeps a newer build's keys.
3. **A file that doesn't parse at launch (differs from emira).** After every successful read or write, dock2
   keeps a copy of the text in `Application Support/dock2/config.last-good.toml`. A grammar error at launch
   runs on that copy (defaults if there is none) and raises a notice. While the file doesn't parse, writes are
   refused: Settings shows the diagnostic and an "Open config.toml" button, and a pin drag gets a notice. A
   grammar error on reload changes nothing. If a write finds the file broken, its pending edits are dropped
   and the values go back to what the file last said, with the same notice. The last-good copy is kept only
   for the default path; a `DOCK2_CONFIG` run keeps none, so dev runs can't overwrite the real one.
4. **Copy, share later.** `TOML.swift` and a generalised `ConfigDocument` go into a new target, `Dock2TOML`,
   that knows nothing about dock2, with a header comment naming the emira commit. Pulling it out into a shared
   package later is just moving the target.
5. **Pinned apps sync** as bundle ids, or a path (with `~/`) for an app without one. An app not installed on
   this Mac stays in the list and isn't drawn. `DockModel.pinning` already keeps entries that can't be drawn.
6. **The file wins.** On a Mac where `onboarded = true` is already in the file, dock2 starts without
   onboarding. Takeovers start from the file. Files asks for access the first time it opens there, as it
   already does for `.notAsked`. Without `onboarded`, onboarding runs, pre-filled from the file. The system
   Dock's settings fill in only the keys the file doesn't set.
7. **Plugins sync.** Their choices move from `plugins.json` to `[plugins."<id>"]` tables. Their code
   (`Plugins/`), storage (`PluginData/`) and secrets (the Keychain) stay on each Mac. More under
   [Plugins](#plugins).
8. **Smaller calls:**
   - Drop `magnification`, `largeSize` and `position`. The first launch writes them and nothing reads them.
   - Import the defaults domain and `plugins.json` once, and leave both in place for downgrades.
   - Path: `~/.config/dock2/config.toml`, overridden by `DOCK2_CONFIG`. `$XDG_CONFIG_HOME` is ignored: an app
     launched at login never sees a shell's environment.
   - Don't port emira's `Draft`. Settings applies changes as they are made, so the store writes each change
     itself.
   - The schema drives reading, the generated example and `dock2 config explain`, not the SwiftUI window.
9. **Open at login comes from the file.** `[general] open-at-login` is applied at every launch once onboarded,
   and whenever it changes: `SMAppService.mainApp` is registered when it's true and unregistered when it's
   false. The file wins in both directions. Settings shows `.requiresApproval` as it does today. Only the
   bundled app applies it; a run from `.build` has no bundle to register. The import carries over the current
   `SMAppService` status, so the first launch of the new build doesn't turn off a login item.
10. **dock2 never changes `enabled`.** A failing plugin is stopped and surfaced; the user's intent isn't
    rewritten. See [A plugin that keeps failing](#a-plugin-that-keeps-failing).

Nothing is open.

---

## The file

`~/.config/dock2/config.toml`. A missing file means every setting is at its default. dock2 creates the file
with emira-style starter comments on its first write. **Setting a value to its default removes its line**
(emira's rule), so a file only says what the user changed.

| Table | Key | From | Spelling |
| --- | --- | --- | --- |
| `[general]` | `onboarded` | `onboarded` | bool |
| | `open-at-login` | `SMAppService` | bool, applied at every launch |
| | `summon` | `summonShortcut` | `"cmd-space"` (taken from Spotlight), a chord `"ctrl-alt-space"`, or `"none"` |
| `[dock]` | `style` | `dockStyle` | `"glass"`, `"snow-leopard"` |
| | `tile-size` | `tileSize` | points, 16–128 |
| | `autohide` | `autohide` | bool |
| | `reveal-delay`, `hide-delay` | `revealDelay`, `hideDelay` | seconds, ≥ 0 |
| | `slide-time-modifier` | `slideTimeModifier` | ≥ 0; 0 means no slide |
| | `type-to-search`, `number-badges` | `typeToSearch`, `numberBadges` | bool |
| | `bounce-on-launch`, `show-running-apps` | `bounceOnLaunch`, `showRunningApps` | bool |
| | `minimize-into-app-icon` | `minimizeIntoAppIcon` | bool |
| | `pinned` | `pinnedApps` | `["com.apple.Safari", "~/Applications/Foo.app"]` |
| `[search]` | `field-form` | `fieldForm` | `"drop"`, `"gem"`, `"lava-lamp"`, `"capsule"` |
| | `sources-off` | `searchSourcesOff` | section titles |
| | `first-folders`, `excluded-folders` | `searchFirstFolders`, `searchExcludedFolders` | paths, `~/` under home |
| | `plugin-order` | `pluginResultsOrder` | plugin ids |
| `[clipboard]` | `history` | `clipboardHistory` | bool |
| | `retention-days` | `clipboardRetentionDays` | integer ≥ 1 |
| | `ignored-apps` | `clipboardIgnoredApps` | bundle ids |
| | `shortcut` | `clipboardShortcut` | as `summon`, without `cmd-space` |
| | `paste-on-return` | `clipboardPastes` | bool |
| `[files]` | `show-in-finder-opens-files` | `showInFinderOpensFiles` | bool |
| | `folders-first`, `show-hidden`, `preview-column` | same | bool |
| | `icon` | `finderIcon.picture` | `"finder"` or a Cairo picture, `"palm-tree"` |
| | `icon-color` | `finderIcon.color` | `"#6A5BD8"`, Display P3 |
| | `icon-filled` | `finderIcon.filled` | bool |
| `[plugins."<id>"]` | see [Plugins](#plugins) | `plugins.json` | |

Enum words are the Swift raw values in kebab-case. Chords use emira's spelling: modifiers first, in canonical
⌃⌥⇧⌘ order, then a named key position. `"cmd-space"` always means the Spotlight takeover
(`Shortcut.commandSpace`), never a plain chord, because a plain ⌘space can't register while Spotlight holds it.
`plugin-order` stays under `[search]` because every key under `[plugins]` is a plugin id.

Paths are written with `~/` and expanded on read, so a shared file works under another user name.
`icon-color` is quantised to 8 bits. The store's value always comes from reading the file back, so the window
and the file agree. A hand-written value that a picker doesn't offer (`retention-days = 14`) still takes
effect. The picker gets an extra "14 days" entry rather than showing nothing selected.

---

## Plugins

```toml
[plugins."zip.tanner.dock2.bitwarden"]
enabled = true
revoked = ["query"]

[plugins."zip.tanner.dock2.bitwarden".settings]
server = "https://vault.bitwarden.eu"

[plugins."zip.tanner.dock2.now-playing".tiles]
player = false
```

**Defaults come from the installed manifest.** `enabled` defaults to off for a first-party plugin and on for
one the user installed, since installing it was the question. `revoked` defaults to `["query"]` when its
results start off and `[]` otherwise. `results` and `tiles` default to the manifest's. A plugin used as it
ships writes nothing, apart from `enabled = true` for a first-party one.

**Grants are spelled `revoked`, replacing `granted` + `declared`.** `PluginChoices.granting` computes "declared
now, minus what was declared and not granted", which is the manifest's capabilities minus what was revoked. So
`revoked` alone carries the same decision, and it reads well by hand. `granted` becomes derived and
`granting` goes away. One edge changes: a capability that was revoked, then dropped from the manifest, then
added back stays revoked. Today it would be granted again. That's the safer way round.

**Settings get their types from the manifest:** toggle → bool, number → number (written `5`, not `5.0`, as a
plugin parses it), text and choice → string, folder → path with `~/`. A **secure** setting never goes in the
file. One found there is moved into the plugin's secrets and its line removed, as happens with
`plugins.json` today, and the move is reported. Secure values have to be entered again on each Mac.

**A plugin not installed on this Mac** keeps its table untouched. Nothing validates it and nothing reports it.
Installing it there applies the table. The install sheet shows the grants with `revoked` already applied.

**dock2 never deletes a `[plugins]` table on its own.** Removing a plugin removes its code, storage, secrets and
compiled modules, but not its table. Deleting the table would put another Mac's still-installed copy back on
its defaults, which means every capability it declares granted, without anyone being asked. A "forget"
button for tables of plugins not installed can come later.

### A plugin that keeps failing

Today a trap, an overrun or running out of memory discards the instance, and the next event starts a fresh
one. Five failures in a minute (`PluginInstance.failureLimit`) trigger `PluginHost.disable`, which writes
`enabled = false` and `disabledBecause` into the choices.

The limit itself is worth keeping: without it, a broken plugin restarts on every event and keeps eating the
50 ms search budget. Writing the result into `enabled` is the mistake. It mixes up "the user turned it off"
with "it's broken". The install path already has to undo it (`enabled || disabledBecause != nil`), and with a
synced file one Mac's failure would rewrite every Mac's intent.

So the limit **suspends** the plugin for the rest of the run, and nothing is persisted. `PluginHost` keeps
`suspended: [id: reason]` in memory: the plugin is stopped, its tiles come off, and the notice shows as it does
today. Settings → Plugins shows the reason next to its switch, which stays on, along with a Try Again button.
Try Again, installing new code (`install`, `dev`) and relaunching all clear it. `disabledBecause` leaves
`PluginChoices`, and the file never mentions failures.

Anyone who can write the file can grant a plugin capabilities. That's already true of `plugins.json`. The
difference is that the file may now be pulled from a repo.

---

## Architecture

```
Dock2TOML     new, pure, no dependencies — the TOML 1.0 grammar with spans; TOMLDocument (set, remove,
    ▲           rename, names), addressed by path segments. Knows nothing about dock2.
Dock2Core     the schema: SettingKey<Value> = path + codec + help sentence; Settings.all; reading a table
    ▲           into values + diagnostics; chord spelling; plugin choices ⇄ table, given a manifest;
    │           MachineState; the example document.
Dock2System   SettingsStore over the file: path, lock, load, watch, edits, coalesced write; MachineStore;
    ▲           the one-time import.
Dock2Plugins  PluginStore reads and writes its choices through SettingsStore.
    ▲
Dock2Shell    unchanged call sites; SettingsModel on the store's change signal; the banner; onboarding.
dock2         `dock2 config …` and `dock2 plugin …` write the file through the same store code.
```

**`Dock2TOML`.** `TOML.swift` copied over. `TOMLDocument` is `ConfigDocument` with the schema removed: it holds
the text and its parse together, `commit` re-parses only the grammar, and validation is the caller's job. Keys
are `[String]` paths rather than dotted strings, because plugin ids contain dots
(`["plugins", "zip.tanner.dock2.bitwarden", "enabled"]`). `TOMLTable.spell(key:)` already quotes a segment
that needs it. The errors split in two: `TOMLError` (syntax, duplicate key) lives here, and schema
diagnostics live in Core.

**`SettingKey<Value>`** replaces `name` + `SettingValue` (property lists) with a path and a codec,
`read(TOMLValue) throws -> Value` plus `write(Value) -> TOMLValue`. The codecs come from a small set: toggle,
number with bounds, integer, enum word, string list, path list, app list, chord and hex colour. `FinderIcon` is
one `SettingKey` stored as three keys, the way emira's springs are one field behind two keys. `Settings.all`
lists every key for reading, the example and the import. `[plugins]` is an open table, the counterpart of
emira's `[keys]`. The reader takes it whole and leaves it to `PluginStore`, which reports its own diagnostics
to the store. Consumers don't change.

**`SettingsStore`** keeps `subscript` and `observe(_:_:)` as they are, and replaces `UserDefaults` and KVO:

- **State:** the `TOMLDocument`, the decoded values by key, the diagnostics, and the pending edits. Open
  tables get a lower-level API: read a table by path, set a path, unset a path.
- **Set:** apply the edit to the in-memory document (removing the line when the value is the default), decode,
  notify the observers of each key whose value changed (asynchronously on main, as KVO's delivery is today),
  then schedule a write. The write is coalesced over
  250 ms, so dragging a slider writes the file once.
- **Edits are operations, not text.** At write time the store re-reads the file. If it differs from the last
  text the store read or wrote (a hand edit, a sync tool, or the CLI), the pending operations are replayed onto
  the new text. Every writer (the running dock2, `dock2 config`, `dock2 plugin`) holds an advisory `flock` on
  `Application Support/dock2/config.lock` from that read until the rename, so two processes can't interleave.
- **Writing through a link.** Resolve symlinks, write a temp file in the *target's* folder, and rename it over
  the target. Measured: `Data.write(options: .atomic)` on a symlinked path replaces the link with a plain file
  and leaves the dotfiles copy unchanged. emira has the same bug.
- **Watching:** a port of `ConfigWatcher` (vnode sources on the file and its folder, re-armed by path), plus the
  resolved target and its folder when the file is a link. Coalesced over 80 ms. Changes are reported per key
  by comparing decoded values, so dock2's own writes echo back as nothing.
- **Shutdown:** a pending write is flushed at `applicationWillTerminate`, and by the CLI before it exits (it
  builds a store without a watcher). After `kill -9`, at most 250 ms of edits is lost. Nothing here touches
  `com.apple.dock`, so the Suppressor and the journal are unaffected.

**`PluginStore`** stops owning `plugins.json`. Its `choices` are read from the store against each installed
manifest. `update(id, change)` compares the old and new choices and writes the keys that differ. The watcher
replaces `reloadFromDisk` for choice changes. The distributed notification from `dock2 plugin` stays, but only
for code changes, when the store has to scan `Plugins/` again.

**`SettingsModel`** watches a generation counter on the store instead of `UserDefaults.didChangeNotification`.
Settings gains a banner for diagnostics or a file that doesn't parse, and an "Open config.toml" button (emira's
`ConfigFile.open`: create the file if it's missing, open it with whatever opens `public.toml`, else reveal it
in Finder).

---

## Phases

Each phase builds, passes `make test`, and leaves dock2 working.

**1. `Dock2TOML`.** Copy `TOML.swift`, generalise `ConfigDocument` into `TOMLDocument` with path addressing, and
port the grammar and round-trip halves of `ConfigSyntaxTests` and `ConfigDocumentTests`, adding cases for
quoted, dotted segments. The grammar is copied unchanged apart from its error type, so emira's `toml-test`
result (703 of 709) carries over; `toml-test` isn't installed here. Nothing uses it yet.

**2. The schema, additive.** Add the path, codec and help sentence to every `SettingKey` alongside the
property-list conversion, which the store still uses. Codecs, with tests for each spelling and each refusal.
Port emira's `KeyChord` vocabulary and map it to Carbon codes and modifiers. Read a table into values plus
diagnostics. Generate `config.example.toml` from `Settings.all`, pinned by a golden test, with `make example` to
regenerate it. `MachineState`.

**3. The store and its import, together**, so no build in between starts on empty settings. Swap
`SettingsStore` over to the file as described above, add `MachineStore`, and move `askedToPaste` and
`fileAccess` there at their call sites. The property-list conversion moves into the importer, which runs at
launch before anything reads a setting: if `config.toml` is missing and the domain holds a dock2 key, it
decodes each value with the old rules (the bit-13 ⌃ fix-up included), writes the non-default ones under the
starter comments with `open-at-login` from `SMAppService`, and logs what it carried over. If `state.json` is
missing, it imports `askedToPaste` and `fileAccess` the same way. The domain is left untouched, and a config
that already exists always wins over it. Back up first with `defaults export zip.tanner.dock2`. Tests run
against a temporary folder:
- defaults when the file is missing;
- setting a default removes its line;
- comments and order survive;
- a hand edit is heard once, and dock2's own write is heard once;
- pending edits are replayed over a hand edit;
- two processes writing under the lock;
- writing through a symlink keeps the link;
- a grammar error falls back to the last-good copy and refuses writes;
- an unknown key is reported, survives a write, and doesn't block other keys;
- the import, from a scratch defaults suite, writes only what differs from the defaults.

**4. Plugins on the store, and their import.** Plugin choices ⇄ table, given a manifest, with the defaults
above. `PluginStore` moves its choices to the store; `revoked` replaces `granted`/`declared`; `remove` keeps
the table. The failure limit becomes an in-memory suspension in `PluginHost`, and `disabledBecause` goes. `dock2
plugin install|dev|remove` write through the store code. `plugins.json` is imported once, when the file has no
`[plugins]` table, and a plugin dock2 switched off for failing is imported as `enabled = true`, since that's
what the user last chose. Port the `PluginStore` tests, and add:
- a table for a plugin that isn't installed survives other writes;
- installing applies an existing table;
- a secure value in the file moves to the secrets;
- five failures suspend the plugin without writing anything, and installing again or Try Again clears the
  suspension.

**5. Wiring.** The banner and the open button. Onboarding: the branches in Decided 6, and its open-at-login
choice writes the key. `LoginItem` is applied from the key at launch and on change; the Settings toggle writes
the key. `SystemDockSettings.copy` drops the three dead keys and fills only what the file doesn't set.

**6. CLI.** `dock2 config path | open | check | explain | get <key> | set <key> <value>` work on the file
directly, as `emira config` does, with no running dock2 needed. `check` prints the diagnostics and exits
non-zero, which is useful in a dotfiles repo's CI. This phase can be cut; phases 1–5 stand without it.

**7. Docs, then the pass in `DOCS.md`.**
- `product/settings.md`: where settings live, what syncs and what stays on one Mac, a broken file, the banner,
  plugin settings in the file.
- `product/plugins/`: grants as `revoked`, a removed plugin keeping its table, secure settings per Mac. In
  `runtime.md` and `README.md`, "switched off" for a failing plugin becomes suspended for the run, with Try
  Again.
- `IMPLEMENTATION.md`: §5 Settings (domain → file); the plugins section (`plugins.json` at two places); §12
  (the window, the first launch's branches, the defaults note); §15 (the cask's `zap` leaves `~/.config/dock2`
  alone, since it's the user's file).
- `design/README.md`: the module graph and the object graph line for `SettingsStore`.
- `OBSERVING.md`: replace `defaults write zip.tanner.dock2 …` with editing the file through `DOCK2_CONFIG` or
  `dock2 config set`.
- `README.md`: a short config section pointing at `config.example.toml`.
- The change file.

---

## Validation

All of it observed live, per `OBSERVING.md`: `DOCK2_DEBUG=1 DOCK2_CONFIG=<scratch>/config.toml`, reading
`dock2 debug state` and screenshots.

- A hand edit applies live, both in place (`printf >>`) and as an atomic save (`mv` over the file, as vim
  does). `tile-size` and `style` show up in the tiles' frames and in a screenshot.
- A Settings slider drag produces one write (count them with `fs_usage -w -f filesys dock2`), and a comment
  above the key survives.
- A symlinked config: a write keeps the link, and an edit to the target in the "dotfiles" folder is heard.
- A grammar error at launch runs on the last-good copy with the notice up. A grammar error on reload changes
  nothing. An unknown key shows in the banner, and a later write leaves its line alone.
- Plugins: switching Now Playing's tile off in Settings writes `tiles.player = false` and the tile leaves;
  deleting that line by hand brings it back. `dock2 plugin dev` running alongside the Settings window: both
  sets of edits land. A plugin built to trap on every event gets suspended after five failures, its line in
  the file doesn't change, and Try Again runs it again.
- `open-at-login = true` registers dock2 on launch after it was removed in System Settings → Login Items, and
  `false` unregisters it.
- Importing this Mac's real domain and `plugins.json`, after the backups above, matches them key for key.
- A second Mac, simulated by deleting `state.json` with `onboarded = true` in the file: no onboarding, the
  dock comes up with the file's pins, and Files asks for access when first opened. With `onboarded` removed,
  onboarding pre-fills from the file and copies nothing from the system Dock.
