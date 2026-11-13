# Icons

Built (`IMPLEMENTATION.md` §5 and §12, [icons](../product/icons.md)): a catalog drawn through a shim bundle, checked
with `assetutil`, `[icons]`, the one resolver, Settings → Icons. What is ahead is the system's other icon styles for
Cairo's pictures, and the product's _Next_.

## Pictures in the other styles

- **Reading the style.** On this Mac the global domain holds only `AppleIconAppearanceTintColor`
  (`Graphite`); the style itself is written nowhere dock2 has looked. Switch it in System Settings and read
  what changes, rather than guess a key.
- **Their plates.** Icon Composer's Dark, Clear (light and dark) and Tinted plates come out pixel-identical
  whatever the fill, so each is one more reference in `Resources/Plates`, drawn as it is, with no blend.
  Tinted follows the system's tint, which `ictool` takes as `--tint-color` and `--tint-strength`: a
  reference per tint, or one recoloured — **Open:** which, once the tint's values are read.
- **The picture in Dark** takes a lighter tint of the colour (orange's `(230, 115, 38)` gave about
  `(255, 173, 95)` at its brightest) and is shaded top to bottom, where Default's is flat white. **Open:** the
  rule, fitted against `ictool`'s renders as the shadow was, and what a filled picture's black and white
  become there.

## Open

- **The style switched while dock2 runs**: whether `NSWorkspace`'s icons change, and whether dock2 draws them
  again — not measured for apps' own icons either.
- **Tinted** (the _Next_ strip): `ISBundleIcon` and an `ISImageDescriptor` drew a shim in Default, Dark and
  Clear, light and dark, through `appearance` and `appearanceVariant`; its `tintColor` given a `CGColor` threw
  (`-[__NSCFType digest]`). What type it takes.
- **A file replaced in place** (_Next_): `[icons]` names it by path and is read again only when it changes, so a new
  catalog at the same path waits for a relaunch. Watching each named file, as `SettingsStore` watches its own, would
  hash it again on a change.
- **An Icon Composer icon in four styles beside its well** (_Next_): the `ISImageDescriptor` route above, once
  Tinted's colour is known.
