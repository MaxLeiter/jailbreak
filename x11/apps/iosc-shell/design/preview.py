#!/usr/bin/env python3
"""Off-device mockup of the proposed iosc panel visual language (top-bar layout).
Faithful-ish approximation using PIL + SF (SFNS.ttf) + real rasterized GNOME icons.
This is a design proposal render, not the actual cairo output."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import os

S = 2                      # retina scale for a crisp mockup
W, BARH = 1360, 40         # logical canvas width, bar height
DESKH = 150                # show some desktop below the bar so translucency reads
CW, CH = W*S, (BARH+DESKH)*S

SF   = "/System/Library/Fonts/SFNS.ttf"
def font(sz, weight="Regular"):
    # SFNS.ttf is a variable font; PIL picks default instance. Use size only.
    try: return ImageFont.truetype(SF, sz*S)
    except Exception: return ImageFont.load_default()

ICONS = "icons"
def icon(name, px):
    p = os.path.join(ICONS, name+".png")
    im = Image.open(p).convert("RGBA")
    return im.resize((px*S, px*S), Image.LANCZOS)

def rrect(draw, box, r, fill):
    draw.rounded_rectangle(box, radius=r*S, fill=fill)

# ---- desktop wallpaper behind (to demonstrate translucency) ----
base = Image.new("RGB", (CW, CH), (18, 20, 28))
d = ImageDraw.Draw(base)
for y in range(CH):                       # deep blue->indigo gradient wallpaper
    t = y/CH
    d.line([(0,y),(CW,y)], fill=(int(20+30*t), int(22+18*t), int(34+40*t)))
# a couple soft "window" rectangles peeking under the bar to show blend
rrect(d, (60*S, 30*S, 520*S, 300*S), 14, (236,236,238))
rrect(d, (560*S, 26*S, 1040*S, 300*S), 14, (44,46,54))

canvas = base.convert("RGBA")

# ---- the translucent panel surface ----
bar = Image.new("RGBA", (CW, BARH*S), (0,0,0,0))
bd = ImageDraw.Draw(bar)
# base tint rgba(28,28,30,0.72) with a subtle vertical gradient (lighter at top)
for y in range(BARH*S):
    t = y/(BARH*S)
    a = 184                                 # ~0.72
    c = int(30 - 6*t)                        # 30->24 top-to-bottom
    bd.line([(0,y),(CW,y)], fill=(c+4, c+4, c+6, a))
# 1px inner top highlight + bottom hairline shadow
bd.line([(0,0),(CW,0)], fill=(255,255,255,26))
bd.line([(0,BARH*S-1),(CW,BARH*S-1)], fill=(0,0,0,80))
canvas.alpha_composite(bar, (0,0))
dr = ImageDraw.Draw(canvas)

FG   = (245,245,247,255)     # #F5F5F7
FG2  = (235,235,245,170)     # secondary ~65%
ACC  = (10,132,255,255)      # #0A84FF
WHT  = lambda a: (255,255,255,a)

cy = (BARH*S)//2
# ---- launcher strip (left): real icons in rounded tiles ----
x = 12*S
tile = 28
for name in ["files","text-editor","console","calculator"]:
    ic = icon(name, tile-6)
    tx = x
    ty = (BARH*S - (tile-6)*S)//2
    canvas.alpha_composite(ic, (tx + 3*S, ty))
    x += (tile+6)*S
# separator
dr.line([(x, 10*S),(x, (BARH-10)*S)], fill=WHT(28)); x += 12*S

# ---- taskbar pills (icon + title; one active) ----
def pill(x, label, icon_name, active, hover=False):
    w = 172*S; h = 28*S; y=(BARH*S-h)//2
    if active:
        rrect(dr, (x, y, x+w, y+h), 9, (10,132,255,54))          # accent-tinted fill
        dr.rounded_rectangle((x, y+h-2*S, x+w, y+h), radius=1, fill=ACC)  # accent underline
    elif hover:
        rrect(dr, (x, y, x+w, y+h), 9, (255,255,255,20))         # subtle hover
    ic = icon(icon_name, 18)
    canvas.alpha_composite(ic, (x+9*S, y+(h-18*S)//2))
    f = font(13)
    dr.text((x+9*S+18*S+8*S, cy), label, font=f, fill=FG if active else FG2, anchor="lm")
    # close glyph
    dr.text((x+w-13*S, cy), "×", font=font(14), fill=(FG if active else FG2), anchor="mm")
    return x+w+8*S

px = x
px = pill(px, "Text Editor",  "text-editor", True)
px = pill(px, "Files",        "files",       False, hover=True)
px = pill(px, "Calculator",   "calculator",  False)

# ---- right: status glyphs + clock ----
clk = "9:41"
f = font(14)
cw = dr.textlength(clk, font=f)
dr.text((CW-16*S, cy), clk, font=f, fill=FG, anchor="rm")

out = "panel-preview.png"
canvas.convert("RGB").save(out)
print("wrote", out, canvas.size)
