//! Maximal: views filled past what they were built for. The other screens show each variation alone; these
//! put them in each other's way, tags above all, since a row's tags and its words want the same room.

use crate::data::{self, Rng, TINTS};
use crate::details::{long_body, MARKDOWN};
use crate::png::pictures;
use crate::{say, Screen};
use dock2_plugin::*;

const LONG_TITLE: &str = "A title long enough to run into whatever stands at the row's end, however wide the panel happens to be";
const LONG_SUBTITLE: &str = "And a subtitle as long as the title above it, so both lines of the row reach for the same room";
const LONG_TAG: &str = "A tag long enough to need a sentence of its own, which no pill was ever meant to hold, and wider than the pane it sits in";

/// `count` tags, each its tint's name.
fn tints(count: usize) -> Vec<Tag> {
    (0..count).map(|index| TINTS[index % TINTS.len()]).map(|(tint, name)| Tag::new(name).tint(tint)).collect()
}

/// `count` tags of one and two words, every ninth with no tint.
fn scattered(count: usize) -> Vec<Tag> {
    let mut rng = Rng::new(count as u64);
    (0..count)
        .map(|index| {
            let tag = Tag::new(&data::words(&mut rng, 1 + index % 2));
            match index % 9 {
                8 => tag,
                tint => tag.tint(TINTS[tint].0),
            }
        })
        .collect()
}

fn scripts() -> Vec<Tag> {
    vec![Tag::new("東京").tint(Tint::Red), Tag::new("עברית").tint(Tint::Blue), Tag::new("Ελληνικά").tint(Tint::Green), Tag::new("☕️🚀")]
}

fn slight() -> Vec<Tag> {
    vec![Tag::new("i").tint(Tint::Blue), Tag::new("3").tint(Tint::Red), Tag::new("").tint(Tint::Gray)]
}

fn row(id: &str, title: &str) -> Item {
    Item::new(id, title).actions(vec![Action::new("open", "Open as a View").icon(Icon::symbol("arrow.up.left.and.arrow.down.right"))])
}

fn tagged(item: Item, tags: Vec<Tag>) -> Item {
    tags.into_iter().fold(item, Item::tag)
}

/// Rows whose tags compete for their room: the same rows a wide list draws and a compact one beside a preview.
fn sections() -> Vec<(&'static str, Vec<Item>)> {
    let selected = vec![tagged(row("selected", "Selected, in a wide list, its tags give way to what ↩ does").subtitle("↓ brings them back"), tints(2))];

    let title = vec![
        tagged(row("title-two", LONG_TITLE), tints(2)),
        tagged(row("title-four", LONG_TITLE).subtitle(LONG_SUBTITLE), tints(4)),
        tagged(row("title-eight", LONG_TITLE).subtitle(LONG_SUBTITLE), tints(8)),
        row("title-long", LONG_TITLE).subtitle(LONG_SUBTITLE).tag(Tag::new(LONG_TAG).tint(Tint::Orange)),
    ];

    let mut whole = row("whole", "One accessory naming text, an icon and a tag").subtitle("All three");
    whole.accessories = Some(vec![Accessory { text: Some("Text".into()), icon: Some(Icon::symbol("lock.fill")), tag: Some(Tag::new("Tag").tint(Tint::Green)) }]);
    let beside = vec![
        row("text-one", "Text and a tag").accessory("12 KB").tag(Tag::new("New").tint(Tint::Green)),
        tagged(row("text-four", "Text and four tags").accessory("5 min ago"), tints(4)),
        tagged(row("text-long", "Long text and four tags").accessory("Updated three days ago by Margaret Hamilton from her laptop"), tints(4)),
        tagged(row("text-title", LONG_TITLE).subtitle(LONG_SUBTITLE).accessory("5 min ago"), tints(2)),
        row("order", "Tags and icons, in the order given")
            .tag(Tag::new("First").tint(Tint::Blue))
            .accessory_icon(Icon::symbol("lock.fill").tint(Tint::Gray))
            .tag(Tag::new("Third").tint(Tint::Pink))
            .accessory_icon(Icon::app("com.apple.Safari")),
        row("icons", "Two icons").accessory_icon(Icon::symbol("person.2.fill")).accessory_icon(Icon::symbol("star.fill").tint(Tint::Yellow)),
        tagged(row("all", "All of it").accessory("12 KB").accessory("5 min ago"), tints(3)).accessory_icon(Icon::symbol("lock.fill")).accessory_icon(Icon::symbol("pin.fill")),
        whole,
    ];

    let mut room: Vec<Item> = (1..=8).map(|count| tagged(row(&format!("room-{count}"), &format!("{count} of 8")), tints(count))).collect();
    room.push(row("room-long", "One tag longer than the row").tag(Tag::new(LONG_TAG).tint(Tint::Orange)));

    let odd = vec![
        row("odd-narrow", "Narrower than it is tall").tag(Tag::new("i").tint(Tint::Blue)),
        row("odd-digit", "A digit").tag(Tag::new("3").tint(Tint::Red)),
        row("odd-empty", "No text at all").tag(Tag::new("").tint(Tint::Gray)),
        tagged(row("odd-scripts", "Other scripts and emoji"), scripts()),
        row("odd-lines", "A newline in a tag").tag(Tag::new("Two\nlines").tint(Tint::Purple)),
    ];

    vec![("Selection", selected), ("Against the Title", title), ("Beside Text and Icons", beside), ("How Many Fit", room), ("Odd Tags", odd)]
}

