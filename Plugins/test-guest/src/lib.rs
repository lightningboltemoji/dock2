//! The plugin dock2's tests drive (`Tests/Dock2PluginsTests`): one command per path the host must
//! survive — answering, showing a view, never returning, running out of memory, trapping.

use dock2_plugin::*;

#[derive(Default)]
struct Guest {
    events: u32,
}

impl Plugin for Guest {
    fn handle(&mut self, event: Event, out: &mut Effects) {
        self.events += 1;
        match event {
            Event::Started { settings } => out.toast(&format!("started with {} settings", settings.len())),
            Event::Command { id } => match id.as_str() {
                "echo" => out.toast(&format!("echo {}", self.events)),
                "view" => out.show_view(List::new("things").title("Things").preview().items(vec![
                    Item::new("1", "First").subtitle("one").tag(Tag::new("New").tint(Tint::Green)).actions(vec![Action::new("pick", "Pick")])
                        .detail(Detail::new("first").body("The **first** thing.").tags("Kinds", vec![Tag::new("Shared").tint(Tint::Blue), Tag::new("Plain")])),
                    Item::new("2", "Second"),
                ])),
                "grid" => {
                    let symbols = ["star", "heart", "bolt", "leaf", "flame", "drop", "moon", "sun.max", "cloud", "snowflake"];
                    let items = (0..60)
                        .map(|i| GridItem {
                            id: format!("{i}"),
                            image: Icon::symbol(symbols[i % symbols.len()]),
                            title: Some(format!("{} {i}", symbols[i % symbols.len()])),
                            actions: Some(vec![Action::new("pick", "Pick"), Action::new("look", "Look Closer")]),
                        })
                        .collect();
                    out.show_view(Grid { id: "grid".into(), title: Some("Sixty Things".into()), items, columns: Some(6), actions: None });
                }
                "spin" => loop {
                    std::hint::black_box(self.events);
                },
                "grow" => {
                    let mut hoard: Vec<Vec<u8>> = Vec::new();
                    loop {
                        hoard.push(vec![1u8; 8 << 20]);
                        std::hint::black_box(&hoard);
                    }
                }
                "trap" => panic!("asked to"),
                "fetch" => out.http("r1", "GET", "https://example.com/", &[], None),
                "forbidden" => out.copy("not granted", false),
                "remember" => out.storage_set("count", &self.events.to_string()),
                "recall" => out.storage_get("r2", "count"),
                "time" => out.toast(&format!("{}", now_ms() > 1_700_000_000_000)),
                "keep" => out.secret_set("k", "v"),
                "find" => out.secret_get("r3", "k"),
                "peek" => out.secret_get("r4", "dock2.setting.token"),
                _ => out.toast("unknown"),
            },
            // Typing is no action: dock2 refuses the URL.
            Event::Query { text, .. } if text == "open" => out.open("https://example.com/"),
            Event::Query { id, text } => {
                let items = ["apple", "banana", "cherry"]
                    .iter()
                    .filter(|name| name.contains(&text.to_lowercase()))
                    .map(|name| ResultItem { id: name.to_string(), title: name.to_string(), subtitle: None, icon: None, actions: vec![] })
                    .collect();
                out.results(id, items);
            }
            Event::Action { action, item: Some(item), .. } => out.toast(&format!("{action} {item}")),
            Event::Storage { key, value, .. } => out.toast(&format!("{key}={}", value.unwrap_or_default())),
            Event::Secret { key, value, .. } => out.toast(&format!("secret {key}={}", value.unwrap_or_default())),
            Event::Error { message, .. } => out.toast(&format!("error: {message}")),
            Event::Http { status, error, .. } => out.toast(&format!("http {status:?} {error:?}")),
            _ => {}
        }
    }
}

export!(Guest);
