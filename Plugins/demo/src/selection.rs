//! Where a view starts: a list and a grid that open on an item partway down, move to another when they name it, and
//! open where they were left.

use crate::data::{self, Rng, SYMBOLS, TINTS};
use crate::{say, Screen};
use dock2_plugin::*;

// ---- an agenda, open on today ---------------------------------------------------------------------

const DAYS: [&str; 7] = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const WEEKS: usize = 40;
/// Wednesday of week 21: half the agenda before it and half after.
const TODAY: usize = 20 * 7 + 2;

/// Forty weeks of days, opened on today, or on the day selected when it last closed. The item its node names moves only
/// when the name does.
pub struct Agenda {
    named: usize,
}

impl Default for Agenda {
    fn default() -> Self {
        Agenda { named: TODAY }
    }
}

fn day_id(day: usize) -> String {
    format!("d{day}")
}

impl Screen for Agenda {
    fn render(&self, view: &str) -> ViewNode {
        let mut rng = Rng::new(40);
        let mut list = List::new(view).title("Agenda").selected(&day_id(self.named)).actions(vec![
            Action::new("later", "Name a Week Later").key("cmd+l").icon(Icon::symbol("calendar.badge.clock")),
            Action::new("redraw", "Redraw, Naming the Same Day").key("cmd+r").icon(Icon::symbol("arrow.clockwise")),
        ]);
        for week in 0..WEEKS {
            let items = (0..7)
                .map(|weekday| {
                    let day = week * 7 + weekday;
                    let item = Item::new(&day_id(day), DAYS[weekday])
                        .subtitle(&data::words(&mut rng, 3))
                        .icon(Icon::symbol("calendar").tint(if day == TODAY { Tint::Blue } else { Tint::Gray }))
                        .keywords(vec![format!("week {}", week + 1)])
                        .actions(vec![Action::new("toast", "Show a Toast")]);
                    if day == TODAY { item.tag(Tag::new("Today").tint(Tint::Blue)) } else { item }
                })
                .collect();
            list = list.section(&format!("Week {}", week + 1), items);
        }
        list.into()
    }

    fn resume(&mut self, selected: &str) {
        if let Some(day) = selected.strip_prefix('d').and_then(|day| day.parse().ok()) {
            self.named = day;
        }
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "later" => self.named = (self.named + 7) % (WEEKS * 7),
            "redraw" => {}
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }
}

// ---- a grid, open partway down --------------------------------------------------------------------

const CELLS: usize = 240;

/// Two hundred and forty cells, opened on the 130th, or on the one selected when it last closed.
pub struct Cells {
    named: usize,
}

impl Default for Cells {
    fn default() -> Self {
        Cells { named: 130 }
    }
}

impl Screen for Cells {
    fn render(&self, view: &str) -> ViewNode {
        let cells = (0..CELLS)
            .map(|n| {
                let symbol = SYMBOLS[n % SYMBOLS.len()];
                GridItem::new(&format!("{n}"), Icon::symbol(symbol).tint(TINTS[n % 8].0))
                    .title(&format!("{symbol} {n}"))
                    .actions(vec![Action::new("toast", "Show a Toast")])
            })
            .collect();
        Grid::new(view, cells)
            .title("Partway Down")
            .columns(6)
            .selected(&self.named.to_string())
            .actions(vec![
                Action::new("later", "Name Thirty Later").key("cmd+l").icon(Icon::symbol("arrow.down.to.line")),
                Action::new("redraw", "Redraw, Naming the Same Cell").key("cmd+r").icon(Icon::symbol("arrow.clockwise")),
            ])
            .into()
    }

    fn resume(&mut self, selected: &str) {
        if let Ok(n) = selected.parse() {
            self.named = n;
        }
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match action {
            "later" => self.named = (self.named + 30) % CELLS,
            "redraw" => {}
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }
}
