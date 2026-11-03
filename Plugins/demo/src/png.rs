//! Pictures drawn here and written as PNGs, since a plugin has no files to read them from. Deflate's stored
//! blocks keep the encoder short; the pictures are made once, as the plugin starts.

use crate::data::{Rng, TINTS};
use dock2_plugin::Tint;
use std::sync::OnceLock;

pub struct Pictures {
    /// 150 pt square at 2×: album art.
    pub square: Vec<u8>,
    /// 240 × 100 pt at 2×: a chart.
    pub wide: Vec<u8>,
    /// 100 × 180 pt at 2×: a poster.
    pub tall: Vec<u8>,
    /// 64 pt at 1×, soft on a Retina display.
    pub low: Vec<u8>,
    /// Hairlines a pixel apart at 2×: crisp only where drawn at its own size.
    pub stripes: Vec<u8>,
    /// 48 pt at 2×, one per tint, in `TINTS`' order.
    pub thumbs: Vec<Vec<u8>>,
}

static PICTURES: OnceLock<Pictures> = OnceLock::new();

pub fn pictures() -> &'static Pictures {
    PICTURES.get_or_init(|| Pictures {
        square: art(300, 300, 2, rgb(Tint::Purple), rgb(Tint::Pink)),
        wide: chart(480, 200),
        tall: poster(200, 360),
        low: art(64, 64, 1, rgb(Tint::Green), rgb(Tint::Blue)),
        stripes: stripes(200, 200),
        thumbs: TINTS.iter().enumerate().map(|(index, (tint, _))| art(96, 96, 2, rgb(*tint), rgb(TINTS[(index + 3) % 8].0))).collect(),
    })
}

/// The tints as the system draws them in the light appearance.
pub fn rgb(tint: Tint) -> [u8; 3] {
    match tint {
        Tint::Red => [255, 59, 48],
        Tint::Orange => [255, 149, 0],
        Tint::Yellow => [255, 204, 0],
        Tint::Green => [52, 199, 89],
        Tint::Blue => [0, 122, 255],
        Tint::Purple => [175, 82, 222],
        Tint::Pink => [255, 45, 85],
        Tint::Gray => [142, 142, 147],
    }
}

fn mix(a: [u8; 3], b: [u8; 3], t: u32, of: u32) -> [u8; 3] {
    let channel = |i: usize| ((a[i] as u32 * (of - t) + b[i] as u32 * t) / of.max(1)) as u8;
    [channel(0), channel(1), channel(2)]
}

/// A diagonal blend from `a` to `b` under a pale disc.
fn art(width: u32, height: u32, density: u32, a: [u8; 3], b: [u8; 3]) -> Vec<u8> {
    let (cx, cy, r) = (width as i64 * 2 / 3, height as i64 / 3, width.min(height) as i64 / 4);
    encode(width, height, density, |x, y| {
        let blend = mix(a, b, x + y, width + height);
        let (dx, dy) = (x as i64 - cx, y as i64 - cy);
        if dx * dx + dy * dy < r * r { mix(blend, [255, 255, 255], 2, 5) } else { blend }
    })
}

/// Bars over a pale ground, as a chart rendered elsewhere would be.
fn chart(width: u32, height: u32) -> Vec<u8> {
    let mut rng = Rng::new(7);
    let bars: Vec<u32> = (0..12).map(|_| height / 5 + rng.below((height * 3 / 5) as usize) as u32).collect();
    let slot = width / bars.len() as u32;
    encode(width, height, 2, |x, y| {
        let bar = bars[((x / slot) as usize).min(bars.len() - 1)];
        let inside = x % slot > slot / 5 && x % slot < slot * 4 / 5;
        if y >= height - 4 { [60, 60, 67] } else if inside && y > height - 4 - bar { rgb(Tint::Blue) } else { [242, 242, 247] }
    })
}

/// A sky from orange to purple over a dark ground.
fn poster(width: u32, height: u32) -> Vec<u8> {
    let horizon = height * 2 / 3;
    encode(width, height, 2, |_, y| {
        if y < horizon { mix(rgb(Tint::Orange), rgb(Tint::Purple), y, horizon) } else { mix([40, 30, 60], [10, 10, 20], y - horizon, height - horizon) }
    })
}

/// Vertical hairlines on the left half, horizontal on the right.
fn stripes(width: u32, height: u32) -> Vec<u8> {
    encode(width, height, 2, |x, y| {
        let line = if x < width / 2 { x % 2 == 0 } else { y % 2 == 0 };
        if line { [0, 0, 0] } else { [255, 255, 255] }
    })
}

/// An 8-bit RGB PNG, `density` pixels to the point.
pub fn encode(width: u32, height: u32, density: u32, pixel: impl Fn(u32, u32) -> [u8; 3]) -> Vec<u8> {
    let mut raw = Vec::with_capacity(((width * 3 + 1) * height) as usize);
    for y in 0..height {
        raw.push(0);
        for x in 0..width {
            raw.extend_from_slice(&pixel(x, y));
        }
    }
    let mut png = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    let mut header = Vec::with_capacity(13);
    header.extend_from_slice(&width.to_be_bytes());
    header.extend_from_slice(&height.to_be_bytes());
    header.extend_from_slice(&[8, 2, 0, 0, 0]);
    chunk(&mut png, b"IHDR", &header);
    // Pixels a metre at 72 dpi times the density: what tells AppKit the picture's size in points.
    let per_metre = (2835 * density).to_be_bytes();
    chunk(&mut png, b"pHYs", &[&per_metre[..], &per_metre[..], &[1]].concat());
    chunk(&mut png, b"IDAT", &zlib_stored(&raw));
    chunk(&mut png, b"IEND", &[]);
    png
}

fn chunk(png: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    png.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = png.len();
    png.extend_from_slice(kind);
    png.extend_from_slice(data);
    let crc = crc32(&png[start..]);
    png.extend_from_slice(&crc.to_be_bytes());
}

fn zlib_stored(data: &[u8]) -> Vec<u8> {
    let mut out = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = if data.is_empty() { vec![&[]] } else { data.chunks(65_535).collect() };
    for (index, block) in blocks.iter().enumerate() {
        out.push((index == blocks.len() - 1) as u8);
        let len = block.len() as u16;
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&(!len).to_le_bytes());
        out.extend_from_slice(block);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for &byte in data {
        a = (a + byte as u32) % 65_521;
        b = (b + a) % 65_521;
    }
    out.extend_from_slice(&((b << 16) | a).to_be_bytes());
    out
}

fn crc32(data: &[u8]) -> u32 {
    static TABLE: OnceLock<[u32; 256]> = OnceLock::new();
    let table = TABLE.get_or_init(|| {
        let mut table = [0u32; 256];
        for (n, entry) in table.iter_mut().enumerate() {
            let mut c = n as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            }
            *entry = c;
        }
        table
    });
    !data.iter().fold(!0u32, |crc, &byte| table[((crc ^ byte as u32) & 0xFF) as usize] ^ (crc >> 8))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_png_carries_its_signature_size_and_checksums() {
        let png = encode(3, 2, 2, |x, y| [x as u8, y as u8, 0]);
        assert_eq!(&png[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        assert_eq!(&png[16..24], &[0, 0, 0, 3, 0, 0, 0, 2]);
        assert_eq!(crc32(b"IEND"), 0xAE42_6082);
        assert_eq!(&png[png.len() - 4..], &0xAE42_6082u32.to_be_bytes());
    }
}
