//! Made-up data, the same every run: a seeded generator and the words it draws from.

use dock2_plugin::Tint;

/// xorshift64*: enough to scatter names and sizes, and the same sequence for the same seed.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1)
    }

    pub fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    pub fn below(&mut self, n: usize) -> usize {
        (self.next() % n as u64) as usize
    }

    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }
}

pub const TINTS: [(Tint, &str); 8] = [
    (Tint::Red, "Red"),
    (Tint::Orange, "Orange"),
    (Tint::Yellow, "Yellow"),
    (Tint::Green, "Green"),
    (Tint::Blue, "Blue"),
    (Tint::Purple, "Purple"),
    (Tint::Pink, "Pink"),
    (Tint::Gray, "Gray"),
];

pub const SYMBOLS: &[&str] = &[
    "star", "heart", "bolt", "leaf", "flame", "drop", "moon", "sun.max", "cloud", "snowflake", "bell", "bookmark", "camera", "doc",
    "folder", "gift", "globe", "house", "key", "lightbulb", "map", "mic", "paperplane", "pencil", "tag", "tray", "tv", "umbrella",
];

const FIRST: &[&str] = &[
    "Ada", "Grace", "Linus", "Margaret", "Alan", "Barbara", "Dennis", "Frances", "Ken", "Radia", "Hedy", "Edsger", "Katherine", "Donald",
    "Annie", "Guido", "Sophie", "Tim", "Joan", "Niklaus",
];

const LAST: &[&str] = &[
    "Lovelace", "Hopper", "Torvalds", "Hamilton", "Turing", "Liskov", "Ritchie", "Allen", "Thompson", "Perlman", "Lamarr", "Dijkstra",
    "Johnson", "Knuth", "Easley", "van Rossum", "Wilson", "Berners-Lee", "Clarke", "Wirth",
];

const WORDS: &[&str] = &[
    "quartz", "harbor", "ember", "lattice", "meadow", "signal", "cobalt", "juniper", "orbit", "pylon", "saffron", "tundra", "velvet",
    "willow", "zephyr", "basalt", "cinder", "delta", "fjord", "glacier", "hollow", "isthmus", "kestrel", "lagoon", "marble", "nimbus",
    "obsidian", "prairie", "quiver", "ridge", "sorrel", "thistle", "umber", "vertex", "walnut", "yarrow",
];

pub fn person(rng: &mut Rng) -> String {
    format!("{} {}", rng.pick(FIRST), rng.pick(LAST))
}

/// `count` words, the first capitalised.
pub fn words(rng: &mut Rng, count: usize) -> String {
    let mut text = String::new();
    for index in 0..count {
        let word = *rng.pick(WORDS);
        if index == 0 {
            let mut chars = word.chars();
            text.extend(chars.next().map(|c| c.to_ascii_uppercase()));
            text.push_str(chars.as_str());
        } else {
            text.push(' ');
            text.push_str(word);
        }
    }
    text
}

pub fn sentence(rng: &mut Rng) -> String {
    let count = 6 + rng.below(9);
    format!("{}.", words(rng, count))
}

pub fn paragraph(rng: &mut Rng, sentences: usize) -> String {
    (0..sentences).map(|_| sentence(rng)).collect::<Vec<_>>().join(" ")
}

pub fn ago(rng: &mut Rng) -> String {
    match rng.below(4) {
        0 => format!("{} min ago", 1 + rng.below(59)),
        1 => format!("{} h ago", 1 + rng.below(23)),
        2 => "Yesterday".into(),
        _ => format!("{} days ago", 2 + rng.below(28)),
    }
}

pub fn size(rng: &mut Rng) -> String {
    match rng.below(3) {
        0 => format!("{} bytes", 1 + rng.below(1023)),
        1 => format!("{} KB", 1 + rng.below(999)),
        _ => format!("{}.{} MB", 1 + rng.below(99), rng.below(10)),
    }
}

/// "3:07".
pub fn clock(seconds: f64) -> String {
    let seconds = seconds.max(0.0) as u64;
    format!("{}:{:02}", seconds / 60, seconds % 60)
}
