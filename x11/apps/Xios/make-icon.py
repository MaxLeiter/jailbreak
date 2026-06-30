#!/usr/bin/env python3
"""Generate the Xios app icon — a stylized X11 'X' in the brand blue — into the
asset catalog. Run via the Pillow venv:  .repo-venv/bin/python x11/apps/Xios/make-icon.py
"""
import os, json
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "Resources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

S = 1024
SS = S * 4                      # supersample then downscale (smooth edges)
ACCENT  = (85, 170, 255)        # #55aaff  (maxleiter.com brand blue)
HILITE  = (165, 210, 255)       # lighter sheen
BG_TOP  = (20, 22, 32)
BG_BOT  = (7, 7, 11)

def lerp(a, b, t): return tuple(int(a[i]*(1-t) + b[i]*t) for i in range(3))

img = Image.new("RGB", (SS, SS), BG_BOT)
d = ImageDraw.Draw(img)
for y in range(SS):                              # vertical gradient background
    d.line([(0, y), (SS, y)], fill=lerp(BG_TOP, BG_BOT, y / SS))

m = SS * 0.30                                     # endpoint margin from edges
TL, BR = (m, m), (SS - m, SS - m)
TR, BL = (SS - m, m), (m, SS - m)

def stroke(draw, a, b, width, color):            # thick line with round caps
    draw.line([a, b], fill=color, width=width)
    r = width // 2
    for (x, y) in (a, b):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)

# soft outer glow
glow = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
stroke(gd, TL, BR, int(SS * 0.135), ACCENT + (255,))
stroke(gd, TR, BL, int(SS * 0.135), ACCENT + (255,))
glow = glow.filter(ImageFilter.GaussianBlur(SS * 0.03))
glow.putalpha(glow.getchannel("A").point(lambda p: int(p * 0.45)))
img.paste(Image.new("RGB", (SS, SS), ACCENT), (0, 0), glow)

# crisp X + highlight sheen
ov = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
od = ImageDraw.Draw(ov)
stroke(od, TL, BR, int(SS * 0.115), ACCENT + (255,))
stroke(od, TR, BL, int(SS * 0.115), ACCENT + (255,))
stroke(od, TL, BR, int(SS * 0.030), HILITE + (235,))
stroke(od, TR, BL, int(SS * 0.030), HILITE + (235,))
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
