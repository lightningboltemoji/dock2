//! Everything an action can answer with: toasts, a confirmation, notices after a dismissal, a page opened,
//! views pushed, popped and closed, and effects dock2 refuses.

use crate::{say, Screen};
use dock2_plugin::*;

const ROWS: &[(&str, &str, &str, &str)] = &[
    ("toast", "A toast", "text.bubble", "Just above the panel for 2 s"),
    ("toast-long", "A long toast", "text.bubble.fill", "Longer than the panel is wide"),
    ("toast-two", "Two toasts at once", "bubble.left.and.bubble.right", "Which one stays?"),
    ("confirm", "A confirmation", "exclamationmark.triangle", "A destructive action asks first: ↩ or Esc"),
    ("notice", "Copy, dismiss, notice", "doc.on.doc", "“Copied” where the field was"),
    ("notice-long", "A long notice", "text.alignleft", "A sentence stays up longer"),
    ("open", "Open a page", "safari", "example.com, in the browser"),
    ("push", "Push views", "square.stack", "A stack of details, each pushing the next"),
    ("pop", "Pop this list", "arrow.uturn.backward", "Back to whatever opened it"),
    ("close", "Close every view", "xmark.square", "Back to search"),
    ("dismiss", "Dismiss dock2", "escape", "dock2 lets go"),
    ("refused", "An effect dock2 refuses", "hand.raised", "A secret, without the capability: an error comes back"),
    ("update-missing", "Update a view that isn't open", "questionmark.square.dashed", "Refused, and the plugin's log says so"),
];

const LONG: &str = "A notice long enough to be a sentence stays up longer than a word does: a character's eighteenth of a second, six seconds at most.";

#[derive(Default)]
pub struct Everything {
    depth: u32,
}

impl Everything {
    fn pushed(&self, view: &str) -> Detail {
        Detail::new(&format!("{view}/pushed-{}", self.depth))
            .body(&format!("**{} deep.** Esc pops one; Close Every View pops them all.", self.depth))
            .status(&["Pushed", &format!("Depth {}", self.depth)])
            .actions(vec![
                Action::new("push-more", "Push Another").key("cmd+n").icon(Icon::symbol("plus.square.on.square")),
                Action::new("pop-pushed", "Pop This One").icon(Icon::symbol("arrow.uturn.backward")),
                Action::new("close", "Close Every View").icon(Icon::symbol("xmark")),
            ])
    }
}

impl Screen for Everything {
    fn render(&self, view: &str) -> ViewNode {
        let items = ROWS
            .iter()
            .map(|(id, title, symbol, subtitle)| {
                let action = Action::new(id, title);
                let action = if *id == "confirm" { Action::new(id, "Do the Irreversible Thing").destructive() } else { action };
                Item::new(id, title).subtitle(subtitle).icon(Icon::symbol(symbol)).actions(vec![action])
            })
            .collect();
        List::new(view).title("Feedback").items(items).into()
    }

    fn action(&mut self, view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "toast" => out.toast("A short toast"),
            "toast-long" => out.toast(LONG),
            "toast-two" => {
                out.toast("The first of two toasts");
                out.toast("The second of two toasts");
            }
            "confirm" => out.toast("Done: it was only a demo"),
            "notice" => {
                out.copy("Copied by the demo", false);
                out.dismiss();
                out.toast("Copied");
            }
            "notice-long" => {
                out.dismiss();
                out.toast(LONG);
            }
            "open" => out.open("https://example.com/"),
            "push" | "push-more" => {
                self.depth += 1;
                out.show_view(self.pushed(view));
            }
            "pop" => out.pop_view(),
            "pop-pushed" => out.pop_view(),
            "close" => out.close_view(),
            "dismiss" => out.dismiss(),
            "refused" => out.secret_set("demo", "never kept"),
            "update-missing" => {
                out.update_view(Detail::new("nowhere"));
                out.toast("Refused: dock2's log says “no open view”");
            }
            _ => say(action, item, out),
        }
        false
    }

    fn popped(&mut self, _view: &str, _name: &str) {
        self.depth = self.depth.saturating_sub(1);
    }
}
