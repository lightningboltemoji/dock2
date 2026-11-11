//! The gallery: every screen, by kind, each with what it is there to show.

use crate::{details, feedback, forms, grids, lists, maximal, scopes, Screen};
use dock2_plugin::*;

pub const ID: &str = "gallery";

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    List,
    Detail,
    Form,
    Grid,
    Feedback,
    Maximal,
}

impl Kind {
    fn title(self) -> &'static str {
        match self {
            Kind::List => "Lists",
            Kind::Detail => "Details",
            Kind::Form => "Forms",
            Kind::Grid => "Grids",
            Kind::Feedback => "Actions and Feedback",
            Kind::Maximal => "Maximal",
        }
    }

    fn icon(self) -> Icon {
        match self {
            Kind::List => Icon::symbol("list.bullet").tint(Tint::Blue),
            Kind::Detail => Icon::symbol("doc.richtext").tint(Tint::Orange),
            Kind::Form => Icon::symbol("rectangle.and.pencil.and.ellipsis").tint(Tint::Green),
            Kind::Grid => Icon::symbol("square.grid.3x3").tint(Tint::Pink),
            Kind::Feedback => Icon::symbol("bubble.left").tint(Tint::Purple),
            Kind::Maximal => Icon::symbol("rectangle.compress.vertical").tint(Tint::Red),
        }
    }

    /// The manifest's command that opens the kind's first screen.
    pub fn command(self) -> &'static str {
        match self {
            Kind::List => "list",
            Kind::Detail => "detail",
            Kind::Form => "form",
            Kind::Grid => "grid",
            Kind::Feedback => "feedback",
            Kind::Maximal => "maximal",
        }
    }
}

pub struct Entry {
    pub id: &'static str,
    pub kind: Kind,
    pub title: &'static str,
    /// What it shows, in a line: the gallery's subtitle.
    pub summary: &'static str,
    /// What to look at, and what to try: the gallery's preview.
    pub covers: &'static str,
    pub make: fn() -> Box<dyn Screen>,
}

pub fn entries() -> &'static [Entry] {
    ENTRIES
}

