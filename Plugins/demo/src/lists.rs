//! Lists: every row a list can draw, a preview beside one, one at size, one its owner filters, loading,
//! empty, and bare.

use crate::data::{self, Rng, SYMBOLS, TINTS};
use crate::details;
use crate::png::pictures;
use crate::{say, Screen};
use dock2_plugin::*;
use std::collections::BTreeSet;

fn png(bytes: &[u8]) -> Icon {
    Icon::png(bytes.to_vec())
}

/// What most rows offer: a toast, a copy, and a removal that asks first.
fn row(id: &str, title: &str) -> Item {
    Item::new(id, title).actions(vec![
        Action::new("toast", "Show a Toast").icon(Icon::symbol("text.bubble")),
        Action::new("copy", "Copy Its ID and Dismiss").icon(Icon::symbol("doc.on.doc")),
        Action::new("delete", "Delete This Row").icon(Icon::symbol("trash")).destructive(),
    ])
}

// ---- every row ------------------------------------------------------------------------------------

#[derive(Default)]
pub struct Everything {
    removed: BTreeSet<String>,
    added: u32,
    spinning: bool,
}

impl Everything {
    fn sections(&self) -> Vec<(&'static str, Vec<Item>)> {
        let pictures = pictures();
        // Every kind first, the tints after: the first screen shows the variety.
        let mut icons = vec![
            row("symbol-plain", "A symbol with no tint").subtitle("In the text's colour").icon(Icon::symbol("star")),
            row("symbol-unknown", "A symbol that names nothing").subtitle("“not.a.symbol”").icon(Icon::symbol("not.a.symbol")),
            row("picture-2x", "A picture at 2×").subtitle("48 pt, 96 px").icon(png(&pictures.thumbs[4])),
            row("picture-1x", "A picture at 1×").subtitle("64 pt, 64 px: soft on a Retina display").icon(png(&pictures.low)),
            row("picture-wide", "A wide picture").subtitle("240 × 100 pt in a square").icon(png(&pictures.wide)),
            row("app", "An app's icon").subtitle("com.apple.Safari").icon(Icon::app("com.apple.Safari")),
            row("app-missing", "An app that isn't installed").subtitle("com.example.nothing").icon(Icon::app("com.example.nothing")),
            row("file-folder", "A folder's icon").subtitle("/Applications").icon(Icon::file("/Applications")),
            row("file-document", "A file's icon").subtitle("/etc/hosts").icon(Icon::file("/etc/hosts")),
            row("file-missing", "A file that isn't there").subtitle("/nowhere/at/all.txt").icon(Icon::file("/nowhere/at/all.txt")),
            row("no-icon", "No icon").subtitle("Its title against the others'"),
        ];
        icons.extend(TINTS.iter().enumerate().map(|(index, (tint, name))| {
            row(&format!("tint-{}", name.to_lowercase()), &format!("{name} symbol"))
                .subtitle("A glyph in its tint")
                .icon(Icon::symbol(SYMBOLS[index]).tint(*tint))
        }));

        let every_tint = TINTS.iter().fold(row("acc-tints", "Every tint"), |item, (tint, name)| item.tag(Tag::new(name).tint(*tint)));
        let accessories = vec![
            row("acc-text", "Text").subtitle("One accessory").accessory("12 KB"),
            row("acc-texts", "Two texts").subtitle("Joined with a dot").accessory("12 KB").accessory("5 min ago"),
            row("acc-tag", "A tag").tag(Tag::new("New").tint(Tint::Green)),
            row("acc-tag-plain", "A tag with no tint").tag(Tag::new("Draft")),
            every_tint,
            row("acc-icon", "An icon").accessory_icon(Icon::symbol("lock.fill").tint(Tint::Gray)),
            row("acc-icon-app", "An app's icon as an accessory").accessory_icon(Icon::app("com.apple.Safari")),
            row("acc-all", "Text, a tag and an icon")
                .subtitle("All three kinds")
                .accessory("3 days ago")
                .tag(Tag::new("Shared").tint(Tint::Blue))
                .accessory_icon(Icon::symbol("person.2.fill")),
            row("acc-long", "A long accessory").accessory("Updated three days ago by Margaret Hamilton from her laptop"),
            row("acc-long-title", "A long title beside accessories, to see which of them gives way first")
                .subtitle("And a subtitle that is quite long as well, for good measure")
                .accessory("Yesterday")
                .tag(Tag::new("Pinned").tint(Tint::Orange)),
        ];

        let text = vec![
            row("long-title", "A title long enough that it cannot fit on one row of the panel, however wide the panel happens to be")
                .subtitle("Truncated at its tail"),
            row("long-subtitle", "A long subtitle")
                .subtitle("A subtitle long enough that it runs past the end of the row and has to give way somewhere along it"),
            row("no-subtitle", "No subtitle"),
            row("scripts", "Café, 東京, עברית, Ελληνικά, ☕️🚀").subtitle("Mixed scripts and emoji"),
            row("keywords", "Found by its keywords").subtitle("Type “banana” or “hidden”").keywords(vec!["banana".into(), "hidden".into()]),
            row("markdown", "**Not bold**: a title is plain text").subtitle("`nor is this code`"),
        ];

        let toast = Action::new("toast", "Show a Toast");
        let many = (1..=14).map(|n| Action::new(&format!("many-{n}"), &format!("Action Number {n}"))).collect();
        let actions = vec![
            Item::new("act-none", "No actions").subtitle("↩ does nothing, ⌘K offers only the view's"),
            Item::new("act-one", "One action").subtitle("↩").actions(vec![toast.clone()]),
            Item::new("act-two", "Two actions").subtitle("↩ and ⌘↩").actions(vec![toast.clone(), Action::new("copy", "Copy Its ID and Dismiss")]),
            Item::new("act-chords", "Chords")
                .subtitle("⌘S and ⇧⌘S bound; ⌘K, ⌘C and ⌥↩ refused")
                .actions(vec![
                    toast.clone(),
                    Action::new("star", "Star").key("cmd+s"),
                    Action::new("share", "Share").key("cmd+shift+s"),
                    Action::new("refused-k", "Bound to ⌘K, So Refused").key("cmd+k"),
                    Action::new("refused-c", "Bound to ⌘C, So Refused").key("cmd+c"),
                    Action::new("refused-option", "Bound to ⌥↩, So Refused").key("opt+return"),
                ]),
            Item::new("act-icons", "Actions with icons").subtitle("A symbol, a tinted one, an app's").actions(vec![
                toast.clone().icon(Icon::symbol("text.bubble")),
                Action::new("star", "Star").icon(Icon::symbol("star.fill").tint(Tint::Yellow)),
                Action::new("share", "Share").icon(Icon::symbol("square.and.arrow.up")),
                Action::new("safari", "As Safari Would").icon(Icon::app("com.apple.Safari")),
            ]),
            Item::new("act-destructive", "A destructive action").subtitle("Asks first, then removes the row").actions(vec![
                toast.clone(),
                Action::new("delete", "Delete This Row").icon(Icon::symbol("trash")).destructive(),
            ]),
            Item::new("act-many", "Fourteen actions").subtitle("A long menu").actions(many),
            Item::new("act-copy", "Copy and dismiss").subtitle("A notice where the field was").actions(vec![Action::new("copy", "Copy Its ID and Dismiss")]),
            Item::new("act-url", "Open a page").subtitle("example.com, in the browser").actions(vec![Action::new("url", "Open example.com")]),
            Item::new("act-push", "Push a view").subtitle("A detail over this list; Esc comes back").actions(vec![Action::new("push", "Push a View")]),
        ];
        vec![("Icons", icons), ("Accessories", accessories), ("Text", text), ("Actions", actions)]
    }
}

