# Plugin permissions

A plugin reaches nothing outside itself unless the user granted it. Its manifest declares capabilities;
installing shows them in plain words; an update that adds one asks again. Settings → Plugins shows every
grant, and revokes any of them.

## Capabilities

| Capability | Grants | Shown as |
| --- | --- | --- |
| `network` | HTTP to the hosts it names; a host may come from one of its settings, for a self-hosted server | "Connects to api.bitwarden.com" |
| `query` | what is typed in search, so that it can answer with results | "Sees what you type in dock2's search" |
| `clipboard.write` | copying, and marking a copy concealed | "Copies to the clipboard" |
| `clipboard.read` | the clipboard history | "Reads your clipboard history" |
| `paste` | pasting into the app in front, through dock2's Accessibility | "Pastes into other apps" |
| `secrets` | Keychain items of its own | "Stores secrets in your Keychain" |
| `files` | folders the user picks, to read or to read and write | "Reads files in ~/Notes" |
| `now-playing` | the system's now-playing information and controls, through dock2 | "Sees and controls what is playing" |

Always allowed: its own storage, opening a URL or a file in answer to an action, toasts, timers.

## Never

- Running programs. A plugin that would wrap a command-line tool uses the service's API instead.
- Reading the screen, another plugin's data or secrets, or another app's windows.
- Sending keystrokes or clicks.
- Seeing what is typed in search without `query`, or the clipboard without `clipboard.read`.

## Trust

First-party plugins ship inside dock2 and hold what their manifests declare, shown in Settings like any
other's. _Next_: plugins from a registry, signed, under the same grants; until then a plugin installed from
a folder is marked as one.
