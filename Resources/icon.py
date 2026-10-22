# /// script
# requires-python = ">=3.12"
# dependencies = ["fonttools", "skia-pathops", "numpy", "scipy", "scikit-image", "pillow"]
# ///
"""Writes Resources/dock2.icon, the Icon Composer document the app icon is compiled from:
`uv run Resources/icon.py`. The icon is Inter's 2 with the dock for its foot, drawn to the system
Dock's own proportions; the document's two layers are glass groups over a violet plate."""

import hashlib
import json
import math
import shutil
import urllib.request
from pathlib import Path

import numpy as np
import pathops
from fontTools.pens.basePen import BasePen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from PIL import Image, ImageDraw
from scipy import ndimage
from skimage import measure

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "dock2.icon"
CACHE = ROOT / ".build" / "icon"

# Inter is OFL; fetched at a fixed commit of google/fonts and checked, never committed here.
FONT_URL = (
    "https://raw.githubusercontent.com/google/fonts/e1d6480102fed30739fead0faee463101f892c8f/"
    "ofl/inter/Inter%5Bopsz,wght%5D.ttf"
)
FONT_SHA256 = "29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031"
FONT_AXES = {"wght": 800, "opsz": 32}

# The Dock at tile size 48, in points (`DockMetrics`): a 68 tall platter, 52 wide slots with 8 at
# either end, running dots centred 6 above its bottom. An icon's visible art is 412/512 of its tile.
PT_H = 68
TILES = ["#5AC8FA", "#FFCC00", "#FF6B5A", "#34C759"]
RUNNING = [0, 1, 3]
ICON = 48 * 412 / 512

TOTAL = 690  # the drawing's height on the 1024 canvas
CORNER = 6  # the platter's corners are a CORNER-th of its height
PAST = 0.18  # how far the platter runs past the bowl, × its height
SINK = 40  # how far below the platter's top the diagonal lands, in canvas px
PLATE = ("#6D5BE0", "#3A2A9C")


# --- shapes -------------------------------------------------------------------------------------


def squircle_d(x, y, w, h, r, smoothing=0.6):
    """A rounded rect with continuous corners (Figma's corner smoothing), as SVG path data. `r` is
    one radius or four (top-left, top-right, bottom-right, bottom-left); 0 is a square corner."""
    tl, tr, br, bl = r if isinstance(r, tuple) else (r,) * 4
    f = lambda *v: " ".join(f"{n:.3f}" for n in v)

    def corner(r):
        """How far along each side the corner reaches, and its segments in a (along, across) frame."""
        if r <= 0:
            return 0, []
        sm, budget = smoothing, min(w, h) / 2
        p = (1 + sm) * r
        if p > budget:
            sm = max(budget / r - 1, 0)
            p = min(p, budget)
        arc_measure = 90 * (1 - sm)
        arc = math.sin(math.radians(arc_measure / 2)) * r * math.sqrt(2)
        p3p4 = r * math.tan(math.radians((90 - arc_measure) / 4))
        c = p3p4 * math.cos(math.radians(45 * sm))
        d = c * math.tan(math.radians(45 * sm))
        b = (p - arc - c - d) / 3
        a = 2 * b
        return p, [("c", (a, 0, a + b, 0, a + b + c, d)), ("a", r, (arc, arc)), ("c", (d, c, d, b + c, d, a + b + c))]

    def emit(segs, rot):
        out = []
        for seg in segs:
            if seg[0] == "c":
                v = seg[1]
                out.append("c" + f(*[n for i in (0, 2, 4) for n in rot(v[i], v[i + 1])]))
            else:
                out.append(f"a{f(seg[1], seg[1])} 0 0 1 {f(*rot(*seg[2]))}")
        return " ".join(out)

    (ptl, stl), (ptr, s_tr), (pbr, sbr), (pbl, sbl) = map(corner, (tl, tr, br, bl))
    return (
        f"M{f(x + w - ptr, y)} {emit(s_tr, lambda u, v: (u, v))} "
        f"L{f(x + w, y + h - pbr)} {emit(sbr, lambda u, v: (-v, u))} "
        f"L{f(x + pbl, y + h)} {emit(sbl, lambda u, v: (-u, -v))} "
        f"L{f(x, y + ptl)} {emit(stl, lambda u, v: (v, -u))} "
        f"L{f(x + w - ptr, y)} Z"
    )


