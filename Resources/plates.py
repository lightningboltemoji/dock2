# /// script
# requires-python = ">=3.12"
# ///
"""Writes Resources/Plates, what the Finder tile's own icon is drawn on: `uv run Resources/plates.py`. Each is
Icon Composer's plate for an icon with nothing on it, rendered by Icon Composer's `ictool`, which ships in
Xcode alone. Filled black and filled white, they are the two ends dock2 blends any colour between."""

import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "Plates"
WORK = ROOT / ".build" / "plates-source"
SIZE = 512  # past the largest tile's plate, 206 px at 128 pt on a 2× screen

# The plate is an icon's whole canvas, so the one layer a document needs is left empty.
EMPTY = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"></svg>\n'


def ictool():
    developer = subprocess.run(["xcode-select", "-p"], capture_output=True, text=True, check=True).stdout.strip()
    tool = Path(developer).parent / "Applications" / "Icon Composer.app" / "Contents" / "Executables" / "ictool"
    if not tool.exists():
        raise SystemExit(f"no {tool}: Icon Composer comes with Xcode, not the Command Line Tools")
    return tool


def document(path, fill):
    shutil.rmtree(path, ignore_errors=True)
    (path / "Assets").mkdir(parents=True)
    (path / "Assets" / "empty.svg").write_text(EMPTY)
    doc = {
        "fill": {"solid": "srgb:" + ",".join(f"{c:.5f}" for c in (*fill, 1))},
        "groups": [{"layers": [{"image-name": "empty.svg", "name": "empty"}]}],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (path / "icon.json").write_text(json.dumps(doc, indent=2) + "\n")


def main():
    tool = ictool()
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fill in [("default-black", (0, 0, 0)), ("default-white", (1, 1, 1))]:
        doc = WORK / f"{name}.icon"
        document(doc, fill)
        subprocess.run([tool, doc, "--export-image", "--output-file", OUT / f"{name}.png", "--platform", "macOS",
                        "--rendition", "Default", "--width", str(SIZE), "--height", str(SIZE), "--scale", "1"],
                       check=True, capture_output=True)
        print(f"wrote {(OUT / name).relative_to(ROOT)}.png")


if __name__ == "__main__":
    main()