impl Screen for Everything {
    fn render(&self, view: &str) -> ViewNode {
        let mut list = List::new(view).title("Every Row").loading(self.spinning).actions(vec![
            Action::new("add", "Add a Row").key("cmd+n").icon(Icon::symbol("plus")),
            Action::new("restore", "Restore Deleted Rows").key("cmd+shift+r").icon(Icon::symbol("arrow.uturn.backward")),
            Action::new("spin", if self.spinning { "Stop the Spinner" } else { "Spin the Field's Spinner" }).key("cmd+l"),
        ]);
        if self.added > 0 {
            let added = (1..=self.added).rev().map(|n| row(&format!("added-{n}"), &format!("Added row {n}")).tag(Tag::new("New").tint(Tint::Green)));
            list = list.section("Added", added.filter(|item| !self.removed.contains(&item.id)).collect());
        }
        for (title, items) in self.sections() {
            list = list.section(title, items.into_iter().filter(|item| !self.removed.contains(&item.id)).collect());
        }
        list.into()
    }

    fn action(&mut self, view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("add", _) => self.added += 1,
            ("restore", _) => self.removed.clear(),
            ("spin", _) => self.spinning = !self.spinning,
            ("delete", Some(item)) => {
                self.removed.insert(item.into());
            }
            ("copy", Some(item)) => {
                out.copy(item, false);
                out.dismiss();
                out.toast("Copied");
                return false;
            }
            ("url", _) => {
                out.open("https://example.com/");
                return false;
            }
            ("push", _) => {
                out.show_view(
                    Detail::new(&format!("{view}/pushed"))
                        .body("A view pushed over the list. **Esc** goes back to it, as does the button.")
                        .status(&["Pushed"])
                        .actions(vec![Action::new("pop", "Back to the List")]),
                );
                return false;
            }
            ("pop", _) => {
                out.pop_view();
                return false;
            }
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }
}