def path_from_d(d):
    p = pathops.Path()
    parse_path(d, p.getPen())
    return p


def rect(x0, y0, x1, y1):
    return path_from_d(f"M{x0} {y0} H{x1} V{y1} H{x0} Z")


def to_d(path):
    pen = SVGPathPen(None, ntos=lambda v: f"{v:.2f}")
    path.draw(pen)
    return pen.getCommands()


class FlattenPen(BasePen):
    """Collects each contour as a polyline, curves cut into short segments."""

    def __init__(self):
        super().__init__(None)
        self.contours, self.cur = [], []

    def _moveTo(self, p):
        self.cur = [p]

    def _lineTo(self, p):
        self.cur.append(p)

    def _curveToOne(self, p1, p2, p3):
        p0 = self.cur[-1]
        for i in range(1, 17):
            t, u = i / 16, 1 - i / 16
            self.cur.append(tuple(u**3 * a + 3 * u * u * t * b + 3 * u * t * t * c + t**3 * d for a, b, c, d in zip(p0, p1, p2, p3)))

    def _closePath(self):
        self.contours.append(self.cur)
        self.cur = []


def fillet(shape, band, radius, box, box_radius, scale=4):
    """`shape` with its concave corners within the rows `band` rounded to `radius`, and its convex
    ones within `box` to `box_radius`: a closing and an opening on a raster at `scale`, traced back
    as one outline, within 1/scale px of the vectors."""
    n = 1024 * scale
    pen = FlattenPen()
    shape.draw(pen)
    im = Image.new("L", (n, n), 0)
    draw = ImageDraw.Draw(im)
    for c in pen.contours:
        draw.polygon([(x * scale, y * scale) for x, y in c], fill=1)
    mask = np.array(im, dtype=bool)
    edt = ndimage.distance_transform_edt
    rows, cols = np.arange(n)[:, None] / scale, np.arange(n)[None, :] / scale
    r = radius * scale
    mask |= (edt(edt(~mask) <= r) > r) & (rows >= band[0]) & (rows <= band[1])
    r = box_radius * scale
    inside = (cols >= box[0]) & (cols <= box[2]) & (rows >= box[1]) & (rows <= box[3])
    mask = np.where(inside, edt(~(edt(mask) > r)) <= r, mask)
    smooth = ndimage.gaussian_filter(mask.astype(float), scale * 0.5)
    out = pathops.Path()
    pen = out.getPen()
    for c in measure.find_contours(smooth, 0.5):
        c = measure.approximate_polygon(c, tolerance=scale * 0.15)
        pen.moveTo((c[0][1] / scale, c[0][0] / scale))
        for y, x in c[1:]:
            pen.lineTo((x / scale, y / scale))
        pen.closePath()
    out.simplify()
    return out


# --- the 2 and the dock -------------------------------------------------------------------------


def font():
    path = CACHE / "Inter.ttf"
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != FONT_SHA256:
        CACHE.mkdir(parents=True, exist_ok=True)
        data = urllib.request.urlopen(FONT_URL).read()
        if hashlib.sha256(data).hexdigest() != FONT_SHA256:
            raise SystemExit(f"{FONT_URL} is not the Inter this icon was drawn from")
        path.write_bytes(data)
    return instancer.instantiateVariableFont(TTFont(path), FONT_AXES)


def glyph_two():
    """The 2 in font units (y up), overlaps removed."""
    f = font()
    p = pathops.Path()
    f.getGlyphSet()[f.getBestCmap()[ord("2")]].draw(p.getPen())
    p.simplify()
    return p


def base_top(g):
    """The height of the top of the 2's base bar: where the glyph narrows from the bar to the spine."""
    x0, y0, x1, y1 = g.bounds
    full, y = None, y0 + 4
    while y < y1:
        w = pathops.op(g, rect(x0 - 10, y, x1 + 10, y + 2), pathops.PathOp.INTERSECTION).bounds
        w = w[2] - w[0] if w else 0
        full = full or w
        if w < 0.8 * full:
            return y
        y += 2
    raise ValueError("no base bar")


