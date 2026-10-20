# Views

The components plugins build UI from. dock2 renders each one natively, in its own glass and type, with the
same keyboard behaviour everywhere.

## Components

| Component | Holds | Keyboard |
| --- | --- | --- |
| **List** | sections of items: an icon, a title, a subtitle, accessories (text, a tag, an icon), keywords | ↑ ↓; typing filters; ↩, ⌘↩, ⌘K on the selection |
| **Detail** | a body of formatted text, and metadata rows (a label and a value, links, tags); also a list item's preview, beside the list | scrolls |
| **Form** | fields — text, secure text, multi-line text, toggle, choice, date, folder — with validation messages | Tab between fields; ⌘↩ submits |
| **Grid** | images or icons, with titles | the arrows; ↩, ⌘↩, ⌘K |
| **Actions** | per item or per view: a title, an icon, a shortcut, a destructive style | ⌘K lists them; the first is ↩, the second ⌘↩ |
| **Feedback** | a toast in the panel; a confirmation before a destructive action; a brief notice after dismissal ("Copied") | — |
| **Tile** | on the dock: an image or an icon, a badge, a progress ring, a short caption, and a label for hover | a click, or ↩ with the ring on it |

## Navigation

A view can push another; Esc pops it. A view with a list takes over the field as its filter. Loading shows
as the field's spinner; an empty list shows the plugin's empty state.

Filtering a list is dock2's by default: the plugin hands over every item, and dock2 matches them as search
does. A plugin whose items live elsewhere — on a server — asks for the query instead, and answers it.

## Shortcuts

↩, ⌘↩, ⌘K, ⌘1–9, ⌘,, ⌘W, Esc, the arrows and the text-editing keys are dock2's. A plugin binds its actions
to the remaining ⌘- and ⌘⇧-letter chords; a plugin whose own bindings clash is refused at install.

## What a plugin cannot do

Choose its colours (beyond tints from a fixed palette), fonts, layout or sizes, or draw: there is no canvas
and no measuring of text. An image — album art, a chart rendered elsewhere — is the escape hatch. A plugin's
view is part of dock2's panel, and looks it.
