//! Scopes: a list, a grid and a menu too long for its room, each narrowed by the menu along the panel's top.

use crate::data::{self, Rng, SYMBOLS, TINTS};
use crate::Screen;
use dock2_plugin::*;

// ---- a list scoped to a server -------------------------------------------------------------------

/// Where a share lives: on this Mac, or on a server.
struct Share {
    id: String,
    title: &'static str,
    server: &'static str,
}

const SERVERS: &[(&str, &str, &str)] = &[
    ("nas", "nas.local", "externaldrive.connected.to.line.below"),
    ("mini", "mini.local", "macmini"),
    ("pi", "pi.local", "cpu"),
    ("vps-1", "vps-1.example.com", "server.rack"),
    ("vps-2", "vps-2.example.com", "server.rack"),
];

const SHARES: &[(&str, &str)] = &[
    ("Macintosh HD", "mac"),
    ("Downloads", "mac"),
    ("Projects", "mac"),
    ("Media", "nas"),
    ("Backups", "nas"),
    ("Photos", "nas"),
    ("Time Machine", "nas"),
    ("Home", "mini"),
    ("Builds", "mini"),
    ("homebridge", "pi"),
    ("www", "vps-1"),
    ("postgres", "vps-1"),
    ("mail", "vps-2"),
];

/// A list whose scope chooses this Mac, the servers, or one of them: this Mac's answered at once, a server's after a
/// delay, as over the network, the field's spinner showing until it lands.
pub struct Servers {
    shares: Vec<Share>,
    /// The scope the rows answer.
    shown: String,
    /// A scope chosen and not yet answered: its value and id.
    pending: Option<(String, u64)>,
    /// The scope taken off the open view, from ⌘K, and every share shown.
    unscoped: bool,
}

impl Default for Servers {
    fn default() -> Self {
        let shares = SHARES.iter().enumerate().map(|(n, (title, server))| Share { id: format!("s{n}"), title, server }).collect();
        Servers { shares, shown: "all".into(), pending: None, unscoped: false }
    }
}

impl Servers {
    fn shows(&self, share: &Share) -> bool {
        match self.shown.as_str() {
            _ if self.unscoped => true,
            "all" => true,
            "mac" => share.server == "mac",
            "remote" => share.server != "mac",
            server => share.server == server,
        }
    }

    fn server(id: &str) -> Option<&'static (&'static str, &'static str, &'static str)> {
        SERVERS.iter().find(|(server, _, _)| *server == id)
    }
}

impl Screen for Servers {
    fn render(&self, view: &str) -> ViewNode {
        let chosen = self.pending.as_ref().map_or(self.shown.as_str(), |(value, _)| value.as_str());
        let scope = Scope::new(chosen)
            .options(vec![
                ScopeOption::new("all", "All"),
                ScopeOption::new("mac", "This Mac").icon(Icon::symbol("laptopcomputer")),
                ScopeOption::new("remote", "Remote").icon(Icon::symbol("network")),
            ])
            .section("Servers", SERVERS.iter().map(|(id, name, symbol)| ScopeOption::new(id, name).icon(Icon::symbol(symbol))).collect());
        let items = self
            .shares
            .iter()
            .filter(|share| self.shows(share))
            .map(|share| {
                let (place, symbol, tag) = match Self::server(share.server) {
                    Some((_, name, symbol)) => (*name, *symbol, Tag::new("Remote").tint(Tint::Blue)),
                    None => ("This Mac", "laptopcomputer", Tag::new("Local").tint(Tint::Green)),
                };
                Item::new(&share.id, share.title)
                    .subtitle(place)
                    .icon(Icon::symbol(symbol).tint(Tint::Blue))
                    .tag(tag)
                    .keywords(vec![place.into()])
                    .actions(vec![Action::new("toast", "Show a Toast")])
            })
            .collect();
        let toggle = if self.unscoped { Action::new("scope", "Bring the Scope Back") } else { Action::new("scope", "Take the Scope Away") };
        let list = List::new(view).title("Shares").actions(vec![toggle]);
        let list = if self.unscoped { list } else { list.scope(scope) };
        list.loading(self.pending.is_some())
            .empty("No shares here", Some("Choose another server with ⌘P"))
            .items(items)
            .into()
    }