def compose():
    """The 2 above its bar and the platter in place of the bar, in canvas px (y down). The diagonal
    lands on the platter's left end SINK below its top, the platter's corner cut along its line;
    the platter's width spans the 2 and PAST, its height follows at the Dock's proportions."""
    g = glyph_two()
    gx0, gy0, gx1, gy1 = g.bounds
    b = base_top(g)
    at = lambda y: pathops.op(g, rect(gx0 - 50, y, gx1 + 50, y + 2), pathops.PathOp.INTERSECTION).bounds[0]
    edge = at(b)
    run = (at(b + 80) - edge) / 80  # the diagonal's run per unit of rise, where it lands
    cut = pathops.op(g, rect(gx0 - 50, b, gx1 + 50, gy1 + 50), pathops.PathOp.INTERSECTION)
    gw, above = cut.bounds[2] - edge, gy1 - b
    ratio = (len(TILES) * 52 + 16) / PT_H
    # W = gw * k + PAST * H = ratio * H, and TOTAL = above * k + H - SINK
    H = (TOTAL + SINK) / (above * (ratio - PAST) / gw + 1)
    k = (ratio - PAST) * H / gw
    W = ratio * H
    px0, py0 = 512 - W / 2, 512 - TOTAL / 2 + 6 + above * k - SINK
    land = py0 + SINK
    spine = pathops.Path()
    cut.draw(TransformPen(spine.getPen(), (k, 0, 0, -k, px0 - edge * k, land + b * k)))
    r = H / CORNER
    platter = path_from_d(squircle_d(px0, py0, W, H, (0, r, r, r)))
    up = SINK + 40
    bevel = path_from_d(f"M{px0} {land} L{px0 + up * run} {land - up} L{px0 - 60} {land - up} L{px0 - 60} {land} Z")
    platter = pathops.op(platter, bevel, pathops.PathOp.DIFFERENCE)
    body = pathops.op(spine, platter, pathops.PathOp.UNION)
    body = fillet(body, (py0 - 120, py0 + 40), 0.7 * r, (px0 - 20, land - 60, px0 + 60, land + 40), 6)
    return body, (px0, py0, W, H)


def tiles(px0, py0, W, H):
    s = H / PT_H
    size = ICON * s
    cx = lambda i: px0 + (8 + 26 + 52 * i) * s
    squares = [
        f'<path d="{squircle_d(cx(i) - size / 2, py0 + (H - size) / 2, size, size, size * 0.225)}" fill="{c}"/>'
        for i, c in enumerate(TILES)
    ]
    # the dots are 1.5× the Dock's 4 pt, so they survive at icon sizes
    dots = [f'<circle cx="{cx(i):.2f}" cy="{py0 + H - 6.5 * s:.2f}" r="{3 * s:.2f}" fill="#1B1B1F" fill-opacity="0.75"/>' for i in RUNNING]
    return squares + dots


# --- the document -------------------------------------------------------------------------------


def svg(*body):
    return '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n  ' + "\n  ".join(body) + "\n</svg>\n"


def colour(hex):
    return "srgb:" + ",".join(f"{int(hex[i:i + 2], 16) / 255:.5f}" for i in (1, 3, 5)) + ",1.00000"


def group(name, translucency):
    return {
        "blend-mode": "normal",
        "hidden": False,
        "layers": [{"blend-mode": "normal", "glass": True, "hidden": False, "image-name": f"{name}.svg", "name": name, "opacity": 1}],
        "lighting": "individual",
        "opacity": 1,
        "shadow": {"kind": "neutral", "opacity": 0.5},
        "specular": True,
        "translucency": {"enabled": True, "value": translucency},
    }


def main():
    body, box = compose()
    shutil.rmtree(OUT, ignore_errors=True)
    (OUT / "Assets").mkdir(parents=True)
    (OUT / "Assets" / "tiles.svg").write_text(svg(*tiles(*box)))
    (OUT / "Assets" / "dock.svg").write_text(svg(f'<path d="{to_d(body)}" fill="#ffffff" fill-opacity="0.88"/>'))
    doc = {
        "fill-specializations": [
            {"value": {"linear-gradient": [colour(PLATE[0]), colour(PLATE[1])]}},
            {"appearance": "dark", "value": "system-dark"},
        ],
        "groups": [group("tiles", 0.2), group("dock", 0.35)],  # first is topmost
        "supported-platforms": {"squares": ["macOS"]},
    }
    (OUT / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
