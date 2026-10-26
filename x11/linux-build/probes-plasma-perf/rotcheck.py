#!/usr/bin/env python3
# rotcheck.py SLOT: is a portrait KDE session healthy? Exit 0 when the newest launch created the panel's layer
# surface, Plasma's screen 0 is portrait, iosc's output is portrait and the panel corner of a grim capture is not black.
import json, os, re, subprocess, sys
slot = sys.argv[1]
log = "/var/jb/tmp/kde-plasma-%s.log" % slot
env = dict(os.environ, XDG_RUNTIME_DIR="/var/jb/tmp/xios-kde-runtime-" + slot, WAYLAND_DISPLAY="wayland-" + slot)
text = open(log, errors="replace").read()
text = text[max(0, text.rfind("launch kwin: QT_QUICK_BACKEND")):]
panel = "create layer shell surface PanelView" in text
geo = ""
try:
    bus = open("/var/jb/tmp/xios-kde-runtime-%s/kde-session-bus-%s" % (slot, slot)).read().strip()
    r = subprocess.run(["gdbus", "call", "--session", "--dest", "org.kde.plasmashell", "--object-path", "/PlasmaShell",
                        "--method", "org.kde.PlasmaShell.evaluateScript", "print(JSON.stringify(screenGeometry(0)))"],
                       env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=bus), capture_output=True, text=True, timeout=15)
    geo = (r.stdout + r.stderr).strip()
except Exception as e:
    geo = "gdbus failed: %s" % e
m = re.search(r'\\?"width\\?":(\d+),\\?"height\\?":(\d+)', geo)
portrait = bool(m and int(m.group(2)) > int(m.group(1)))
try:
    j = json.load(open("/var/jb/tmp/xios-%s.json" % slot))
    out = "%sx%s" % (j.get("width"), j.get("height"))
except Exception:
    out = "?"
r = subprocess.run(["grim", "-t", "ppm", "-g", "1040,1415 30x20", "/var/jb/tmp/rotcheck.ppm"], env=env, capture_output=True)
corner = -1.0
if r.returncode == 0:
    d = open("/var/jb/tmp/rotcheck.ppm", "rb").read()
    body = d[d.index(b"255\n") + 4:]
    corner = sum(body) / len(body)
if out == "2880x2160":
    print("  iosc output still landscape (Xios never rotated it): run INVALID; plasma=%s" % (m.group(0) if m else geo[:80]))
    sys.exit(2)
r = subprocess.run(["grim", "-t", "ppm", "-g", "300,500 200x200", "/var/jb/tmp/rotcheck2.ppm"], env=env, capture_output=True)
wall = -1.0
if r.returncode == 0:
    d = open("/var/jb/tmp/rotcheck2.ppm", "rb").read()
    body = d[d.index(b"255\n") + 4:]
    wall = sum(body) / len(body)
ok = panel and portrait and corner > 8 and wall > 5
wp = text.count("unknown wallpaper provider")
print("  wallpaper-unknown-path=%d panel=%s plasma=%s iosc-out=%s corner=%.1f wallpaper=%.1f -> %s" % (wp, panel, m.group(0) if m else geo[:80], out, corner, wall,
      "OK" if ok else "WEDGED"))
sys.exit(0 if ok else 1)
