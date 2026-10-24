# Files

Built (`IMPLEMENTATION.md` §9). What is ahead:

- **Verify without Full Disk Access** itself: search's access row; external and network volumes' prompts.
- **Put Back**: whether Finder's Put Back works for what dock2 trashes (`FileManager.trashItem`).
- _Later_, as the product says: Compress, tags, renaming many at once, operations needing a password.

## The tile's icon

Built in the Default style (`IMPLEMENTATION.md` §5, [icon](../product/files/icon.md)). What is ahead is the
system's other icon styles:

- **Reading the style.** On this Mac the global domain holds only `AppleIconAppearanceTintColor`
  (`Graphite`); the style itself is written nowhere dock2 has looked. Switch it in System Settings and read
  what changes, rather than guess a key.
- **Their plates.** Icon Composer's Dark, Clear (light and dark) and Tinted plates come out pixel-identical
  whatever the fill, so each is one more reference in `Resources/Plates`, drawn as it is, with no blend.
  Tinted follows the system's tint, which `ictool` takes as `--tint-color` and `--tint-strength`: a
  reference per tint, or one recoloured — **Open:** which, once the tint's values are read.
- **The picture in Dark** takes a lighter tint of the colour (orange's `(230, 115, 38)` gave about
  `(255, 173, 95)` at its brightest) and is shaded top to bottom, where Default's is flat white. **Open:** the
  rule, fitted against `ictool`'s renders as the shadow was.
