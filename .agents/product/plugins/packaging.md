# Packaging

A plugin is a folder, `<id>.dock2plugin`: a manifest, a WebAssembly module, and its assets.

## The manifest

`manifest.json`:

| Field | Holds |
| --- | --- |
| `id` | reverse-DNS, unique |
| `name`, `description`, `icon`, `author` | as Settings shows them |
| `version` | a semantic version |
| `api` | the interface version it targets ([runtime](runtime.md)) |
| `module` | the `.wasm` file |
| `capabilities` | what it may reach ([permissions](permissions.md)) |
| `commands` | each: an id, a title, a subtitle, an icon, keywords, whether it opens a view, whether it waits hidden until the plugin lists it |
| `results` | whether it answers search, the shortest query it wants, its section's title |
| `tiles` | each: an id, a title, whether it is on the dock by default |
| `settings` | each: an id, a title, a kind (text, secure text, toggle, choice, number, folder), a default |

## Installing

- First-party plugins ship inside dock2, switched off.
- Any other is a folder, installed from Settings → Plugins → Install, or with
  `dock2 plugin install <folder>`. Installing shows its capabilities and asks.
- Its code goes in `~/Library/Application Support/dock2/Plugins/<id>/`, its storage in
  `PluginData/<id>/` beside it, its secrets in the Keychain under dock2's service and its id.
- Updating is installing a newer version. Removing deletes the code, the storage and the secrets.

_Next_: a registry, signed packages, updates.