/// A tag in every place a metadata row can hold one, the rows that wrap first.
fn tag_rows() -> Vec<Metadata> {
    let mut rng = Rng::new(3);
    let row = |label: &str, value: &str, tags: Vec<Tag>| Metadata { label: label.into(), value: value.into(), tags: Some(tags), ..Default::default() };
    let mut long_among_short = tints(2);
    long_among_short.push(Tag::new(LONG_TAG).tint(Tint::Orange));
    long_among_short.extend(tints(2));
    vec![
        row("Every tint", "", tints(8)),
        row("Thirty tags", "", scattered(30)),
        row("After a value", "Active", tints(3)),
        row("After a value that wraps", &data::paragraph(&mut rng, 2), scattered(6)),
        Metadata { link: Some("https://example.com/".into()), ..row("After a link", "example.com", tints(3)) },
        Metadata { masked: Some(true), ..row("After a secret", "", tints(2)) },
        row("One tag wider than the pane", "", vec![Tag::new(LONG_TAG).tint(Tint::Orange)]),
        row("A long one among short ones", "", long_among_short),
        row("Narrow and empty", "", slight()),
        row("Other scripts and emoji", "", scripts()),
        row("A newline in a tag", "", vec![Tag::new("Two\nlines").tint(Tint::Purple)]),
        Metadata { label: "A plain row after them".into(), value: "To see the gap under the pills".into(), ..Default::default() },
    ]
}

/// Everything a detail can hold at once, each part at its longest.
fn full_detail(id: &str) -> Detail {
    let mut detail = Detail::new(id)
        .image(Icon::png(pictures().square.clone()))
        .body(&format!("{MARKDOWN}\n\n{}", long_body(&mut Rng::new(21), 3)))
        .scrubber(Scrubber {
            id: "position".into(),
            value: 42.0,
            maximum: 100.0,
            leading: Some("1:02:33 elapsed so far".into()),
            trailing: Some("-12:44:09 still to come".into()),
        })
        .status(&["A status of more facts than one line holds", "Edited Yesterday by Margaret Hamilton from her laptop", "Eleven paragraphs", "Demo"])
        .actions(vec![
            Action::new("primary", "Open in the Default Browser").icon(Icon::symbol("safari")),
            Action::new("second", "Copy the Whole Thing as Markdown").icon(Icon::symbol("doc.on.doc")),
            Action::new("third", "Share with Everyone in the Workspace").icon(Icon::symbol("square.and.arrow.up")).key("cmd+shift+s"),
            Action::new("fourth", "Move to Another Folder").icon(Icon::symbol("folder")).key("cmd+m"),
            Action::new("fifth", "Pin to the Top of the List").icon(Icon::symbol("pin")).key("cmd+p"),
            Action::new("sixth", "Delete for Good").icon(Icon::symbol("trash")).destructive(),
        ]);
    detail.metadata = Some(tag_rows());
    detail
}

