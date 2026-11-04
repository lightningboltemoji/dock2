# Plugins

Built (`IMPLEMENTATION.md` §11), every capability of [permissions](../product/plugins/permissions.md) included
(`changes/1793764149.md` to `changes/1793766656.md`). What is ahead:

- **Now Playing's fallback**: Apple Events to Music and Spotify, asked per player, when the helper finds nothing.
- **Signing and a registry** (_Next_ in the product).
- **TypeScript** through a JavaScript engine compiled to WebAssembly (_Next_ in the product).
- **NSXPCConnection** (_Next_ in the product): `NSXPCInterface` refuses a protocol built at runtime ("Unable to
  get extended method signature from Protocol data … Use of clang is required for NSXPCInterface"), measured
  with `objc_allocateProtocol` against a compiled protocol of the same method that answered. So one compiled
  protocol, `Dock2Service`: a dictionary in, one back, beside `xpc`'s dictionaries.
- **A first-party plugin that a new dock2 makes reach further** asks nothing while it is on, since nothing
  installs it. `PluginData/<id>/agreed.json` holds the reach to compare against; the sheet would show at launch,
  or at the next summon, for what is new.
- **The sheet's note for `files`** says macOS may ask whatever folder is chosen. `FileAccess` knows whether the
  chosen folder is one macOS guards and whether Dock2 may already read it.
- _Later_: when each capability was last used, which the host sees, under its switch in Settings; `ws://` and
  HTTPS with a device's own certificate on the local network.
