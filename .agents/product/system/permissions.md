# Permissions

The macOS permission each feature needs. The core needs none. A feature that needs one asks when it is
offered or first used, says why in a sentence, and still works, in a lesser way, without it.

| Permission | dock2 uses it for | Asked | Without it |
| --- | --- | --- | --- |
| none | the dock and auto-hide; reveal-to-type; ⌘space and every global shortcut; ⌘1–9; apps and commands; file search and Files outside the protected folders; clipboard history; hiding and quitting apps; plugins | — | — |
| **Full Disk Access** | showing and finding files everywhere, in Files and in search ([access](../files/access.md)) | the first time Files opens, or at the first launch's files step — a switch in System Settings, since macOS has no prompt for it | the three folders below, or locked places |
| **Files and Folders** — Desktop, Documents, Downloads | the fallback to Full Disk Access | when the user picks it instead | their files are neither shown nor found, and dock2 says so |
| **Accessibility** | sending the paste, for clipboard history and plugins; apps' badges, read from the hidden system Dock, and minimised windows on the dock and in their apps' menus. _Next_: windows as results; progress from the hidden system Dock | at the first paste, or from Settings → Permissions; the dock never asks | ↩ copies instead; no badges or minimised windows |
| **pasteboard access** | reading the clipboard, if the user has set dock2 to be asked or denied | when macOS reports either, or from Settings → Permissions | the history pauses |
| **Automation**, per app | Now Playing's fallback, for players the system service does not cover | at first use, per player | that player is not shown |
| **Contacts**, **Calendars** | _Later_: sources, if they are added | at first use | — |
| **Screen Recording** | minimised windows' pictures on the dock | the first time in a run the dock shows a minimised window, which needs Accessibility, or from Settings → Permissions; macOS prompts until it is answered | their tiles are blank windows in their shapes |
| **Input Monitoring** | never: dock2 has the keyboard whenever it needs keys | — | — |

Settings → Permissions shows each one's state and opens its pane in System Settings. Where macOS has a
prompt — Accessibility, Screen Recording, pasteboard access — it also asks, while the prompt will still come:
only a prompt lists dock2 in the pane. Full Disk Access has none, and dock2 is listed in its pane once it has
looked for it.

**Open:** where the dock says why it wants Screen Recording. Clipboard history says it in the notice its
first paste brings; the dock has no such place. Until one is designed, macOS's prompt comes alone, and
Settings → Permissions says why.