// ---- tags in rows ---------------------------------------------------------------------------------

pub struct Rows;

impl Screen for Rows {
    fn render(&self, view: &str) -> ViewNode {
        let mut list = List::new(view).title("Tags in Rows");
        for (title, items) in sections() {
            list = list.section(title, items);
        }
        list.into()
    }
}

// ---- tags beside a preview ------------------------------------------------------------------------

pub struct Preview;

/// Rows previewing more than their own tags: under a picture, under text, and all a detail holds.
fn shaped(view: &str) -> Vec<Item> {
    let id = |item: &str| format!("{view}/{item}");
    let under = |detail: Detail| Detail { metadata: Some(vec![Metadata { label: "Tags".into(), tags: Some(scattered(12)), ..Default::default() }]), ..detail };
    let picture = Detail::new(&id("shape-picture")).image(Icon::png(pictures().square.clone())).body("**Midnight Lattice**").status(&["Demo", "Centred with its picture"]);
    let wide = Detail::new(&id("shape-wide")).image(Icon::png(pictures().wide.clone())).body("A chart drawn elsewhere.");
    let text = Detail::new(&id("shape-text")).body(&long_body(&mut Rng::new(14), 4)).status(&["Demo", "The tags are past the fold"]);
    let every = Detail { metadata: Some(tag_rows()), ..Detail::new(&id("shape-rows")) };
    vec![
        row("shape-picture", "Tags under a picture").subtitle("The block, centred, as tall as measured").detail(under(picture)),
        row("shape-wide", "Tags under a wide picture").subtitle("No status").detail(under(wide)),
        row("shape-text", "Tags under text that scrolls").subtitle("Scroll to reach them").detail(under(text)),
        row("shape-rows", "Every place a tag sits").subtitle("The metadata screen, at 13 pt").detail(every),
        row("shape-full", "All of a detail").subtitle("A preview draws no scrubber or buttons").detail(full_detail(&id("shape-full"))),
    ]
}

/// A row's tags again, as a metadata row: a preview at the panel's narrowest.
fn own_tags(item: &Item, id: &str) -> Detail {
    let tags = item.accessories.iter().flatten().filter_map(|accessory| accessory.tag.clone()).collect();
    Detail::new(id).body(item.subtitle.as_deref().unwrap_or(&item.title)).tags("Tags", tags).status(&["Demo", &item.id])
}

fn previews(view: &str) -> Vec<(&'static str, Vec<Item>)> {
    let mut all = vec![("Shapes of Preview", shaped(view))];
    for (title, items) in sections() {
        let previewing = |item: Item| {
            let detail = own_tags(&item, &format!("{view}/{}", item.id));
            item.detail(detail)
        };
        all.push((title, items.into_iter().map(previewing).collect()));
    }
    all
}

/// The detail `item` previews, as a view of its own.
fn previewed(view: &str, item: &str) -> Option<Detail> {
    let detail = previews(view).into_iter().flat_map(|(_, items)| items).find(|candidate| candidate.id == item)?.detail?;
    Some(Detail { id: format!("{view}/open"), ..detail })
}

impl Screen for Preview {
    fn render(&self, view: &str) -> ViewNode {
        let mut list = List::new(view).title("Tags Beside a Preview").preview();
        for (title, items) in previews(view) {
            list = list.section(title, items);
        }
        list.into()
    }

    fn action(&mut self, view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("open", Some(item)) => {
                if let Some(detail) = previewed(view, item) {
                    out.show_view(detail);
                }
            }
            _ => say(action, item, out),
        }
        false
    }
}

// ---- tags in metadata -----------------------------------------------------------------------------

pub struct TagRows;

impl Screen for TagRows {
    fn render(&self, view: &str) -> ViewNode {
        let mut detail = Detail::new(view).status(&["Demo", "12 rows"]);
        detail.metadata = Some(tag_rows());
        detail.into()
    }
}

