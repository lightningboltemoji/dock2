//! Views, as dock2 draws them ([views](../../../.agents/product/plugins/views.md)): the same JSON as
//! `Sources/Dock2Core/ViewNode.swift`. A plugin describes; dock2 renders.

use serde::{Deserialize, Serialize};

/// An image ([icons](../../../.agents/product/plugins/packaging.md#icons)): you choose what it is, dock2 how it
/// is drawn. Among apps' icons a symbol stands white on a square in its tint, else the manifest's, and a picture
/// fills one: give it square and edge to edge. A command or result without one wears the plugin's.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Icon {
    #[serde(flatten)]
    pub source: IconSource,
    /// A symbol's colour; dock2's violet is not among them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tint: Option<Tint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum IconSource {
    /// An SF Symbol, by name; among apps' icons, its `.fill` where it has one.
    Symbol(String),
    /// A picture: album art, a favicon, your own.
    Png(#[serde(with = "crate::base64_bytes")] Vec<u8>),
    /// A file's icon, as Finder shows it.
    File(String),
    /// An app's icon, by bundle id.
    App(String),
}

impl Icon {
    pub fn symbol(name: &str) -> Self {
        Icon { source: IconSource::Symbol(name.into()), tint: None }
    }
    pub fn png(bytes: Vec<u8>) -> Self {
        Icon { source: IconSource::Png(bytes), tint: None }
    }
    pub fn file(path: &str) -> Self {
        Icon { source: IconSource::File(path.into()), tint: None }
    }
    pub fn app(bundle_id: &str) -> Self {
        Icon { source: IconSource::App(bundle_id.into()), tint: None }
    }
    pub fn tint(mut self, tint: Tint) -> Self {
        self.tint = Some(tint);
        self
    }
}

/// Something to do: the first of a list is ↩, the second ⌘↩, all of them on ⌘K. `key` is one of the
/// ⌘- or ⌘⇧-letters left to plugins, written "cmd+shift+c".
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Action {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub destructive: Option<bool>,
}

