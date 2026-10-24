# Settings

dock2 owns its settings. They live in its own defaults domain (`zip.tanner.dock2`), apply the moment they
change, and are edited in a Settings window.

## Where they start

The first launch copies the system Dock's: its pinned apps, tile size, auto-hide and where windows minimise
to, and — kept for when
dock2 supports them — magnification and position. Auto-hide is the user's own value, taken from the journal
if the system Dock is already suppressed. From then on the two are independent: the system Dock's settings
are the user's, journaled and given back when dock2 quits ([takeovers](system/takeovers.md)).

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
| **Files** | Folders first. Show hidden files. The preview column. "Show in Finder" opens Files — a takeover ([takeovers](system/takeovers.md)). Icon, the one Files wears in the dock: Finder's own or one of Cairo's pictures, and its colour ([icon](files/icon.md)). |
| **Shortcuts** | Every global shortcut, in one list. _Next_: ⌘⇥. _Later_: a shortcut per command. |
| **Plugins** | The installed plugins, each with an on/off switch, its permissions and its settings. Install from a folder. Remove. |
| **Permissions** | File access first, with the choice the first launch offered ([access](files/access.md)); then each macOS permission dock2 can use, what it unlocks, whether it is granted, and a button to its pane in System Settings ([permissions](system/permissions.md)). |
| **About** | The version. Quit Dock2, giving the Dock back. Logs, for a bug report. The first-launch sequence, again. _Later_: updates. |

A setting the system Dock also has starts at the system Dock's value; every other starts at the default its
own file names.

## Plugin settings

A plugin declares its settings ([packaging](plugins/packaging.md)) and the window draws them: text, secure
text (kept in the Keychain, never in the defaults), toggle, choice, number, folder.
