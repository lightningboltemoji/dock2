//! Details: every combination of their parts, and the shapes they are most often: text alone, a picture
//! and a line, metadata, a player.

use crate::data::{self, Rng};
use crate::png::pictures;
use crate::{say, Screen};
use dock2_plugin::*;
use std::collections::BTreeMap;

/// Paragraphs of made-up prose, a blank line between them.
pub fn long_body(rng: &mut Rng, paragraphs: usize) -> String {
    (0..paragraphs).map(|_| data::paragraph(rng, 5)).collect::<Vec<_>>().join("\n\n")
}

pub const MARKDOWN: &str = "**Bold**, *italic*, ***both***, `code`, and [a link](https://example.com). Inline only: # a heading, - a list \
                        item and > a quote stay as typed.\nA second line, after a newline.";

/// Every kind of metadata row: plain, a link, tags alone and after a value, masked, and long.
pub fn with_metadata(mut detail: Detail, rng: &mut Rng) -> Detail {
    detail = detail
        .row("Owner", &data::person(rng))
        .link("Website", "example.com", "https://example.com/")
        .tags("Labels", vec![Tag::new("Shared").tint(Tint::Blue), Tag::new("2FA").tint(Tint::Green), Tag::new("Archived")]);
    detail.metadata.get_or_insert_with(Vec::new).push(Metadata {
        label: "Status".into(),
        value: "Active".into(),
        tags: Some(vec![Tag::new("Synced").tint(Tint::Green)]),
        ..Default::default()
    });
    detail.masked("Password").row("Notes", &data::paragraph(rng, 2))
}

/// The detail's images, in the order Next Image walks them.
fn image(index: usize) -> (&'static str, Option<Icon>) {
    let pictures = pictures();
    match index {
        0 => ("Square picture at 2×", Some(Icon::png(pictures.square.clone()))),
        1 => ("Wide picture", Some(Icon::png(pictures.wide.clone()))),
        2 => ("Tall picture", Some(Icon::png(pictures.tall.clone()))),
        3 => ("Picture at 1×", Some(Icon::png(pictures.low.clone()))),
        4 => ("Hairlines at 2×", Some(Icon::png(pictures.stripes.clone()))),
        5 => ("A symbol", Some(Icon::symbol("sparkles").tint(Tint::Purple))),
        6 => ("An app's icon", Some(Icon::app("com.apple.Safari"))),
        7 => ("A file's icon", Some(Icon::file("/Applications"))),
        _ => ("No image", None),
    }
}
const IMAGES: usize = 9;

const BODIES: [&str; 4] = ["No body", "A line", "Markdown", "A long body"];

// ---- every combination ----------------------------------------------------------------------------

pub struct Everything {
    image: usize,
    body: usize,
    metadata: bool,
    scrubber: bool,
    status: bool,
    position: f64,
}

impl Default for Everything {
    fn default() -> Self {
        Everything { image: 0, body: 2, metadata: true, scrubber: true, status: true, position: 42.0 }
    }
}

impl Screen for Everything {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(5);
        let (image_name, image) = image(self.image);
        let mut detail = Detail::new(view);
        if let Some(image) = image {
            detail = detail.image(image);
        }
        detail = match self.body {
            1 => detail.body("One line of body."),
            2 => detail.body(MARKDOWN),
            3 => detail.body(&long_body(&mut rng, 5)),
            _ => detail,
        };
        if self.metadata {
            detail = with_metadata(detail, &mut rng);
        }
        if self.scrubber {
            detail = detail.scrubber(Scrubber {
                id: "position".into(),
                value: self.position,
                maximum: 100.0,
                leading: Some(data::clock(self.position)),
                trailing: Some(data::clock(100.0)),
            });
        }
        if self.status {
            detail = detail.status(&[image_name, BODIES[self.body], "Demo"]);
        }
        let switch = |on: bool, part: &str| format!("{} {part}", if on { "Hide" } else { "Show" });
        detail
            .actions(vec![
                Action::new("image", "Next Image").key("cmd+i").icon(Icon::symbol("photo")),
                Action::new("body", "Next Body").key("cmd+b").icon(Icon::symbol("text.alignleft")),
                Action::new("metadata", &switch(self.metadata, "Metadata")).key("cmd+e"),
                Action::new("scrubber", &switch(self.scrubber, "Scrubber")).key("cmd+u"),
                Action::new("status", &switch(self.status, "Status")).key("cmd+t"),
            ])
            .into()
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "image" => self.image = (self.image + 1) % IMAGES,
            "body" => self.body = (self.body + 1) % BODIES.len(),
            "metadata" => self.metadata = !self.metadata,
            "scrubber" => self.scrubber = !self.scrubber,
            "status" => self.status = !self.status,
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }

    fn submit(&mut self, _view: &str, values: &BTreeMap<String, String>, out: &mut Effects) -> bool {
        let Some(position) = values.get("position").and_then(|value| value.parse().ok()) else { return false };
        self.position = position;
        out.toast(&format!("Scrubbed to {}", data::clock(position)));
        true
    }
}