impl Action {
    pub fn new(id: &str, title: &str) -> Self {
        Action { id: id.into(), title: title.into(), ..Default::default() }
    }
    pub fn key(mut self, key: &str) -> Self {
        self.key = Some(key.into());
        self
    }
    pub fn icon(mut self, icon: Icon) -> Self {
        self.icon = Some(icon);
        self
    }
    /// Asks before it runs.
    pub fn destructive(mut self) -> Self {
        self.destructive = Some(true);
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum ViewNode {
    List(List),
    Detail(Detail),
    Form(Form),
    Grid(Grid),
}

impl From<List> for ViewNode {
    fn from(node: List) -> Self {
        ViewNode::List(node)
    }
}
impl From<Detail> for ViewNode {
    fn from(node: Detail) -> Self {
        ViewNode::Detail(node)
    }
}
impl From<Form> for ViewNode {
    fn from(node: Form) -> Self {
        ViewNode::Form(node)
    }
}
impl From<Grid> for ViewNode {
    fn from(node: Grid) -> Self {
        ViewNode::Grid(node)
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Filtering {
    /// dock2 matches the field's text against every item.
    Dock2,
    /// The plugin is told the text, as `Event::Filter`, and answers with new items.
    Owner,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Layout {
    Rows,
    /// Pills side by side under each section's title, wrapping.
    Flow,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct List {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub sections: Vec<Section>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filtering: Option<Filtering>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub preview: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub empty: Option<EmptyState>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub loading: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actions: Option<Vec<Action>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub layout: Option<Layout>,
}

impl List {
    pub fn new(id: &str) -> Self {
        List { id: id.into(), ..Default::default() }
    }
    pub fn title(mut self, title: &str) -> Self {
        self.title = Some(title.into());
        self
    }
    pub fn items(mut self, items: Vec<Item>) -> Self {
        self.sections = vec![Section { title: None, items }];
        self
    }
    pub fn section(mut self, title: &str, items: Vec<Item>) -> Self {
        self.sections.push(Section { title: Some(title.into()), items });
        self
    }
    pub fn preview(mut self) -> Self {
        self.preview = Some(true);
        self
    }
    pub fn loading(mut self, loading: bool) -> Self {
        self.loading = Some(loading);
        self
    }
    pub fn empty(mut self, title: &str, subtitle: Option<&str>) -> Self {
        self.empty = Some(EmptyState { title: title.into(), subtitle: subtitle.map(Into::into) });
        self
    }
    pub fn filtering(mut self, filtering: Filtering) -> Self {
        self.filtering = Some(filtering);
        self
    }
    /// The view's own, on ⌘K after the selected item's.
    pub fn actions(mut self, actions: Vec<Action>) -> Self {
        self.actions = Some(actions);
        self
    }
    /// Which of its items it shows, chosen from a menu along the panel's top.
    pub fn scope(mut self, scope: Scope) -> Self {
        self.scope = Some(scope);
        self
    }
    /// The item to select, by id, scrolled to the middle if out of sight. Taken when the view opens and whenever an
    /// update names another, never on a redraw that names the same, so the user's own selection stands.
    pub fn selected(mut self, item: &str) -> Self {
        self.selected = Some(item.into());
        self
    }
    /// Its items as pills side by side under each section's title, wrapping where the next would not fit: denser,
    /// for short items. A pill shows an item's title and icon; the arrows walk them as a grid's. Never a tree.
    pub fn flow(mut self) -> Self {
        self.layout = Some(Layout::Flow);
        self
    }
}

/// Which of a list's or a grid's items it shows — Local, Remote, one server of several — chosen from a menu along
/// the panel's top, which ⌘P opens. dock2 draws it and sends [`crate::Event::Scope`] when another option is chosen;
/// answer with the items that option leaves, the scope's `value` now naming it.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Scope {
    /// The option chosen, by id.
    pub value: String,
    pub sections: Vec<ScopeSection>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ScopeSection {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub options: Vec<ScopeOption>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct ScopeOption {
    pub id: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
}

impl ScopeOption {
    pub fn new(id: &str, title: &str) -> Self {
        ScopeOption { id: id.into(), title: title.into(), icon: None }
    }
    pub fn icon(mut self, icon: Icon) -> Self {
        self.icon = Some(icon);
        self
    }
}

impl Scope {
    /// `value` names the option chosen: one of those added.
    pub fn new(value: &str) -> Self {
        Scope { value: value.into(), sections: Vec::new() }
    }
    /// Options without a title, after those already added.
    pub fn options(mut self, options: Vec<ScopeOption>) -> Self {
        self.sections.push(ScopeSection { title: None, options });
        self
    }
    /// Options under a title: "Servers".
    pub fn section(mut self, title: &str, options: Vec<ScopeOption>) -> Self {
        self.sections.push(ScopeSection { title: Some(title.into()), options });
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Section {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub items: Vec<Item>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Accessory {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag: Option<Tag>,
}

/// The only colours a view can name: the system's own, as dock2 draws them.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Tint {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Pink,
    Gray,
}

/// A short label in a rounded pill.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Tag {
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tint: Option<Tint>,
}

impl Tag {
    pub fn new(text: &str) -> Self {
        Tag { text: text.into(), tint: None }
    }
    pub fn tint(mut self, tint: Tint) -> Self {
        self.tint = Some(tint);
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Item {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Icon>,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accessories: Option<Vec<Accessory>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub keywords: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actions: Option<Vec<Action>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<Detail>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<Item>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expanded: Option<bool>,
}

impl Item {
    pub fn new(id: &str, title: &str) -> Self {
        Item { id: id.into(), title: title.into(), ..Default::default() }
    }
    pub fn subtitle(mut self, subtitle: &str) -> Self {
        self.subtitle = Some(subtitle.into());
        self
    }
    pub fn icon(mut self, icon: Icon) -> Self {
        self.icon = Some(icon);
        self
    }
    pub fn keywords(mut self, keywords: Vec<String>) -> Self {
        self.keywords = Some(keywords);
        self
    }
    pub fn actions(mut self, actions: Vec<Action>) -> Self {
        self.actions = Some(actions);
        self
    }
    pub fn detail(mut self, detail: Detail) -> Self {
        self.detail = Some(detail);
        self
    }
    pub fn accessory(mut self, text: &str) -> Self {
        self.accessories.get_or_insert_with(Vec::new).push(Accessory { text: Some(text.into()), ..Default::default() });
        self
    }
    pub fn tag(mut self, tag: Tag) -> Self {
        self.accessories.get_or_insert_with(Vec::new).push(Accessory { tag: Some(tag), ..Default::default() });
        self
    }
    pub fn accessory_icon(mut self, icon: Icon) -> Self {
        self.accessories.get_or_insert_with(Vec::new).push(Accessory { icon: Some(icon), ..Default::default() });
        self
    }
    /// The items under it, which make its list a tree: → and ← open and close it, and typing shows each match under
    /// the items it stands in. Ids are unique across the whole tree.
    pub fn children(mut self, children: Vec<Item>) -> Self {
        self.children = Some(children);
        self
    }
    /// Open, its children showing. Taken as [`List::selected`] is, when it differs from the last given; after that, open
    /// or closed is the user's.
    pub fn expanded(mut self) -> Self {
        self.expanded = Some(true);
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct EmptyState {
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subtitle: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Metadata {
    pub label: String,
    pub value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub link: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tags: Option<Vec<Tag>>,
    /// A secret: dock2 draws a mask of fixed length in its place, never a value.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub masked: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Detail {
    pub id: String,
    /// Markdown, inline.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<Icon>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metadata: Option<Vec<Metadata>>,
    /// Short facts in one line along its foot, which stays while the body scrolls.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scrubber: Option<Scrubber>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actions: Option<Vec<Action>>,
}

/// A position to drag, between 0 and `maximum`; let go, the view hears a submit of `{id: value}`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Scrubber {
    pub id: String,
    pub value: f64,
    pub maximum: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub leading: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trailing: Option<String>,
}

impl Detail {
    pub fn scrubber(mut self, scrubber: Scrubber) -> Self {
        self.scrubber = Some(scrubber);
        self
    }
    pub fn new(id: &str) -> Self {
        Detail { id: id.into(), ..Default::default() }
    }
    pub fn body(mut self, body: &str) -> Self {
        self.body = Some(body.into());
        self
    }
    pub fn image(mut self, image: Icon) -> Self {
        self.image = Some(image);
        self
    }
    pub fn row(mut self, label: &str, value: &str) -> Self {
        self.metadata.get_or_insert_with(Vec::new).push(Metadata { label: label.into(), value: value.into(), ..Default::default() });
        self
    }
    /// A row whose value opens `url`.
    pub fn link(mut self, label: &str, value: &str, url: &str) -> Self {
        self.metadata.get_or_insert_with(Vec::new).push(Metadata { label: label.into(), value: value.into(), link: Some(url.into()), ..Default::default() });
        self
    }
    /// A row standing for a secret — a password — that dock2 masks: the secret itself stays in the plugin.
    pub fn masked(mut self, label: &str) -> Self {
        self.metadata.get_or_insert_with(Vec::new).push(Metadata { label: label.into(), masked: Some(true), ..Default::default() });
        self
    }
    /// A row of tags under its label: "Shared", "2FA".
    pub fn tags(mut self, label: &str, tags: Vec<Tag>) -> Self {
        self.metadata.get_or_insert_with(Vec::new).push(Metadata { label: label.into(), tags: Some(tags), ..Default::default() });
        self
    }
    /// The status line: "Safari", "5 min ago".
    pub fn status(mut self, facts: &[&str]) -> Self {
        self.status = Some(facts.iter().map(|fact| fact.to_string()).collect());
        self
    }
    pub fn actions(mut self, actions: Vec<Action>) -> Self {
        self.actions = Some(actions);
        self
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum FieldKind {
    Text,
    Secure,
    Multiline,
    Toggle,
    Choice,
    Date,
    Folder,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FieldOption {
    pub value: String,
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Field {
    pub id: String,
    pub title: String,
    pub kind: FieldKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub options: Option<Vec<FieldOption>>,
}

impl Field {
    pub fn new(id: &str, title: &str, kind: FieldKind) -> Self {
        Field { id: id.into(), title: title.into(), kind, value: None, placeholder: None, error: None, options: None }
    }
    pub fn value(mut self, value: &str) -> Self {
        self.value = Some(value.into());
        self
    }
    pub fn placeholder(mut self, placeholder: &str) -> Self {
        self.placeholder = Some(placeholder.into());
        self
    }
    pub fn error(mut self, error: Option<&str>) -> Self {
        self.error = error.map(Into::into);
        self
    }
    /// A choice's options, each its value and its title.
    pub fn options(mut self, options: &[(&str, &str)]) -> Self {
        self.options = Some(options.iter().map(|(value, title)| FieldOption { value: value.to_string(), title: title.to_string() }).collect());
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Form {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub fields: Vec<Field>,
    /// The submit button's title; ⌘↩ presses it.
    pub submit: String,
}

impl Form {
    pub fn new(id: &str, submit: &str) -> Self {
        Form { id: id.into(), title: None, fields: Vec::new(), submit: submit.into() }
    }
    pub fn title(mut self, title: &str) -> Self {
        self.title = Some(title.into());
        self
    }
    pub fn field(mut self, field: Field) -> Self {
        self.fields.push(field);
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GridItem {
    pub id: String,
    pub image: Icon,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actions: Option<Vec<Action>>,
}

impl GridItem {
    pub fn new(id: &str, image: Icon) -> Self {
        GridItem { id: id.into(), image, title: None, actions: None }
    }
    pub fn title(mut self, title: &str) -> Self {
        self.title = Some(title.into());
        self
    }
    pub fn actions(mut self, actions: Vec<Action>) -> Self {
        self.actions = Some(actions);
        self
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Grid {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub items: Vec<GridItem>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub columns: Option<u32>,
    /// The view's own, on ⌘K after the selected item's.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actions: Option<Vec<Action>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
}

impl Grid {
    pub fn new(id: &str, items: Vec<GridItem>) -> Self {
        Grid { id: id.into(), title: None, items, columns: None, actions: None, scope: None, selected: None }
    }
    /// The item to select, by id, as [`List::selected`].
    pub fn selected(mut self, item: &str) -> Self {
        self.selected = Some(item.into());
        self
    }
    /// Which of its items it shows, chosen from a menu along the panel's top.
    pub fn scope(mut self, scope: Scope) -> Self {
        self.scope = Some(scope);
        self
    }
    pub fn title(mut self, title: &str) -> Self {
        self.title = Some(title.into());
        self
    }
    /// Five when unsaid.
    pub fn columns(mut self, columns: u32) -> Self {
        self.columns = Some(columns);
        self
    }
    pub fn actions(mut self, actions: Vec<Action>) -> Self {
        self.actions = Some(actions);
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_icon_is_one_key_and_its_tint() {
        let tinted = Icon::symbol("forward").tint(Tint::Pink);
        assert_eq!(serde_json::to_string(&tinted).unwrap(), r#"{"symbol":"forward","tint":"pink"}"#);
        assert_eq!(serde_json::to_string(&Icon::app("com.apple.Safari")).unwrap(), r#"{"app":"com.apple.Safari"}"#);
        assert_eq!(serde_json::from_str::<Icon>(r#"{"symbol":"forward","tint":"pink"}"#).unwrap(), tinted);
        assert_eq!(serde_json::from_str::<Icon>(r#"{"png":"AQI="}"#).unwrap(), Icon::png(vec![1, 2]));
    }

    /// A scope as dock2 reads it: the choice by id, its options in sections, the untitled first.
    #[test]
    fn a_scope_is_its_choice_and_its_sections() {
        let list = List::new("servers").scope(
            Scope::new("local")
                .options(vec![ScopeOption::new("all", "All"), ScopeOption::new("local", "Local")])
                .section("Servers", vec![ScopeOption::new("nas", "nas.local").icon(Icon::symbol("server.rack"))]),
        );
        let json = serde_json::to_value(ViewNode::from(list)).unwrap();
        assert_eq!(json["scope"]["value"], "local");
        assert!(json["scope"]["sections"][0].get("title").is_none());
        assert_eq!(json["scope"]["sections"][1]["title"], "Servers");
        assert_eq!(json["scope"]["sections"][1]["options"][0]["icon"]["symbol"], "server.rack");
    }
}
