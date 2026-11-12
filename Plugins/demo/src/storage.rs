//! Storage: notes kept one key each, listed by their prefix a page at a time as the screen opens, and still there
//! after dock2 quits.

use crate::{say, Screen};
use dock2_plugin::*;

const PREFIX: &str = "note/";

/// Kept notes, `note/0000000001` and on, so their keys sort as they were written.
#[derive(Default)]
pub struct Notes {
    notes: Vec<StorageEntry>,
    loaded: bool,
}

impl Notes {
    fn next_key(&self) -> String {
        let last = self.notes.last().and_then(|note| note.key.strip_prefix(PREFIX)?.parse::<u64>().ok()).unwrap_or(0);
        format!("{PREFIX}{:010}", last + 1)
    }
}

impl Screen for Notes {
    fn render(&self, view: &str) -> ViewNode {
        let items = self
            .notes
            .iter()
            .map(|note| {
                Item::new(&note.key, note.value.as_deref().unwrap_or(""))
                    .subtitle(&note.key)
                    .icon(Icon::symbol("note.text").tint(Tint::Yellow))
                    .actions(vec![Action::new("delete", "Delete This Note").icon(Icon::symbol("trash")).destructive()])
            })
            .collect();
        List::new(view)
            .title("Kept Notes")
            .items(items)
            .loading(!self.loaded)
            .empty("No notes kept", Some("⌘N keeps one, which is still here after dock2 quits."))
            .actions(vec![
                Action::new("add", "Keep a Note").key("cmd+n").icon(Icon::symbol("square.and.pencil")),
                Action::new("clear", "Delete Every Note").key("cmd+shift+d").icon(Icon::symbol("trash")).destructive(),
            ])
            .into()
    }

    fn opened(&mut self, view: &str, out: &mut Effects) {
        out.storage_list(&format!("{view}/list"), StorageList::prefix(PREFIX).limit(50));
    }

    fn listed(&mut self, view: &str, entries: Vec<StorageEntry>, more: bool, out: &mut Effects) -> bool {
        let last = entries.last().map(|entry| entry.key.clone());
        self.notes.extend(entries);
        match (more, last) {
            (true, Some(last)) => out.storage_list(&format!("{view}/list"), StorageList::prefix(PREFIX).after(&last).limit(50)),
            _ => self.loaded = true,
        }
        true
    }

    fn action(&mut self, view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        let mut batch = StorageBatch::default();
        match (action, item) {
            ("add", _) => {
                let key = self.next_key();
                let value = format!("Note {}", self.notes.len() + 1);
                batch.set(&key, &value);
                self.notes.push(StorageEntry { key, value: Some(value) });
            }
            ("delete", Some(key)) => {
                batch.delete(key);
                self.notes.retain(|note| note.key != key);
            }
            ("clear", _) => {
                batch.delete_prefix(PREFIX);
                self.notes.clear();
            }
            _ => {
                say(action, item, out);
                return false;
            }
        }
        out.storage_write(Some(&format!("{view}/write")), batch);
        true
    }

    fn written(&mut self, _view: &str, out: &mut Effects) {
        out.toast("Kept");
    }
}
