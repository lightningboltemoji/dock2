# The panel

Everything above the dock: the field, and what grows out of it. One surface, at three sizes.

## Sizes

| Size | Height | When |
| --- | --- | --- |
| **the field** | the field alone | dock2 has the keyboard and nothing is typed |
| **results** | fits the results, up to a maximum (**Open:** eight rows), then scrolls at the far end | a query |
| **a view** | the maximum, always | a view is open |
| **Files** | its own, wider than search's (**Open:** 960 × 520 pt) | Files is open ([files](files/README.md)) |

A view's size never depends on its content, so a plugin lays out against a known canvas. The results' size
always does: two results never open a tall, empty panel.

## Geometry

The starting numbers are Spotlight's, on macOS 27 the nearest surface the system draws: a field of
640 × 57 pt, rows of 56 pt, a panel that grows to fit (467 pt for seven rows). A prototype tunes them
against the dock; then they are measured like the rest ([visual](visual.md)).

- **Width.** **Open:** fixed (640 pt, steady while apps launch and quit) or the dock's (one object, but one
  that changes with the dock). Fixed, until the prototype.
- **Placement.** Centred over the dock, the field's bottom 44 pt above the platter: room for a tile's label
  between them, 9 pt either side of it, so the echo's label never touches the field.
- **Corners.** The field alone is a capsule; grown, the panel's corners are continuous, like Spotlight's.

## Layout

Upward from the field:

1. **The field.** It never moves while you type.
2. **The top hit**, selected.
3. **The sections**, in their fixed order ([search](search/README.md)): Apps, Commands, Clipboard, Files,
   then each plugin's. A section's title sits above its rows, like a label over a stack.

↑ moves the selection away from the field, ↓ toward it. The least likely result is the furthest, and the
far end is what scrolls.

A row is an icon, a title, a subtitle (a path, a kind, a source app) and one accessory on the right: a state
("Running"), or on the selected row, the key of its primary action.

A query with no results shows one row saying so. A source still working after the first frame shows as a
spinner at the field's trailing edge, never as a placeholder row.

## Motion

- The field rises into place from below, as if from the bottom of the screen: it grows a little as it
  comes, and fades in from its middle outward, its ends last. Summoned with the dock away, it follows the
  dock up rather than leading it. It cannot part from the platter like a drop: glass merges only with glass
  of its own recipe, and the field's is Spotlight's, far frostier than the platter's.
- Results grow the panel upward; dismissal plays the rise back, quicker. What grows shows only inside the
  glass, never ahead of it: a view's or Files' contents fade in as the glass reaches them, and the glass
  frosts as it grows, clearing again when the panel is the field alone.
- Reduce Motion turns both into fades; Reduce Transparency turns the glass into a solid fill.
