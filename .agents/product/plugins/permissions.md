# Plugin permissions

A plugin reaches nothing outside itself unless the user granted it. Its manifest declares each capability
with what it reaches and why it asks; installing shows them in plain words, each with a switch
([asking](#asking)); an update that reaches further asks again. Settings → Plugins shows every grant with its
reason, and revokes any of them at once: what a capability holds open — a stream, a connection, a process —
ends with it. The settings file keeps what was revoked, so a capability an update adds is granted once agreed
to, and one revoked stays revoked.

## Capabilities

| Capability | Grants | Shown as |
| --- | --- | --- |
| `network` | HTTPS to the hosts it names, or `*` for any; a host may come from one of its settings, for a self-hosted server. A response may stream, and a WebSocket stays open | "Connects to api.bitwarden.com" · "Connects to any website" |
| `local-network` | HTTP to the hosts and ports it names on this Mac or the local network, and over the Unix sockets it names | "Connects to localhost:11434" |
| `query` | what is typed in search, so that it can answer with results | "Sees what you type in dock2's search" |
| `clipboard.write` | copying, and marking a copy concealed | "Copies to the clipboard" |
| `clipboard.read` | _Next_: the clipboard history | "Reads your clipboard history" |
| `paste` | pasting into the app in front, through dock2's Accessibility | "Pastes into other apps" |
| `secrets` | Keychain items of its own | "Stores secrets in your Keychain" |
| `files` | the folders the user picks for its folder settings: to read, or to read and write; and their changes as they happen | "Reads files in ~/Notes" |
| `apps` | opening links of the schemes it names, and files in the apps it names, in answer to an action | "Opens zed: links" · "Opens files in Zed" |
| `xpc` | messages to the XPC services it names, each signed by the team it names ([services](#services)) | "Talks to com.example.agent, signed by ABCDE12345" |
| `run` | the commands it declares ([commands](#commands)) | "Runs /usr/bin/git -C ‹folder› status --porcelain" |
| `now-playing` | the system's now-playing information and controls, through dock2 | "Sees and controls what is playing" |

Each comes with the plugin's reason, a sentence of its own, shown under dock2's line and as the plugin's —
"Bitwarden says: …" — never in its place: dock2's line is what it enforces, the reason what the plugin claims.
A capability without a reason refuses the install.

Always allowed: its own storage, opening a web page or a document in answer to an action — never an app,
an executable or a script, which would run a program — showing a view, toasts, timers. A view brings dock2
up only in answer to something the user did — an action, or the answer to a request one made — and any
other shows only while dock2 is in use, since nothing a plugin does on its own takes the keyboard.
`clipboard.read` is a name reserved for effects still to come; a manifest may declare it, and it grants
nothing yet. _Later_: Apple Events, to the apps it names.

## Commands

A command is a program, by its absolute path, and its arguments. An argument is fixed, or a slot the plugin
fills as it runs the command: `{text}`, `{path}`, `{folder}`. A slot is one argument, never read by a shell,
and never one that starts with `-`; a path or a folder is one inside a folder the user picked for one of its
folder settings. The plugin names the command and its slots' values; it never writes a command line.

The arguments are declared so that the manifest, not the code, says what may run — an update that changes
a command asks again — and so that nothing the plugin is handed, a query or a server's answer, becomes a
command. They bound the invocation, not what the program does with it: `git status` runs what a
repository's config names. dock2 says what runs, and never that it is safe.

A command with any arguments, `"args": "*"`, is the escape: shown as "Runs /bin/zsh with any arguments — it
can do anything you can", off until the user switches it on, and with it the plugin's other switches limit
only what it does through dock2. A command whose slot reaches a folder the plugin may also write is shown
the same way, since the program may run what the plugin put there.

Every program a plugin runs answers to macOS for itself — never with dock2's Accessibility, Full Disk Access
or Screen Recording; asking for its own. It runs with a minimal environment, what it prints comes back as it
prints it, and it ends when its time is up, its capability is revoked or its plugin stops. A command may name
the team its program is signed by, and then runs only while it is.

## Services

A service is reached by its Mach name, and only while it is signed by the team the manifest names; Apple's
are refused. It hears dock2, which is what connects, so dock2 sets the plugin's id on every message: the
service can tell plugins apart, and trust which one speaks. Messages are XPC dictionaries, as are its
replies and what it sends unasked. _Next_: a service that speaks NSXPCConnection, through one protocol dock2
compiles in — a dictionary in, one back.

## Asking

Installing shows a sheet: the plugin — its icon, name, author, where it came from — and a row for each
capability, with dock2's line, the plugin's reason and a switch. Every switch starts on but a command with any
arguments. What is switched off is revoked before the plugin first runs. Switching a first-party plugin on
for the first time shows the same sheet. An update asks again only when it reaches further — a capability, a
host, a socket, a folder, an app, a service or a command added, or a command's arguments changed — and
shows what is new, the rest as it was. `dock2 plugin install` asks the same, in text. A plugin hears what it
holds as it starts and whenever that changes, so it can say what it is missing.

## Never

- Running a program except as a command it declares: no shell behind one, nothing it composes.
- Lending dock2's own access: a program it runs answers to macOS for itself, and a service it talks to is
  told which plugin speaks.
- Apple's XPC services.
- Reading the screen, another plugin's data or secrets, or another app's windows.
- Sending keystrokes or clicks.
- Seeing what is typed in search without `query`, or the clipboard without `clipboard.read`.

A command with any arguments runs as the user, and so reaches past this list — through the program, never
through dock2 — and says so ([commands](#commands)).

## Trust

First-party plugins ship inside dock2, off until the user switches them on, and hold what their manifests
declare, shown in Settings like any other's. _Next_: plugins from a registry, signed, under the same grants; until then a plugin installed from
a folder is marked as one.
