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

## Budgets

| Event | Time | Past it |
| --- | --- | --- |
| interactive — a query, an action | **Open:** 50 ms | the call is interrupted; results due by then go to the end of their section |
| background — a timer, a response | **Open:** 1 s | the call is interrupted |

Memory is capped per plugin. A plugin that traps or overruns is restarted with its stored state; one that
keeps failing is switched off, and Settings says why.

## The engine

**Open.** It must interrupt a running call, cap memory, start fast, and be maintained. wasmtime does all four
(epoch interruption; compiled just in time or ahead of time); WasmKit, a pure-Swift interpreter, cannot
interrupt a running call. wasmtime, until a spike settles its size, its start time, and whether it runs
under the hardened runtime's JIT entitlement or compiles plugins ahead of time at install.

## The interface

Versioned from the first release; a plugin declares the version it targets. A view is a tree, and WIT, the
component model's interface language, has no recursive types, so events, effects and views travel encoded.
**Open:** JSON first — readable, and enough at this size — with room for a binary encoding later.

## Languages

Rust first: an SDK crate with the event loop, builders for the components, and typed effects. TypeScript
next, since most extension authors write it: a JavaScript engine compiled to WebAssembly, inside the same
model (**Open:** which engine).

## For plugin authors

_Next_: `dock2 plugin dev <folder>` loads a plugin from its folder, reloads it whenever it is rebuilt, and
streams its logs.
