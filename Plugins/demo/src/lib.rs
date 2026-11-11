//! The demo: every view dock2 draws, in every variation it knows, over made-up data
//! ([views](../../../.agents/product/plugins/views.md)). A debug run loads it; the app never ships it.

mod data;
mod details;
mod feedback;
mod forms;
mod gallery;
mod grids;
mod lists;
mod maximal;
mod png;
mod scopes;

use dock2_plugin::*;
use std::collections::BTreeMap;

/// One screen, made fresh as it opens and dropped as it closes, so every visit starts alike. `view` is its id;
/// what it pushes or times is named `<view>/<name>`, so what that hears comes back to it.
pub trait Screen {
    fn render(&self, view: &str) -> ViewNode;
    fn opened(&mut self, _view: &str, _out: &mut Effects) {}
    /// An action on the screen, or on a view it pushed; true redraws the screen.
    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        say(action, item, out);
        false
    }
    fn submit(&mut self, _view: &str, values: &BTreeMap<String, String>, out: &mut Effects) -> bool {
        out.toast(&format!("Submitted {} values", values.len()));
        false
    }
    /// For a list whose owner filters it: answer with `out.answer_filter(…, id)`.
    fn filter(&mut self, _view: &str, _text: &str, _id: u64, _out: &mut Effects) {}
    /// Another option of its scope chosen; true redraws the screen, or answer later with `out.answer_filter(…, id)`.
    fn scope(&mut self, _view: &str, _value: &str, _id: u64, _out: &mut Effects) -> bool {
        false
    }
    fn timer(&mut self, _view: &str, _name: &str, _out: &mut Effects) -> bool {
        false
    }
    /// A view it pushed, `<view>/<name>`, closed.
    fn popped(&mut self, _view: &str, _name: &str) {}
    fn closed(&mut self, _view: &str, _out: &mut Effects) {}
}

/// What an action that only reports itself does: says what ran on what.
pub fn say(action: &str, item: Option<&str>, out: &mut Effects) {
    match item {
        Some(item) => out.toast(&format!("“{action}” on {item}")),
        None => out.toast(&format!("“{action}”")),
    }
}

#[derive(Default)]
struct Demo {
    open: BTreeMap<String, Box<dyn Screen>>,
}

/// The screen a view or a timer belongs to: its id up to the first slash.
fn owner(id: &str) -> &str {
    id.split('/').next().unwrap_or(id)
}

impl Demo {
    fn open(&mut self, entry: &gallery::Entry, out: &mut Effects) {
        let mut screen = (entry.make)();
        out.show_view(screen.render(entry.id));
        screen.opened(entry.id, out);
        self.open.insert(entry.id.into(), screen);
    }

    /// Hands `event` to the screen `id` belongs to, and redraws the screen if it says so.
    fn route(&mut self, id: &str, out: &mut Effects, event: impl FnOnce(&mut dyn Screen, &str, &mut Effects) -> bool) {
        let view = owner(id);
        let Some(screen) = self.open.get_mut(view) else { return };
        if event(screen.as_mut(), view, out) {
            out.update_view(screen.render(view));
        }
    }
}

impl Plugin for Demo {
    fn handle(&mut self, event: Event, out: &mut Effects) {
        match event {
            // Drawn under the start's budget, not an action's.
            Event::Started { .. } => {
                png::pictures();
            }
            Event::Command { id } if id == "gallery" => out.show_view(gallery::render()),
            Event::Command { id } => {
                if let Some(entry) = gallery::entries().iter().find(|entry| entry.kind.command() == id) {
                    self.open(entry, out);
                }
            }
            Event::Action { item, view: Some(view), .. } if view == gallery::ID => {
                if let Some(entry) = gallery::entries().iter().find(|entry| Some(entry.id) == item.as_deref()) {
                    self.open(entry, out);
                }
            }
            Event::Action { action, item, view: Some(view), .. } => {
                self.route(&view, out, |screen, root, out| screen.action(root, &action, item.as_deref(), out))
            }
            Event::Submit { view, values } => self.route(&view, out, |screen, root, out| screen.submit(root, &values, out)),
            Event::Filter { view, text, id } => self.route(&view, out, |screen, root, out| {
                screen.filter(root, &text, id, out);
                false
            }),
            Event::Scope { view, value, id } => self.route(&view, out, |screen, root, out| screen.scope(root, &value, id, out)),
            Event::Timer { id } => {
                let name = id.split_once('/').map_or("", |(_, name)| name);
                self.route(&id, out, |screen, root, out| screen.timer(root, name, out))
            }
            Event::ViewClosed { view } => match view.split_once('/') {
                Some((root, name)) => {
                    if let Some(screen) = self.open.get_mut(root) {
                        screen.popped(root, name);
                    }
                }
                None => {
                    if let Some(mut screen) = self.open.remove(&view) {
                        screen.closed(&view, out);
                    }
                }
            },
            Event::Error { message, .. } => out.toast(&format!("Refused: {message}")),
            _ => {}
        }
    }
}

export!(Demo);

#[cfg(test)]
mod tests {
    use super::*;

    fn id(node: &ViewNode) -> &str {
        match node {
            ViewNode::List(list) => &list.id,
            ViewNode::Detail(detail) => &detail.id,
            ViewNode::Form(form) => &form.id,
            ViewNode::Grid(grid) => &grid.id,
        }
    }

    #[test]
    fn every_screen_draws_under_its_own_id() {
        let mut seen = std::collections::BTreeSet::new();
        for entry in gallery::entries() {
            assert!(seen.insert(entry.id), "{} listed twice", entry.id);
            assert!(!entry.id.contains('/'), "{}: a slash names a pushed view", entry.id);
            let node = (entry.make)().render(entry.id);
            assert_eq!(id(&node), entry.id);
            serde_json::to_vec(&node).unwrap();
        }
    }

    #[test]
    fn each_kind_has_a_command_in_the_manifest() {
        let manifest: serde_json::Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let commands: Vec<&str> = manifest["commands"].as_array().unwrap().iter().map(|command| command["id"].as_str().unwrap()).collect();
        for entry in gallery::entries() {
            assert!(commands.contains(&entry.kind.command()), "no command {}", entry.kind.command());
        }
    }

    #[test]
    fn a_saved_form_becomes_a_detail_in_place() {
        let mut demo = Demo::default();
        let mut out = Effects::default();
        demo.handle(Event::Command { id: "form".into() }, &mut out);
        let values = [("name", "Ada"), ("email", "ada@example.com"), ("password", "12345678")];
        let values = values.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        demo.handle(Event::Submit { view: "form.everything".into(), values }, &mut out);
        assert!(matches!(out.list.last(), Some(Effect::UpdateView { view: ViewNode::Detail(detail), .. }) if detail.id == "form.everything"));
    }
}
