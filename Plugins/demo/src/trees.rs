//! Trees: a project's folders and files, items under items, alone and beside a preview.

use crate::{say, Screen};
use dock2_plugin::*;

/// A folder or a file, by name.
enum Node {
    Folder(&'static str, Vec<Node>),
    File(&'static str, &'static str),
}

use Node::{File, Folder};

fn project() -> Vec<Node> {
    vec![
        Folder(
            "src",
            vec![
                Folder("app", vec![File("main.rs", "4 KB"), File("window.rs", "11 KB"), File("menu.rs", "3 KB")]),
                Folder(
                    "views",
                    vec![
                        File("list.rs", "18 KB"),
                        File("detail.rs", "9 KB"),
                        File("form.rs", "12 KB"),
                        File("grid.rs", "7 KB"),
                        Folder("tree", vec![File("outline.rs", "6 KB"), File("rows.rs", "5 KB")]),
                    ],
                ),
                File("lib.rs", "2 KB"),
            ],
        ),
        Folder("tests", vec![File("views.rs", "14 KB"), File("outline.rs", "8 KB")]),
        Folder("docs", vec![File("guide.md", "22 KB"), File("api.md", "31 KB"), Folder("pictures", vec![File("overview.png", "412 KB"), File("tree.png", "388 KB")])]),
        Folder("assets", vec![]),
        File("Cargo.toml", "1 KB"),
        File("README.md", "6 KB"),
    ]
}

/// Files changed since the last commit: a tag on their rows.
const MODIFIED: &[&str] = &["src/views/list.rs", "src/views/tree/outline.rs", "docs/guide.md"];

fn icon(name: &str) -> Icon {
    match name.rsplit_once('.').map(|(_, extension)| extension) {
        Some("md") => Icon::symbol("doc.richtext").tint(Tint::Orange),
        Some("png") => Icon::symbol("photo").tint(Tint::Purple),
        Some("toml") => Icon::symbol("gearshape").tint(Tint::Gray),
        _ => Icon::symbol("doc.text").tint(Tint::Gray),
    }
}

/// The nodes as items, each id its path; `preview` gives each its detail.
fn items(nodes: &[Node], parent: &str, preview: bool) -> Vec<Item> {
    nodes
        .iter()
        .map(|node| match node {
            Folder(name, children) => {
                let path = format!("{parent}{name}");
                let count = if children.len() == 1 { "1 item".to_string() } else { format!("{} items", children.len()) };
                let mut item = Item::new(&path, name).icon(Icon::symbol("folder").tint(Tint::Blue)).subtitle(&count);
                if path == "docs" {
                    item = item.actions(vec![Action::new("publish", "Publish the Docs").icon(Icon::symbol("paperplane"))]);
                }
                if preview {
                    item = item.detail(Detail::new(&path).body(&format!("**{name}**, a folder")).row("Items", &count).row("Where", &format!("/{path}")));
                }
                // An empty folder is a row like a file's: there is nothing under it to show.
                item.children(items(children, &format!("{path}/"), preview))
            }
            File(name, size) => {
                let path = format!("{parent}{name}");
                let mut item = Item::new(&path, name).icon(icon(name)).subtitle(size).actions(vec![
                    Action::new("open", "Open").icon(Icon::symbol("arrow.up.forward.app")),
                    Action::new("copy", "Copy Path").icon(Icon::symbol("doc.on.doc")),
                ]);
                if MODIFIED.contains(&path.as_str()) {
                    item = item.tag(Tag::new("Modified").tint(Tint::Orange));
                }
                if preview {
                    item = item.detail(Detail::new(&path).body(&format!("**{name}**\n\nA made-up file in a made-up project, {size}.")).row("Size", size).row("Where", &format!("/{path}")));
                }
                item
            }
        })
        .collect()
}

/// `src` open and `src/views` closed, as a plugin names where its tree starts.
fn opened(mut items: Vec<Item>) -> Vec<Item> {
    if let Some(src) = items.iter_mut().find(|item| item.id == "src") {
        src.expanded = Some(true);
    }
    items
}

/// A project's files, `src` open; files run their actions on ↩, a folder opens or closes, but for `docs`, which has an
/// action of its own. Adding a file redraws the tree, which keeps what is open and selected.
#[derive(Default)]
pub struct Project {
    added: usize,
    preview: bool,
}

impl Project {
    pub fn beside_a_preview() -> Self {
        Project { added: 0, preview: true }
    }
}

impl Screen for Project {
    fn render(&self, view: &str) -> ViewNode {
        let mut nodes = project();
        if let Some(Folder(_, src)) = nodes.first_mut() {
            if let Some(Folder(_, views)) = src.get_mut(1) {
                const NEW: [&str; 4] = ["scope.rs", "flow.rs", "pills.rs", "chips.rs"];
                views.extend(NEW.iter().take(self.added).map(|name| File(name, "1 KB")));
            }
        }
        let mut list = List::new(view)
            .title(if self.preview { "Project Beside a Preview" } else { "Project" })
            .items(opened(items(&nodes, "", self.preview)))
            .actions(vec![Action::new("add", "Add a File to src/views").key("cmd+n").icon(Icon::symbol("doc.badge.plus"))]);
        if self.preview {
            list = list.preview();
        }
        list.into()
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("add", _) if self.added < 4 => {
                self.added += 1;
                true
            }
            ("add", _) => {
                out.toast("src/views is full");
                false
            }
            ("copy", Some(path)) => {
                out.copy(&format!("/{path}"), false);
                out.dismiss();
                false
            }
            _ => {
                say(action, item, out);
                false
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every id is a path, unique across the tree; `src` opens and nothing else does.
    #[test]
    fn a_projects_ids_are_its_paths() {
        fn walk(items: &[Item], ids: &mut Vec<String>) {
            for item in items {
                ids.push(item.id.clone());
                walk(item.children.as_deref().unwrap_or_default(), ids);
            }
        }
        let tree = opened(items(&project(), "", false));
        let mut ids = Vec::new();
        walk(&tree, &mut ids);
        let count = ids.len();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), count);
        assert!(ids.contains(&"src/views/tree/outline.rs".to_string()) && ids.contains(&"tests/outline.rs".to_string()));
        assert_eq!(tree.iter().filter(|item| item.expanded == Some(true)).map(|item| item.id.as_str()).collect::<Vec<_>>(), ["src"]);
    }
}
