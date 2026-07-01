#!/usr/bin/env python3
"""Generate the iosc Host app icon — overlapping window tiles in the brand blue,
signaling native per-app windows. This is only the fallback/base-build icon; each
generated per-app bundle gets its Linux app's own icon via gen-icons.py.
Run via the Pillow venv:  .repo-venv/bin/python x11/apps/iosc-host/make-icon.py
"""
import os, json
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "Resources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

S = 1024
SS = S * 4
ACCENT = (85, 170, 255)     # #55aaff brand blue
LIGHT  = (150, 200, 255)
BG_TOP = (20, 22, 32)
BG_BOT = (7, 7, 11)

def lerp(a, b, t): return tuple(int(a[i]*(1-t) + b[i]*t) for i in range(3))

img = Image.new("RGB", (SS, SS), BG_BOT)
d = ImageDraw.Draw(img)
for y in range(SS):
    d.line([(0, y), (SS, y)], fill=lerp(BG_TOP, BG_BOT, y / SS))

def window(draw, x, y, w, h, fill, title):
    r = int(SS * 0.02)
    draw.rounded_rectangle([x, y, x + w, y + h], radius=r, fill=fill)
    draw.rounded_rectangle([x, y, x + w, y + int(h * 0.16)], radius=r, fill=title)

# Two overlapping windows: a back one (dim) and a front one (bright), like two
# apps side by side in the multitasker.
ov = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
od = ImageDraw.Draw(ov)
window(od, int(SS*0.20), int(SS*0.20), int(SS*0.44), int(SS*0.40),
       (40, 54, 82, 255), (70, 96, 150, 255))
window(od, int(SS*0.38), int(SS*0.40), int(SS*0.44), int(SS*0.40),
       ACCENT + (255,), LIGHT + (255,))
glow = ov.filter(ImageFilter.GaussianBlur(SS * 0.012))
img.paste(glow, (0, 0), glow)
img.paste(ov, (0, 0), ov)

icon = img.resize((S, S), Image.LANCZOS)
icon.save(os.path.join(OUT, "icon-1024.png"))

with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({
        "images": [{"filename": "icon-1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, f, indent=2)

print("Wrote", os.path.join(OUT, "icon-1024.png"))
