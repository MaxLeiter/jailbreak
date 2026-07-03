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

Run via the venv that has Pillow:  .repo-venv/bin/python bin/make-repo.py
Re-run after adding/removing .debs. No network needed.
"""
import os, io, gzip, json, hashlib, tarfile, html, shutil, math, re

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "repo"))
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
    if ctrl.get("Package") in APP_SECTION_PACKAGES:
        ctrl["Section"] = APP_SECTION

def normalize_publisher(ctrl):
    for key in ("Maintainer", "Author"):
        ctrl[key] = PUBLISHER
        if key not in ctrl["__order__"]:
            ctrl["__order__"].append(key)

def human_size(n):
    return f"{n/1024:.1f} KiB" if n >= 1024 else f"{n} B"

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
    --bg:#000; --surface:#0a0a0a; --surface-2:#141414;
    --border:#232323; --border-hi:#3a3a3a;
    --fg:#ededed; --fg-dim:#a1a1a1; --fg-mute:#8f8f8f;
    --accent:{ACCENT_HEX}; --accent-ink:#001321; --glow:.10;
    --radius:12px; --maxw:720px;
  }}
  :root[data-theme="light"]{{
    color-scheme:light;
    --bg:#fff; --surface:#fafafa; --surface-2:#f3f3f3;
    --border:#eaeaea; --border-hi:#cfcfcf;
    --fg:#171717; --fg-dim:#555; --fg-mute:#767676;
    --accent:#0a6fce; --accent-ink:#fff; --glow:.06;
  }}
  *{{box-sizing:border-box}}
  html{{-webkit-text-size-adjust:100%}}
  body{{margin:0;font-family:"Geist",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
    font-size:16px;line-height:1.6;background:var(--bg);color:var(--fg);
    -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;
    background-image:radial-gradient(62% 46% at 50% -8%, rgba({ACCENT[0]},{ACCENT[1]},{ACCENT[2]},var(--glow)), transparent 70%);
    background-repeat:no-repeat;background-attachment:fixed}}
  .wrap{{max-width:var(--maxw);margin:0 auto;padding:64px 24px 96px}}
  a{{color:var(--accent);text-decoration:none}}
  .vh{{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;
    clip:rect(0,0,0,0);white-space:nowrap;border:0}}

  .masthead{{display:flex;align-items:center;gap:18px;margin-bottom:6px}}
  .masthead img{{width:60px;height:60px;border-radius:14px;border:1px solid var(--border)}}
  .masthead h1{{font-size:28px;font-weight:600;letter-spacing:-.02em;margin:0}}
  .masthead .sub{{color:var(--fg-dim);margin:5px 0 0;font-size:15px}}
  .theme-toggle{{margin-left:auto;flex:0 0 auto;display:inline-flex;align-items:center;
    justify-content:center;width:38px;height:38px;border-radius:10px;cursor:pointer;
    border:1px solid var(--border);background:var(--surface);color:var(--fg-dim);
    transition:color .15s,border-color .15s,background .15s}}
  .theme-toggle:hover{{color:var(--fg);border-color:var(--border-hi)}}
  .theme-toggle:focus-visible{{outline:2px solid var(--accent);outline-offset:2px}}
  .theme-toggle svg{{width:18px;height:18px;display:block}}
  .i-moon{{display:none}}
  :root[data-theme="light"] .i-sun{{display:none}}
  :root[data-theme="light"] .i-moon{{display:block}}

  .install{{margin:30px 0 4px}}
  .field{{display:flex;gap:8px}}
  .field input{{flex:1;min-width:0;padding:11px 14px;border-radius:10px;
    border:1px solid var(--border);background:var(--surface);color:var(--fg);
    font-family:"Geist Mono",ui-monospace,monospace;font-size:13.5px}}
  .field input:focus-visible{{outline:none;border-color:var(--accent)}}
  .btn{{display:inline-flex;align-items:center;justify-content:center;gap:6px;
    padding:11px 16px;border-radius:10px;font-weight:500;font-size:14px;cursor:pointer;
    white-space:nowrap;border:1px solid var(--border);background:var(--surface);color:var(--fg);
    transition:border-color .15s,background .15s,color .15s}}
  .btn:hover{{border-color:var(--border-hi)}}
  .btn:focus-visible{{outline:2px solid var(--accent);outline-offset:2px}}
  .btn.copy{{border:0;background:var(--fg);color:var(--bg);font-weight:600;min-width:88px}}
  .btn.copy:hover{{opacity:.88}}
  .btn.copy.ok{{background:var(--accent);color:var(--accent-ink)}}
  .managers{{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}}
  .btn.primary{{background:var(--accent);border-color:var(--accent);color:var(--accent-ink);font-weight:600}}
  .btn.primary:hover{{filter:brightness(1.08);border-color:var(--accent)}}

  .cat{{margin-top:34px}}
  summary.cat-head{{list-style:none;display:flex;align-items:center;gap:10px;cursor:pointer;
    padding-bottom:11px;border-bottom:1px solid var(--border);
    -webkit-tap-highlight-color:transparent}}
  summary.cat-head::-webkit-details-marker{{display:none}}
  summary.cat-head:focus-visible{{outline:2px solid var(--accent);outline-offset:3px;border-radius:6px}}
  .cat-name{{font-size:12px;text-transform:uppercase;letter-spacing:.09em;
    color:var(--fg-dim);font-weight:600}}
  summary.cat-head:hover .cat-name{{color:var(--fg)}}
  .cat-head .count{{font-family:"Geist Mono",monospace;font-size:12px;color:var(--fg-mute)}}
  .chev{{width:16px;height:16px;margin-left:auto;color:var(--fg-mute);transition:transform .2s ease}}
  details.cat[open] .chev{{transform:rotate(90deg)}}
  details.cat[open] .grid{{margin-top:14px}}

  .grid{{display:grid;grid-template-columns:minmax(0,1fr);gap:10px}}
  .pkg{{display:flex;gap:14px;align-items:center;padding:13px 14px;min-width:0;
    border:1px solid var(--border);border-radius:var(--radius);background:var(--surface);
    text-decoration:none;color:inherit;transition:border-color .15s,background .15s}}
  .pkg:hover{{border-color:var(--border-hi);background:var(--surface-2)}}
  .pkg:focus-visible{{outline:2px solid var(--accent);outline-offset:2px}}
  .pkg img{{width:48px;height:48px;border-radius:11px;flex:0 0 auto;border:1px solid var(--border)}}
  .pkg .meta{{min-width:0;flex:1}}
  .pkg .n{{font-weight:600;font-size:16px;letter-spacing:-.01em}}
  .pkg .t{{color:var(--fg-dim);font-size:14px;margin-top:1px;
    overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
  .pkg .v{{margin-left:auto;align-self:center;color:var(--fg-mute);
    font-family:"Geist Mono",monospace;font-size:12px;
    border:1px solid var(--border);border-radius:999px;padding:3px 9px;white-space:nowrap}}

  .back{{display:inline-flex;align-items:center;gap:7px;color:var(--fg-dim);
    font-size:14px;margin-bottom:26px;transition:color .15s}}
  .back:hover{{color:var(--fg)}}
  .back svg{{width:15px;height:15px;display:block}}
  .prose p{{margin:.6em 0;color:var(--fg-dim)}}
  .prose strong{{color:var(--fg);font-weight:600}} .prose em{{color:var(--fg)}}
  .prose ul{{margin:.5em 0;padding-left:1.15em}} .prose li{{margin:.25em 0;color:var(--fg-dim)}}
  h2.section{{font-size:12px;text-transform:uppercase;letter-spacing:.09em;
    color:var(--fg-dim);font-weight:600;margin:34px 0 4px}}
  table.info{{width:100%;border-collapse:collapse;font-size:14px;margin-top:6px}}
  table.info td{{padding:11px 2px;border-bottom:1px solid var(--border)}}
  table.info tr:last-child td{{border-bottom:0}}
  table.info td:first-child{{color:var(--fg-mute);width:38%}}
  table.info td:last-child{{font-family:"Geist Mono",monospace;font-size:13px;word-break:break-word}}

  footer{{margin-top:48px;padding-top:20px;border-top:1px solid var(--border);
    color:var(--fg-mute);font-size:13px}}
  footer a{{color:var(--fg-dim)}} footer a:hover{{color:var(--fg)}}

  @media (max-width:560px){{
    .wrap{{padding:40px 18px 72px}}
    .masthead h1{{font-size:23px}}
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

# right-chevron used by the collapsible category headers (rotates when open)
CHEV_SVG = ('<svg class="chev" viewBox="0 0 16 16" fill="none" aria-hidden="true">'
            '<path d="M6 4l4 4-4 4" stroke="currentColor" stroke-width="1.5" '
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
</script>
"""

