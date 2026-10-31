# The dock

Built (`IMPLEMENTATION.md` §5). What is ahead:

- **Dark mode, measured again**: the dot, now that it can blend; the separator.
- **The sideline's next steps** ([dock](../product/dock.md#the-sideline)): dragging into and out of the puck
  needs a drop gap in two dimensions — a cell from a point, the cells after it moving on in fill order — where
  `DockLayout.insertionIndex` reads x alone; an app asking for attention needs a measurement first, of what the
  hidden system Dock's item exposes while its app bounces; the full-height puck is `SidelinePacking` with the
  cell sized so its tallest column fills the platter's rows.
