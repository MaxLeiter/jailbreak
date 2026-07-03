#!/usr/bin/env python3
"""Generate the Xios app icon into the asset catalog.

Run via the Pillow venv:
  .repo-venv/bin/python x11/apps/Xios/make-icon.py
"""
import os, json
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "Resources", "Assets.xcassets", "AppIcon.appiconset")
os.makedirs(OUT, exist_ok=True)

S = 1024
SS = S * 4
ACCENT = (61, 158, 255)
ACCENT_2 = (55, 226, 255)
SHADOW = (2, 7, 16)
BG_TOP = (19, 25, 42)
BG_MID = (9, 15, 28)
BG_BOT = (4, 6, 12)

def lerp(a, b, t): return tuple(int(a[i]*(1-t) + b[i]*t) for i in range(3))

img = Image.new("RGB", (SS, SS), BG_BOT)
d = ImageDraw.Draw(img)
for y in range(SS):
    t = y / (SS - 1)
    col = lerp(BG_TOP, BG_MID, t / 0.48) if t < 0.48 else lerp(BG_MID, BG_BOT, (t - 0.48) / 0.52)
    d.line([(0, y), (SS, y)], fill=col)

grid = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
gd = ImageDraw.Draw(grid)
for x in range(int(SS * 0.14), int(SS * 0.86), int(SS * 0.115)):
    gd.line([(x, int(SS * 0.20)), (x, int(SS * 0.80))], fill=(76, 154, 255, 22), width=max(1, SS // 420))
for y in range(int(SS * 0.20), int(SS * 0.82), int(SS * 0.115)):
    gd.line([(int(SS * 0.14), y), (int(SS * 0.86), y)], fill=(76, 154, 255, 18), width=max(1, SS // 420))
grid = grid.filter(ImageFilter.GaussianBlur(SS * 0.0015))
img.paste(grid, (0, 0), grid)

halo = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
hd = ImageDraw.Draw(halo)
hd.ellipse([SS * 0.18, SS * 0.12, SS * 0.82, SS * 0.88], fill=(36, 154, 255, 80))
halo = halo.filter(ImageFilter.GaussianBlur(SS * 0.115))
img.paste(Image.new("RGB", (SS, SS), (38, 137, 255)), (0, 0), halo)

m = SS * 0.235
TL, BR = (m, m * 1.10), (SS - m, SS - m * 1.10)
TR, BL = (SS - m, m * 1.10), (m, SS - m * 1.10)

def stroke(draw, a, b, width, color):
    draw.line([a, b], fill=color, width=width)
    r = width // 2
    for (x, y) in (a, b):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color)

def shifted(p, dx, dy):
    return (p[0] + dx, p[1] + dy)

depth = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
dd = ImageDraw.Draw(depth)
for off, alpha in ((SS * 0.034, 95), (SS * 0.021, 135), (SS * 0.010, 165)):
    stroke(dd, shifted(TL, off, off), shifted(BR, off, off), int(SS * 0.142), SHADOW + (alpha,))
    stroke(dd, shifted(TR, off, off), shifted(BL, off, off), int(SS * 0.142), SHADOW + (alpha,))
depth = depth.filter(ImageFilter.GaussianBlur(SS * 0.010))
img.paste(depth, (0, 0), depth)

glow = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
stroke(gd, TL, BR, int(SS * 0.185), ACCENT + (255,))
stroke(gd, TR, BL, int(SS * 0.185), ACCENT_2 + (255,))
glow = glow.filter(ImageFilter.GaussianBlur(SS * 0.032))
glow.putalpha(glow.getchannel("A").point(lambda p: int(p * 0.55)))
img.paste(Image.new("RGB", (SS, SS), ACCENT), (0, 0), glow)

ov = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
od = ImageDraw.Draw(ov)
stroke(od, TL, BR, int(SS * 0.142), ACCENT + (255,))
stroke(od, TR, BL, int(SS * 0.142), ACCENT_2 + (255,))
img.paste(ov, (0, 0), ov)

rim = Image.new("RGBA", (SS, SS), (0, 0, 0, 0))
rd = ImageDraw.Draw(rim)
rd.rounded_rectangle([SS * 0.035, SS * 0.035, SS * 0.965, SS * 0.965],
                     radius=int(SS * 0.215), outline=(255, 255, 255, 26),
                     width=max(1, SS // 155))
rd.rounded_rectangle([SS * 0.055, SS * 0.055, SS * 0.945, SS * 0.945],
                     radius=int(SS * 0.195), outline=(0, 0, 0, 90),
                     width=max(1, SS // 105))
img.paste(rim, (0, 0), rim)

icon = img.resize((S, S), Image.LANCZOS)
icon.save(os.path.join(OUT, "icon-1024.png"))

with open(os.path.join(OUT, "Contents.json"), "w") as f:
    json.dump({
        "images": [{"filename": "icon-1024.png", "idiom": "universal",
                    "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1},
    }, f, indent=2)

print("Wrote", os.path.join(OUT, "icon-1024.png"))
