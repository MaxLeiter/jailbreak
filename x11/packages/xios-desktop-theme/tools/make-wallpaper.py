#!/usr/bin/env python3
"""Generate the default Xios desktop wallpaper.

A calm, dark desktop background: a smooth diagonal gradient from a deep
blue-grey down to near-black, with a soft, wide glow toward the top-centre for
a little depth. Rendered at full resolution with a touch of dither so the dark
gradient stays band-free through JPEG. Deterministic: every build is identical.

Usage: make-wallpaper.py OUTPUT.jpg [WIDTH HEIGHT]
"""
import sys
import numpy as np
from PIL import Image

W = int(sys.argv[2]) if len(sys.argv) > 2 else 2160   # iPad 7 native landscape
H = int(sys.argv[3]) if len(sys.argv) > 3 else 1620

# Corner colours (top-left, top-right, bottom-left, bottom-right) and the glow.
C00 = np.array([24, 30, 42], np.float32)
C10 = np.array([16, 22, 32], np.float32)
C01 = np.array([12, 16, 24], np.float32)
C11 = np.array([6, 9, 14], np.float32)
GLOW = np.array([54, 68, 92], np.float32)

yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
u = (xx / (W - 1))[..., None]
v = (yy / (H - 1))[..., None]

# Bilinear diagonal gradient across the four corners.
top = C00 * (1 - u) + C10 * u
bot = C01 * (1 - u) + C11 * u
base = top * (1 - v) + bot * v

# Wide, soft radial glow toward the top-centre.
cx, cy = 0.5 * W, 0.34 * H
r = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
rmax = np.sqrt(max(cx, W - cx) ** 2 + max(cy, H - cy) ** 2)
g = np.clip(1.0 - r / (rmax * 0.95), 0.0, 1.0) ** 2.2
a = (g * 0.30)[..., None]
base = base * (1.0 - a) + GLOW * a

# Subtle dither to keep the dark gradient smooth after JPEG quantisation.
noise = np.random.default_rng(7).normal(0.0, 1.4, size=base.shape)
img = np.clip(base + noise, 0, 255).astype(np.uint8)

out = sys.argv[1]
Image.fromarray(img, "RGB").save(out, quality=92, subsampling=0, optimize=True)
print("wrote", out, "%dx%d" % (W, H))
