# Views

The components plugins build UI from. dock2 renders each one natively, on the panel's
[pane](../visual.md#glass-on-solid) and in its own type, with the same keyboard behaviour everywhere.

## Components

| Component | Holds | Keyboard |
| --- | --- | --- |
| **List** | sections of items, read from the top: an icon, a title, a subtitle, accessories (text, a tag, an icon), keywords; beside a preview, its rows are compact | ↑ ↓; typing filters, its best match selected; ↩, ⌘↩, ⌘K on the selection |
| **Detail** | a body of formatted text, and metadata rows (a label and a value, links, tags, or a masked secret — a password — drawn as a mask of fixed length, the secret never sent); a status line, short facts along its foot that stay while the body scrolls; a scrubber, a position to drag that submits where it is let go; also a list item's preview, beside the list | scrolls |
| **Form** | fields — text, secure text, multi-line text, toggle, choice, date, folder — with validation messages; a form longer than the view scrolls | Tab between fields, the one with the keys kept in view; ⌘↩ submits |
| **Grid** | images or icons, with titles | the arrows; ↩, ⌘↩, ⌘K |
| **Scope** | on a list or a grid: which of its items it shows, as options in sections — each a title and an icon — and the one chosen | ⌘P, or its pill, opens its menu; the arrows and ↩ choose |
| **Actions** | per item or per view: a title, an icon, a shortcut, a destructive style | ⌘K, or the bar's Actions, lists them; the first is ↩, the second ⌘↩; dock2's own views bind ⌘⌫ to remove an item, which its row also offers as a × under the pointer |
| **Feedback** | a toast just above the panel; a confirmation before a destructive action, answered by its buttons or ↩ and Esc; a brief notice after dismissal ("Copied") | — |
| **Tile** | on the dock: an image or an icon, a badge, a progress ring, a short caption, and a label for hover | a click, or ↩ with the ring on it |

An icon is drawn by where it stands ([packaging](packaging.md#icons)): in a view, a symbol is a glyph in its
tint and a picture is as it is; on a tile, as among apps' anywhere, a symbol stands on a square and a picture
fills one.

A tag is one line, at most 240 pt, its text ending in an ellipsis past that. Tags stand 6 pt apart, side by side or a line
apart. In a row, the words and what stands at the row's end share its width, and the two never meet: the end takes all the
words leave and half the row whatever they take, the title and subtitle cut to make way, and tags past that give way to a
count of the rest, "+3". In a detail, tags wrap and none is left out, so a list beside a preview can repeat there what its
rows have no room for.

## The bar

Along a view's foot, at the field's trailing end, its bar: one pill of glass, "Actions ⌘K" — in a form,
which has no actions, its submit with ⌘↩ instead. Clicked, or on ⌘K, the pill grows up into a menu over the
view, its label giving way to the selection's actions, then the view's own, each with its key, while the
view fades back behind it. The arrows, ↩ and an action's own key work in it; Esc, ⌘K or a click
elsewhere closes it back into the pill, and typing closes it and goes to the field. Keys are dock2's to say,
in the bar, its menu and Settings, so a view never describes its own, nor masks a secret with dots of its
own.

## Scope

A list or a grid can have a scope: which of its items it shows — Local, Remote, one server of several. Along the
panel's top runs a bar of the ground, as the field's runs along its foot, and at its trailing end one pill of glass
saying the option chosen, its icon before it and ⌘P after. Clicked, or on ⌘P, the pill grows down into a menu of every
option, by section, a check on the one chosen; the arrows and ↩ choose, and Esc, ⌘P or a click elsewhere closes it, as
the bar's menu does. One of the two is open at a time.

dock2 shows the choice at once and tells the plugin, which answers with the items the option leaves and the scope saying
it — at once from what it holds, or later from a server, loading meanwhile. The field filters what the scope leaves, and
a new scope selects its first item, as a new query does. The panel grows by the bar, so the view keeps its size: a
plugin lays out against the same pane with a scope or without one.

## Navigation

A view can push another; Esc pops it. A view's id names it for as long as it is open: an update names the
view it redraws by that id, and may change its kind in place — a sign-in form becomes the list it opens. A view with a list takes over the field as its filter. A view reads from the top: its
first item there and selected, whatever the field holds, since a list in a view often has an order of its
own — A to Z — that search's bottom-up reading would turn over. Loading shows as the field's spinner; an
empty list shows the plugin's empty state.

Filtering a list is dock2's by default: the plugin hands over every item, and dock2 matches them as search
does. A plugin whose items live elsewhere — on a server — asks for the query instead, and answers it.

## Shortcuts

↩, ⌘↩, ⌘K, ⌘P, ⌘1–9, ⌘,, ⌘W, Esc, the arrows and the text-editing keys are dock2's. A plugin binds its actions
to the remaining ⌘- and ⌘⇧-letter chords. A binding that clashes is not made — its action stays on ⌘K — and
the plugin's log says so; bindings arrive with views, so there is nothing to check at install.

## What a plugin cannot do

Choose its colours (beyond tints from a fixed palette), fonts, layout or sizes, or draw: there is no canvas
and no measuring of text. An image — album art, a chart rendered elsewhere — is the escape hatch. A plugin's
view is part of dock2's panel, and looks it.
