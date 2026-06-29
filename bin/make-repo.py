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

# ── identity / theme ─────────────────────────────────────────────────────────
BASE_URL    = "https://repo.maxleiter.com"
ORIGIN      = "Max's Tweaks"
DESCRIPTION = "Jailbreak tweaks by Max"
ARCH        = "iphoneos-arm64"
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

# ── native (Sileo) depiction ─────────────────────────────────────────────────
def native_depiction(ctrl, meta, size):
    pid = ctrl["Package"]
    info = [
        ("Version", ctrl.get("Version", "")),
        ("Size", human_size(size)),
        ("Developer", meta.get("developer", ctrl.get("Author", ctrl.get("Maintainer", "")))),
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
            ("Developer", meta.get("developer", ctrl.get("Author", ""))),
            ("Section", ctrl.get("Section", "Tweaks")), ("Identifier", pid)])
    body = md_to_html(meta.get("description", ctrl.get("Description", "")))
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(ctrl.get('Name', pid))}</title>{PAGE_CSS}</head>
<body><div class="wrap">
  <header><img src="{BASE_URL}/icons/{pid}.png" alt="">
    <div><h1>{html.escape(ctrl.get('Name', pid))}</h1>
    <p class="sub">{html.escape(meta.get('tagline', ctrl.get('Description','')))}</p></div></header>
  <div class="prose">{body}</div>
  <h2>Information</h2><table class="info">{rows}</table>
</div></body></html>"""

# ── shared CSS ───────────────────────────────────────────────────────────────
PAGE_CSS = f"""<style>
  :root{{color-scheme:dark}} *{{box-sizing:border-box}}
  body{{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
        background:#08080b;color:#e9e9ee;-webkit-font-smoothing:antialiased}}
  .wrap{{max-width:680px;margin:0 auto;padding:48px 20px 90px}}
  header{{display:flex;align-items:center;gap:16px;margin-bottom:18px}}
  header img{{width:64px;height:64px;border-radius:15px}}
  h1{{font-size:26px;margin:0}} .sub{{color:#9a9aa6;margin:3px 0 0}}
  h2{{font-size:13px;text-transform:uppercase;letter-spacing:.07em;color:#8a8a96;margin:30px 0 12px}}
  .prose p{{margin:.5em 0}} .prose ul{{margin:.4em 0;padding-left:1.2em}} .prose li{{margin:.2em 0}}
  .prose strong{{color:#fff}} a{{color:{ACCENT_HEX};text-decoration:none}}
  .url{{display:flex;gap:8px;margin:26px 0}}
  .url input{{flex:1;padding:12px 14px;border-radius:10px;border:1px solid #23232c;
    background:#121218;color:#e9e9ee;font:14px ui-monospace,monospace}}
  .url button,.btns a{{padding:12px 16px;border-radius:10px;font-weight:600;font-size:14px;cursor:pointer}}
  .url button{{border:0;background:{ACCENT_HEX};color:#04121f}}
  .btns{{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:36px}}
  .btns a{{background:#14141b;border:1px solid #23232c;color:#e9e9ee}}
  .btns a:hover{{border-color:{ACCENT_HEX}}}
  .pkg{{display:flex;gap:14px;align-items:center;padding:14px;border:1px solid #1d1d26;
    border-radius:14px;background:#101017;margin-bottom:12px;text-decoration:none;color:inherit}}
  .pkg:hover{{border-color:{ACCENT_HEX}}}
  .pkg img{{width:54px;height:54px;border-radius:12px;flex:0 0 auto}}
  .pkg .n{{font-weight:600;font-size:17px}} .pkg .t{{color:#9a9aa6;font-size:14px}}
  .pkg .v{{margin-left:auto;color:#6a6a76;font:12px ui-monospace,monospace;align-self:flex-start}}
  table.info{{width:100%;border-collapse:collapse;font-size:14px}}
  table.info td{{padding:9px 0;border-bottom:1px solid #18181f}}
  table.info td:first-child{{color:#8a8a96;width:40%}}
  footer{{margin-top:40px;color:#6a6a76;font-size:13px}}
</style>"""

# ── index / landing page ─────────────────────────────────────────────────────
def write_index(pkgs):
    cards = ""
    for p in pkgs:
        pid = p["ctrl"]["Package"]
        cards += f"""
    <a class="pkg" href="depictions/{pid}.html">
      <img src="icons/{pid}.png" alt="">
      <div><div class="n">{html.escape(p['ctrl'].get('Name', pid))}</div>
        <div class="t">{html.escape(p['meta'].get('tagline', p['ctrl'].get('Description','')))}</div></div>
      <div class="v">v{html.escape(p['ctrl'].get('Version',''))}</div>
    </a>"""
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(ORIGIN)}</title><link rel="icon" href="favicon.ico">{PAGE_CSS}</head>
<body><div class="wrap">
  <header><img src="CydiaIcon.png" alt="">
    <div><h1>{html.escape(ORIGIN)}</h1><p class="sub">{html.escape(DESCRIPTION)}</p></div></header>
  <div class="url"><input id="repo" readonly value="">
    <button onclick="navigator.clipboard.writeText(document.getElementById('repo').value)">Copy</button></div>
  <div class="btns"><a id="sileo" href="#">Add to Sileo</a>
    <a id="zebra" href="#">Add to Zebra</a><a id="cydia" href="#">Add to Cydia</a></div>
  <h2>Packages</h2>{cards}
  <footer>Add the URL above to your package manager to install.</footer>
</div>
<script>
  var u=location.origin+location.pathname.replace(/index\\.html$/,"");
  document.getElementById("repo").value=u;
  document.getElementById("sileo").href="sileo://source/"+u;
  document.getElementById("zebra").href="zbra://sources/add/"+u;
  document.getElementById("cydia").href="cydia://url/https://cydia.saurik.com/api/share#?source="+u;
</script></body></html>"""
    open(os.path.join(REPO, "index.html"), "w").write(page)

# ── main ─────────────────────────────────────────────────────────────────────
def main():
    for d in ("icons", "banners", "depictions"):
        os.makedirs(os.path.join(REPO, d), exist_ok=True)

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
        meta = load_meta(pid)
        pkgs.append({"ctrl": ctrl, "meta": meta})

        # assets
        if HAVE_PIL:
            icon = clock_icon(256)
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
            f"Homepage: {meta.get('homepage', BASE_URL)}",
        ]
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
    rel = [f"Origin: {ORIGIN}", f"Label: {ORIGIN}", "Suite: stable", "Version: 1.0",
           "Codename: ios", f"Architectures: {ARCH}", "Components: main",
           f"Description: {DESCRIPTION}", "MD5Sum:"]
    rel += [f" {m} {s} {n}" for n, s, m, _ in idx]
    rel.append("SHA256:")
    rel += [f" {sh} {s} {n}" for n, s, _, sh in idx]
    open(os.path.join(REPO, "Release"), "w").write("\n".join(rel) + "\n")

    write_index(pkgs)
    print(f"Generated repo ({len(pkgs)} package(s)), PIL={HAVE_PIL}")

if __name__ == "__main__":
    main()
