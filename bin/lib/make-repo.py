#!/usr/bin/env python3
"""Generate a polished static APT (Cydia/Sileo) repo from repo/debs/*.deb.

Outputs in repo/:
  Packages, Packages.gz, Release      package index (+ rich fields)
  index.html                          themed landing page
  CydiaIcon.png, favicon.ico          repo icon (from maxleiter.com favicon)
  icons/<pkg>.png                     per-package icon
  banners/<pkg>.png                   featured banner
  depictions/<pkg>.json               Sileo native depiction
  depictions/<pkg>.html               HTML depiction (Cydia/Zebra)
  sileo-featured.json                 featured carousel
  meta/<pkg>.json                     (input) optional per-package metadata

Run via the venv that has Pillow:  .repo-venv/bin/python bin/lib/make-repo.py
Re-run after adding/removing .debs. No network needed.
"""
import functools, os, io, gzip, json, hashlib, tarfile, html, shutil, math, re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "repo"))
DEBS = os.path.join(REPO, "debs")
META = os.path.join(REPO, "meta")

APP_SECTION = "X11/Wayland Apps"
APP_SECTION_PACKAGES = {
    "baobab",
    "d-spy",
    "file-roller",
    "gnome-calculator",
    "gnome-console",
    "gnome-font-viewer",
    "gnome-terminal",
    "gnome-text-editor",
    "hitori",
    "nautilus",
    "thunar",
    "xfce4-appfinder",
}

# ── identity / theme ─────────────────────────────────────────────────────────
BASE_URL    = "https://repo.maxleiter.com"
REPO_NAME   = "Max's Repo"
ORIGIN      = REPO_NAME
DESCRIPTION = "Jailbreak packages by Max"
ARCH        = "iphoneos-arm64"
PUBLISHER   = "Max Leiter <maxwell.leiter@gmail.com>"
ACCENT      = (85, 170, 255)      # #55aaff (maxleiter.com brand blue)
ACCENT_HEX  = "#55aaff"
ICON_BG     = (16, 16, 20)
FAVICON_SRC = os.path.expanduser("~/Documents/maxleiter.com/public/favicons")

try:
    from PIL import Image, ImageDraw, ImageFont
    HAVE_PIL = True
except Exception:
    HAVE_PIL = False

def font(bold=False, size=40):
    for p in (["/System/Library/Fonts/Supplemental/Arial Bold.ttf"] if bold else
              ["/System/Library/Fonts/Supplemental/Arial.ttf",
               "/System/Library/Fonts/SFNS.ttf"]):
        if os.path.exists(p):
            try: return ImageFont.truetype(p, size)
            except Exception: pass
    return ImageFont.load_default()

# ── .deb parsing ─────────────────────────────────────────────────────────────
def ar_members(data):
    assert data[:8] == b"!<arch>\n"
    out, off = {}, 8
    while off + 60 <= len(data):
        hdr = data[off:off + 60]; off += 60
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        out[name] = data[off:off + size]; off += size + (size & 1)
    return out

def control_dict(deb_bytes):
    m = ar_members(deb_bytes)
    cn = next(n for n in m if n.startswith("control.tar"))
    mode = {"control.tar.gz": "r:gz", "control.tar.xz": "r:xz", "control.tar": "r:"}.get(cn, "r:*")
    with tarfile.open(fileobj=io.BytesIO(m[cn]), mode=mode) as tf:
        mem = next(x for x in tf.getmembers() if x.name.lstrip("./") == "control")
        text = tf.extractfile(mem).read().decode("utf-8")
    d, order = {}, []
    for ln in text.splitlines():
        if ": " in ln and not ln.startswith(" "):
            k, v = ln.split(": ", 1); d[k] = v; order.append(k)
    d["__order__"] = order
    return d

def normalize_section(ctrl):
    sec = (ctrl.get("Section") or "").strip()
    if sec.lower() == "x11":
        ctrl["Section"] = "X11"
    if ctrl.get("Package") in APP_SECTION_PACKAGES:
        ctrl["Section"] = APP_SECTION

def normalize_publisher(ctrl):
    for key in ("Maintainer", "Author"):
        ctrl[key] = PUBLISHER
        if key not in ctrl["__order__"]:
            ctrl["__order__"].append(key)

def human_size(n):
    return f"{n/1024:.1f} KiB" if n >= 1024 else f"{n} B"

def _deb_order_char(ch):
    if not ch:
        return 0
    if ch == "~":
        return -1
    if ch.isalpha():
        return ord(ch)
    return ord(ch) + 256

def _deb_verrevcmp(a, b):
    ia = ib = 0
    la, lb = len(a), len(b)
    while ia < la or ib < lb:
        while (ia < la and not a[ia].isdigit()) or (ib < lb and not b[ib].isdigit()):
            ca = a[ia] if ia < la and not a[ia].isdigit() else ""
            cb = b[ib] if ib < lb and not b[ib].isdigit() else ""
            oa, ob = _deb_order_char(ca), _deb_order_char(cb)
            if oa != ob:
                return -1 if oa < ob else 1
            ia += 1 if ca else 0
            ib += 1 if cb else 0

        while ia < la and a[ia] == "0":
            ia += 1
        while ib < lb and b[ib] == "0":
            ib += 1

        enda = ia
        while enda < la and a[enda].isdigit():
            enda += 1
        endb = ib
        while endb < lb and b[endb].isdigit():
            endb += 1

        lena, lenb = enda - ia, endb - ib
        if lena != lenb:
            return -1 if lena < lenb else 1
        if a[ia:enda] != b[ib:endb]:
            return -1 if a[ia:enda] < b[ib:endb] else 1
        ia, ib = enda, endb
    return 0

