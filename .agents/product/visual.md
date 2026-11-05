# Visual

## Where the numbers come from

Every number in the dock was measured off the system Dock (`IMPLEMENTATION.md` §1). The panel has no twin in
the system, so its starting numbers come from the nearest surface macOS draws — Spotlight's, on macOS 27
([panel](panel.md)) — and its final ones from a prototype measured the same way: Accessibility frames,
screenshots, pixel profiles, in both appearances.

Every macOS release is measured again. Apple redraws these surfaces between releases, and a dock that was
right a release ago can be wrong now.

## The glass

The dock's own glass for the platter, the label and the badges; Spotlight's for the field, fitted against
it — the label's family, frostier and lighter than the platter's, with a sharp rim and the shadow
Spotlight's window casts. The field alone stays clear, to stay in the background. It is a capsule, or its
[form](panel.md#the-fields-form), the gem's marble clearer so its facets read through it; grown, the panel
has continuous corners. Plugin tiles sit on the platter as app tiles do. Text on the glass is drawn on it in
the system's label colours, never on a fill of its own.

## Glass on solid

Whatever grows from the field is read: a list of small names over a dark window or a white page, a view,
Files. So the grown panel is solid, a **ground**: the window's own material, opaque and faintly tinted by
the wallpaper, well under white in the light appearance. A **pane** of glass is laid on it over what
grew. Over a desktop that moves and changes, content stays still and legible, and the glass laid on it is
what makes it dock2's.

- **The field's strip of the ground is bare**, a bar: the field, or a screen's bar, sits on the ground
  itself.
- **The pane sits 6 pt in from the ground's edge**, its corners concentric with the panel's, its foot on the
  field's top. It is the system's own glass for a control, its sidebar search field's, and it has that field's body
  in both appearances: with nothing behind it to blur, it reads as a slab, by its edge. Its face stands above the
  ground and stays under white, so a light can show on it. A bright lip runs along its top and its foot, falling away
  softly inward and tapering out round its corners; its ends are a dark line and no light. It is lit from above: its
  shadow falls just inside its top edge and past its foot, the seam between the field and what grew. What is behind
  the panel never changes it.
- **Search's rows and every screen sit on the pane**: a view, Files, Quick Look. On it, content is drawn as
  in any window, in the system's controls. A screen's contents fade in as the glass reaches them.
- **A selection is let down through the pane to the ground**: the ground's own material in the selection's
  rounded shape, a well cut in the slab, as deep as the pane stands high: its top wall throws the shadow the pane
  throws past its foot, and a line of light runs along its foot. Where the list holds the keys among others
  that might, as in Files' columns, it goes a little past the ground, darker.
- **Glass over the pane is chrome over content**, as a menu over a window: the bar's menu floats over it, and
  bends what is under it.
- **A toast is a piece of the grown panel**: a capsule of the ground with a pane laid on it, over the panel's
  shadow. It stays off the content: it floats 6 pt above the panel, as far as the pane sits inside it, and
  rides its top edge as the panel grows and shrinks, in step with it; with the field alone, it rests above the
  field.
- Reduce Transparency fills the pane as solid as the ground, and Increase Contrast borders both.

## The dock's style

Liquid Glass, or **Snow Leopard**: the Dock of Mac OS X 10.6, as a throwback. It was measured off a
screenshot of that Dock, as the glass was measured off macOS 27's.

- The icons stand on a shelf in perspective, which mirrors them and the screen above it.
- A blue light glows under each running app.
- A dashed lane runs across the shelf for a separator.
- dock2's own marks mean the same on it. The panel is Liquid Glass in both styles: it is dock2's own surface.

**Open:**

- Snow Leopard's label and badges, which no screenshot shows. Until one does, they are the glass's.
- The icons' size. Today's icons fill 80% of their tile, where Snow Leopard's filled 86–96%. Until decided,
  they are drawn as the apps ship them, standing on the shelf as Snow Leopard's did.

## dock2's own marks

| Mark | Look |
| --- | --- |
| the ring | the system Dock's keyboard focus (⌃F3): the icon darkened to 48%, as a press darkens it, and its label |
| the echo | the ring, and the tile's label |
| the selection | a rounded band across the row, let down through the pane to the ground ([glass on solid](#glass-on-solid)) |
| tile numbers | the digit alone, which replaces the running indicator: semibold, in the dot's ink, and small enough to stay out of the way, on the flat of the band the glass refracts along the platter's foot. It comes out of the dot on a spring, up and a little past its size and place, and drops straight back in; under Reduce Motion it fades where it stands. On the shelf, white, on the light's core |
| an app's badge | the system Dock's, but never under 16pt across, where its label still reads: the Dock's goes down to 6pt on the smallest tiles. A small badge grows from the Dock's badge's centre, past the icon's corner |
| the sideline's puck | a second piece of the platter's glass to its right, hugging its rows of smaller tiles ([dock](dock.md#the-sideline)) |
| a minimised window | the system Dock's tile: the window as it was minimised, in its shape, the app's icon in the corner; without Screen Recording, a blank window in that shape — title bar, buttons |
| Files' rows | **Open:** denser than search's 56 pt — the system's own list density, measured |
| progress on the Finder tile | the system Dock's own progress, measured |

## Layout

What sits on the panel stands on one grid, so the field, search's rows, a view and Files line up with one
another however they change.

- **A 4 pt unit.** Every inset, gap and row on the pane is a whole number of them. The ground's rim outside
  it, 6 pt, is tuned by eye: at 8 pt it looks off.
- **Each layer nests in the one beneath, concentric**: the ground, the pane 6 pt in from it, a row's band 8 pt
  in from the pane, their corners 28, 22 and 14 pt, each the one outside it less the gap.
- **A row's icon stands in a square as tall as the row**: as far from the band's side, and from the text, as
  from the band's top and bottom. Search's rows are 56 pt, the icon's plate 32 pt; a list beside a preview has
  36 pt rows and 20 pt plates.
- **Two lines run up the panel** from the field, its bottom row: the **glyph line**, 42 pt in, on which the
  icons and the field's magnifier are centred, and the **text line**, 70 pt in, where titles and the field's
  text start.
- **The margin is the same at both edges**, 26 pt in: icons and sections' titles start on it, and rows'
  trailing text and marks, and the bar's pill, stop on it.
- **What shows is placed, not its frame**: a symbol by its ink, a line of text from where it starts, the
  field's capitals centred on its midline.
- **Four sizes of type**: 22 pt for the field, 16 pt for a row's title, 13 pt for subtitles and details, 12 pt
  semibold for a section's title.
- **A divider runs edge to edge** across what it divides: between a list and its preview, between Files'
  columns, over a detail's status.

**Open:** Files' rows, which keep Finder's measured density rather than the grid's.

## Icons among apps

Wherever an icon stands with apps' — search's rows, the dock, Settings → Plugins — it is an object the size of
theirs, never a bare glyph. An app's or a file's icon is the system's own. Any other stands on Icon Composer's
plate for an empty icon, the Finder tile's ([icon](files/icon.md)), as much of its image as an app icon's plate
is: in search's 56 pt rows, 32 pt, as the app icons beside it measure.

- **A symbol** is white on the plate, filled where it has a fill, with Icon Composer's shadow under a layer.
  Every symbol is one size, so SF Symbols' own balance holds; one far wider than the rest — play/pause — is drawn
  smaller rather than past the plate's edge.
- **A picture** fills the plate's shape, its corners rounded off; the plate shows wherever it is clear.
- **The colour** says whose it is. Violet, the app icon's, is dock2 about itself: Settings, Toggle Auto-hide. A
  thing dock2 does has a colour of its own: Clipboard History is orange, the calculator's answer blue. Quit is red, the exception. A plugin's
  are its tint ([packaging](plugins/packaging.md#icons)), one of the eight a view can name, which violet is not.

In a view — a list's rows, the grid, actions, accessories — a symbol is a glyph, in its tint or the text's
colour, and a picture is drawn as it is; in a list's row either is as large as an app icon's plate beside it.
"Show all…" is search's, and wears search's icons.

**Open:** a clip in search, whose row shows a glyph for its kind; a colour's could show the colour, a text's
its source app. And the system's Dark, Clear and Tinted icon styles, as for the Finder tile
([design](../design/files.md#the-tiles-icon)).

## The app icon

A 2 whose foot is the dock. It is Inter's numeral with its base bar replaced by a platter of four tiles, drawn
to the Dock's proportions. The diagonal runs into the platter's left end, and the platter runs just past the
bowl. It is one body of Liquid Glass on a violet plate, with the system's dark plate in dark mode. It has to
read at 16 px: dock2 has no Dock tile, so its icon is mostly seen small, in Finder, Spotlight and the privacy
lists in System Settings.

## Motion

The reveal and the hide are the system Dock's slide, measured. The entrance is dock2's own: coming in from
all the way away, the tiles pop onto the platter with a light bounce, in a wave from wherever the dock was
called, and the field rises into place above them, growing a little and fading in from its middle outward.
A form becomes the field, and the field the form, on springs of its own.
Results grow the panel upward on a spring of dock2's own, a little past and back, and its rows move, fade in
and fade out as they change rather than redraw; dismissal plays the rise back, quicker. The sideline moves on
springs of the same kind: an app's tile crossing to the puck or back hops over the tiles between, as the puck
buds out of the platter, a little past its size and back, and draws back in without passing it. Only the
entrance, and the sideline's springs settling, run longer than the Dock's own reveal.

## The system's display settings

Reduce Motion: fades instead of slides and morphs. Reduce Transparency: solid fills. Increase Contrast: the
system's borders. Under any of the three, the field is the capsule, whatever its form. On Snow Leopard's shelf,
Reduce Transparency takes away its reflection of the screen, and Increase Contrast outlines it.
