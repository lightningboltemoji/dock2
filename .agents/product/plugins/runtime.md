# Runtime

How a plugin runs. These are product decisions: they decide what a plugin author can write, and what a bad
plugin can do to dock2.

## The model

A plugin is an actor. dock2 delivers one event at a time; the plugin handles it, returns effects, and waits
for the next. All I/O — network, files, storage, secrets, the clipboard, programs, services — is an effect
dock2 performs, and its result comes back as a later event. Nothing a plugin calls blocks, and nothing calls
into it while it runs. The guest imports nothing that reaches out: a capability is effects and events, never
a function it calls.

| Events in | Effects out |
| --- | --- |
| started, with what it holds; stopped; settings or grants changed | show a view; update a view |
| a command run; a query typed (results on) | set a tile |
| an action chosen; a form submitted; a scope chosen | an HTTP request, whole or streamed; a WebSocket |
| a timer fired; a system event it subscribed to | storage: keys read, a range listed, a batch written whole; secrets: read, write |
| an HTTP response, or a part of one; a WebSocket's message; a storage or secrets result | files: read, list, write, watch |
| a file read or listed; a change in a folder it watches | a command run; a message to a service |
| a command's output, and its exit; a service's reply, or a message it sent | copy; open a URL or a file, or a link or a file in an app it names |
| | a toast; a timer |
| | a key derived from a password, by dock2: key derivation is slow by design, past any call's budget |
| | dock2 letting go, after a copy |
| | which of its commands Commands lists, as its state changes — signed in or not |

## Storage

A plugin's own, always allowed, kept on this Mac: string keys to string values, the keys in the order of their
UTF-8 bytes, so a prefix — `item/`, `meta/` — serves as a table of its own. A plugin reads several keys at once;
lists the keys under a prefix, every key for none, a page at a time, from past the last key of the page before,
forward or back, with their values or without; and writes a batch of sets, deletes and prefix deletes, applied in
order, all of them or none. The effects of one answer apply in the order given, so a read after a write sees it.
An index is the plugin's own keys — `by-date/<ts>/<id>` — written in the same batch as what it indexes: dock2 keeps
none for it. No query language reaches a plugin: SQL would put a dialect in the versioned interface and a
database's reach — attaching another file, its pragmas — in its hands, and a plugin, its store's one writer, needs
a batch to be atomic, not isolated.

| Limit | |
| --- | --- |
| a key | 1 KiB |
| a value | 24 MiB: a whole 16 MiB HTTP body, even as base64 |
| a plugin's storage | 256 MiB, an entry counting its key, its value and 16 bytes |
| a listed page | 1,000 entries or 4 MiB, and never empty: a value past it comes alone |

A write past one is refused whole, and the plugin hears why.

## Budgets

| Event | Time | Past it |
| --- | --- | --- |
| interactive — a query, an action | 50 ms | the call is interrupted; results due by then go to the end of their section |
| background — a timer, a response | 1 s | the call is interrupted |

Memory is capped per plugin. A plugin that traps or overruns is restarted with its stored state; one that
keeps failing is stopped until dock2 quits, new code is installed or Settings tries it again, and Settings
says why. Its switch stays on.

## The engine

wasmtime's Pulley interpreter: it interrupts a running call, caps memory, starts in a fraction of a
millisecond from a module compiled once and cached, and needs no executable memory — so no entitlement under
the hardened runtime, which its JIT would. WasmKit, a pure-Swift interpreter, cannot interrupt a running call.

## The interface

Versioned from the first release; a plugin declares the version it targets. A view is a tree, and WIT, the
component model's interface language, has no recursive types, so events, effects and views travel encoded.
JSON — readable, and enough at this size — with room for a binary encoding later.

## Languages

Rust first: an SDK crate with the event loop, builders for the components, and typed effects. TypeScript
next, since most extension authors write it: a JavaScript engine compiled to WebAssembly, inside the same
model (**Open:** which engine).

## For plugin authors

`dock2 plugin dev <folder>` installs a plugin from its folder, installs it again whenever it is rebuilt, and
streams its logs.
