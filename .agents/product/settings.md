# Settings

dock2 owns its settings. They live in a TOML file, `~/.config/dock2/config.toml`, apply the moment they
change, and are edited in a Settings window or by hand.

## The file

A person may keep the file in a dotfiles repo, a link to it included, and share it between Macs. It says
only what differs from the defaults: changing a setting back to its default takes its line out. Dock2 writes
it one value at a time and leaves everything else as the person wrote it: comments, order, spelling. It
hears an edit as it is saved. `config.example.toml` lists every setting with what it does.

- **What stays on one Mac**: the file-access choice and whether macOS was asked for Accessibility, both
  answers macOS keeps per Mac; plugins' code, storage and secrets. Everything else is in the file,
  including the first launch being done, open at login, and the plugins' choices.
- **A setting the file gets wrong** — an unknown key, perhaps from a newer Dock2 on another Mac, or a value
  out of range — is at its default, and Settings lists it with its line. Dock2 never removes a line it
  doesn't understand.
- **A file that isn't TOML** changes nothing: Dock2 keeps the settings it had, or at launch the last file
  it could read, says so, and saves nothing until the file is fixed.
- `dock2 config` finds the file, checks it, explains every setting, and gets or sets one.

## Where they start

The first launch copies the system Dock's: its pinned apps, tile size, auto-hide and its delays, the launch
bounce and where windows minimise to — each only where the file doesn't already say, since another Mac may
have written it. Auto-hide is the user's own value, taken from the journal if the system Dock is already
suppressed. From then on the two are independent: the system Dock's settings are the user's, journaled and
given back when dock2 quits ([takeovers](system/takeovers.md)). A Mac whose file says the first launch is
done skips it, and starts with the file's settings.

## The window

A standard macOS settings window with a sidebar. It opens from the platter's right-click menu, from the
Settings command, or with ⌘, while dock2 has the keyboard. While it is open dock2 is a regular app — a menu
bar, a place in the app switcher — but never a tile on its own dock.

## Sections

| Section | Settings |
| --- | --- |
| **General** | Open at login. The summon shortcut: ⌘space (taken over from Spotlight), another, or none. |
| **Dock** | The style: Liquid Glass or Snow Leopard ([visual](visual.md#the-docks-style)). Tile size. Auto-hide, with the reveal and hide delays. Type to search when the dock appears. Number badges while ⌘ is held. Bounce apps as they open. Show running apps that are not pinned. Minimize windows into application icon. |
| **Search** | The field's form ([panel](panel.md#the-fields-form)): Drop, Gem, Lava lamp or Capsule. Each source on or off, and the plugins' order. Folders ranked first. Excluded folders. Learned picks: list, clear. |
| **Clipboard** | Keep history. Keep for. Ignored apps. The global shortcut. Paste or copy on ↩. Clear history. |
| **Files** | Folders first. Show hidden files. The preview column. "Show in Finder" opens Files — a takeover ([takeovers](system/takeovers.md)). Icon, the one Files wears in the dock: Finder's own or one of Cairo's pictures, its colour, and whether it is filled ([icon](files/icon.md)). |
| **Shortcuts** | Every global shortcut, in one list. _Next_: ⌘⇥. _Later_: a shortcut per command. |
| **Plugins** | The installed plugins, each with an on/off switch, its permissions and its settings. Install from a folder. Remove. |
| **Permissions** | File access first, with the choice the first launch offered ([access](files/access.md)); then each macOS permission dock2 can use, what it unlocks, whether it is granted or not yet asked, and a button to it: macOS's prompt until it has asked, then its pane in System Settings ([permissions](system/permissions.md)). |
| **About** | The version. The settings file, opened. Quit Dock2, giving the Dock back. Logs, for a bug report. The first-launch sequence, again. _Later_: updates. |

A setting the system Dock also has starts at the system Dock's value; every other starts at the default its
own file names. Above every section, Settings lists what the file gets wrong, with a button to open it.

## Plugin settings

A plugin declares its settings ([packaging](plugins/packaging.md)) and the window draws them: text, secure
text (kept in the Keychain on each Mac, never in the file), toggle, choice, number, folder. They are kept in
the file under the plugin's id, with whether it is on, what it may not do, and its results and tiles.