// ---- a full detail --------------------------------------------------------------------------------

pub struct Full;

impl Screen for Full {
    fn render(&self, view: &str) -> ViewNode {
        full_detail(view).into()
    }
}

// ---- a full form ----------------------------------------------------------------------------------

pub struct FullForm;

const LONG_ERROR: &str = "An error long enough to wrap under its field, which says what went wrong, why it matters and what to do about it, at length";
const LONG_PATH: &str = "/Users/Shared/A Folder With A Long Name/Another Folder Nested Inside It/And Another One/And Yet Another One Past The Field's End";

impl Screen for FullForm {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(40);
        let lines = (0..24).map(|_| data::sentence(&mut rng)).collect::<Vec<_>>().join("\n");
        let mut options: Vec<(String, String)> = (0..40).map(|n| (format!("{n}"), format!("{} {n}", data::words(&mut rng, 2)))).collect();
        options.push(("long".into(), LONG_TITLE.into()));
        let options: Vec<(&str, &str)> = options.iter().map(|(value, title)| (value.as_str(), title.as_str())).collect();
        Form::new(view, "Save Everything and Close This Screen Afterwards")
            .title("A form with a title long enough to run past the end of the field it names")
            .field(Field::new("text", LONG_TITLE, FieldKind::Text).value(LONG_SUBTITLE).placeholder(LONG_TITLE).error(Some(LONG_ERROR)))
            .field(Field::new("placeholder", "Only a placeholder", FieldKind::Text).placeholder(LONG_TITLE).error(Some(LONG_ERROR)))
            .field(Field::new("secure", LONG_TITLE, FieldKind::Secure).value(LONG_SUBTITLE).error(Some(LONG_ERROR)))
            .field(Field::new("multiline", LONG_TITLE, FieldKind::Multiline).value(&lines).error(Some(LONG_ERROR)))
            .field(Field::new("toggle", LONG_TITLE, FieldKind::Toggle).value("true").error(Some(LONG_ERROR)))
            .field(Field::new("choice", LONG_TITLE, FieldKind::Choice).value("long").options(&options).error(Some(LONG_ERROR)))
            .field(Field::new("date", LONG_TITLE, FieldKind::Date).value("2026-11-07").error(Some(LONG_ERROR)))
            .field(Field::new("folder", LONG_TITLE, FieldKind::Folder).value(LONG_PATH).error(Some(LONG_ERROR)))
            .into()
    }
}

// ---- a full grid ----------------------------------------------------------------------------------

/// What Change the Columns walks: past either end of what a grid is built for.
const COLUMNS: [u32; 4] = [2, 1, 12, 20];

#[derive(Default)]
pub struct FullGrid {
    columns: usize,
}

impl Screen for FullGrid {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(50);
        let thumbs = &pictures().thumbs;
        let cells = (0..40)
            .map(|n| GridItem::new(&format!("{n}"), Icon::png(thumbs[n % thumbs.len()].clone())).title(&format!("{} {n}", data::sentence(&mut rng))).actions(vec![Action::new("toast", "Show a Toast")]))
            .collect();
        Grid::new(view, cells)
            .title("Long Titles, Few and Many Columns")
            .columns(COLUMNS[self.columns])
            .actions(vec![Action::new("columns", "Change the Columns").key("cmd+e")])
            .into()
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        if action == "columns" {
            self.columns = (self.columns + 1) % COLUMNS.len();
            return true;
        }
        say(action, item, out);
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_row_opens_as_the_detail_it_previews() {
        for (_, items) in previews("max") {
            for item in items {
                assert_eq!(previewed("max", &item.id).expect(&item.id).id, "max/open");
            }
        }
    }

    #[test]
    fn a_rows_preview_repeats_its_tags() {
        let (_, items) = previews("max").into_iter().find(|(title, _)| *title == "How Many Fit").unwrap();
        let tags = |item: &Item| item.detail.as_ref().unwrap().metadata.as_ref().unwrap()[0].tags.as_ref().unwrap().len();
        assert_eq!(tags(&items[7]), 8);
    }
}
