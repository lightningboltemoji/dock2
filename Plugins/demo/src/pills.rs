//! Flows: short items as pills under their sections' titles, alone and beside a preview.

use crate::{say, Screen};
use dock2_plugin::*;

/// SF Symbols by what they show: a picker's worth of short names, each with its glyph.
const SYMBOLS: &[(&str, &[&str])] = &[
    ("Weather", &["sun.max", "moon", "cloud", "cloud.rain", "cloud.bolt", "snowflake", "wind", "tornado", "rainbow", "thermometer.sun", "humidity", "sunrise", "sunset", "moon.stars", "cloud.fog", "hurricane"]),
    ("Objects", &["pencil", "trash", "folder", "paperplane", "tray", "archivebox", "doc", "book", "bookmark", "paperclip", "link", "scissors", "bag", "cart", "gift", "key", "lock", "lightbulb", "hammer", "wrench", "camera", "printer", "tv", "headphones", "gamecontroller", "umbrella", "briefcase", "clock", "alarm", "hourglass"]),
    ("Nature", &["leaf", "flame", "drop", "bolt", "globe", "mountain.2", "tree", "carrot", "fish", "bird", "ant", "ladybug", "tortoise", "hare", "pawprint", "feather"]),
    ("Communication", &["message", "phone", "envelope", "bubble.left", "bubble.left.and.bubble.right", "quote.bubble", "mic", "video", "bell", "megaphone", "antenna.radiowaves.left.and.right", "waveform"]),
    ("Shapes", &["circle", "square", "triangle", "diamond", "hexagon", "octagon", "seal", "capsule", "oval", "pentagon", "rhombus", "star", "heart", "suit.club", "suit.spade", "shield"]),
];

/// Tints a few pills, as an item's icon may.
fn tint(name: &str) -> Option<Tint> {
    match name {
        "sun.max" | "sunrise" | "lightbulb" | "bolt" => Some(Tint::Yellow),
        "flame" | "heart" => Some(Tint::Red),
        "leaf" | "tree" | "carrot" => Some(Tint::Green),
        "drop" | "cloud.rain" | "fish" => Some(Tint::Blue),
        _ => None,
    }
}

/// Every symbol a pill, by section; beside a preview, each one's detail. One name is far too long for a pill, and one
/// pill has no icon.
#[derive(Default)]
pub struct Symbols {
    preview: bool,
}

impl Symbols {
    pub fn beside_a_preview() -> Self {
        Symbols { preview: true }
    }
}

impl Screen for Symbols {
    fn render(&self, view: &str) -> ViewNode {
        let mut list = List::new(view).title(if self.preview { "Symbols Beside a Preview" } else { "Symbols" }).flow();
        for (section, names) in SYMBOLS {
            let mut items: Vec<Item> = names
                .iter()
                .map(|name| {
                    let icon = Icon::symbol(name);
                    let mut item = Item::new(name, name)
                        .icon(match tint(name) {
                            Some(tint) => icon.tint(tint),
                            None => icon,
                        })
                        .keywords(vec![section.to_lowercase()])
                        .actions(vec![Action::new("copy", "Copy Its Name"), Action::new("toast", "Show a Toast")]);
                    if self.preview {
                        let image = Icon::symbol(name);
                        item = item.detail(Detail::new(name).image(image).body(&format!("**{name}**")).row("Section", section));
                    }
                    item
                })
                .collect();
            if *section == "Shapes" {
                items.push(Item::new("long", "a name far too long for any pill to hold on one line, cut short").actions(vec![Action::new("toast", "Show a Toast")]));
                items.push(Item::new("plain", "no icon"));
            }
            list = list.section(section, items);
        }
        if self.preview {
            list = list.preview();
        }
        list.into()
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("copy", Some(name)) => {
                out.copy(name, false);
                out.dismiss();
            }
            _ => say(action, item, out),
        }
        false
    }
}
