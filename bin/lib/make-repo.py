#!/usr/bin/env python3
"""Generate a polished static APT (Cydia/Sileo) repo from repo/debs/*.deb.

Outputs in repo/:
  Packages, Packages.gz, Release      package index (+ rich fields)
  index.html                          themed landing page
  robots.txt, sitemap.xml             search-engine discovery
  favicon.svg/.ico/.png, touch icons  X11-inspired repo identity
  icons/<pkg>.png                     per-package icon
  banners/<pkg>.png                   featured banner
  depictions/<pkg>.json               Sileo native depiction
  depictions/<pkg>.html               HTML depiction (Cydia/Zebra)
  sileo-featured.json                 featured carousel
  meta/<pkg>.json                     (input) optional per-package metadata

Run via the venv that has Pillow:  .repo-venv/bin/python bin/lib/make-repo.py
Re-run after adding/removing .debs. No network needed.

Two modes:
  (default)      read repo/debs/*.deb and generate the whole tree, Packages
                 included. This is the authoring mode: it needs the payloads.
  --from-index   treat the committed repo/Packages as the source of truth and
                 regenerate only what derives from it (Packages.gz, Release,
                 depictions, sileo-featured, site). Needs no .deb payloads, so
                 CI can rebuild and sign the index from a plain checkout while
                 the payloads live immutably in Blob. Leaves repo/Packages and
                 the tracked icons/banners byte-identical.
  --identity-only regenerate just the favicon, touch/repo icons, and manifest
                  from x11/apps/Xios/assets/xios-mark.svg.

Both modes prune per-package assets whose package left the index; see
prune_orphan_assets.
"""
import argparse, functools, os, io, gzip, json, hashlib, tarfile, html, shutil, math, re, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "repo"))

# Rootless and rootful builds share package names but install into incompatible
# prefixes, so each profile owns an independent index and payload tree.
PROFILE = os.environ.get("XIOS_REPO_PROFILE", "rootless")
REPO = REPO_ROOT if PROFILE == "rootless" else os.path.join(REPO_ROOT, "profiles", PROFILE)
DEBS = os.path.join(REPO, "debs")
META = os.path.join(REPO_ROOT, "meta")
LOGO_SOURCES = os.path.join(HERE, "logo-sources")

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
DEFAULT_BASE_URL = "https://repo.maxleiter.com"
if PROFILE != "rootless":
    DEFAULT_BASE_URL += f"/profiles/{PROFILE}"
BASE_URL    = os.environ.get("XIOS_REPO_BASE_URL", DEFAULT_BASE_URL)
REPO_NAME   = "Max's Repo"
ORIGIN      = REPO_NAME
DESCRIPTION = "Jailbreak packages by Max"
ARCH        = "iphoneos-arm64" if PROFILE == "rootless" else "iphoneos-arm"
PUBLISHER   = "Max Leiter <maxwell.leiter@gmail.com>"
ACCENT      = (85, 170, 255)      # #55aaff (maxleiter.com brand blue)
ACCENT_HEX  = "#55aaff"
ICON_BG     = (16, 16, 20)
REPO_ICON_SOURCE = os.path.abspath(os.path.join(
    HERE, "..", "..", "x11", "apps", "Xios", "assets", "xios-mark.svg"))

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
    data = m[cn]
    mode = {"control.tar.gz": "r:gz", "control.tar.xz": "r:xz", "control.tar": "r:"}.get(cn, "r:*")
    if cn == "control.tar.zst":
        zstd = shutil.which("zstd")
        if not zstd:
            raise RuntimeError("control.tar.zst requires zstd in PATH")
        data = subprocess.check_output([zstd, "-qdc"], input=data)
        mode = "r:"
    with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as tf:
        mem = next(x for x in tf.getmembers() if x.name.lstrip("./") == "control")
        text = tf.extractfile(mem).read().decode("utf-8")
    d, order = {}, []
    for ln in text.splitlines():
        if ": " in ln and not ln.startswith(" "):
            k, v = ln.split(": ", 1); d[k] = v; order.append(k)
    d["__order__"] = order
    return d

def deb_payload_profile(deb_bytes):
    """Infer rootless/rootful ownership from a package's payload paths."""
    m = ar_members(deb_bytes)
    dn = next((n for n in m if n.startswith("data.tar")), None)
    if dn is None:
        return None
    data = m[dn]
    mode = {"data.tar.gz": "r:gz", "data.tar.xz": "r:xz", "data.tar": "r:"}.get(dn, "r:*")
    if dn == "data.tar.zst":
        zstd = shutil.which("zstd")
        if not zstd:
            raise RuntimeError("data.tar.zst requires zstd in PATH to verify the repo profile")
        data = subprocess.check_output([zstd, "-qdc"], input=data)
        mode = "r:"
    with tarfile.open(fileobj=io.BytesIO(data), mode=mode) as tf:
        names = [x.name.lstrip(".").lstrip("/") for x in tf.getmembers() if x.isfile()]
    if not names:
        return None
    return "rootless" if any(n.startswith("var/jb/") for n in names) else "rootful"

def parse_packages_index(path):
    """Read a generated Packages file back into (raw_text, [ctrl, ...])."""
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    return raw, parse_packages_text(raw)

def parse_packages_text(raw):
    """Parse Packages text into [ctrl, ...].

    The inverse of the stanza writer in main(). Lossless for our indexes:
    control_dict() drops RFC822 continuation lines when it parses a .deb, so
    the stanzas this file contains are always single-line fields (long-form
    prose lives in repo/meta/<pkg>.json, not in the control blob).
    """
    out = []
    for block in raw.split("\n\n"):
        if not block.strip():
            continue
        d, order = {}, []
        for ln in block.splitlines():
            if ": " in ln and not ln.startswith((" ", "\t")):
                k, v = ln.split(": ", 1)
                d[k] = v
                order.append(k)
        if "Package" not in d:
            raise SystemExit("ERROR: Packages index has a stanza without a Package field")
        d["__order__"] = order
        out.append(d)
    return out