// ---- previews -------------------------------------------------------------------------------------

/// Rows whose details differ in shape, beside them.
pub struct Previews;

const PREVIEWS: &[(&str, &str, &str, &str)] = &[
    ("picture", "Picture and text", "photo", "Centred together"),
    ("wide", "A wide picture", "chart.bar", "240 × 100 pt"),
    ("tall", "A tall picture", "rectangle.portrait", "100 × 180 pt"),
    ("text", "Text that scrolls", "text.alignleft", "From the top"),
    ("metadata", "Metadata only", "list.bullet.rectangle", "Labels and values"),
    ("everything", "Everything", "square.stack.3d.up", "Picture, text, rows, status"),
    ("status", "A status alone", "minus", "Only the foot"),
    ("symbol", "A symbol for a picture", "sparkles", "At 160 pt"),
    ("app", "An app's icon for a picture", "safari", "As the system draws it"),
    ("none", "No detail", "questionmark.square.dashed", "The preview stays empty"),
];

fn preview(id: &str, item: &str) -> Option<Detail> {
    let pictures = pictures();
    let mut rng = Rng::new(item.len() as u64);
    let detail = Detail::new(id);
    Some(match item {
        "picture" => detail.image(png(&pictures.square)).body("**Midnight Lattice**\nAda Lovelace — Analytical Engines").status(&["Demo", "3:37"]),
        "wide" => detail.image(png(&pictures.wide)).body("Twelve months of made-up numbers, as a chart drawn elsewhere would come."),
        "tall" => detail.image(png(&pictures.tall)).body("A poster, taller than it is wide."),
        "text" => detail.body(&details::long_body(&mut rng, 6)).status(&["Demo", "6 paragraphs"]),
        "metadata" => details::with_metadata(detail, &mut rng),
        "everything" => details::with_metadata(detail.image(png(&pictures.square)).body(&data::paragraph(&mut rng, 2)), &mut rng)
            .status(&["Demo", "Everything", "Edited Yesterday"]),
        "status" => detail.status(&["Only", "a status", "along the foot"]),
        "symbol" => detail.image(Icon::symbol("sparkles").tint(Tint::Purple)).body("A symbol, drawn as a glyph at the detail's size."),
        "app" => detail.image(Icon::app("com.apple.Safari")).body("An app's icon, as `NSWorkspace` gives it."),
        _ => return None,
    })
}

