# Packaging

A plugin is a folder, `<id>.dock2plugin`: a manifest, a WebAssembly module, and its assets.

## The manifest

`manifest.json`:

| Field | Holds |
| --- | --- |
| `id` | reverse-DNS, unique |
| `name`, `description`, `author` | as Settings shows them |
| `icon`, `tint` | its icon and its colour ([icons](#icons)) |
| `version` | a semantic version |
| `api` | the interface version it targets ([runtime](runtime.md)) |
| `module` | the `.wasm` file |
| `capabilities` | what it may reach ([permissions](permissions.md)) |
| `commands` | each: an id, a title, a subtitle, an icon, keywords, whether it opens a view, whether it waits hidden until the plugin lists it |
| `results` | whether it answers search, the shortest query it wants, its section's title |
| `tiles` | each: an id, a title, whether it is on the dock by default |
| `settings` | each: an id, a title, a kind (text, secure text, toggle, choice, number, folder), a default |

## Icons

A plugin chooses what its icons are; dock2 chooses how they are drawn, by where they stand
([visual](../visual.md#icons-among-apps)).

- **`icon`** is the plugin's own: in Settings, and worn by a command or result of its that names none. Without
  one, a puzzle piece.
- **`tint`** is its colour: red, orange, yellow, green, blue, purple, pink or gray, the eight a view can name.
  dock2's violet is not among them. Without one, gray.

An icon is one of three things:

| | As JSON | Among apps' — search, the dock, Settings | In a view |
| --- | --- | --- | --- |
| a symbol | `{"symbol": "forward", "tint": "pink"}` | white on a square in its tint, else the plugin's | a glyph in its tint, else the text's colour |
| a picture | `{"png": "<base64>"}`; in the manifest, `{"image": "icon.png"}`, a PNG in its folder | fills the square, its corners rounded off | as it is |
| an app's or a file's | `{"app": "com.bitwarden.desktop"}`, `{"file": "/path"}` | the system's own | the system's own |

A picture is square and edge to edge, with no corners, margin or shadow of its own: those are dock2's, so
every icon among apps' matches. An `image` outside the folder, or not a `.png`, refuses the install.

## Installing

- First-party plugins ship inside dock2, switched off.
- Any other is a folder, installed from Settings → Plugins → Install, or with
  `dock2 plugin install <folder>`. Installing shows its capabilities and asks.
- Its code goes in `~/Library/Application Support/dock2/Plugins/<id>/`, its storage in
  `PluginData/<id>/` beside it, its secrets in the Keychain under dock2's service and its id — all on this
  Mac. The choices made about it are the settings file's (`[plugins."<id>"]`), so installing it on another
  Mac that shares the file brings them along.
- Updating is installing a newer version. Removing deletes the code, the storage and the secrets, and
  leaves its choices in the file: another Mac may still have it installed.

_Next_: a registry, signed packages, updates.