# category display order on the landing page (unknown sections fall after these)
SECTION_ORDER = ["Desktop", "X11/Wayland Apps", "Tweaks", "Utilities", "X11", "Development", "Libraries"]
# categories expanded by default; large dependency buckets start collapsed
OPEN_SECTIONS = {"Desktop", "X11/Wayland Apps", "Tweaks", "Utilities", "X11"}

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
    # group packages by their Section (category) and order the groups sensibly
    groups = {}
    for p in pkgs:
        sec = (p["ctrl"].get("Section") or "Tweaks").strip()
        groups.setdefault(sec, []).append(p)
    order = [s for s in SECTION_ORDER if s in groups] + \
            sorted(s for s in groups if s not in SECTION_ORDER)

    # staggered reveal counter (0 = masthead, 1 = install block); cap so the
    # tail of a long list doesn't wait too long to appear
    step = [2]
    def nxt():
        v = min(step[0], 16); step[0] += 1; return v

    sections_html = ""
    for sec in order:
        items = sorted(groups[sec],
                       key=lambda p: p["ctrl"].get("Name", p["ctrl"]["Package"]).lower())
        cards = ""
        for p in items:
            pid = p["ctrl"]["Package"]
            # one-line tagline for the list: first line, first sentence
            tag = (p["meta"].get("tagline") or p["ctrl"].get("Description", "")).split("\n")[0].strip()
            tag = tag.split(". ")[0].strip()
            cards += f"""
        <a class="pkg reveal" style="--i:{nxt()}" href="depictions/{pid}.html">
          <img src="icons/{pid}.png" alt="" loading="lazy">
          <div class="meta"><div class="n">{html.escape(p['ctrl'].get('Name', pid))}</div>
            <div class="t">{html.escape(tag)}</div></div>
          <span class="v">v{html.escape(p['ctrl'].get('Version',''))}</span>
        </a>"""
        is_open = " open" if sec in OPEN_SECTIONS else ""
        sections_html += f"""
      <details class="cat"{is_open}>
        <summary class="cat-head"><span class="cat-name">{html.escape(sec)}</span><span class="count">{len(items)}</span>{CHEV_SVG}</summary>
        <div class="grid">{cards}</div>
      </details>"""

    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#000000">
<title>{html.escape(ORIGIN)}</title><link rel="icon" href="favicon.ico">{head_links("")}{HEAD_JS}</head>
<body><div class="wrap">
  <header class="masthead reveal" style="--i:0"><img src="CydiaIcon.png" alt="">
    <div><h1>{html.escape(ORIGIN)}</h1>
      <p class="sub">{html.escape(DESCRIPTION)} · {len(pkgs)} packages</p></div>{THEME_BTN}</header>
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
  {sections_html}
  <footer><a href="https://maxleiter.com">maxleiter.com</a></footer>
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
    for fn in sorted(os.listdir(DEBS)):
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