// ---- text alone -----------------------------------------------------------------------------------

pub struct Text;

impl Screen for Text {
    fn render(&self, view: &str) -> ViewNode {
        let body = format!("{MARKDOWN}\n\n{}", long_body(&mut Rng::new(12), 10));
        Detail::new(view).body(&body).status(&["Demo", "11 paragraphs", "Edited Yesterday"]).into()
    }
}

// ---- a picture and a line -------------------------------------------------------------------------

pub struct Picture;

impl Screen for Picture {
    fn render(&self, view: &str) -> ViewNode {
        Detail::new(view)
            .image(Icon::png(pictures().square.clone()))
            .body("**Midnight Lattice** — Ada Lovelace")
            .status(&["Demo", "Analytical Engines", "2026"])
            .actions(vec![
                Action::new("play", "Play").icon(Icon::symbol("play.fill")),
                Action::new("share", "Share").icon(Icon::symbol("square.and.arrow.up")).key("cmd+shift+s"),
            ])
            .into()
    }
}

// ---- metadata -------------------------------------------------------------------------------------

pub struct MetadataOnly;

impl Screen for MetadataOnly {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(9);
        with_metadata(Detail::new(view), &mut rng)
            .row("Created", "2 November 2026 at 09:41")
            .row("Size", &data::size(&mut rng))
            .row("Empty value", "")
            .link("A long link", "https://example.com/a/path/long/enough/to/wrap/past/the/edge/of/the/panel/and/onto/a/second/line", "https://example.com/")
            .masked("Another secret")
            .status(&["Demo", "11 rows"])
            .into()
    }
}

// ---- a player -------------------------------------------------------------------------------------

const TRACKS: &[(&str, &str, &str, f64)] = &[
    ("Midnight Lattice", "Ada Lovelace", "Analytical Engines", 217.0),
    ("Compiler Blues", "Grace Hopper", "Nanoseconds", 184.0),
    ("Go To Considered", "Edsger Dijkstra", "Structured", 251.0),
    ("Apollo Guidance", "Margaret Hamilton", "Lunar Module", 302.0),
    ("The Halting Song", "Alan Turing", "Decidable", 45.0),
];

pub struct Player {
    track: usize,
    position: f64,
    playing: bool,
}

impl Default for Player {
    fn default() -> Self {
        Player { track: 0, position: 0.0, playing: true }
    }
}

impl Player {
    fn skip(&mut self, by: isize) {
        self.track = (self.track as isize + by).rem_euclid(TRACKS.len() as isize) as usize;
        self.position = 0.0;
    }
}

impl Screen for Player {
    fn render(&self, view: &str) -> ViewNode {
        let (title, artist, album, duration) = TRACKS[self.track];
        let track = format!("{} of {}", self.track + 1, TRACKS.len());
        Detail::new(view)
            .image(Icon::png(pictures().square.clone()))
            .body(&format!("**{title}**\n{artist} — {album}"))
            .scrubber(Scrubber {
                id: "position".into(),
                value: self.position,
                maximum: duration,
                leading: Some(data::clock(self.position)),
                trailing: Some(format!("-{}", data::clock(duration - self.position))),
            })
            .status(&["Demo Player", &track, if self.playing { "Playing" } else { "Paused" }])
            .actions(vec![
                Action::new("toggle", if self.playing { "Pause" } else { "Play" }).icon(Icon::symbol(if self.playing { "pause.fill" } else { "play.fill" })),
                Action::new("next", "Next Track").icon(Icon::symbol("forward.fill")).key("cmd+shift+n"),
                Action::new("previous", "Previous Track").icon(Icon::symbol("backward.fill")).key("cmd+shift+b"),
            ])
            .into()
    }

    fn opened(&mut self, view: &str, out: &mut Effects) {
        out.timer(&format!("{view}/tick"), 1000, true);
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "toggle" => self.playing = !self.playing,
            "next" => self.skip(1),
            "previous" => self.skip(-1),
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }

    fn submit(&mut self, _view: &str, values: &BTreeMap<String, String>, _out: &mut Effects) -> bool {
        let Some(position) = values.get("position").and_then(|value| value.parse::<f64>().ok()) else { return false };
        self.position = position.clamp(0.0, TRACKS[self.track].3);
        true
    }

    fn timer(&mut self, _view: &str, _name: &str, _out: &mut Effects) -> bool {
        if !self.playing {
            return false;
        }
        self.position += 1.0;
        if self.position >= TRACKS[self.track].3 {
            self.skip(1);
        }
        true
    }

    fn closed(&mut self, view: &str, out: &mut Effects) {
        out.cancel_timer(&format!("{view}/tick"));
    }
}