def compare_deb_versions(a, b):
    def split(v):
        if ":" in v:
            epoch, rest = v.split(":", 1)
        else:
            epoch, rest = "0", v
        if "-" in rest:
            upstream, revision = rest.rsplit("-", 1)
        else:
            upstream, revision = rest, "0"
        try:
            epoch_i = int(epoch)
        except ValueError:
            epoch_i = 0
        return epoch_i, upstream, revision

    ea, ua, ra = split(a)
    eb, ub, rb = split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    c = _deb_verrevcmp(ua, ub)
    if c:
        return c
    return _deb_verrevcmp(ra, rb)

def compare_deb_filenames(a, b):
    def split(fn):
        stem = fn[:-4] if fn.endswith(".deb") else fn
        parts = stem.split("_", 2)
        if len(parts) == 3:
            return parts
        return stem, "0", ""

    pa, va, aa = split(a)
    pb, vb, ab = split(b)
    if pa != pb:
        return -1 if pa < pb else 1
    c = compare_deb_versions(va, vb)
    if c:
        return c
    if aa != ab:
        return -1 if aa < ab else 1
    return 0

# ── markdown-lite → HTML (for the HTML depiction / landing) ───────────────────
def md_to_html(md):
    out, in_ul = [], False
    for raw in md.split("\n"):
        line = html.escape(raw).strip()
        line = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", line)
        line = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<em>\1</em>", line)
        if line.startswith("- "):
            if not in_ul: out.append("<ul>"); in_ul = True
            out.append(f"<li>{line[2:]}</li>")
        else:
            if in_ul: out.append("</ul>"); in_ul = False
            out.append(f"<p>{line}</p>" if line else "")
    if in_ul: out.append("</ul>")
    return "\n".join(x for x in out if x)

# ── image assets ─────────────────────────────────────────────────────────────
def clock_icon(px=256):
    s = 4; S = px * s
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=ICON_BG + (255,))
    c = S / 2; r = S * 0.30; w = max(2, int(S * 0.05))
    d.ellipse([c - r, c - r, c + r, c + r], outline=ACCENT + (255,), width=w)
    # hands (rounded-ish via wide lines)
    d.line([c, c, c, c - r * 0.72], fill=ACCENT + (255,), width=w)                       # minute → 12
    d.line([c, c, c + r * 0.46, c + r * 0.30], fill=ACCENT + (255,), width=w)            # hour → ~4-5
    hub = S * 0.035
    d.ellipse([c - hub, c - hub, c + hub, c + hub], fill=ACCENT + (255,))
    return img.resize((px, px), Image.LANCZOS)

# ── per-category glyph icons ──────────────────────────────────────────────────
# A cohesive set of line/solid glyphs on the same dark rounded tile, one per
# repo Section, so every package no longer shares a single clock icon.
def _icon_base(px):
    s = 4; S = px * s
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.22), fill=ICON_BG + (255,))
    return img, d, S

def _glyph_sliders(d, S):          # Tweaks — three setting sliders
    A = ACCENT + (255,)
    w = max(2, int(S * 0.045)); r = int(S * 0.072)
    x0, x1 = S * 0.24, S * 0.76
    for y, kx in ((S * 0.34, S * 0.60), (S * 0.50, S * 0.40), (S * 0.66, S * 0.62)):
        d.line([x0, y, x1, y], fill=A, width=w)
        d.ellipse([kx - r, y - r, kx + r, y + r], fill=ICON_BG + (255,), outline=A, width=w)

def _glyph_gear(d, S):             # Utilities — cog
    A = ACCENT + (255,); c = S / 2
    R_disc, R_teeth, tr, hole = S * 0.205, S * 0.275, S * 0.066, S * 0.090
    for k in range(8):
        a = math.pi * 2 * k / 8
        tx, ty = c + R_teeth * math.cos(a), c + R_teeth * math.sin(a)
        d.ellipse([tx - tr, ty - tr, tx + tr, ty + tr], fill=A)
    d.ellipse([c - R_disc, c - R_disc, c + R_disc, c + R_disc], fill=A)
    d.ellipse([c - hole, c - hole, c + hole, c + hole], fill=ICON_BG + (255,))

def _glyph_window(d, S):           # X11 — titled window
    A = ACCENT + (255,); w = max(2, int(S * 0.05))
    d.rounded_rectangle([S * 0.21, S * 0.25, S * 0.79, S * 0.71],
                        radius=int(S * 0.05), outline=A, width=w)
    d.line([S * 0.21, S * 0.37, S * 0.79, S * 0.37], fill=A, width=w)

def _glyph_books(d, S):            # Libraries — books on a shelf
    A = ACCENT + (255,); rad = int(S * 0.028); base = S * 0.70
    for x0, x1, top in ((0.30, 0.40, 0.36), (0.42, 0.52, 0.30), (0.54, 0.64, 0.44)):
        d.rounded_rectangle([S * x0, S * top, S * x1, base], radius=rad, fill=A)
    d.line([S * 0.26, base + S * 0.02, S * 0.70, base + S * 0.02],
           fill=A, width=max(2, int(S * 0.035)))

def _glyph_code(d, S):             # Development — </> brackets
    A = ACCENT + (255,); w = max(2, int(S * 0.052))
    d.line([S * 0.40, S * 0.33, S * 0.27, S * 0.50, S * 0.40, S * 0.67], fill=A, width=w, joint="curve")
    d.line([S * 0.60, S * 0.33, S * 0.73, S * 0.50, S * 0.60, S * 0.67], fill=A, width=w, joint="curve")
    d.line([S * 0.55, S * 0.30, S * 0.45, S * 0.70], fill=A, width=w)