def guard_shrink(deb_filenames):
    """Refuse a from-debs regeneration that would silently retire packages.

    Compares package names derivable from the on-disk deb filenames against the
    existing index. Filename-based on purpose: this runs before any deb is
    opened, so a refusal cannot leave half-written depictions behind.
    """
    index_path = os.path.join(REPO, "Packages")
    if not os.path.exists(index_path) or os.environ.get("MAKE_REPO_ALLOW_SHRINK"):
        return
    with open(index_path, encoding="utf-8", errors="replace") as fh:
        previous = parse_packages_text(fh.read())
    have = {fn[:-4].split("_")[0] for fn in deb_filenames if fn.endswith(".deb")}
    gone = sorted({c["Package"] for c in previous} - have)
    if len(gone) <= max(5, len(previous) // 20):
        return
    sample = ", ".join(gone[:8]) + (" ..." if len(gone) > 8 else "")
    raise SystemExit(
        f"ERROR: regenerating from repo/debs would drop {len(gone)} of {len(previous)} "
        f"packages from the index.\n"
        f"       no payload on disk for: {sample}\n"
        f"       repo/debs holds {len(have)} package name(s). A worktree looks exactly\n"
        f"       like this, because repo/debs is gitignored and never checked out.\n"
        f"\n"
        f"       To regenerate the site/index without payloads:\n"
        f"           python3 bin/lib/make-repo.py --from-index\n"
        f"       If you really are retiring those packages, set MAKE_REPO_ALLOW_SHRINK=1."
    )

# Generated per-package assets, as {directory: extensions}. Only these names are
# ever removed by a prune -- meta/ and screenshots/ are hand-authored inputs and
# a retired package's metadata is worth keeping for when it comes back.
ASSET_DIRS = {"depictions": (".html", ".json"), "icons": (".png",), "banners": (".png",)}

def prune_orphan_assets(pids):
    """Delete depictions/icons/banners for packages no longer in the index.

    Both generation modes only ever *write* assets for packages they index, so
    without this the three directories are append-only: retiring a package
    (fribidi, ladybird-xios-launcher) leaves its depiction, icon and banner
    served forever at URLs apt no longer references.

    `pids` MUST be the full generated package set. It is passed in from main()'s
    in-memory list rather than re-read from a file on purpose: bin/publish-repo.sh
    --only serves a deliberately narrower index than the tree holds, and keying
    the prune off that would delete assets for everything the scoped publish left
    out. That scoping happens in deploy_static_repo(), on a throwaway rsync copy,
    strictly after make-repo.py has run against the whole tree -- so the set this
    function sees is the unscoped one, and the deploy copy keeps every asset the
    live index it reconciles against might still point at.
    """
    # Plan every directory before unlinking anything, so tripping the backstop on
    # the last directory cannot leave the first two already pruned.
    plan = []
    for sub, exts in ASSET_DIRS.items():
        d = os.path.join(REPO, sub)
        if not os.path.isdir(d):
            continue
        present = [fn for fn in sorted(os.listdir(d)) if fn.endswith(exts)]
        gone = [fn for fn in present if os.path.splitext(fn)[0] not in pids]
        # Same backstop as guard_shrink, for the same reason: an empty or
        # truncated package set must not be able to empty the site in one run.
        if gone and len(gone) > max(20, len(present) // 10) \
                and not os.environ.get("MAKE_REPO_ALLOW_SHRINK"):
            sample = ", ".join(gone[:8]) + (" ..." if len(gone) > 8 else "")
            raise SystemExit(
                f"ERROR: pruning would delete {len(gone)} of {len(present)} files in "
                f"repo/{sub}.\n"
                f"       orphaned: {sample}\n"
                f"       That is too many to be a routine retirement -- check that the\n"
                f"       index really holds every package it should before rerunning.\n"
                f"       If the retirement is intended, set MAKE_REPO_ALLOW_SHRINK=1."
            )
        plan += [(d, sub, fn) for fn in gone]

    removed = []
    for d, sub, fn in plan:
        os.remove(os.path.join(d, fn))
        removed.append(f"{sub}/{fn}")
    if removed:
        pkgs_gone = sorted({os.path.splitext(os.path.basename(p))[0] for p in removed})
        print(f"Pruned {len(removed)} orphaned asset(s) for {len(pkgs_gone)} retired "
              f"package(s): {', '.join(pkgs_gone)}")
    return removed

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

try:
    import apt_pkg as _apt_pkg
    _apt_pkg.init_system()
except Exception:
    _apt_pkg = None

def compare_deb_versions(a, b):
    # dpkg version-comparison semantics. Prefer apt_pkg when available (exact
    # libapt implementation); otherwise fall back to the vendored algorithm
    # below. Naive string sort is wrong here (e.g. "+ios9" vs "+ios10").
    if _apt_pkg is not None:
        return _apt_pkg.version_compare(a, b)

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
        line = re.sub(r"`([^`]+)`", r"<code>\1</code>", line)
        # Sileo renders markdown links natively; the web depiction needs the anchor.
        line = re.sub(r"\[([^\]]+)\]\((https?://[^\s)]+)\)",
                      r'<a href="\2" rel="noopener">\1</a>', line)
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

RSVG_CONVERT = shutil.which("rsvg-convert")

# real upstream app icons, extracted once from each .deb's own hicolor icon
# theme (bin/lib/logo-sources/<pid>.{svg,png}) and composited onto the same
# dark rounded tile the generated glyphs use, so real + generated icons sit
# together without looking mismatched.
def _load_logo_source(pid, px):
    candidates = ([(REPO_ICON_SOURCE, "svg")] if pid == "com.max.xios" else
                  [(os.path.join(LOGO_SOURCES, f"{pid}.{ext}"), ext)
                   for ext in ("svg", "png")])
    for path, ext in candidates:
        if not os.path.exists(path):
            continue
        if ext == "svg":
            if not RSVG_CONVERT:
                return None
            out = subprocess.run(
                [RSVG_CONVERT, "-w", str(px), "-h", str(px), path],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            if out.returncode != 0:
                return None
            return Image.open(io.BytesIO(out.stdout)).convert("RGBA")
        return Image.open(path).convert("RGBA")
    return None

def _render_svg(path, px):
    if not HAVE_PIL or not RSVG_CONVERT or not os.path.exists(path):
        return None
    out = subprocess.run(
        [RSVG_CONVERT, "-w", str(px), "-h", str(px), path],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if out.returncode != 0:
        return None
    return Image.open(io.BytesIO(out.stdout)).convert("RGBA")

def generate_repo_identity(render_rasters=False):
    """Install the vector identity and, on authoring hosts, its raster family."""
    shutil.copyfile(REPO_ICON_SOURCE, os.path.join(REPO, "favicon.svg"))
    manifest = {
        "name": REPO_NAME,
        "short_name": "Xios Repo",
        "icons": [
            {"src": "icon-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "icon-512.png", "sizes": "512x512", "type": "image/png"},
        ],
        "theme_color": "#0a0a0b",
        "background_color": "#0a0a0b",
        "display": "standalone",
    }
    with open(os.path.join(REPO, "site.webmanifest"), "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    if not render_rasters:
        return
    master = _render_svg(REPO_ICON_SOURCE, 512)
    if master is None:
        raise SystemExit("ERROR: repo identity raster generation needs Pillow and rsvg-convert")
    for filename, size in (
        ("favicon-16x16.png", 16),
        ("favicon-32x32.png", 32),
        ("apple-touch-icon.png", 180),
        ("CydiaIcon.png", 180),
        ("icon-192.png", 192),
        ("icon-512.png", 512),
    ):
        master.resize((size, size), Image.LANCZOS).save(os.path.join(REPO, filename))
    master.save(os.path.join(REPO, "favicon.ico"), format="ICO",
                sizes=[(16, 16), (32, 32), (48, 48)])

    # Keep the package-manager depiction in the same identity family as the
    # actual Home Screen app, rather than falling back to the Desktop glyph.
    os.makedirs(os.path.join(REPO, "icons"), exist_ok=True)
    os.makedirs(os.path.join(REPO, "banners"), exist_ok=True)
    xios_icon = package_icon("com.max.xios", "Desktop", 256)
    xios_icon.save(os.path.join(REPO, "icons", "com.max.xios.png"))
    xios_ctrl = {}
    packages_path = os.path.join(REPO, "Packages")
    if os.path.exists(packages_path):
        _, ctrls = parse_packages_index(packages_path)
        xios_ctrl = next((c for c in ctrls if c.get("Package") == "com.max.xios"), {})
    xios_meta = load_meta("com.max.xios")
    make_banner(
        os.path.join(REPO, "banners", "com.max.xios.png"),
        package_name(xios_ctrl, xios_meta) if xios_ctrl else "Xios",
        xios_meta.get("tagline", xios_ctrl.get(
            "Description", "The app that puts the desktop on your screen")),
        xios_icon,
    )

def package_icon(pid, section, px=256):
    s = 4; S = px * s
    logo = _load_logo_source(pid, S)
    if logo is None:
        return category_icon(section, px)
    img, _, _ = _icon_base(px)
    img.alpha_composite(logo.resize((S, S), Image.LANCZOS), (0, 0))
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
    catalog_path = os.path.join(META, "app-catalog.json")
    catalog_meta = {}
    if os.path.exists(catalog_path):
        with open(catalog_path) as f:
            catalog_meta = json.load(f).get(pkgid, {})
    p = os.path.join(META, f"{pkgid}.json")
    if os.path.exists(p):
        with open(p) as f:
            package_meta = json.load(f)
        return {**catalog_meta, **package_meta}
    return catalog_meta

def package_developer(meta, ctrl):
    developer = meta.get("developer")
    if not developer or developer == "Max":
        return ctrl.get("Author", ctrl.get("Maintainer", ""))
    return developer

def package_name(ctrl, meta):
    return meta.get("name") or ctrl.get("Name", ctrl["Package"])

def plain_text(value):
    """Collapse the small Markdown subset used in metadata into snippet text."""
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", value or "")
    text = re.sub(r"[`*_#>|]", "", text)
    return " ".join(text.split())

def seo_description(ctrl, meta):
    value = (meta.get("seoDescription") or meta.get("tagline")
             or meta.get("description") or ctrl.get("Description", ""))
    return plain_text(value)[:180]

def seo_head(ctrl, meta):
    """Canonical, snippet, social-card, and optional SoftwareApplication data."""
    pid = ctrl["Package"]
    name = package_name(ctrl, meta)
    description = seo_description(ctrl, meta)
    canonical = meta.get("canonicalUrl") or f"{BASE_URL}/depictions/{pid}.html"
    screenshots = screenshot_assets(meta)
    image = screenshots[0]["url"] if screenshots else f"{BASE_URL}/banners/{pid}.png"
    title = meta.get("seoTitle") or f"{name} · {ORIGIN}"
    tags = [
        f"<title>{html.escape(title)}</title>",
        f'<meta name="description" content="{html.escape(description)}">',
        f'<link rel="canonical" href="{html.escape(canonical)}">',
        '<meta name="robots" content="index,follow,max-image-preview:large">',
        '<meta property="og:type" content="website">',
        f'<meta property="og:site_name" content="{html.escape(ORIGIN)}">',
        f'<meta property="og:title" content="{html.escape(title)}">',
        f'<meta property="og:description" content="{html.escape(description)}">',
        f'<meta property="og:url" content="{html.escape(canonical)}">',
        f'<meta property="og:image" content="{html.escape(image)}">',
        '<meta name="twitter:card" content="summary_large_image">',
        f'<meta name="twitter:title" content="{html.escape(title)}">',
        f'<meta name="twitter:description" content="{html.escape(description)}">',
        f'<meta name="twitter:image" content="{html.escape(image)}">',
    ]
    if meta.get("schemaType") == "SoftwareApplication":
        data = {
            "@context": "https://schema.org",
            "@type": "SoftwareApplication",
            "name": name,
            "description": description,
            "url": canonical,
            "applicationCategory": meta.get("applicationCategory", ctrl.get("Section", "Application")),
            "operatingSystem": meta.get("operatingSystem", "iOS on a jailbroken device"),
            "softwareVersion": ctrl.get("Version", ""),
            "image": image,
            "screenshot": [s["url"] for s in screenshots],
            "author": {
                "@type": "Organization",
                "name": package_developer(meta, ctrl),
                "url": meta.get("homepage", ctrl.get("Homepage", BASE_URL)),
            },
            "offers": {
                "@type": "Offer",
                "price": "0",
                "priceCurrency": "USD",
                "availability": "https://schema.org/InStock",
                "url": canonical,
            },
        }
        payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")
        tags.append(f'<script type="application/ld+json">{payload}</script>')
    return "".join(tags)

def screenshot_assets(meta):
    assets = []
    for item in meta.get("screenshots", []):
        if isinstance(item, str):
            item = {"src": item}
        src = (item.get("src") or item.get("path") or "").lstrip("/")
        url = item.get("url")
        if not src and not url:
            continue
        if not url:
            url = f"{BASE_URL}/{src}"
        alt = item.get("accessibilityText") or item.get("alt") or "App screenshot"
        html_src = url if re.match(r"^https?://", url) else f"../{src}"
        if src:
            html_src = f"../{src}"
        assets.append({
            "url": url,
            "html_src": html_src,
            "alt": alt,
            "caption": item.get("caption", ""),
        })
    return assets

# ── native (Sileo) depiction ─────────────────────────────────────────────────
def native_depiction(ctrl, meta, size):
    pid = ctrl["Package"]
    screenshots = screenshot_assets(meta)
    info = [
        ("Version", ctrl.get("Version", "")),
        ("Size", human_size(size)),
        ("Developer", package_developer(meta, ctrl)),
        ("Section", ctrl.get("Section", "Tweaks")),
        ("Identifier", pid),
    ]
    markdown = meta.get("description", ctrl.get("Description", ""))
    if meta.get("projectPage"):
        markdown += f"\n\n[More screenshots and port details]({meta['projectPage']})"
    details = []
    # securityNotice goes above the description, not inside it: a caveat about what the
    # package exposes should be readable before the pitch, and it must survive an edit
    # to the prose. Sileo has no callout view, so bold markdown is the honest ceiling.
    if meta.get("securityNotice"):
        details.append({"class": "DepictionMarkdownView",
                        "markdown": f"**Security notice.** {meta['securityNotice']}"})
        details.append({"class": "DepictionSeparatorView"})
    details.append({"class": "DepictionMarkdownView", "markdown": markdown})
    if screenshots:
        details += [
            {"class": "DepictionScreenshotsView",
             "itemCornerRadius": 8,
             "itemSize": "{220, 320}",
             "screenshots": [
                 {"url": s["url"], "accessibilityText": s["alt"]}
                 for s in screenshots
             ]},
        ]
    details += [{"class": "DepictionSeparatorView"},
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

    return {"minVersion": "0.4" if screenshots else "0.1", "class": "DepictionTabView",
            "headerImage": f"{BASE_URL}/banners/{pid}.png",
            "tintColor": ACCENT_HEX, "tabs": tabs}

# ── HTML depiction (Cydia/Zebra) ─────────────────────────────────────────────
def html_screenshot_gallery(meta):
    screenshots = screenshot_assets(meta)
    if not screenshots:
        return ""
    figs = []
    for s in screenshots:
        cap = (f"<figcaption>{html.escape(s['caption'])}</figcaption>"
               if s.get("caption") else "")
        figs.append(
            f'<figure class="shot"><img src="{html.escape(s["html_src"])}" '
            f'alt="{html.escape(s["alt"])}" loading="lazy">{cap}</figure>')
    return f'<h2 class="section">Screenshots</h2><div class="shots">{"".join(figs)}</div>'

def html_depiction(ctrl, meta, size):
    pid = ctrl["Package"]
    rows = "".join(
        f"<tr><td>{html.escape(k)}</td><td>{html.escape(v)}</td></tr>" for k, v in [
            ("Version", ctrl.get("Version", "")), ("Size", human_size(size)),
            ("Developer", package_developer(meta, ctrl)),
            ("Section", ctrl.get("Section", "Tweaks")), ("Identifier", pid)])
    body = md_to_html(meta.get("description", ctrl.get("Description", "")))
    project_link = ""
    if meta.get("projectPage"):
        project_link = (
            f'<p class="project-link"><a href="{html.escape(meta["projectPage"])}">'
            "More screenshots and port details on xiOS&nbsp;&rarr;</a></p>"
        )
    notice = ""
    if meta.get("securityNotice"):
        notice = (f'<div class="notice" role="note"><strong>Security notice</strong>'
                  f'{md_to_html(meta["securityNotice"])}</div>')
    gallery = html_screenshot_gallery(meta)
    gallery_block = f"\n  {gallery}" if gallery else ""
    name = html.escape(package_name(ctrl, meta))
    tagline = html.escape(meta.get("tagline", ctrl.get("Description", "")))
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#000000">
{seo_head(ctrl, meta)}{favicon_links("../")}{head_links("../")}{HEAD_JS}</head>
<body><div class="wrap">
  <a class="back" href="../index.html">{BACK_SVG}<span>{html.escape(ORIGIN)}</span></a>
  <header class="masthead"><img src="../icons/{pid}.png" alt="">
    <div><h1>{name}</h1><p class="sub">{tagline}</p></div>{THEME_PICKER}</header>
  {notice}<div class="prose">{body}{project_link}</div>{gallery_block}
  <h2 class="section">Information</h2><table class="info">{rows}</table>
  <footer><a href="../index.html">&larr; All packages</a></footer>
</div>{THEME_JS}{ANALYTICS_JS}</body></html>"""

# ── shared CSS ───────────────────────────────────────────────────────────────
def head_links(prefix=""):
    # One shared, cacheable stylesheet (site.css) instead of a ~7 KB <style> block
    # inlined into every page. Fonts are self-hosted via @font-face inside it, so the
    # site makes no third-party (Google Fonts) requests.
    return f'<link rel="stylesheet" href="{prefix}site.css">'

def favicon_links(prefix=""):
    return (
        f'<link rel="icon" href="{prefix}favicon.ico" sizes="16x16 32x32 48x48">'
        f'<link rel="icon" href="{prefix}favicon.svg" type="image/svg+xml">'
        f'<link rel="icon" href="{prefix}favicon-32x32.png" sizes="32x32" type="image/png">'
        f'<link rel="apple-touch-icon" href="{prefix}apple-touch-icon.png">'
        f'<link rel="manifest" href="{prefix}site.webmanifest">'
    )

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
    --notice-accent:#e0a33a; --notice-line:#4a3a1c; --notice-bg:#1a150b;
    --mono:"Geist Mono",ui-monospace,monospace;
    --maxw:760px;
  }}
  :root[data-theme="light"]{{
    color-scheme:light;
    --bg:#fbfbfa; --bg-hover:#f1f1ee;
    --line:#e4e4e0; --line-hi:#c6c6bf;
    --fg:#151514; --fg-dim:#5d5d58; --fg-mute:#8b8b85;
    --accent:#0a6fce; --accent-ink:#fff;
    --notice-accent:#8a5a00; --notice-line:#e6d5ac; --notice-bg:#fdf6e6;
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
  a.micro{{color:var(--fg-mute);transition:color .15s}}
  a.micro:hover{{color:var(--fg)}}
  .mast h1{{font-size:clamp(40px,9vw,68px);font-weight:640;letter-spacing:-.045em;
    line-height:1.04;margin:30px 0 0}}

  /* depiction masthead */
  .masthead{{display:flex;align-items:center;gap:16px;margin-bottom:6px}}
  .masthead img{{width:56px;height:56px;flex:0 0 auto}}
  .masthead h1{{font-size:26px;font-weight:640;letter-spacing:-.03em;margin:0}}
  .masthead .sub{{color:var(--fg-dim);margin:4px 0 0;font-size:14.5px}}
  .masthead .theme-picker{{margin-left:auto}}

  .theme-picker{{flex:0 0 auto;display:inline-flex;border:1px solid var(--line)}}
  .theme-picker button{{display:inline-flex;align-items:center;justify-content:center;
    width:32px;height:32px;cursor:pointer;border:0;border-left:1px solid var(--line);
    border-radius:0;background:transparent;color:var(--fg-mute);padding:0;
    transition:color .15s,background .15s}}
  .theme-picker button:first-child{{border-left:0}}
  .theme-picker button:hover{{color:var(--fg)}}
  .theme-picker button[aria-pressed="true"]{{color:var(--fg);background:var(--bg-hover)}}
  .theme-picker button:focus-visible{{outline:2px solid var(--accent);outline-offset:-2px}}
  .theme-picker svg{{width:15px;height:15px;display:block}}

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

  /* search */
  .search{{position:relative;margin-top:-1px}}
  .search input{{width:100%;padding:12px 96px 12px 14px;border:1px solid var(--line);
    border-radius:0;background:transparent;color:var(--fg);
    font-family:var(--mono);font-size:13px;-webkit-appearance:none;appearance:none}}
  .search input::placeholder{{color:var(--fg-mute)}}
  .search input::-webkit-search-cancel-button{{display:none}}
  .search input:focus-visible{{outline:none;border-color:var(--line-hi)}}
  .search .micro{{position:absolute;right:14px;top:50%;transform:translateY(-50%)}}
  body.searching .tabs,body.searching .lede,body.searching .fl-head,
  body.searching .flavors{{display:none}}
  body.searching .reveal{{animation:none;opacity:1;transform:none}}
  .no-results{{display:none;color:var(--fg-dim);font-size:14px;margin-top:30px}}
  body.searching .no-results.show{{display:block}}

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
  /* securityNotice: sits above the prose, must read as a caveat rather than a badge.
     Amber rather than red -- these packages work as documented, the notice is about
     what they expose, and a red alarm on every visit trains people to skip it. */
  .notice{{margin:0 0 22px;padding:13px 15px;border:1px solid var(--notice-line);
    border-left:3px solid var(--notice-accent);border-radius:7px;background:var(--notice-bg)}}
  .notice strong{{display:block;color:var(--notice-accent);font-family:var(--mono);
    font-size:11px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;
    margin-bottom:7px}}
  .notice p{{margin:.4em 0;color:var(--fg-dim);font-size:14px;line-height:1.55}}
  .notice p:first-of-type{{margin-top:0}} .notice p:last-child{{margin-bottom:0}}
  .notice a{{color:var(--fg);border-bottom:1px solid var(--notice-accent)}}
  .notice code{{font-family:var(--mono);font-size:.9em;color:var(--fg)}}
  .prose p{{margin:.6em 0;color:var(--fg-dim)}}
  .prose strong{{color:var(--fg);font-weight:600}} .prose em{{color:var(--fg)}}
  .prose ul{{margin:.5em 0;padding-left:1.15em}} .prose li{{margin:.25em 0;color:var(--fg-dim)}}
  .prose a{{border-bottom:1px solid color-mix(in srgb,var(--accent) 40%,transparent)}}
  .project-link{{margin-top:20px}}
  .project-link a{{display:inline-flex;padding:9px 12px;border:1px solid var(--line-hi);
    border-radius:7px}}
  .prose code{{font-family:var(--mono);font-size:.9em;color:var(--fg);
    background:var(--bg-hover);border:1px solid var(--line);border-radius:4px;padding:1px 4px}}
  .shots{{display:flex;gap:14px;overflow-x:auto;margin-top:8px;padding:4px 2px 10px;
    scroll-snap-type:x mandatory;-webkit-overflow-scrolling:touch}}
  .shot{{flex:0 0 min(260px,72vw);margin:0;border:1px solid var(--line);
    border-radius:8px;overflow:hidden;background:var(--bg-hover);scroll-snap-align:start}}
  .shot img{{display:block;width:100%;height:auto}}
  .shot figcaption{{padding:9px 10px;border-top:1px solid var(--line);
    color:var(--fg-dim);font-size:12.5px;line-height:1.35}}
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
  // Which manager people actually add the repo with. The href is a custom URL
  // scheme, so the navigation never reaches us as a page view -- the click is
  // the only place to count it.
  ["sileo", "zebra", "cydia"].forEach(function (id) {
    document.getElementById(id).addEventListener("click", function () {
      window.va("event", { name: "add-repo", data: { manager: id } });
    });
  });

  var b = document.getElementById("copyBtn");
  b.addEventListener("click", function () {
    window.va("event", { name: "copy-repo-url" });
    navigator.clipboard.writeText(u).then(function () {
      var prev = b.textContent;
      b.textContent = "Copied";
      b.classList.add("ok");
      setTimeout(function () { b.textContent = prev; b.classList.remove("ok"); }, 1400);
    });
  });

  var tabs = [].slice.call(document.querySelectorAll(".tab"));
  function showTab(name) {
    if (!tabs.some(function (t) { return t.dataset.tab === name; })) name = "tweaks";
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

  // live search across both tabs ("/" focuses, Esc clears)
  var qInput = document.getElementById("q");
  var searchN = document.getElementById("searchN");
  var noRes = document.getElementById("noResults");
  var panels = tabs.map(function (t) { return document.getElementById("panel-" + t.dataset.tab); });
  var cats = [].slice.call(document.querySelectorAll("details.cat"));
  var solos = [].slice.call(document.querySelectorAll(".list.solo"));
  var rows = [].slice.call(document.querySelectorAll(".row"));
  rows.forEach(function (r) {
    var pid = (r.getAttribute("href") || "").replace(/^depictions\\//, "").replace(/\\.html$/, "");
    r.dataset.k = (r.textContent + " " + pid).toLowerCase();
  });
  var searching = false;
  function anyVisible(el) {
    return [].slice.call(el.querySelectorAll(".row")).some(function (r) { return !r.hidden; });
  }
  function applySearch() {
    var terms = qInput.value.trim().toLowerCase().split(/\\s+/).filter(Boolean);
    var on = terms.length > 0;
    if (on && !searching)
      cats.forEach(function (c) { c.dataset.wasOpen = c.open ? "1" : ""; });
    searching = on;
    document.body.classList.toggle("searching", on);
    if (!on) {
      rows.forEach(function (r) { r.hidden = false; });
      cats.forEach(function (c) { c.open = !!c.dataset.wasOpen; c.style.display = ""; });
      solos.forEach(function (l) { l.style.display = ""; });
      searchN.hidden = true;
      noRes.classList.remove("show");
      var cur = tabs.filter(function (t) { return t.getAttribute("aria-selected") === "true"; })[0];
      showTab(cur ? cur.dataset.tab : "tweaks");
      return;
    }
    panels.forEach(function (p) { p.hidden = false; });
    var total = 0;
    rows.forEach(function (r) {
      var hit = terms.every(function (t) { return r.dataset.k.indexOf(t) !== -1; });
      r.hidden = !hit;
      if (hit) total++;
    });
    cats.forEach(function (c) {
      var m = anyVisible(c);
      c.style.display = m ? "" : "none";
      c.open = m;
    });
    solos.forEach(function (l) { l.style.display = anyVisible(l) ? "" : "none"; });
    searchN.textContent = total + (total === 1 ? " match" : " matches");
    searchN.hidden = false;
    noRes.classList.toggle("show", !total);
  }
  qInput.addEventListener("input", applySearch);
  qInput.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { qInput.value = ""; applySearch(); qInput.blur(); }
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "/" && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
      e.preventDefault(); qInput.focus();
    }
  });
</script>
"""

# xiOS category display order on the landing page: pinned head, then unknown
# sections alphabetically, then the big dependency buckets last (collapsed)
SECTION_ORDER = ["Desktop", "X11/Wayland Apps", "X11", "Utilities"]
SECTION_TAIL = ["Development", "Libraries"]
COLLAPSED_SECTIONS = {"Development", "Libraries"}
TWEAKS_SECTION = "Tweaks"
# Homepage split only: normal iOS apps belong beside jailbreak tweaks on the
# first tab. Native Linux/X11/Wayland apps keep their explicit xiOS sections.
HOMEPAGE_TWEAK_SECTIONS = {TWEAKS_SECTION, "Apps"}
# featured flavor meta-packages (shown when their deb exists), display label
FLAVORS = [("xios-gnome", "GNOME"), ("xios-kde", "KDE Plasma"),
           ("xios-native", "Native"), ("xios-x11", "X11")]

# three-way theme picker: system (default) / light / dark
_SVG = ('<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
        'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">')
THEME_PICKER = (
    '<div class="theme-picker" role="group" aria-label="Theme">'
    '<button type="button" data-theme="system" aria-label="Follow system theme" aria-pressed="true">'
    f'{_SVG}<rect x="3" y="5" width="18" height="12" rx="1"/><path d="M8 21h8M12 17v4"/></svg></button>'
    '<button type="button" data-theme="light" aria-label="Light theme" aria-pressed="false">'
    f'{_SVG}<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4'
    'M17.7 17.7l1.4 1.4M2 12h2M20 12h2M6.3 17.7l-1.4 1.4M19.1 4.9l-1.4 1.4"/></svg></button>'
    '<button type="button" data-theme="dark" aria-label="Dark theme" aria-pressed="false">'
    f'{_SVG}<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/></svg></button>'
    '</div>'
)

# Vercel Web Analytics. Cookieless and first-party (/_vercel/insights/* is served
# by the platform, not a third party), so there is nothing to consent-banner.
# Depictions carry it as well as the index: Sileo renders them in a WKWebView, so
# per-package page views are the one install-interest signal we can read from the
# client. Deb downloads are NOT tracked here -- see the ANALYTICS note at the top
# of bin/publish-repo.sh for why. The va() shim queues events fired before
# script.js finishes loading.
ANALYTICS_JS = """
<script>
  window.va = window.va || function () { (window.vaq = window.vaq || []).push(arguments); };
</script>
<script defer src="/_vercel/insights/script.js"></script>
"""

# applies the saved/system theme before paint to avoid a flash of the wrong theme
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

# wires up the theme picker; "system" clears the override and tracks the OS live
THEME_JS = """
<script>
  (function () {
    var btns = [].slice.call(document.querySelectorAll(".theme-picker button"));
    if (!btns.length) return;
    var root = document.documentElement;
    var mq = matchMedia("(prefers-color-scheme: light)");
    function pref() {
      try {
        var t = localStorage.getItem("theme");
        if (t === "light" || t === "dark") return t;
      } catch (e) {}
      return "system";
    }
    function apply() {
      var p = pref();
      root.setAttribute("data-theme", p === "system" ? (mq.matches ? "light" : "dark") : p);
      btns.forEach(function (b) {
        b.setAttribute("aria-pressed", String(b.dataset.theme === p));
      });
    }
    btns.forEach(function (b) {
      b.addEventListener("click", function () {
        try {
          if (b.dataset.theme === "system") localStorage.removeItem("theme");
          else localStorage.setItem("theme", b.dataset.theme);
        } catch (e) {}
        apply();
      });
    });
    if (mq.addEventListener) mq.addEventListener("change", apply);
    else if (mq.addListener) mq.addListener(apply);
    apply();
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

    tweaks = [p for p in pkgs if section(p) in HOMEPAGE_TWEAK_SECTIONS]
    xios = [p for p in pkgs if section(p) not in HOMEPAGE_TWEAK_SECTIONS]

    # staggered reveal counter (0 = masthead, 1 = install, 2 = tabs); cap so
    # the tail of a long list doesn't wait too long to appear
    step = [3]
    def nxt():
        v = min(step[0], 16); step[0] += 1; return v

    def name(p):
        return package_name(p["ctrl"], p["meta"])

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

    if PROFILE == "rootless":
        index_description = ("Rootless jailbreak packages and xiOS desktop apps for iPad, "
                             "including GIMP, GNOME, KDE Plasma, X11, and Wayland software.")
        tweak_lede = "Small quality-of-life tweaks and companion apps for iPadOS on rootless jailbreaks."
    else:
        index_description = (f"{PROFILE.title()} jailbreak packages for 64-bit iPhone and iPad "
                             "on iOS or iPadOS 16 and newer.")
        tweak_lede = (f"Apps and packages built for {PROFILE} jailbreaks on "
                      "iOS and iPadOS 16 or newer.")
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="theme-color" content="#0a0a0b">
<title>{html.escape(ORIGIN)} · iOS jailbreak and xiOS packages</title>
<meta name="description" content="{html.escape(index_description)}">
<link rel="canonical" href="{BASE_URL}/">
<meta name="robots" content="index,follow,max-image-preview:large">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{html.escape(ORIGIN)}">
<meta property="og:title" content="{html.escape(ORIGIN)} · iOS jailbreak and xiOS packages">
<meta property="og:description" content="{html.escape(index_description)}">
<meta property="og:url" content="{BASE_URL}/">
<meta property="og:image" content="{BASE_URL}/CydiaIcon.png">
<meta name="twitter:card" content="summary">
{favicon_links("")}{head_links("")}{HEAD_JS}</head>
<body><div class="wrap">
  <header class="mast reveal" style="--i:0">
    <div class="mast-top"><a class="micro" href="https://maxleiter.com">maxleiter.com</a>{THEME_PICKER}</div>
    <h1>{html.escape(ORIGIN)}</h1>
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
  <div class="search reveal" style="--i:2">
    <label class="vh" for="q">Search packages</label>
    <input id="q" type="search" placeholder="Search {len(pkgs)} packages" autocomplete="off" spellcheck="false">
    <span class="micro" id="searchN" hidden></span>
  </div>
  <nav class="tabs reveal" style="--i:2" role="tablist" aria-label="Package groups">
    <button class="tab" id="tab-tweaks" data-tab="tweaks" type="button" role="tab" aria-selected="true" aria-controls="panel-tweaks">Tweaks<span class="tab-n">{len(tweaks)}</span></button>
    <button class="tab" id="tab-xios" data-tab="xios" type="button" role="tab" aria-selected="false" aria-controls="panel-xios" tabindex="-1">xiOS<span class="tab-n">{len(xios)}</span></button>
  </nav>
  <section class="panel" id="panel-tweaks" role="tabpanel" aria-labelledby="tab-tweaks">
    <p class="lede reveal" style="--i:3">{html.escape(tweak_lede)}</p>
    <div class="list solo">{tweak_rows}</div>
  </section>
  <section class="panel" id="panel-xios" role="tabpanel" aria-labelledby="tab-xios" hidden>
    <p class="lede">A desktop for jailbroken iPads: X11, Wayland, GNOME and KDE, cross-compiled to run natively on iOS. <strong>Install one flavor</strong> and it pulls in everything it needs.</p>
{flavors_html}
{sections_html}
  </section>
  <p class="no-results" id="noResults">No matching packages.</p>
  <footer><a href="https://maxleiter.com">maxleiter.com</a><span>{ARCH}</span></footer>
</div>{INDEX_JS}{THEME_JS}{ANALYTICS_JS}</body></html>"""
    open(os.path.join(REPO, "index.html"), "w").write(page)

def write_seo_files(pkgs):
    """Write deterministic crawler discovery files for the public rootless repo."""
    if PROFILE != "rootless":
        return
    robots = f"User-agent: *\nAllow: /\nSitemap: {BASE_URL}/sitemap.xml\n"
    open(os.path.join(REPO, "robots.txt"), "w").write(robots)

    latest = {}
    for p in pkgs:
        latest[p["ctrl"]["Package"]] = p
    entries = [f"  <url><loc>{BASE_URL}/</loc></url>"]
    for pid, p in sorted(latest.items()):
        # A rich xiOS app page can be the declared canonical for a terse package
        # depiction. Sitemaps should list canonical URLs only.
        if p["meta"].get("canonicalUrl"):
            continue
        loc = f"{BASE_URL}/depictions/{pid}.html"
        image_xml = []
        for shot in screenshot_assets(p["meta"]):
            image_xml.append(
                f"<image:image><image:loc>{html.escape(shot['url'])}</image:loc>"
                f"<image:caption>{html.escape(shot['alt'])}</image:caption></image:image>"
            )
        entries.append(f"  <url><loc>{html.escape(loc)}</loc>{''.join(image_xml)}</url>")
    sitemap = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
        'xmlns:image="http://www.google.com/schemas/sitemap-image/1.1">\n'
        + "\n".join(entries)
        + "\n</urlset>\n"
    )
    open(os.path.join(REPO, "sitemap.xml"), "w").write(sitemap)

# ── main ─────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--from-index", action="store_true",
                    help="regenerate only what derives from the committed "
                         "repo/Packages; needs no .deb payloads")
    ap.add_argument("--identity-only", action="store_true",
                    help="regenerate only the repo favicon, touch icon, and web manifest")
    args = ap.parse_args()
    from_index = args.from_index

    if args.identity_only:
        generate_repo_identity(render_rasters=True)
        return

    for d in ("icons", "banners", "depictions"):
        os.makedirs(os.path.join(REPO, d), exist_ok=True)

    # one shared, cacheable stylesheet for index + all depictions (was inlined per page)
    open(os.path.join(REPO, "site.css"), "w").write(SITE_CSS)

    # The vector source and manifest are cheap and deterministic. Raster assets
    # stay byte-identical in --from-index/CI runs, but authoring runs refresh the
    # complete icon family from the checked-in source.
    generate_repo_identity(render_rasters=not from_index)

    pkgs, stanzas, featured_by_pid = [], [], {}

    if from_index:
        # The committed index is authoritative: reuse its bytes verbatim rather
        # than recomputing stanzas, so a CI regeneration can never perturb the
        # payload hashes it is signing.
        index_path = os.path.join(REPO, "Packages")
        if not os.path.exists(index_path):
            raise SystemExit(f"ERROR: --from-index needs {index_path}")
        packages, ctrls = parse_packages_index(index_path)
        if not packages.endswith("\n"):
            packages += "\n"
        for ctrl in ctrls:
            pid = ctrl["Package"]
            meta = load_meta(pid)
            pkgs.append({"ctrl": ctrl, "meta": meta})
            size = int(ctrl.get("Size", "0") or 0)
            with open(os.path.join(REPO, "depictions", f"{pid}.json"), "w") as f:
                json.dump(native_depiction(ctrl, meta, size), f, indent=2)
            open(os.path.join(REPO, "depictions", f"{pid}.html"), "w").write(
                html_depiction(ctrl, meta, size))
            featured_by_pid[pid] = {"title": ctrl.get("Name", pid), "package": pid,
                                    "url": f"{BASE_URL}/banners/{pid}.png"}
    else:
        # A regeneration indexes only the payloads on disk. repo/debs is
        # gitignored, so a fresh worktree (or a half-finished restore) holds a
        # handful of debs while the committed index describes hundreds -- and
        # writing that out silently retires every package whose deb is merely
        # absent. Check before generating anything, so a refusal leaves the tree
        # untouched. --from-index is what the caller almost always wanted.
        guard_shrink(sorted(os.listdir(DEBS)))

        for fn in sorted(os.listdir(DEBS), key=functools.cmp_to_key(compare_deb_filenames)):
            if not fn.endswith(".deb"):
                continue
            blob = open(os.path.join(DEBS, fn), "rb").read()
            ctrl = control_dict(blob); pid = ctrl["Package"]
            payload_profile = deb_payload_profile(blob)
            if payload_profile is not None and payload_profile != PROFILE:
                raise SystemExit(
                    f"ERROR: {fn} has {payload_profile} payload paths but this is the "
                    f"{PROFILE} profile.\n"
                    f"       Put it in repo/profiles/{payload_profile}/debs/ and generate "
                    f"with XIOS_REPO_PROFILE={payload_profile}."
                )
            normalize_section(ctrl)
            normalize_publisher(ctrl)
            meta = load_meta(pid)
            pkgs.append({"ctrl": ctrl, "meta": meta})

            # assets
            if HAVE_PIL:
                icon = package_icon(pid, ctrl.get("Section", "Tweaks"), 256)
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
                f"SileoDepiction: {BASE_URL}/depictions/{pid}.json",
                f"Native Depiction: {BASE_URL}/depictions/{pid}.json",
            ]
            if "Homepage" not in ctrl:
                lines.append(f"Homepage: {meta.get('homepage', BASE_URL)}")
            stanzas.append("\n".join(lines))
            featured_by_pid[pid] = {"title": ctrl.get("Name", pid), "package": pid,
                                    "url": f"{BASE_URL}/banners/{pid}.png"}

        # The deb pool is additive and retains every superseded version file; index
        # only the newest version of each package id, not every .deb present. Uses
        # dpkg version-comparison semantics (compare_deb_versions), keyed on the
        # control Package field (what apt resolves against), so stale duplicate
        # stanzas never reach the generated Packages index.
        latest_idx = {}
        for i, p in enumerate(pkgs):
            pid = p["ctrl"]["Package"]
            if (pid not in latest_idx
                    or compare_deb_versions(p["ctrl"].get("Version", ""),
                                            pkgs[latest_idx[pid]]["ctrl"].get("Version", "")) > 0):
                latest_idx[pid] = i
        keep = set(latest_idx.values())
        pkgs = [p for i, p in enumerate(pkgs) if i in keep]
        stanzas = [s for i, s in enumerate(stanzas) if i in keep]

        packages = "\n\n".join(stanzas) + "\n"
        open(os.path.join(REPO, "Packages"), "w").write(packages)

    with open(os.path.join(REPO, "Packages.gz"), "wb") as f:
        f.write(gzip.compress(packages.encode(), 9, mtime=0))

    # Flat side indexes, not part of the apt contract. They exist because they
    # are what you actually want during a recovery: .pv answers "what version is
    # published?" and .sha answers "which payload bytes does this stanza point
    # at?" without parsing stanzas. Derived, so regenerate them here rather than
    # letting a hand-made copy go stale.
    indexed = parse_packages_text(packages)
    with open(os.path.join(REPO, "Packages.pv"), "w") as f:
        f.write("".join(f"{c['Package']}={c.get('Version','')}\n" for c in indexed))
    with open(os.path.join(REPO, "Packages.sha"), "w") as f:
        f.write("".join(f"{c.get('Filename','')} {c.get('SHA256','')}\n" for c in indexed))

    # featured carousel
    with open(os.path.join(REPO, "sileo-featured.json"), "w") as f:
        json.dump({"class": "FeaturedBannersView", "itemSize": "{263, 148}",
                   "itemCornerRadius": 8, "banners": list(featured_by_pid.values())}, f, indent=2)

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

    # After every asset this run writes, so the survivors are already refreshed
    # and whatever is left over really is orphaned. pkgs is the full generated
    # set in both modes -- see prune_orphan_assets on why that matters for --only.
    prune_orphan_assets({p["ctrl"]["Package"] for p in pkgs})

    write_index(pkgs)
    write_seo_files(pkgs)
    src = "committed Packages" if from_index else "repo/debs"
    print(f"Generated {PROFILE} repo at {REPO} ({len(pkgs)} package(s)) "
          f"from {src}, PIL={HAVE_PIL}")

if __name__ == "__main__":
    main()