    /// The scope comes and goes on the open view: the panel grows by its bar and gives it back.
    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        if action != "scope" {
            crate::say(action, item, out);
            return false;
        }
        self.unscoped = !self.unscoped;
        true
    }

    fn scope(&mut self, view: &str, value: &str, id: u64, out: &mut Effects) -> bool {
        out.cancel_timer(&format!("{view}/answer"));
        if value == "all" || value == "mac" {
            self.pending = None;
            self.shown = value.into();
            out.answer_filter(self.render(view), id);
            return false;
        }
        // The rows stay as they were, under the spinner, until the server answers.
        self.pending = Some((value.into(), id));
        out.answer_filter(self.render(view), id);
        out.timer(&format!("{view}/answer"), 450, false);
        false
    }

    fn timer(&mut self, view: &str, _name: &str, out: &mut Effects) -> bool {
        if let Some((value, id)) = self.pending.take() {
            self.shown = value;
            out.answer_filter(self.render(view), id);
        }
        false
    }

    fn closed(&mut self, view: &str, out: &mut Effects) {
        out.cancel_timer(&format!("{view}/answer"));
    }
}

// ---- a grid scoped to a palette ------------------------------------------------------------------

/// A grid of every tint, its scope choosing the warm or the cool, answered at once.
pub struct Palette {
    shown: String,
}

impl Default for Palette {
    fn default() -> Self {
        Palette { shown: "all".into() }
    }
}

impl Screen for Palette {
    fn render(&self, view: &str) -> ViewNode {
        let warm = |tint: Tint| matches!(tint, Tint::Red | Tint::Orange | Tint::Yellow | Tint::Pink);
        let cells = (0..48)
            .filter_map(|n| {
                let (tint, name) = TINTS[n % TINTS.len()];
                let keep = match self.shown.as_str() {
                    "warm" => warm(tint),
                    "cool" => !warm(tint) && tint != Tint::Gray,
                    _ => true,
                };
                keep.then(|| GridItem::new(&format!("{n}"), Icon::symbol(SYMBOLS[n % SYMBOLS.len()]).tint(tint)).title(&format!("{name} {n}")))
            })
            .collect();
        let scope = Scope::new(&self.shown).options(vec![
            ScopeOption::new("all", "Every Tint"),
            ScopeOption::new("warm", "Warm").icon(Icon::symbol("flame").tint(Tint::Orange)),
            ScopeOption::new("cool", "Cool").icon(Icon::symbol("snowflake").tint(Tint::Blue)),
        ]);
        Grid::new(view, cells).title("Palette").columns(6).scope(scope).into()
    }

    fn scope(&mut self, _view: &str, value: &str, _id: u64, _out: &mut Effects) -> bool {
        self.shown = value.into();
        true
    }
}

// ---- a scope too long for its room ---------------------------------------------------------------

/// Forty-eight servers in four regions, one with a name longer than the menu's least width: the menu scrolls, and
/// widens to what it lists.
pub struct ManyServers {
    shown: String,
}

impl Default for ManyServers {
    fn default() -> Self {
        ManyServers { shown: "eu-1".into() }
    }
}

const REGIONS: &[(&str, &str)] = &[("eu", "Europe"), ("us", "North America"), ("ap", "Asia Pacific"), ("sa", "South America")];

impl Screen for ManyServers {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(48);
        let mut scope = Scope::new(&self.shown).options(vec![ScopeOption::new("all", "Every Region")]);
        for (code, region) in REGIONS {
            let options = (1..=12)
                .map(|n| {
                    let id = format!("{code}-{n}");
                    let title = if *code == "ap" && n == 12 {
                        format!("{id}.a-server-whose-name-runs-long.example.com")
                    } else {
                        format!("{id} · {}", data::words(&mut rng, 1))
                    };
                    ScopeOption::new(&id, &title).icon(Icon::symbol("server.rack"))
                })
                .collect();
            scope = scope.section(region, options);
        }
        let items = (0..20)
            .map(|n| Item::new(&format!("{n}"), &format!("{} job {n}", self.shown)).subtitle(&data::ago(&mut rng)).icon(Icon::symbol("gearshape").tint(Tint::Gray)))
            .collect();
        List::new(view).title("Jobs").scope(scope).items(items).into()
    }

    fn scope(&mut self, _view: &str, value: &str, _id: u64, _out: &mut Effects) -> bool {
        self.shown = value.into();
        true
    }
}
