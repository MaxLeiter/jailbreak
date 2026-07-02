#!/usr/bin/env python3
"""Resolve a .desktop Icon= name to a source image and emit the iOS home-screen
icon PNGs for one generated launcher .app bundle.

Pipeline:
  1. resolve the Icon name (or absolute path) against the freedesktop icon dirs
     mirrored under one or more --icons-root trees (largest raster wins; SVG is
     rasterised with rsvg-convert);
  2. centre it on a consistent dark, brand-blue-framed square so transparent or
     oddly-shaped Linux icons still look at home on the iPad Home Screen;
  3. write the named PNGs the bundle's Info.plist CFBundleIcons points at.

Standalone; uses Pillow (repo .repo-venv) + rsvg-convert. Invoked by gen-launchers.sh.

  gen-icons.py --icon org.gnome.Console --name "Console" \
               --icons-root /path/to/var/jb/usr/share --out BUNDLE.app
"""
import argparse, os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

# iOS icon outputs: (filename, pixel size). Base names match CFBundleIconFiles.
OUTPUTS = [
    ("AppIcon60x60@2x.png", 120),
    ("AppIcon76x76@2x~ipad.png", 152),
    ("AppIcon83.5x83.5@2x~ipad.png", 167),
]

# freedesktop raster sizes, largest first (we want the crispest source).
HICOLOR_SIZES = ["512x512", "256x256", "192x192", "128x128", "96x96",
                 "64x64", "48x48", "scalable"]
BG_TOP = (24, 27, 38)     # #181b26
BG_BOT = (9, 10, 16)      # #090a10
ACCENT = (85, 170, 255)   # #55aaff brand blue


def lerp(a, b, t):
    return tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(3))


def find_icon(name, roots):
    """Return a path to a source image for `name`, or None."""
    if not name:
        return None
    if os.path.isabs(name) and os.path.isfile(name):
        return name
    # strip an extension if the .desktop gave one (Icon=foo.png is legal)
    base = name
    for ext in (".png", ".svg", ".xpm"):
        if base.lower().endswith(ext):
            base = base[: -len(ext)]
            break
    for root in roots:
        # hicolor (and any other theme dirs present), largest raster first
        for theme in ("hicolor", "Adwaita", "gnome", "default"):
            for size in HICOLOR_SIZES:
                for ext in ("png", "svg"):
                    p = os.path.join(root, "icons", theme, size, "apps", base + "." + ext)
                    if os.path.isfile(p):
                        return p
        # flat pixmaps fallback
        for ext in ("png", "svg", "xpm"):
            p = os.path.join(root, "pixmaps", base + "." + ext)
            if os.path.isfile(p):
                return p
    return None


def load_source(path, px=1024):
    """Load `path` as an RGBA image ~px on its long edge (rasterising SVG)."""
    if path.lower().endswith(".svg"):
        tmp = tempfile.NamedTemporaryFile(suffix=".png", delete=False)
        tmp.close()
        try:
            subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px),
                            "-o", tmp.name, path], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            img = Image.open(tmp.name).convert("RGBA")
        finally:
            os.unlink(tmp.name)
        return img
    return Image.open(path).convert("RGBA")


def placeholder(name, px=1024):
    """A brand tile with the app's initial — used when no icon resolves."""
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    letter = (name.strip()[:1] or "?").upper()
    try:
        font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", int(px * 0.5))
    except Exception:
        font = ImageFont.load_default()
    bbox = d.textbbox((0, 0), letter, font=font)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text(((px - w) / 2 - bbox[0], (px - h) / 2 - bbox[1]), letter,
           fill=ACCENT + (255,), font=font)
    return img


def compose(src, px=1024):
    """Centre `src` on the brand gradient square at output size `px`."""
    canvas = Image.new("RGB", (px, px), BG_BOT)
    d = ImageDraw.Draw(canvas)
    for y in range(px):
        d.line([(0, y), (px, y)], fill=lerp(BG_TOP, BG_BOT, y / px))
    # fit the source into ~80% of the tile, centred, preserving aspect
    inner = int(px * 0.80)
    s = src.copy()
    s.thumbnail((inner, inner), Image.LANCZOS)
    canvas.paste(s, ((px - s.width) // 2, (px - s.height) // 2), s)
    return canvas


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--icon", default="", help="Icon= name or absolute path")
    ap.add_argument("--name", default="App", help="display name (placeholder initial)")
    ap.add_argument("--icons-root", default="", help="colon-separated share roots to search")
    ap.add_argument("--out", required=True, help="bundle .app dir to write icons into")
    args = ap.parse_args()

    roots = [r for r in args.icons_root.split(":") if r]
    src_path = find_icon(args.icon, roots)
    if src_path:
        try:
            src = load_source(src_path)
            print(f"   icon: {args.icon} -> {src_path}")
        except Exception as e:
            print(f"   icon: {args.icon} failed to load ({e}); using placeholder", file=sys.stderr)
            src = placeholder(args.name)
    else:
        print(f"   icon: {args.icon or '(none)'} not found; using placeholder")
        src = placeholder(args.name)

    os.makedirs(args.out, exist_ok=True)
    master = compose(src, 1024)
    for fname, size in OUTPUTS:
        master.resize((size, size), Image.LANCZOS).save(os.path.join(args.out, fname))


if __name__ == "__main__":
    main()
