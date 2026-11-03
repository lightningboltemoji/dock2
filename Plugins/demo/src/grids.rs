//! Grids: every kind of picture, five hundred cells, pictures without titles, and none.

use crate::data::{SYMBOLS, TINTS};
use crate::png::pictures;
use crate::{say, Screen};
use dock2_plugin::*;
use std::collections::BTreeSet;

fn cell(id: &str, image: Icon, title: Option<&str>) -> GridItem {
    let item = GridItem::new(id, image).actions(vec![
        Action::new("toast", "Show a Toast"),
        Action::new("copy", "Copy Its ID and Dismiss"),
        Action::new("delete", "Delete This Cell").icon(Icon::symbol("trash")).destructive(),
    ]);
    match title {
        Some(title) => item.title(title),
        None => item,
    }
}

fn copy(item: &str, out: &mut Effects) {
    out.copy(item, false);
    out.dismiss();
    out.toast("Copied");
}

// ---- every picture --------------------------------------------------------------------------------

/// The columns Change Columns walks; none says five.
const COLUMNS: [Option<u32>; 5] = [None, Some(3), Some(4), Some(6), Some(8)];

#[derive(Default)]
pub struct Everything {
    removed: BTreeSet<String>,
    columns: usize,
}

impl Everything {
    fn cells() -> Vec<GridItem> {
        let pictures = pictures();
        let png = |bytes: &Vec<u8>| Icon::png(bytes.clone());
        let mut cells: Vec<GridItem> = TINTS
            .iter()
            .enumerate()
            .map(|(index, (tint, name))| cell(&format!("tint-{index}"), Icon::symbol(SYMBOLS[index]).tint(*tint), Some(name)))
            .collect();
        cells.extend([
            cell("symbol-plain", Icon::symbol("star"), Some("No tint")),
            cell("symbol-unknown", Icon::symbol("not.a.symbol"), Some("Names nothing")),
        ]);
        cells.extend(TINTS.iter().enumerate().map(|(index, (_, name))| cell(&format!("thumb-{index}"), png(&pictures.thumbs[index]), Some(&format!("{name} art")))));
        cells.extend([
            cell("square", png(&pictures.square), Some("Square, 2×")),
            cell("wide", png(&pictures.wide), Some("Wide, 2×")),
            cell("tall", png(&pictures.tall), Some("Tall, 2×")),
            cell("low", png(&pictures.low), Some("Square, 1×")),
            cell("stripes", png(&pictures.stripes), Some("Hairlines, 2×")),
        ]);
        for (id, title) in [
            ("com.apple.Safari", "Safari"),
            ("com.apple.finder", "Finder"),
            ("com.apple.Music", "Music"),
            ("com.apple.Notes", "Notes"),
            ("com.apple.Terminal", "Terminal"),
            ("com.example.nothing", "Not installed"),
        ] {
            cells.push(cell(id, Icon::app(id), Some(title)));
        }
        for (path, title) in [("/Applications", "Applications"), ("/etc/hosts", "hosts"), ("/nowhere/at/all.txt", "A missing file")] {
            cells.push(cell(path, Icon::file(path), Some(title)));
        }
        cells.extend([
            cell("untitled-1", png(&pictures.thumbs[1]), None),
            cell("untitled-2", Icon::symbol("leaf").tint(Tint::Green), None),
            cell("long-title", png(&pictures.thumbs[6]), Some("A title far too long for any cell to hold on one line")),
        ]);
        cells
    }
}

impl Screen for Everything {
    fn render(&self, view: &str) -> ViewNode {
        let count = |columns: Option<u32>| columns.unwrap_or(5);
        let (now, next) = (COLUMNS[self.columns], COLUMNS[(self.columns + 1) % COLUMNS.len()]);
        let mut grid = Grid::new(view, Self::cells().into_iter().filter(|cell| !self.removed.contains(&cell.id)).collect())
            .title("Every Picture")
            .actions(vec![
                Action::new("columns", &format!("{} Columns, Not {}", count(next), count(now))).key("cmd+l").icon(Icon::symbol("square.grid.3x3")),
                Action::new("restore", "Restore Deleted Cells").key("cmd+shift+r").icon(Icon::symbol("arrow.uturn.backward")),
            ]);
        grid.columns = now;
        grid.into()
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("columns", _) => self.columns = (self.columns + 1) % COLUMNS.len(),
            ("restore", _) => self.removed.clear(),
            ("delete", Some(item)) => {
                self.removed.insert(item.into());
            }
            ("copy", Some(item)) => {
                copy(item, out);
                return false;
            }
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }
}

// ---- five hundred ---------------------------------------------------------------------------------

pub struct Many;

impl Screen for Many {
    fn render(&self, view: &str) -> ViewNode {
        let cells = (0..500)
            .map(|n| {
                let symbol = SYMBOLS[n % SYMBOLS.len()];
                GridItem::new(&format!("{n}"), Icon::symbol(symbol).tint(TINTS[n % 8].0)).title(&format!("{symbol} {n}")).actions(vec![Action::new("toast", "Show a Toast")])
            })
            .collect();
        Grid::new(view, cells).title("Five Hundred").columns(6).into()
    }
}

// ---- pictures without titles ----------------------------------------------------------------------

pub struct Untitled;

impl Screen for Untitled {
    fn render(&self, view: &str) -> ViewNode {
        let pictures = pictures();
        let mut cells: Vec<GridItem> = pictures.thumbs.iter().enumerate().map(|(n, thumb)| GridItem::new(&format!("thumb-{n}"), Icon::png(thumb.clone()))).collect();
        cells.extend((0..24).map(|n| GridItem::new(&format!("symbol-{n}"), Icon::symbol(SYMBOLS[n]).tint(TINTS[n % 8].0))));
        Grid::new(view, cells).title("Pictures Without Titles").columns(8).into()
    }
}

// ---- empty ----------------------------------------------------------------------------------------

#[derive(Default)]
pub struct Empty {
    filled: bool,
}

impl Screen for Empty {
    fn render(&self, view: &str) -> ViewNode {
        let cells = if self.filled {
            (0..12).map(|n| cell(&format!("{n}"), Icon::symbol(SYMBOLS[n]).tint(TINTS[n % 8].0), Some(SYMBOLS[n]))).collect()
        } else {
            Vec::new()
        };
        Grid::new(view, cells)
            .title("Empty Grid")
            .actions(vec![Action::new("fill", if self.filled { "Empty It Again" } else { "Fill It" }).key("cmd+n")])
            .into()
    }

    fn action(&mut self, _view: &str, action: &str, item: Option<&str>, out: &mut Effects) -> bool {
        match (action, item) {
            ("fill", _) => self.filled = !self.filled,
            ("copy", Some(item)) => {
                copy(item, out);
                return false;
            }
            _ => {
                say(action, item, out);
                return false;
            }
        }
        true
    }
}
