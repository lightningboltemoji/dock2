# Icons

dock2 draws every tile's icon, so it can give one another without touching the app. Each tile wears its own
icon until the user gives it one of Cairo's pictures or an Icon Composer icon. The Files tile's own is
Finder's. Everywhere else on the Mac — Finder, ⌘⇥, Launchpad — an app keeps its own.

- **Wherever dock2 shows the app as an app**: its tile, on the dock or the puck; a minimised window's corner;
  search's app rows; Open With; a plugin's view that names it. Where dock2 shows it as a file — a row in Files,
  a file in search — it is what Finder shows, since the bundle has not changed.
- **A file that goes missing**, or stops being an icon dock2 takes, leaves the tile its own icon, and Settings
  lists the line ([settings](settings.md#the-file)).

## Cairo's pictures

One of Cairo's pictures — the palm tree, the dog, the TV — filled black and white, or white alone, on a
colour the user chooses, as a macOS icon of Liquid Glass.

- **A grid** of them, each drawn as the tile would wear it, like with like — flowers, trees, fruit, animals —
  a colour well, and the fill. The tile changes as any of them does.
- **Any colour**: the colour well's whole range, never a palette. Going back to the tile's own icon keeps the
  colour for the next picture while Settings is open.
- **Fill**, a toggle under the colour, on until switched off: the picture's ink is black and what it
  encloses white — the strawberry's body, the TV's screen, the inside of a ring — as Cairo drew them, black
  on white paper. What encloses nothing, the cross or the waves, is black alone. Inside is whatever paper
  cannot reach the picture's edge through a side; no picture is filled by hand. Off, the ink is white.
- **Cairo's own pixels**: 59 of its pictures, chosen by eye — no arrows, no train, none of the circuit
  symbols but the resistor. At every tile size each of Cairo's pixels covers a whole number of the
  screen's, so a picture stays crisp; its size steps as the tile grows rather than following it smoothly. On
  the smallest tiles, with no room for a pixel apiece, it is scaled down.
- **Icon Composer's look.** The plate, its rim and its shading are Icon Composer's own, and the picture sits
  on it as Icon Composer draws a layer — white or filled, with its shadow — so the tile reads as one of the
  dock's icons rather than a picture pasted on.
- **Open:** the system's icon style — Dark, Clear, Tinted — which every app's icon follows. In Dark the
  picture takes the colour, on the system's dark plate; Clear and Tinted ignore the colour, as they do every
  app's. Until dock2 can read which style is chosen, a picture is Default's.

## Icon Composer's icons

- **Compiled**: an asset catalog, `.car`, as `actool` builds from `.icon` documents and every app made for
  Liquid Glass ships one. dock2 draws it as macOS draws an app's own — the glass, Dark, Clear and Tinted, at
  every size — so it stands among the others as one of them.
- **A pack**: one catalog can hold many icons, each named for the `.icon` document it was built from, since
  `actool` takes several at once. An entry names which; a catalog of one icon needs no name.
- **Nothing else** is refused: an image, an `.icns`, an `.icon` document, or a catalog whose icon is flat, as
  apps made before Liquid Glass ship.

## The file

```toml
[icons]
files = { picture = "strawberry", color = "#D87087" }
"com.apple.Safari" = "icons/safari.car"
"com.mitchellh.ghostty" = { file = "icons/pack.car", name = "ghostty" }
"com.google.Chrome" = { file = "icons/pack.car", name = "chrome" }
"com.apple.Notes" = { picture = "pear", color = "#34C759", filled = false }
```

- **Keyed as `pinned` is** — a bundle identifier, or the path of an app without one — and `files` for the
  Files tile, which no app's key can be.
- **A string is a catalog of one icon**, and `{ file, name }` one icon of a pack. A path is relative to the
  settings file's folder — through a link, the folder of the file it leads to — so an `icons/` folder beside
  it travels with it in a dotfiles repo. `~` and absolute paths work too.
- **`{ picture }` is one of Cairo's pictures**: its `color` `#6A5CD8`, dock2's own violet, and `filled` true,
  unless it says.
- **Giving a tile its own icon back takes its line out.** A file it named stays.

## The section

Icons sits under Dock in Settings' sidebar: the Files tile, then the apps on the dock in its order — pinned,
running, sidelined — then any other the file gives an icon, each a row with its own icon and the one it wears.

- **A row's well** opens its choices: its own icon, Cairo's pictures with the colour well and Fill, and Choose
  File… for a compiled icon. A `.car` dropped on the well is chosen too.
- **A pack** opens a grid of its icons, each drawn as the tile would wear it, to pick one.
- **Choosing a file copies it** into `icons/` beside the settings file, under its own name, and the entry
  names the copy, so it travels with the settings and an emptied Downloads folder takes nothing. A pack is
  copied once, however many tiles wear its icons; a file already beside the settings is named where it is.
- **A file that is not an icon dock2 takes** is refused as it is chosen, saying why.
- **Other App…** adds an app that is not on the dock.
- **From the dock**: a tile's menu has Change Icon…, which opens Icons at its row, the choices open.

_Next_: an Icon Composer icon shown in Default, Dark, Clear and Tinted beside its well, as macOS would draw
it. A file replaced in place read again without its line changing.

_Later_: a pack applied at once, each icon to the app its name is the bundle identifier of.
