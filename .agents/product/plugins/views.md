# Views

The components plugins build UI from. dock2 renders each one natively, in its own glass and type, with the
same keyboard behaviour everywhere.

## Components

| Component | Holds | Keyboard |
| --- | --- | --- |
| **List** | sections of items: an icon, a title, a subtitle, accessories (text, a tag, an icon), keywords; beside a preview, its rows are compact | ↑ ↓; typing filters; ↩, ⌘↩, ⌘K on the selection |
| **Detail** | a body of formatted text, and metadata rows (a label and a value, links, tags); a status line, short facts along its foot that stay while the body scrolls; a scrubber, a position to drag that submits where it is let go; also a list item's preview, beside the list | scrolls |
| **Form** | fields — text, secure text, multi-line text, toggle, choice, date, folder — with validation messages | Tab between fields; ⌘↩ submits |
| **Grid** | images or icons, with titles | the arrows; ↩, ⌘↩, ⌘K |
| **Actions** | per item or per view: a title, an icon, a shortcut, a destructive style | ⌘K lists them; the first is ↩, the second ⌘↩; dock2's own views bind ⌘⌫ to remove an item, which its row also offers as a × under the pointer |
| **Feedback** | a toast in the panel; a confirmation before a destructive action, answered by its buttons or ↩ and Esc; a brief notice after dismissal ("Copied") | — |
| **Tile** | on the dock: an image or an icon, a badge, a progress ring, a short caption, and a label for hover | a click, or ↩ with the ring on it |

An icon is drawn by where it stands ([packaging](packaging.md#icons)): in a view, a symbol is a glyph in its
tint and a picture is as it is; on a tile, as among apps' anywhere, a symbol stands on a square and a picture
fills one.

## Navigation

A view can push another; Esc pops it. A view with a list takes over the field as its filter. Loading shows
as the field's spinner; an empty list shows the plugin's empty state.

Filtering a list is dock2's by default: the plugin hands over every item, and dock2 matches them as search
does. A plugin whose items live elsewhere — on a server — asks for the query instead, and answers it.

## Shortcuts

↩, ⌘↩, ⌘K, ⌘1–9, ⌘,, ⌘W, Esc, the arrows and the text-editing keys are dock2's. A plugin binds its actions
to the remaining ⌘- and ⌘⇧-letter chords. A binding that clashes is not made — its action stays on ⌘K — and
the plugin's log says so; bindings arrive with views, so there is nothing to check at install.

## What a plugin cannot do

Choose its colours (beyond tints from a fixed palette), fonts, layout or sizes, or draw: there is no canvas
and no measuring of text. An image — album art, a chart rendered elsewhere — is the escape hatch. A plugin's
view is part of dock2's panel, and looks it.