impl Screen for Previews {
    fn render(&self, view: &str) -> ViewNode {
        let items = PREVIEWS
            .iter()
            .map(|(id, title, symbol, subtitle)| {
                let item = Item::new(id, title).subtitle(subtitle).icon(Icon::symbol(symbol)).accessory(&format!("{}", id.len())).actions(vec![
                    Action::new("open", "Open as a View").icon(Icon::symbol("arrow.up.left.and.arrow.down.right")),
                    Action::new("copy", "Copy Its ID and Dismiss"),
                ]);
                match preview(&format!("{view}/{id}"), id) {
                    Some(detail) => item.detail(detail),
                    None => item,
                }
            })
            .collect();
        List::new(view).title("Previews").preview().items(items).into()
    }

    fn action(&mut self, view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("open", Some(item)) => match preview(&format!("{view}/open"), item) {
                Some(detail) => out.show_view(detail.actions(vec![Action::new("pop", "Back")])),
                None => out.toast("It has no detail to open"),
            },
            ("pop", _) => out.pop_view(),
            ("copy", Some(item)) => {
                out.copy(item, false);
                out.dismiss();
                out.toast("Copied");
            }
            _ => say(action, item, out),
        }
        false
    }
}

// ---- many -----------------------------------------------------------------------------------------

pub struct Many {
    sections: Vec<Section>,
}

impl Many {
    pub fn new() -> Self {
        let mut rng = Rng::new(2000);
        let sections = (0..20)
            .map(|section| {
                let items = (0..100)
                    .map(|n| {
                        let index = section * 100 + n;
                        let (tint, _) = TINTS[index % 8];
                        Item::new(&format!("{index}"), &data::person(&mut rng))
                            .subtitle(&data::words(&mut rng, 4))
                            .icon(Icon::symbol(SYMBOLS[index % SYMBOLS.len()]).tint(tint))
                            .accessory(&data::size(&mut rng))
                            .accessory(&data::ago(&mut rng))
                            .keywords(vec![data::words(&mut rng, 1).to_lowercase()])
                            .actions(vec![Action::new("toast", "Show a Toast")])
                    })
                    .collect();
                Section { title: Some(format!("Section {}", section + 1)), items }
            })
            .collect();
        Many { sections }
    }
}

impl Screen for Many {
    fn render(&self, view: &str) -> ViewNode {
        let mut list = List::new(view).title("Two Thousand Rows");
        list.sections = self.sections.clone();
        list.into()
    }
}

// ---- filtered by its owner ------------------------------------------------------------------------

pub struct Owner {
    records: Vec<Item>,
    /// The query the rows answer.
    shown: String,
    /// A filter heard and not yet answered: its text and id.
    pending: Option<(String, u64)>,
}

impl Default for Owner {
    fn default() -> Self {
        let mut rng = Rng::new(400);
        let states = [("Open", Tint::Green), ("Closed", Tint::Purple), ("Draft", Tint::Gray)];
        let records = (0..400)
            .map(|n| {
                let (state, tint) = *rng.pick(&states);
                Item::new(&format!("r{n}"), &format!("#{} {}", 1000 + n, data::words(&mut rng, 4)))
                    .subtitle(&format!("{} · {}", data::person(&mut rng), data::ago(&mut rng)))
                    .icon(Icon::symbol("smallcircle.filled.circle").tint(tint))
                    .tag(Tag::new(state).tint(tint))
                    .actions(vec![Action::new("toast", "Show a Toast")])
            })
            .collect();
        Owner { records, shown: String::new(), pending: None }
    }
}

