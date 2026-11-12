//! The plugin dock2's tests drive (`Tests/Dock2PluginsTests`): one command per path the host must
//! survive — answering, showing a view, never returning, running out of memory, trapping.

use dock2_plugin::*;

#[derive(Default)]
struct Guest {
    events: u32,
    granted: Vec<String>,
    folder: String,
    local: String,
    parts: Vec<String>,
    printed: std::collections::BTreeMap<String, Vec<u8>>,
}

impl Plugin for Guest {
    fn handle(&mut self, event: Event, out: &mut Effects) {
        self.events += 1;
        match event {
            Event::Started { settings, granted } => {
                self.granted = granted;
                self.folder = settings.get("folder").cloned().unwrap_or_default();
                self.local = settings.get("local").cloned().unwrap_or_default();
                out.toast(&format!("started with {} settings", settings.len()))
            }
            Event::Granted { granted } => out.toast(&format!("granted {}", granted.join(" "))),
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
                    out.show_view(Grid { id: "grid".into(), title: Some("Sixty Things".into()), items, columns: Some(6), actions: None, scope: None, selected: None });
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
                // A write, then a read and a page of what it wrote, from one event: they see it.
                "store" => {
                    let mut batch = StorageBatch::default();
                    batch.set("item/1", "one").set("item/2", "two").set("item/3", "three").set("meta/n", "1");
                    out.storage_write(Some("w"), batch);
                    out.storage_read("rd", &["item/2", "nothing", "meta/n"]);
                    out.storage_list("ls", StorageList::prefix("item/").limit(2));
                }
                "store-next" => out.storage_list("ls", StorageList::prefix("item/").after("item/2")),
                "store-clear" => {
                    let mut batch = StorageBatch::default();
                    batch.delete_prefix("item/");
                    out.storage_write(None, batch);
                    out.storage_list("all", StorageList::all().keys_only());
                }
                "time" => out.toast(&format!("{}", now_ms() > 1_700_000_000_000)),
                "keep" => out.secret_set("k", "v"),
                "find" => out.secret_get("r3", "k"),
                "peek" => out.secret_get("r4", "dock2.setting.token"),
                "subscribe" => out.subscribe("nowPlaying"),
                "holds" => out.toast(&format!("holds {}", self.granted.join(" "))),
                // Its own `dock2.plugin`, which dock2 writes over.
                "xpc" => out.xpc_send(
                    Some("x1"),
                    "zip.tanner.dock2.test-service",
                    XpcValue::dictionary([("n", XpcValue::Int(7)), ("dock2.plugin", "forged".into())]),
                ),
                "run-echo" => out.run("echo", "echo", &[("text", "hi; rm -rf ~")], None),
                "run-dash" => out.run("dash", "echo", &[("text", "-n")], None),
                "run-where" => out.run("where", "where", &[("folder", &self.folder)], None),
                "run-outside" => out.run("outside", "where", &[("folder", "/etc")], None),
                "run-sleep" => out.run("sleep", "sleep", &[("text", "5")], None),
                "run-yes" => out.run("yes", "yes", &[], None),
                "run-signed" => out.run("signed", "signed", &[], None),
                "run-cat" => out.run("cat", "cat", &[], Some(b"piped in".to_vec())),
                "cancel-sleep" => out.cancel_run("sleep"),
                "file-write" => out.file_write("write", &format!("{}/notes/new.txt", self.folder), b"hello", false),
                "file-append" => out.file_write("append", &format!("{}/notes/new.txt", self.folder), b" world", true),
                "file-read" => out.file_read("read", &format!("{}/notes/new.txt", self.folder)),
                "file-list" => out.file_list("list", &self.folder),
                "file-stat" => out.file_stat("stat", &format!("{}/notes", self.folder)),
                "file-missing" => out.file_stat("missing", &format!("{}/nothing", self.folder)),
                "file-leak" => out.file_read("leak", &format!("{}/leak.txt", self.folder)),
                "file-climb" => out.file_read("climb", &format!("{}/notes/../../outside.txt", self.folder)),
                "local" => out.http("local", "POST", &format!("{}/echo?x=1", self.local), &[("X-Test", "yes")], Some(b"ping".to_vec())),
                "local-stream" => out.http_stream("stream", "GET", &format!("{}/stream", self.local), &[], None),
                "local-socket" => out.http_socket("socket", "/tmp/dock2-test-guest.sock", "GET", "http://localhost/v1/info", &[], None),
                "local-elsewhere" => out.http("elsewhere", "GET", "http://127.0.0.1:1/", &[], None),
                "plain-internet" => out.http("internet", "GET", "http://example.com/", &[], None),
                "watch" => out.watch("w", &self.folder),
                "unwatch" => out.unwatch("w"),
                "xpc-elsewhere" => out.xpc_send(None, "com.example.unnamed", XpcValue::dictionary([("n", XpcValue::Int(1))])),
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
            Event::StorageRead { request, entries } => out.toast(&format!(
                "values {request} {}",
                entries.iter().map(|e| format!("{}={}", e.key, e.value.as_deref().unwrap_or("?"))).collect::<Vec<_>>().join(" ")
            )),
            Event::StorageListed { request, entries, more } => out.toast(&format!(
                "keys {request} {} more={more}",
                entries.iter().map(|e| e.key.as_str()).collect::<Vec<_>>().join(" ")
            )),
            Event::StorageWritten { request } => out.toast(&format!("written {request}")),
            Event::Secret { key, value, .. } => out.toast(&format!("secret {key}={}", value.unwrap_or_default())),
            Event::Error { message, .. } => out.toast(&format!("error: {message}")),
            Event::XpcReply { message, .. } => out.toast(&format!(
                "reply from {} n={:?}",
                message.get("plugin").and_then(XpcValue::as_str).unwrap_or("?"),
                message.get("n")
            )),
            Event::XpcMessage { message, .. } => out.toast(&format!("unasked {}", message.get("note").and_then(XpcValue::as_str).unwrap_or("?"))),
            Event::XpcClosed { reason, .. } => out.toast(&format!("closed {reason}")),
            Event::FileRead { data, size, .. } => out.toast(&format!("read {size}: {}", String::from_utf8_lossy(&data))),
            Event::FileListed { entries, .. } => {
                out.toast(&format!("listed {}", entries.iter().map(|e| format!("{}:{}", e.name, e.kind)).collect::<Vec<_>>().join(" ")))
            }
            Event::FileStat { request, entry, .. } => out.toast(&format!("stat {request} {:?}", entry.map(|e| e.kind))),
            Event::FileWritten { request, .. } => out.toast(&format!("wrote {request}")),
            Event::FileChanged { paths, .. } => {
                out.toast(&format!("changed {}", paths.iter().map(|p| p.rsplit('/').next().unwrap_or("")).collect::<Vec<_>>().join(" ")))
            }
            Event::Output { request, data, .. } => self.printed.entry(request).or_default().extend(data),
            Event::Exited { request, status, signal, truncated, timed_out } => {
                let printed = self.printed.remove(&request).unwrap_or_default();
                let text = if printed.len() > 4000 { format!("{} bytes", printed.len()) } else { String::from_utf8_lossy(&printed).trim().to_string() };
                out.toast(&format!("exited {request} {status:?} {signal:?} truncated={truncated} timedOut={timed_out}: {text}"));
            }
            Event::HttpPart { request, status, body, .. } => {
                if let Some(status) = status {
                    self.parts.push(format!("{request} head {status}"));
                    out.toast(&format!("heard {request}"));
                }
                if let Some(body) = body {
                    self.parts.push(format!("{request} part {}", String::from_utf8_lossy(&body)));
                }
            }
            Event::Http { request, status, body, error, .. } if request != "r1" => out.toast(&format!(
                "http {request} {status:?} {:?} {error:?} parts=[{}]",
                body.map(|b| String::from_utf8_lossy(&b).to_string()),
                std::mem::take(&mut self.parts).join(", ")
            )),
            Event::Http { status, error, .. } => out.toast(&format!("http {status:?} {error:?}")),
            _ => {}
        }
    }
}

export!(Guest);