static ENTRIES: &[Entry] = &[
    Entry {
        id: "list.everything",
        kind: Kind::List,
        title: "Every Row",
        summary: "Icons, accessories, text and actions",
        covers: "Sections of rows, each a variation: a symbol in each tint and in none, a picture at 2× and at 1×, an app's icon and a file's, an icon that names nothing. Accessories alone and together, every tag tint, long and mixed-script text, keywords. Actions with chords, icons, a destructive one that asks first and removes its row, a copy that dismisses, a pushed view.\n\nTry ⌘K on each row of **Actions**, and the view's own: add a row, restore removed ones, spin the field's spinner.",
        make: || Box::new(lists::Everything::default()),
    },
    Entry {
        id: "list.preview",
        kind: Kind::List,
        title: "Preview Beside the List",
        summary: "Compact rows and the selection's detail",
        covers: "Rows on the left, each with a detail of another shape on the right: picture and text, wide and tall pictures, text that scrolls, metadata only, a status alone, a symbol and an app's icon, and a row with no detail.\n\n↩ opens the selection's detail as a view of its own, to compare the preview's 13 pt with a view's 14.",
        make: || Box::new(lists::Previews),
    },
    Entry {
        id: "list.many",
        kind: Kind::List,
        title: "Two Thousand Rows",
        summary: "Scrolling and filtering at size",
        covers: "Twenty sections of a hundred rows, each with an icon, a subtitle, two accessories and keywords. Type to filter: by title, keywords and subsequences, best match first, sections kept.",
        make: || Box::new(lists::Many::new()),
    },
    Entry {
        id: "list.owner",
        kind: Kind::List,
        title: "Filtered by the Plugin",
        summary: "filtering: owner, answered after a delay",
        covers: "The plugin filters its own four hundred records, as one whose items live on a server would. Typing pauses 0.15 s before dock2 asks; the plugin answers at once with the field's spinner, then with the matches 350 ms later. A query nothing matches shows the plugin's empty state.",
        make: || Box::new(lists::Owner::default()),
    },
    Entry {
        id: "list.scope",
        kind: Kind::List,
        title: "Scoped to a Server",
        summary: "A scope along the top: this Mac, remote, one server",
        covers: "Shares on this Mac and on five servers, the scope's menu along the panel's top choosing which show: All, This Mac, Remote, or one server from its section, each with its icon.\n\n⌘P opens the menu, or a click on its pill. This Mac and All answer at once; Remote and a server answer after 450 ms, as over the network, the field's spinner showing and the scope already saying what was chosen. Typing filters what the scope leaves. ⌘K takes the scope away from the open view and brings it back.",
        make: || Box::new(scopes::Servers::default()),
    },
    Entry {
        id: "list.loading",
        kind: Kind::List,
        title: "Loading, Then Rows",
        summary: "The field's spinner, then the rows",
        covers: "Opens loading, with no rows, and fills a second and a half later. From ⌘K: load again, or load nothing and land on the empty state.",
        make: || Box::new(lists::Loading::default()),
    },
    Entry {
        id: "list.empty",
        kind: Kind::List,
        title: "Empty",
        summary: "The plugin's empty state, and dock2's",
        covers: "No rows, and the plugin's empty state with its subtitle. From ⌘K: add rows, clear them, or drop the empty state for dock2's own “No results”.",
        make: || Box::new(lists::Empty::default()),
    },
    Entry {
        id: "list.bare",
        kind: Kind::List,
        title: "Bare",
        summary: "No title, icons, sections or actions",
        covers: "The least a list can be: rows with titles and nothing else, in a list with no title, so the field says its plain placeholder. ↩ does nothing, and ⌘K offers nothing.",
        make: || Box::new(lists::Bare),
    },
    Entry {
        id: "detail.everything",
        kind: Kind::Detail,
        title: "Every Combination",
        summary: "Image, body, metadata, scrubber, status",
        covers: "A detail with everything on, and an action for each part: the next image (nine kinds, among them pictures at 2× and 1×, hairlines, a symbol, an app's and a file's icon, none), the next body (none, a line, Markdown, a long one that scrolls), and metadata, the scrubber and the status on and off. The buttons are its actions.",
        make: || Box::new(details::Everything::default()),
    },
    Entry {
        id: "detail.text",
        kind: Kind::Detail,
        title: "Text Alone",
        summary: "A long body that scrolls under its status",
        covers: "Text alone starts at the top and scrolls; the status stays along the foot. No actions, so no buttons.",
        make: || Box::new(details::Text),
    },
    Entry {
        id: "detail.picture",
        kind: Kind::Detail,
        title: "Picture and a Line",
        summary: "An image and its text, centred together",
        covers: "An image and a short line fit the room above the foot, so they are centred as one block. Two actions, two buttons.",
        make: || Box::new(details::Picture),
    },
    Entry {
        id: "detail.metadata",
        kind: Kind::Detail,
        title: "Metadata",
        summary: "Rows of labels and values, nothing else",
        covers: "Plain values, a link, tags alone and after a value, a masked secret — eight dots whatever its length — and a value long enough to wrap.",
        make: || Box::new(details::MetadataOnly),
    },
    Entry {
        id: "detail.player",
        kind: Kind::Detail,
        title: "Player",
        summary: "A scrubber that moves, and its controls",
        covers: "Album art, the track, and a scrubber the plugin moves each second while playing, with the time either side. Drag it: the knob stays where you hold it whatever the plugin redraws, and the track seeks where you let go. Previous, Play/Pause and Next are buttons.",
        make: || Box::new(details::Player::default()),
    },
    Entry {
        id: "form.everything",
        kind: Kind::Form,
        title: "Every Field",
        summary: "Text, secure, multi-line, toggle, choice, date, folder",
        covers: "Every kind of field, with placeholders and values. Save checks them: a name, an email with an @, a password of eight or more. Errors sit under their fields, and what was typed survives. Saved, the form becomes a detail of what it held, in place.",
        make: || Box::new(forms::Everything::default()),
    },
    Entry {
        id: "form.sign-in",
        kind: Kind::Form,
        title: "Sign In, Then a List",
        summary: "A form that becomes the list it opens",
        covers: "A sign-in form whose answer replaces it: a list, loading, then filled. The password “wrong” is refused with an error.",
        make: || Box::new(forms::SignIn::default()),
    },
    Entry {
        id: "form.errors",
        kind: Kind::Form,
        title: "Errors Shown",
        summary: "Every field already wrong",
        covers: "Opens with an error under each kind of field, for their layout. Submit checks them again.",
        make: || Box::new(forms::Errors::default()),
    },
    Entry {
        id: "form.long",
        kind: Kind::Form,
        title: "More Fields Than Fit",
        summary: "Sixteen fields in a panel eight rows high",
        covers: "More fields than the panel holds. Tab through them: the last ones are past the panel's foot.",
        make: || Box::new(forms::Long),
    },
    Entry {
        id: "form.tiny",
        kind: Kind::Form,
        title: "One Toggle",
        summary: "No title, one field",
        covers: "The least a form can be: no title, one toggle, its submit.",
        make: || Box::new(forms::Tiny),
    },
    Entry {
        id: "grid.everything",
        kind: Kind::Grid,
        title: "Every Picture",
        summary: "Symbols, pictures, apps' and files' icons",
        covers: "A symbol in each tint and in none, pictures square, wide, tall, at 1× and in hairlines, apps' and files' icons, an icon that names nothing, cells with no title and one too long for its cell. ⌘K: change the columns, restore what was deleted.",
        make: || Box::new(grids::Everything::default()),
    },
    Entry {
        id: "grid.many",
        kind: Kind::Grid,
        title: "Five Hundred",
        summary: "Scrolling, and the arrows across rows",
        covers: "Five hundred cells in six columns. Walk them with the arrows and type to filter by title.",
        make: || Box::new(grids::Many),
    },
    Entry {
        id: "grid.scope",
        kind: Kind::Grid,
        title: "Grid in a Scope",
        summary: "Every tint, or the warm or the cool",
        covers: "Forty-eight cells, the scope choosing every tint, the warm or the cool, answered at once. The selection goes back to the first cell as the scope changes.",
        make: || Box::new(scopes::Palette::default()),
    },
    Entry {
        id: "grid.pictures",
        kind: Kind::Grid,
        title: "Pictures Without Titles",
        summary: "Eight columns of images alone",
        covers: "Cells with no titles, in eight columns.",
        make: || Box::new(grids::Untitled),
    },
    Entry {
        id: "grid.empty",
        kind: Kind::Grid,
        title: "Empty Grid",
        summary: "A grid with nothing in it",
        covers: "No cells at all. ⌘K fills it.",
        make: || Box::new(grids::Empty::default()),
    },
    Entry {
        id: "feedback.everything",
        kind: Kind::Feedback,
        title: "Toasts, Confirmations, Navigation",
        summary: "Everything an action can answer with",
        covers: "Each row does one thing on ↩: a toast, a long one, two at once, a confirmation, a copy that dismisses with a notice, a long notice, a page opened, views pushed, popped and all closed, dock2 dismissed, and an effect the plugin is refused.",
        make: || Box::new(feedback::Everything::default()),
    },
    Entry {
        id: "max.scope",
        kind: Kind::Maximal,
        title: "Forty-Eight Servers",
        summary: "A scope's menu longer than its room",
        covers: "A scope of forty-nine options in four titled sections, one with a name far wider than the menu's least width. The menu widens to it, stops at the pane's foot and scrolls, the arrows keeping the selection in view.",
        make: || Box::new(scopes::ManyServers::default()),
    },
    Entry {
        id: "max.preview",
        kind: Kind::Maximal,
        title: "Tags Beside a Preview",
        summary: "Compact rows and tags in the narrowest detail",
        covers: "The rows of Tags in Rows, compact, where a tag has least room, each previewing its own tags as a metadata row at 13 pt. **Shapes of Preview** comes first: tags under a picture, under text that scrolls, every place a tag sits, and all of a detail.\n\n↩ opens the selection's detail as a view of its own, at 14 pt and the panel's full width.",
        make: || Box::new(maximal::Preview),
    },
    Entry {
        id: "max.rows",
        kind: Kind::Maximal,
        title: "Tags in Rows",
        summary: "Tags against long titles, text and icons",
        covers: "Tags where the row's room runs out: against a long title and subtitle, beside text and icons, one to eight of them, and one longer than the row. Tags that are narrow, empty, in other scripts, or hold a newline, and one accessory that names all three kinds.\n\nWalk with ↓: in a wide list the selected row's tags give way to what ↩ does.",
        make: || Box::new(maximal::Rows),
    },
    Entry {
        id: "max.metadata",
        kind: Kind::Maximal,
        title: "Tags in Metadata",
        summary: "Tags that wrap, and after every kind of value",
        covers: "Every place a metadata row can hold a tag: enough to wrap once and several times, after a value, one that wraps, a link and a secret, wider than the pane, a long one among short ones, narrow and empty ones, other scripts. A plain row last, for the gap under them.",
        make: || Box::new(maximal::TagRows),
    },
    Entry {
        id: "max.detail",
        kind: Kind::Maximal,
        title: "A Full Detail",
        summary: "Every part at once, each at its longest",
        covers: "A picture, Markdown and prose, every metadata row of Tags in Metadata, a scrubber whose times outgrow their labels, a status longer than its line, and more buttons than the width holds.",
        make: || Box::new(maximal::Full),
    },
    Entry {
        id: "max.form",
        kind: Kind::Maximal,
        title: "A Full Form",
        summary: "Long titles, values, errors and options",
        covers: "Each kind of field with a title, a value and a placeholder too long for it and an error that wraps; a multi-line field of twenty-four lines, a choice of forty-one options, a folder past the field's end, and a submit longer than the bar's pill.",
        make: || Box::new(maximal::FullForm),
    },
    Entry {
        id: "max.grid",
        kind: Kind::Maximal,
        title: "Few and Many Columns",
        summary: "Long titles in two, one, twelve and twenty columns",
        covers: "Forty pictures with titles of a sentence, in two columns. ⌘E walks one, twelve and twenty.",
        make: || Box::new(maximal::FullGrid::default()),
    },
];

pub fn render() -> ViewNode {
    let mut list = List::new(ID).title("Demo").preview();
    for kind in [Kind::List, Kind::Detail, Kind::Form, Kind::Grid, Kind::Feedback, Kind::Maximal] {
        let items = entries()
            .iter()
            .filter(|entry| entry.kind == kind)
            .map(|entry| {
                Item::new(entry.id, entry.title)
                    .subtitle(entry.summary)
                    .icon(kind.icon())
                    .keywords(vec![kind.title().to_lowercase(), entry.id.into()])
                    .actions(vec![Action::new("open", "Open")])
                    .detail(Detail::new(&format!("{ID}/{}", entry.id)).body(entry.covers).status(&[kind.title(), entry.id]))
            })
            .collect();
        list = list.section(kind.title(), items);
    }
    list.into()
}