def _glyph_tiles(d, S):            # Desktop — 2x2 flavor tiles, one filled
    A = ACCENT + (255,); w = max(2, int(S * 0.05)); rad = int(S * 0.04)
    for i, (x0, y0) in enumerate(((0.26, 0.26), (0.54, 0.26), (0.26, 0.54), (0.54, 0.54))):
        box = [S * x0, S * y0, S * (x0 + 0.20), S * (y0 + 0.20)]
        if i == 0: d.rounded_rectangle(box, radius=rad, fill=A)
        else:      d.rounded_rectangle(box, radius=rad, outline=A, width=w)

def _glyph_apps(d, S):             # X11/Wayland Apps — overlapping app windows
    A = ACCENT + (255,); w = max(2, int(S * 0.045)); rad = int(S * 0.045)
    d.rounded_rectangle([S * 0.30, S * 0.24, S * 0.74, S * 0.58], radius=rad, outline=A, width=w)
    d.line([S * 0.30, S * 0.35, S * 0.74, S * 0.35], fill=A, width=w)
    d.rounded_rectangle([S * 0.22, S * 0.40, S * 0.66, S * 0.74], radius=rad, fill=ICON_BG + (255,), outline=A, width=w)
    d.line([S * 0.22, S * 0.51, S * 0.66, S * 0.51], fill=A, width=w)

def _glyph_box(d, S):              # default / unknown section — package box
    A = ACCENT + (255,); w = max(2, int(S * 0.05))
    d.rounded_rectangle([S * 0.24, S * 0.28, S * 0.76, S * 0.72],
                        radius=int(S * 0.05), outline=A, width=w)
    d.line([S * 0.24, S * 0.44, S * 0.76, S * 0.44], fill=A, width=w)
    d.line([S * 0.50, S * 0.44, S * 0.50, S * 0.72], fill=A, width=w)

CATEGORY_GLYPH = {
    "Desktop": _glyph_tiles,
    "X11/Wayland Apps": _glyph_apps,
    "Tweaks": _glyph_sliders,
    "Utilities": _glyph_gear,
    "X11": _glyph_window,
    "Development": _glyph_code,
    "Libraries": _glyph_books,
}

def category_icon(section, px=256):
    img, d, S = _icon_base(px)
    CATEGORY_GLYPH.get(section, _glyph_box)(d, S)
    return img.resize((px, px), Image.LANCZOS)