impl Screen for Owner {
    fn render(&self, view: &str) -> ViewNode {
        let query = self.shown.to_lowercase();
        let matching: Vec<Item> = self
            .records
            .iter()
            .filter(|item| query.is_empty() || item.title.to_lowercase().contains(&query) || item.subtitle.as_deref().unwrap_or("").to_lowercase().contains(&query))
            .cloned()
            .collect();
        let count = matching.len();
        let shown: Vec<Item> = matching.into_iter().take(50).collect();
        let mut list = List::new(view)
            .title("Remote Issues")
            .filtering(Filtering::Owner)
            .loading(self.pending.is_some())
            .empty(&format!("Nothing matches “{}”", self.shown), Some("The plugin searched its 400 records"));
        if !shown.is_empty() {
            list = list.section(&format!("{} of {count} matching", shown.len()), shown);
        }
        list.into()
    }

    fn filter(&mut self, view: &str, text: &str, id: u64, out: &mut Effects) {
        self.pending = Some((text.into(), id));
        out.answer_filter(self.render(view), id);
        out.timer(&format!("{view}/answer"), 350, false);
    }

    fn timer(&mut self, view: &str, _name: &str, out: &mut Effects) -> bool {
        if let Some((text, id)) = self.pending.take() {
            self.shown = text;
            out.answer_filter(self.render(view), id);
        }
        false
    }

    fn closed(&mut self, view: &str, out: &mut Effects) {
        out.cancel_timer(&format!("{view}/answer"));
    }
}

// ---- loading --------------------------------------------------------------------------------------

#[derive(Default)]
pub struct Loading {
    loaded: bool,
    /// What the load in flight brings: rows, or none.
    nothing: bool,
}

impl Loading {
    fn load(&mut self, view: &str, nothing: bool, out: &mut Effects) {
        self.loaded = false;
        self.nothing = nothing;
        out.timer(&format!("{view}/done"), 1500, false);
    }
}

impl Screen for Loading {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(30);
        let mut list = List::new(view).title("Loading").loading(!self.loaded).empty("Nothing came back", Some("The load finished with no rows")).actions(vec![
            Action::new("again", "Load Again").key("cmd+r").icon(Icon::symbol("arrow.clockwise")),
            Action::new("nothing", "Load Nothing").key("cmd+shift+r"),
        ]);
        if self.loaded && !self.nothing {
            list = list.items((0..30).map(|n| Item::new(&format!("{n}"), &data::person(&mut rng)).subtitle(&data::ago(&mut rng))).collect());
        }
        list.into()
    }

    fn opened(&mut self, view: &str, out: &mut Effects) {
        self.load(view, false, out);
    }

    fn action(&mut self, view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "again" => self.load(view, false, out),
            "nothing" => self.load(view, true, out),
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }

    fn timer(&mut self, _view: &str, _name: &str, _out: &mut Effects) -> bool {
        self.loaded = true;
        true
    }

    fn closed(&mut self, view: &str, out: &mut Effects) {
        out.cancel_timer(&format!("{view}/done"));
    }
}

// ---- empty ----------------------------------------------------------------------------------------

#[derive(Default)]
pub struct Empty {
    rows: u32,
    plain: bool,
}

impl Screen for Empty {
    fn render(&self, view: &str) -> ViewNode {
        let mut list = List::new(view)
            .title("Empty")
            .items((1..=self.rows).map(|n| Item::new(&format!("{n}"), &format!("Row {n}")).actions(vec![Action::new("toast", "Show a Toast")])).collect())
            .actions(vec![
                Action::new("add", "Add a Row").key("cmd+n").icon(Icon::symbol("plus")),
                Action::new("clear", "Clear the Rows").key("cmd+shift+n"),
                Action::new("plain", if self.plain { "Bring Back the Empty State" } else { "Drop the Empty State" }).key("cmd+e"),
            ]);
        if !self.plain {
            list = list.empty("Nothing here yet", Some("Add a row from ⌘K, or drop this empty state for dock2's own"));
        }
        list.into()
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("add", _) => self.rows += 1,
            ("clear", _) => self.rows = 0,
            ("plain", _) => self.plain = !self.plain,
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }
}

// ---- bare -----------------------------------------------------------------------------------------

pub struct Bare;

impl Screen for Bare {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(10);
        List::new(view).items((0..12).map(|n| Item::new(&format!("{n}"), &data::words(&mut rng, 2))).collect()).into()
    }
}
