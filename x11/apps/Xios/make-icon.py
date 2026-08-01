#!/usr/bin/env python3
"""Generate the Xios app icon from the shared vector identity.

Run via the Pillow venv:
  .repo-venv/bin/python x11/apps/Xios/make-icon.py

Requires rsvg-convert. The rendered SVG has transparent outer corners for the
web, but Apple app icons may not contain alpha, so this generator flattens it
onto the mark's dark background before writing the asset catalog.
"""
import io, json, os, shutil, subprocess
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "Resources", "Assets.xcassets", "AppIcon.appiconset")
SOURCE = os.path.join(HERE, "assets", "xios-mark.svg")
os.makedirs(OUT, exist_ok=True)

S = 1024
rsvg_convert = shutil.which("rsvg-convert")
if not rsvg_convert:
    raise SystemExit("ERROR: generating the Xios app icon needs rsvg-convert")
rendered = subprocess.run(
    [rsvg_convert, "-w", str(S), "-h", str(S), SOURCE],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
mark = Image.open(io.BytesIO(rendered.stdout)).convert("RGBA")
icon = Image.new("RGB", (S, S), (3, 7, 14))
icon.paste(mark, (0, 0), mark)
icon.save(os.path.join(OUT, "icon-1024.png"))

with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({
        "images": [{"filename": "icon-1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, f, indent=2)

print("Wrote", os.path.join(OUT, "icon-1024.png"))