def make_banner(path, title, tagline, icon_img):
    W, H = 789, 444
    img = Image.new("RGB", (W, H), (9, 9, 12))
    d = ImageDraw.Draw(img)
    # subtle accent glow strip on the left
    for x in range(0, 10):
        d.line([(x, 0), (x, H)], fill=ACCENT)
    ic = icon_img.resize((210, 210), Image.LANCZOS)
    img.paste(ic, (54, (H - 210) // 2), ic)
    tx = 310
    d.text((tx, 150), title, font=font(bold=True, size=58), fill=(238, 238, 244))
    d.text((tx, 226), tagline, font=font(size=30), fill=(150, 150, 162))
    d.text((tx, 300), "repo.maxleiter.com", font=font(bold=True, size=26), fill=ACCENT)
    img.save(path)

# ── per-package metadata ─────────────────────────────────────────────────────
def load_meta(pkgid):
    p = os.path.join(META, f"{pkgid}.json")
    if os.path.exists(p):
        with open(p) as f: return json.load(f)
    return {}

def package_developer(meta, ctrl):
    developer = meta.get("developer")
    if not developer or developer == "Max":
        return ctrl.get("Author", ctrl.get("Maintainer", ""))
    return developer

# ── native (Sileo) depiction ─────────────────────────────────────────────────
def native_depiction(ctrl, meta, size):
    pid = ctrl["Package"]
    info = [
        ("Version", ctrl.get("Version", "")),
        ("Size", human_size(size)),
        ("Developer", package_developer(meta, ctrl)),
        ("Section", ctrl.get("Section", "Tweaks")),
        ("Identifier", pid),
    ]
    details = [{"class": "DepictionMarkdownView",
                "markdown": meta.get("description", ctrl.get("Description", ""))},
               {"class": "DepictionSeparatorView"},
               {"class": "DepictionHeaderView", "title": "Information"}]
    for k, v in info:
        details.append({"class": "DepictionTableTextView", "title": k, "text": v})

    tabs = [{"class": "DepictionStackView", "tabname": "Details", "views": details}]
    cl = meta.get("changelog")
    if cl:
        md = "\n\n".join(f"## {c['version']}" + (f"  ·  {c['date']}" if c.get("date") else "")
                         + "\n" + c.get("notes", "") for c in cl)
        tabs.append({"class": "DepictionStackView", "tabname": "Changelog",
                     "views": [{"class": "DepictionMarkdownView", "markdown": md}]})

    return {"minVersion": "0.1", "class": "DepictionTabView",
            "headerImage": f"{BASE_URL}/banners/{pid}.png",
            "tintColor": ACCENT_HEX, "tabs": tabs}

# ── HTML depiction (Cydia/Zebra) ─────────────────────────────────────────────
def html_depiction(ctrl, meta, size):
    pid = ctrl["Package"]
    rows = "".join(
        f"<tr><td>{html.escape(k)}</td><td>{html.escape(v)}</td></tr>" for k, v in [
            ("Version", ctrl.get("Version", "")), ("Size", human_size(size)),
            ("Developer", package_developer(meta, ctrl)),
            ("Section", ctrl.get("Section", "Tweaks")), ("Identifier", pid)])
    body = md_to_html(meta.get("description", ctrl.get("Description", "")))
    name = html.escape(ctrl.get("Name", pid))
    tagline = html.escape(meta.get("tagline", ctrl.get("Description", "")))
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#000000">
<title>{name} · {html.escape(ORIGIN)}</title><link rel="icon" href="../favicon.ico">{head_links("../")}{HEAD_JS}</head>
<body><div class="wrap">
  <a class="back" href="../index.html">{BACK_SVG}<span>{html.escape(ORIGIN)}</span></a>
  <header class="masthead"><img src="../icons/{pid}.png" alt="">
    <div><h1>{name}</h1><p class="sub">{tagline}</p></div>{THEME_BTN}</header>
  <div class="prose">{body}</div>
  <h2 class="section">Information</h2><table class="info">{rows}</table>
  <footer><a href="../index.html">&larr; All packages</a></footer>
</div>{THEME_JS}</body></html>"""

# ── shared CSS ───────────────────────────────────────────────────────────────
def head_links(prefix=""):
    # One shared, cacheable stylesheet (site.css) instead of a ~7 KB <style> block
    # inlined into every page. Fonts are self-hosted via @font-face inside it, so the
    # site makes no third-party (Google Fonts) requests.
    return f'<link rel="stylesheet" href="{prefix}site.css">'

# Written once to repo/site.css by main(); linked by index + every depiction.
# @font-face url() resolves relative to THIS file (repo/site.css) -> repo/fonts/.
SITE_CSS = f"""
  @font-face{{font-family:"Geist";font-style:normal;font-weight:100 900;font-display:swap;src:url("fonts/Geist-Variable.woff2") format("woff2")}}
  @font-face{{font-family:"Geist Mono";font-style:normal;font-weight:100 900;font-display:swap;src:url("fonts/GeistMono-Variable.woff2") format("woff2")}}
  :root{{
    color-scheme:dark;
    --bg:#0a0a0b; --bg-hover:#141417;
    --line:#26262a; --line-hi:#45454c;
    --fg:#ececef; --fg-dim:#9c9ca4; --fg-mute:#6b6b73;
    --accent:{ACCENT_HEX}; --accent-ink:#001321;
    --mono:"Geist Mono",ui-monospace,monospace;
    --maxw:760px;
  }}
  :root[data-theme="light"]{{
    color-scheme:light;
    --bg:#fbfbfa; --bg-hover:#f1f1ee;
    --line:#e4e4e0; --line-hi:#c6c6bf;
    --fg:#151514; --fg-dim:#5d5d58; --fg-mute:#8b8b85;
    --accent:#0a6fce; --accent-ink:#fff;
  }}
  *{{box-sizing:border-box}}
  html{{-webkit-text-size-adjust:100%}}
  body{{margin:0;font-family:"Geist",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
    font-size:15.5px;line-height:1.6;background:var(--bg);color:var(--fg);
    -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}}
  .wrap{{max-width:var(--maxw);margin:0 auto;padding:52px 24px 96px}}
  a{{color:var(--accent);text-decoration:none}}
  .vh{{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;
    clip:rect(0,0,0,0);white-space:nowrap;border:0}}
  .micro{{font-family:var(--mono);font-size:11px;font-weight:500;
    letter-spacing:.14em;text-transform:uppercase;color:var(--fg-mute)}}

  /* landing masthead */
  .mast-top{{display:flex;align-items:center;gap:12px;padding-bottom:14px;
    border-bottom:1px solid var(--line)}}
  .mast-top .micro{{margin-right:auto}}
  .mast h1{{font-size:clamp(40px,9vw,68px);font-weight:640;letter-spacing:-.045em;
    line-height:1.04;margin:30px 0 10px}}
  .mast .sub{{color:var(--fg-dim);font-size:15px;margin:0}}
  .mast .sub a{{color:var(--fg-dim);border-bottom:1px solid var(--line-hi)}}
  .mast .sub a:hover{{color:var(--fg)}}

  /* depiction masthead */
  .masthead{{display:flex;align-items:center;gap:16px;margin-bottom:6px}}
  .masthead img{{width:56px;height:56px;flex:0 0 auto}}
  .masthead h1{{font-size:26px;font-weight:640;letter-spacing:-.03em;margin:0}}
  .masthead .sub{{color:var(--fg-dim);margin:4px 0 0;font-size:14.5px}}
  .masthead .theme-toggle{{margin-left:auto}}

  .theme-toggle{{flex:0 0 auto;display:inline-flex;align-items:center;justify-content:center;
    width:34px;height:34px;cursor:pointer;border:1px solid var(--line);border-radius:0;
    background:transparent;color:var(--fg-dim);
    transition:color .15s,border-color .15s}}
  .theme-toggle:hover{{color:var(--fg);border-color:var(--line-hi)}}
  .theme-toggle:focus-visible{{outline:2px solid var(--accent);outline-offset:2px}}
  .theme-toggle svg{{width:16px;height:16px;display:block}}
  .theme-toggle .i-moon{{display:none}}
  :root[data-theme="light"] .theme-toggle .i-sun{{display:none}}
  :root[data-theme="light"] .theme-toggle .i-moon{{display:block}}

  /* install strip */
  .install{{margin:26px 0 0}}
  .field{{display:flex}}
  .field input{{flex:1;min-width:0;padding:12px 14px;border:1px solid var(--line);
    border-right:0;border-radius:0;background:transparent;color:var(--fg);
    font-family:var(--mono);font-size:13px}}
  .field input:focus-visible{{outline:none;border-color:var(--line-hi)}}
  .btn{{display:inline-flex;align-items:center;justify-content:center;gap:6px;
    padding:11px 16px;border:1px solid var(--line);border-radius:0;background:transparent;
    color:var(--fg-dim);cursor:pointer;white-space:nowrap;
    font-family:var(--mono);font-size:11.5px;font-weight:500;
    letter-spacing:.12em;text-transform:uppercase;
    transition:color .15s,border-color .15s,background .15s,opacity .15s}}
  .btn:hover{{color:var(--fg);border-color:var(--line-hi)}}
  .btn:focus-visible{{outline:2px solid var(--accent);outline-offset:2px;z-index:1}}
  .btn.copy{{border:1px solid var(--fg);background:var(--fg);color:var(--bg);min-width:92px}}
  .btn.copy:hover{{opacity:.85}}
  .btn.copy.ok{{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);opacity:1}}
  .managers{{display:flex;margin-top:-1px}}
  .managers .btn{{flex:1;position:relative;margin-left:-1px}}
  .managers .btn:first-child{{margin-left:0}}
  .managers .btn:hover{{z-index:1}}
  .btn.primary{{color:var(--accent)}}
  .btn.primary:hover{{border-color:var(--accent);color:var(--accent)}}

  /* top-level tabs: xiOS / Tweaks */
  .tabs{{display:flex;gap:30px;margin-top:48px;border-bottom:1px solid var(--line)}}
  .tab{{appearance:none;background:none;border:0;padding:0 2px 14px;cursor:pointer;
    font-family:inherit;font-size:clamp(27px,5.5vw,40px);font-weight:620;
    letter-spacing:-.035em;line-height:1;color:var(--fg-mute);position:relative;
    transition:color .15s}}
  .tab:hover{{color:var(--fg-dim)}}
  .tab[aria-selected="true"]{{color:var(--fg)}}
  .tab[aria-selected="true"]::after{{content:"";position:absolute;left:0;right:0;
    bottom:-1px;height:2px;background:var(--accent)}}
  .tab:focus-visible{{outline:2px solid var(--accent);outline-offset:4px}}
  .tab .tab-n{{font-family:var(--mono);font-size:11.5px;font-weight:500;
    letter-spacing:0;color:var(--fg-mute);vertical-align:top;
    margin-left:7px;position:relative;top:2px}}

  .lede{{color:var(--fg-dim);font-size:15px;max-width:58ch;margin:24px 0 0}}
  .lede strong{{color:var(--fg);font-weight:560}}

  /* flavor chooser */
  .fl-head{{display:flex;align-items:baseline;gap:10px;margin:36px 0 0;
    padding-bottom:10px;border-bottom:1px solid var(--line)}}
  .fl-head h2{{margin:0}}
  .flavors{{display:grid;grid-template-columns:1fr 1fr;border-left:1px solid var(--line)}}
  .flavor{{display:block;padding:18px 18px 20px;color:inherit;min-width:0;
    border-right:1px solid var(--line);border-bottom:1px solid var(--line);
    transition:background .15s}}
  .flavor:hover{{background:var(--bg-hover)}}
  .flavor:focus-visible{{outline:2px solid var(--accent);outline-offset:-2px}}
  .f-num{{display:block;font-family:var(--mono);font-size:11px;
    letter-spacing:.14em;color:var(--accent)}}
  .f-name{{display:block;font-size:22px;font-weight:620;letter-spacing:-.02em;margin-top:12px}}
  .f-name .arr{{display:inline-block;margin-left:7px;color:var(--accent);opacity:0;
    transform:translateX(-3px);transition:opacity .15s,transform .15s}}
  .flavor:hover .f-name .arr{{opacity:1;transform:none}}
  .f-tag{{display:block;color:var(--fg-dim);font-size:13.5px;line-height:1.5;margin-top:5px}}
  .f-pkg{{display:block;margin-top:14px;font-family:var(--mono);font-size:11px;color:var(--fg-mute)}}

  /* categories + package rows */
  .cat{{margin-top:36px}}
  summary.cat-head{{list-style:none;display:flex;align-items:baseline;gap:10px;cursor:pointer;
    padding-bottom:10px;border-bottom:1px solid var(--line);
    -webkit-tap-highlight-color:transparent}}
  summary.cat-head::-webkit-details-marker{{display:none}}
  summary.cat-head:focus-visible{{outline:2px solid var(--accent);outline-offset:3px}}
  .cat-name{{font-family:var(--mono);font-size:11px;font-weight:500;
    letter-spacing:.14em;text-transform:uppercase;color:var(--fg-dim)}}
  summary.cat-head:hover .cat-name{{color:var(--fg)}}
  .cat-head .count,.fl-head .count{{font-family:var(--mono);font-size:11px;color:var(--fg-mute)}}
  .cat-head .ind{{margin-left:auto;font-family:var(--mono);font-size:13px;color:var(--fg-mute)}}
  .cat-head .ind::before{{content:"+"}}
  details.cat[open] .ind::before{{content:"\\2212"}}

  .list{{display:block}}
  .list.solo{{margin-top:26px;border-top:1px solid var(--line)}}
  .row{{display:flex;align-items:baseline;gap:14px;padding:11px 2px;min-width:0;
    border-bottom:1px solid var(--line);color:inherit;transition:background .15s}}
  .row:hover{{background:var(--bg-hover)}}
  .row:focus-visible{{outline:2px solid var(--accent);outline-offset:-2px}}
  .row .n{{font-weight:560;font-size:15px;letter-spacing:-.01em;white-space:nowrap;
    transition:color .15s}}
  .row:hover .n{{color:var(--accent)}}
  .row .t{{flex:1;min-width:0;color:var(--fg-dim);font-size:13.5px;
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
  .row .v{{font-family:var(--mono);font-size:11.5px;color:var(--fg-mute);white-space:nowrap}}

  /* depiction pages */
  .back{{display:inline-flex;align-items:center;gap:7px;color:var(--fg-dim);
    font-family:var(--mono);font-size:11px;font-weight:500;
    letter-spacing:.14em;text-transform:uppercase;margin-bottom:28px;transition:color .15s}}
  .back:hover{{color:var(--fg)}}
  .back svg{{width:14px;height:14px;display:block}}
  .prose p{{margin:.6em 0;color:var(--fg-dim)}}
  .prose strong{{color:var(--fg);font-weight:600}} .prose em{{color:var(--fg)}}
  .prose ul{{margin:.5em 0;padding-left:1.15em}} .prose li{{margin:.25em 0;color:var(--fg-dim)}}
  h2.section{{font-family:var(--mono);font-size:11px;font-weight:500;
    letter-spacing:.14em;text-transform:uppercase;color:var(--fg-dim);margin:36px 0 4px}}
  table.info{{width:100%;border-collapse:collapse;font-size:14px;margin-top:6px}}
  table.info td{{padding:11px 2px;border-bottom:1px solid var(--line)}}
  table.info tr:last-child td{{border-bottom:0}}
  table.info td:first-child{{color:var(--fg-mute);width:38%}}
  table.info td:last-child{{font-family:var(--mono);font-size:12.5px;word-break:break-word}}

  footer{{margin-top:56px;padding-top:18px;border-top:1px solid var(--line);
    display:flex;justify-content:space-between;gap:12px;
    font-family:var(--mono);font-size:11px;font-weight:500;
    letter-spacing:.14em;text-transform:uppercase;color:var(--fg-mute)}}
  footer a{{color:var(--fg-dim)}} footer a:hover{{color:var(--fg)}}

  @media (max-width:560px){{
    .wrap{{padding:36px 18px 72px}}
    .flavors{{grid-template-columns:1fr}}
    .managers{{flex-wrap:wrap}}
    .managers .btn{{flex:1 1 100%;margin-left:0;margin-top:-1px}}
    .row{{flex-wrap:wrap;row-gap:0}}
    .row .v{{margin-left:auto}}
    .row .t{{flex:1 1 100%;order:3}}
  }}
  @media (prefers-reduced-motion:no-preference){{
    .reveal{{opacity:0;transform:translateY(9px);
      animation:rise .5s cubic-bezier(.2,.7,.3,1) forwards;
      animation-delay:calc(var(--i,0)*38ms)}}
    @keyframes rise{{to{{opacity:1;transform:none}}}}
  }}
"""

# left-chevron used by the depiction "back" link
BACK_SVG = ('<svg viewBox="0 0 16 16" fill="none" aria-hidden="true">'
            '<path d="M10 12L6 8l4-4" stroke="currentColor" stroke-width="1.6" '
            'stroke-linecap="round" stroke-linejoin="round"/></svg>')

# index page behaviour (kept out of the f-string to avoid brace escaping)
INDEX_JS = """
<script>
  var u = location.origin + location.pathname.replace(/index\\.html$/, "");
  document.getElementById("repo").value = u;
  document.getElementById("sileo").href = "sileo://source/" + u;
  document.getElementById("zebra").href = "zbra://sources/add/" + u;
  document.getElementById("cydia").href = "cydia://url/https://cydia.saurik.com/api/share#?source=" + u;
  var b = document.getElementById("copyBtn");
  b.addEventListener("click", function () {
    navigator.clipboard.writeText(u).then(function () {
      var prev = b.textContent;
      b.textContent = "Copied";
      b.classList.add("ok");
      setTimeout(function () { b.textContent = prev; b.classList.remove("ok"); }, 1400);
    });
  });

  var tabs = [].slice.call(document.querySelectorAll(".tab"));
  function showTab(name) {
    if (!tabs.some(function (t) { return t.dataset.tab === name; })) name = "xios";
    tabs.forEach(function (t) {
      var on = t.dataset.tab === name;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById("panel-" + t.dataset.tab).hidden = !on;
    });
  }
  tabs.forEach(function (t, i) {
    t.addEventListener("click", function () {
      showTab(t.dataset.tab);
      try { history.replaceState(null, "", "#" + t.dataset.tab); } catch (e) {}
    });
    t.addEventListener("keydown", function (e) {
      if (e.key !== "ArrowRight" && e.key !== "ArrowLeft") return;
      var next = tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
      next.focus(); next.click();
    });
  });
  addEventListener("hashchange", function () { showTab(location.hash.slice(1)); });
  if (location.hash) showTab(location.hash.slice(1));
</script>
"""

# xiOS category display order on the landing page: pinned head, then unknown
# sections alphabetically, then the big dependency buckets last (collapsed)
SECTION_ORDER = ["Desktop", "X11/Wayland Apps", "X11", "Utilities"]
SECTION_TAIL = ["Development", "Libraries"]
COLLAPSED_SECTIONS = {"Development", "Libraries"}
TWEAKS_SECTION = "Tweaks"
# featured flavor meta-packages (shown when their deb exists), display label
FLAVORS = [("xios-gnome", "GNOME"), ("xios-kde", "KDE Plasma"),
           ("xios-native", "Native"), ("xios-x11", "X11")]

# theme toggle (sun shown in dark mode, moon in light mode)
THEME_BTN = (
    '<button class="theme-toggle" id="theme-toggle" type="button" '
    'aria-label="Toggle theme" aria-pressed="false">'
    '<svg class="i-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4'
    'M17.7 17.7l1.4 1.4M2 12h2M20 12h2M6.3 17.7l-1.4 1.4M19.1 4.9l-1.4 1.4"/></svg>'
    '<svg class="i-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" '
    'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">'
    '<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg></button>'
)

# applies the saved/preferred theme before paint to avoid a flash of the wrong theme
HEAD_JS = """
<script>
  (function () {
    try {
      var t = localStorage.getItem("theme");
      if (t !== "light" && t !== "dark")
        t = matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", t);
    } catch (e) {}
  })();
</script>
"""

# wires up the toggle button (runs after the DOM is in place)
THEME_JS = """
<script>
  (function () {
    var btn = document.getElementById("theme-toggle");
    if (!btn) return;
    var root = document.documentElement;
    function sync() {
      var light = root.getAttribute("data-theme") === "light";
      btn.setAttribute("aria-pressed", String(light));
      btn.setAttribute("aria-label", light ? "Switch to dark theme" : "Switch to light theme");
    }
    sync();
    btn.addEventListener("click", function () {
      var next = root.getAttribute("data-theme") === "light" ? "dark" : "light";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem("theme", next); } catch (e) {}
      sync();
    });
  })();
</script>
"""

# ── index / landing page ─────────────────────────────────────────────────────
def write_index(pkgs):
    # debs are sorted oldest→newest, so keeping the last stanza per package id
    # shows each package once, at its newest version
    latest = {}
    for p in pkgs:
        latest[p["ctrl"]["Package"]] = p
    pkgs = list(latest.values())

    def section(p):
        return (p["ctrl"].get("Section") or TWEAKS_SECTION).strip()

    tweaks = [p for p in pkgs if section(p) == TWEAKS_SECTION]
    xios = [p for p in pkgs if section(p) != TWEAKS_SECTION]

    # staggered reveal counter (0 = masthead, 1 = install, 2 = tabs); cap so
    # the tail of a long list doesn't wait too long to appear
    step = [3]
    def nxt():
        v = min(step[0], 16); step[0] += 1; return v

    def name(p):
        return p["ctrl"].get("Name", p["ctrl"]["Package"])

    def tagline(p):
        # one-line tagline for the list: first line, first sentence
        tag = (p["meta"].get("tagline") or p["ctrl"].get("Description", "")).split("\n")[0].strip()
        return tag.split(". ")[0].strip()

    def row(p, idx=None):
        pid = p["ctrl"]["Package"]
        return f"""
        <a class="row reveal" style="--i:{nxt() if idx is None else idx}" href="depictions/{pid}.html">
          <span class="n">{html.escape(name(p))}</span>
          <span class="t">{html.escape(tagline(p))}</span>
          <span class="v">v{html.escape(p['ctrl'].get('Version',''))}</span>
        </a>"""

    # featured flavor chooser (xiOS tab)
    by_pid = {p["ctrl"]["Package"]: p for p in pkgs}
    flavor_cards, n_flavors = "", 0
    for pid, label in FLAVORS:
        p = by_pid.get(pid)
        if not p:
            continue
        n_flavors += 1
        flavor_cards += f"""
        <a class="flavor reveal" style="--i:{nxt()}" href="depictions/{pid}.html">
          <span class="f-num">{n_flavors:02d}</span>
          <span class="f-name">{html.escape(label)}<span class="arr" aria-hidden="true">&#8599;</span></span>
          <span class="f-tag">{html.escape(tagline(p))}</span>
          <span class="f-pkg">{pid}</span>
        </a>"""
    flavors_html = "" if not flavor_cards else f"""
      <div class="fl-head reveal" style="--i:{nxt()}"><h2 class="cat-name">Pick a flavor</h2><span class="count">{n_flavors}</span></div>
      <div class="flavors">{flavor_cards}</div>"""

    # xiOS categories: pinned head order, unknown sections alphabetically,
    # then the big dependency buckets last (collapsed)
    groups = {}
    for p in xios:
        groups.setdefault(section(p), []).append(p)
    order = ([s for s in SECTION_ORDER if s in groups]
             + sorted(s for s in groups if s not in SECTION_ORDER + SECTION_TAIL)
             + [s for s in SECTION_TAIL if s in groups])
    sections_html = ""
    for sec in order:
        items = sorted(groups[sec], key=lambda p: name(p).lower())
        rows = "".join(row(p) for p in items)
        is_open = "" if sec in COLLAPSED_SECTIONS else " open"
        sections_html += f"""
      <details class="cat"{is_open}>
        <summary class="cat-head"><span class="cat-name">{html.escape(sec)}</span><span class="count">{len(items)}</span><span class="ind" aria-hidden="true"></span></summary>
        <div class="list">{rows}</div>
      </details>"""

    # tweaks live in a hidden panel whose reveal animation restarts on tab
    # switch, so they get their own early stagger indices
    tweak_rows = "".join(row(p, min(3 + j, 16))
                         for j, p in enumerate(sorted(tweaks, key=lambda p: name(p).lower())))

    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#0a0a0b">
<title>{html.escape(ORIGIN)}</title><link rel="icon" href="favicon.ico">{head_links("")}{HEAD_JS}</head>
<body><div class="wrap">
  <header class="mast reveal" style="--i:0">
    <div class="mast-top"><span class="micro">APT repo &middot; {ARCH} &middot; {len(pkgs)} packages</span>{THEME_BTN}</div>
    <h1>{html.escape(ORIGIN)}</h1>
    <p class="sub">{html.escape(DESCRIPTION)} &middot; <a href="https://maxleiter.com">maxleiter.com</a></p>
  </header>
  <div class="install reveal" style="--i:1">
    <label class="vh" for="repo">Repository URL</label>
    <div class="field">
      <input id="repo" readonly value="" aria-label="Repository URL">
      <button class="btn copy" id="copyBtn" type="button">Copy</button>
    </div>
    <div class="managers">
      <a class="btn primary" id="sileo" href="#">Add to Sileo</a>
      <a class="btn" id="zebra" href="#">Add to Zebra</a>
      <a class="btn" id="cydia" href="#">Add to Cydia</a>
    </div>
  </div>
  <nav class="tabs reveal" style="--i:2" role="tablist" aria-label="Package groups">
    <button class="tab" id="tab-xios" data-tab="xios" type="button" role="tab" aria-selected="true" aria-controls="panel-xios">xiOS<span class="tab-n">{len(xios)}</span></button>
    <button class="tab" id="tab-tweaks" data-tab="tweaks" type="button" role="tab" aria-selected="false" aria-controls="panel-tweaks" tabindex="-1">Tweaks<span class="tab-n">{len(tweaks)}</span></button>
  </nav>
  <section class="panel" id="panel-xios" role="tabpanel" aria-labelledby="tab-xios">
    <p class="lede reveal" style="--i:3">A desktop for jailbroken iPads: X11, Wayland, GNOME and KDE, cross-compiled to run natively on iOS. <strong>Install one flavor</strong> and it pulls in everything it needs.</p>
    {flavors_html}
    {sections_html}
  </section>
  <section class="panel" id="panel-tweaks" role="tabpanel" aria-labelledby="tab-tweaks" hidden>
    <p class="lede">Small quality-of-life tweaks for iPadOS on rootless jailbreaks.</p>
    <div class="list solo">{tweak_rows}</div>
  </section>
  <footer><a href="https://maxleiter.com">maxleiter.com</a><span>{ARCH}</span></footer>
</div>{INDEX_JS}{THEME_JS}</body></html>"""
    open(os.path.join(REPO, "index.html"), "w").write(page)

# ── main ─────────────────────────────────────────────────────────────────────
def main():
    for d in ("icons", "banners", "depictions"):
        os.makedirs(os.path.join(REPO, d), exist_ok=True)

    # one shared, cacheable stylesheet for index + all depictions (was inlined per page)
    open(os.path.join(REPO, "site.css"), "w").write(SITE_CSS)

    # repo icon from the website favicon
    if os.path.isdir(FAVICON_SRC):
        shutil.copyfile(os.path.join(FAVICON_SRC, "apple-touch-icon.png"),
                        os.path.join(REPO, "CydiaIcon.png"))
        ico = os.path.join(FAVICON_SRC, "favicon.ico")
        if os.path.exists(ico):
            shutil.copyfile(ico, os.path.join(REPO, "favicon.ico"))

    pkgs, stanzas, featured = [], [], []
    for fn in sorted(os.listdir(DEBS), key=functools.cmp_to_key(compare_deb_filenames)):
        if not fn.endswith(".deb"):
            continue
        blob = open(os.path.join(DEBS, fn), "rb").read()
        ctrl = control_dict(blob); pid = ctrl["Package"]
        normalize_section(ctrl)
        normalize_publisher(ctrl)
        meta = load_meta(pid)
        pkgs.append({"ctrl": ctrl, "meta": meta})

        # assets
        if HAVE_PIL:
            icon = category_icon(ctrl.get("Section", "Tweaks"), 256)
            icon.save(os.path.join(REPO, "icons", f"{pid}.png"))
            make_banner(os.path.join(REPO, "banners", f"{pid}.png"),
                        ctrl.get("Name", pid),
                        meta.get("tagline", ctrl.get("Description", "")), icon)

        # depictions
        with open(os.path.join(REPO, "depictions", f"{pid}.json"), "w") as f:
            json.dump(native_depiction(ctrl, meta, len(blob)), f, indent=2)
        open(os.path.join(REPO, "depictions", f"{pid}.html"), "w").write(
            html_depiction(ctrl, meta, len(blob)))

        # Packages stanza: base control fields + repo/rich fields
        lines = [f"{k}: {ctrl[k]}" for k in ctrl["__order__"]]
        lines += [
            f"Filename: debs/{fn}",
            f"Size: {len(blob)}",
            f"MD5sum: {hashlib.md5(blob).hexdigest()}",
            f"SHA1: {hashlib.sha1(blob).hexdigest()}",
            f"SHA256: {hashlib.sha256(blob).hexdigest()}",
            f"Icon: {BASE_URL}/icons/{pid}.png",
            f"Depiction: {BASE_URL}/depictions/{pid}.html",
            f"Native Depiction: {BASE_URL}/depictions/{pid}.json",
        ]
        if "Homepage" not in ctrl:
            lines.append(f"Homepage: {meta.get('homepage', BASE_URL)}")
        stanzas.append("\n".join(lines))
        featured.append({"title": ctrl.get("Name", pid), "package": pid,
                         "url": f"{BASE_URL}/banners/{pid}.png"})

    packages = "\n\n".join(stanzas) + "\n"
    open(os.path.join(REPO, "Packages"), "w").write(packages)
    with open(os.path.join(REPO, "Packages.gz"), "wb") as f:
        f.write(gzip.compress(packages.encode(), 9, mtime=0))

    # featured carousel
    with open(os.path.join(REPO, "sileo-featured.json"), "w") as f:
        json.dump({"class": "FeaturedBannersView", "itemSize": "{263, 148}",
                   "itemCornerRadius": 8, "banners": featured}, f, indent=2)

    # Release (+ index hashes)
    def h(name):
        b = open(os.path.join(REPO, name), "rb").read()
        return name, len(b), hashlib.md5(b).hexdigest(), hashlib.sha256(b).hexdigest()
    idx = [h("Packages"), h("Packages.gz")]
    import email.utils
    rel = [f"Origin: {ORIGIN}", f"Label: {REPO_NAME}", f"Name: {REPO_NAME}", "Suite: stable", "Version: 1.0",
           "Codename: ios", f"Architectures: {ARCH}", "Components: main",
           f"Description: {DESCRIPTION}",
           f"Date: {email.utils.formatdate(usegmt=True)}", "MD5Sum:"]
    rel += [f" {m} {s} {n}" for n, s, m, _ in idx]
    rel.append("SHA256:")
    rel += [f" {sh} {s} {n}" for n, s, _, sh in idx]
    open(os.path.join(REPO, "Release"), "w").write("\n".join(rel) + "\n")

    write_index(pkgs)
    print(f"Generated repo ({len(pkgs)} package(s)), PIL={HAVE_PIL}")

if __name__ == "__main__":
    main()
