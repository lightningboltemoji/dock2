# Runtime

How a plugin runs. These are product decisions: they decide what a plugin author can write, and what a bad
plugin can do to dock2.

## The model

A plugin is an actor. dock2 delivers one event at a time; the plugin handles it, returns effects, and waits
for the next. All I/O — network, storage, secrets, the clipboard — is an effect dock2 performs, and its
result comes back as a later event. Nothing a plugin calls blocks, and nothing calls into it while it runs.

| Events in | Effects out |
| --- | --- |
| started; stopped; settings changed | show a view; update a view |
| a command run; a query typed (results on) | set a tile |
| an action chosen; a form submitted | an HTTP request |
| a timer fired; a system event it subscribed to | storage and secrets: read, write |
| an HTTP response; a storage or secrets result | copy; open a URL or a file |
| | a toast; a timer |
| | a key derived from a password, by dock2: key derivation is slow by design, past any call's budget |
| | dock2 letting go, after a copy |
| | which of its commands Commands lists, as its state changes — signed in or not |

## Budgets

| Event | Time | Past it |
| --- | --- | --- |
| interactive — a query, an action | 50 ms | the call is interrupted; results due by then go to the end of their section |
| background — a timer, a response | 1 s | the call is interrupted |

Memory is capped per plugin. A plugin that traps or overruns is restarted with its stored state; one that
keeps failing is switched off, and Settings says why.

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
