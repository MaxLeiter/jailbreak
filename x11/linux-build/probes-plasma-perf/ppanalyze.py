#!/usr/bin/env python3
# ppanalyze.py TRACE [--host root@MaxsiPad.local] [--cache DIR] [--thread main|render|all] [--top N] [--from MS --to MS]
# Host-side analysis of an fpsample/popprof trace: maps PCs to images, pulls the non-shared-cache images it hit from
# the device (cached), symbolicates them with atos, and prints per-phase running time, top self and inclusive
# symbols, and a category breakdown. Frames in the dyld shared cache are labelled by image only.
import argparse, collections, os, re, struct, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("trace")
ap.add_argument("--host", default="root@MaxsiPad.local")
ap.add_argument("--cache", default=os.path.expanduser("~/.cache/ppanalyze-bins"))
ap.add_argument("--thread", default="main")
ap.add_argument("--top", type=int, default=30)
ap.add_argument("--phase", default=None, help="open | close | all (default: print both)")
ap.add_argument("--grep", default=None, help="only stacks with a frame matching this regex")
ap.add_argument("--callers", default=None, help="print the callers (next frame up) of symbols matching this regex")
ap.add_argument("--waiting", action="store_true", help="analyze all samples, not just running ones")
ap.add_argument("--timeline", default=None, help="print the time of every sample with a frame matching this regex")
ap.add_argument("--tree", type=float, default=None, help="print a top-down call tree, nodes >= this percent")
ap.add_argument("--root", default=None, help="tree: start at the first frame matching this regex")
ap.add_argument("--from-ms", type=float, default=None)
ap.add_argument("--to-ms", type=float, default=None)
a = ap.parse_args()

images, names, samples, events, tcpu = [], {}, [], [], {}
base = None
for line in open(a.trace):
    p = line.split()
    if not p:
        continue
    if p[0] == "B":
        base = (int(p[1]), int(p[2]), int(p[3]))
    elif p[0] == "I":
        images.append((int(p[1], 16), " ".join(p[2:])))
    elif p[0] == "N":
        names[int(p[1])] = " ".join(p[3:])
    elif p[0] == "S":
        samples.append((int(p[1]), int(p[2]), int(p[3]), [int(x, 16) for x in p[4:]]))
    elif p[0] == "E":
        events.append((int(p[1]), p[2]))
    elif p[0] == "T":
        tcpu[int(p[2])] = (int(p[3]), int(p[4]))
images.sort()
ev_ms = {}
if base:
    for t, n in events:
        ev_ms[n] = (t - base[0]) * base[1] / base[2] / 1e6

def in_cache(path):
    return path.startswith("/System/") or path.startswith("/usr/lib/") or path.startswith("/usr/libexec/")

def local_copy(path):
    dst = os.path.join(a.cache, path.lstrip("/"))
    if not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        r = subprocess.run(["scp", "-q", "%s:%s" % (a.host, path), dst])
        if r.returncode != 0:
            return None
    return dst

def text_size(fn):
    d = open(fn, "rb").read(65536)
    magic, cpu, sub, ft, ncmds, sz, fl, _ = struct.unpack_from("<IiiIIIII", d, 0)
    if magic != 0xFEEDFACF:
        return None
    off = 32
    for _ in range(ncmds):
        cmd, csz = struct.unpack_from("<II", d, off)
        if cmd == 0x19:
            seg = d[off + 8:off + 24].rstrip(b"\0")
            vmaddr, vmsize = struct.unpack_from("<QQ", d, off + 24)
            if seg == b"__TEXT":
                return vmsize
        off += csz
    return None

starts = [b for b, _ in images]
import bisect
sizes = {}
def image_of(pc):
    i = bisect.bisect_right(starts, pc) - 1
    if i < 0:
        return None
    b, path = images[i]
    if in_cache(path):
        nxt = starts[i + 1] if i + 1 < len(starts) else b + (64 << 20)
        return (b, path) if pc < nxt else None
    if path not in sizes:
        fn = local_copy(path)
        sizes[path] = text_size(fn) if fn else None
    sz = sizes[path]
    if sz is None or pc >= b + sz:
        return None
    return (b, path)

def tsel(ti):
    n = names.get(ti, "")
    if a.thread == "main":
        return ti == 0
    if a.thread == "render":
        return n == "QSGRenderThread"
    if a.thread == "all":
        return True
    return re.search(a.thread, n) is not None

sel = [s for s in samples if tsel(s[1])]
pcs = collections.defaultdict(set)
for t, ti, st, fr in sel:
    for k, pc in enumerate(fr):
        im = image_of(pc if k < 2 else pc - 1)
        if im and not in_cache(im[1]):
            pcs[im].add(pc if k < 2 else pc - 1)
sym = {}
for (b, path), s in pcs.items():
    fn = local_copy(path)
    s = sorted(s)
    for i in range(0, len(s), 2000):
        chunk = s[i:i + 2000]
        r = subprocess.run(["atos", "-arch", "arm64", "-o", fn, "-l", hex(b)] + [hex(x) for x in chunk],
                           capture_output=True, text=True)
        outl = r.stdout.splitlines()
        for pc, o in zip(chunk, outl):
            o = re.sub(r" \(in [^)]*\)", "", o)
            o = re.sub(r" \+ \d+$", "", o)
            o = re.sub(r" \([^()]*:\d+\)$", "", o)
            sym[pc] = o + "  [" + os.path.basename(path) + "]"

def name(pc, k):
    q = pc if k < 2 else pc - 1
    if q in sym:
        return sym[q]
    im = image_of(q)
    if im is None:
        return "[jit/anon]"
    return "[" + os.path.basename(im[1]) + "]"

CATS = [
    ("qml-create", r"QQmlObjectCreator|QQmlComponent(Private)?::(create|begin|complete)|QQmlIncubat|QQmlTypeLoader|QQmlDataBlob|QQmlTypeData|QQmlScriptBlob|compilationUnit|QQmlPropertyCache|QQmlMetaType|QQmlType::create|QQmlDelegateModel|QQmlInstantiator|QQmlComponentAttached"),
    ("qml-binding", r"QQmlBinding|QQmlPropertyBinding|QQmlJavaScriptExpression|QQmlNotifier|QQmlBoundSignal|QQmlPropertyPrivate::(write|binding)|QQmlAbstractBinding|QQmlData::|QPropertyBinding|QPropertyObserver|QQmlVMEMetaObject"),
    ("js-v4", r"QV4::|\[jit/anon\]|QJSValue|QJSEngine"),
    ("text", r"QQuickText|QTextLayout|QTextEngine|QFontEngine|QFont|QTextDocument|hb_|harfbuzz|QRawFont|QGlyph|Fc[A-Z]|fontconfig|freetype|FT_|QTextLine|QStaticText|QDistanceField|QSGDistanceField|QSGTextNode|QSGRhiDistance|QSGText"),
    ("icon/svg/image", r"QSvg|KIconLoader|KIconEngine|QIcon|QImage|QPixmap|QQuickPixmap|QQuickImage|Kirigami.*Icon|QQuickIcon|QPainter|QRasterPaintEngine|qt_blend|qt_memfill|QPaintEngine|png_|jpeg_|QImageReader|KSvg|Plasma::Svg|FrameSvg"),
    ("layout/polish", r"QQuickLayout|QQuickGridLayout|QQuickLinearLayout|polish|QQuickAnchors|updatePolish|QQuickItemPrivate::(setImplicit|implicit)|QQuickStackLayout|QQuickRow|QQuickColumn|QQuickBasePositioner|QQuickListView|QQuickItemView|QQuickFlickable"),
    ("scenegraph", r"QSG|QQuickWindowPrivate::(sync|render|polishItems)|updatePaintNode|QSGBatchRenderer|QSGRenderer|QQuickWindow::(render|sync)|QRhi|QSGThreadedRenderLoop|QSGRenderThread|QSGGuiThreadRenderLoop"),
    ("gl/angle/metal", r"libGLESv2|libEGL|ANGLE|\[Metal\]|AGXMetal|IOGPU|IOAccelerator|gl[A-Z]|egl[A-Z]|QOpenGL|\[libEGL|\[libGLESv2"),
    ("wayland", r"wl_|QtWaylandClient|QWayland"),
    ("dbus", r"QDBus|dbus_"),
    ("alloc", r"\[libsystem_malloc|malloc|free|operator new|operator delete"),
]
def category(stack_names):
    for nm in stack_names:  # leaf first: the first frame that matches a category wins
        for c, rx in CATS:
            if re.search(rx, nm):
                return c
    return "other"

def phase_of(t_ms):
    if "open" not in ev_ms:
        return "all"
    if t_ms < ev_ms["open"]:
        return "pre"
    if "close" in ev_ms and t_ms >= ev_ms["close"]:
        return "close"
    return "open"

print("trace %s: %d samples, thread=%s, events %s" % (a.trace, len(sel), a.thread,
      ", ".join("%s@%.0fms" % (k, v) for k, v in ev_ms.items())))
for ti, (u, sy) in sorted(tcpu.items()):
    if names.get(ti) and (u + sy) > 0:
        pass
groups = collections.OrderedDict()
for t, ti, st, fr in sel:
    tm = t / 1000
    if a.from_ms is not None and tm < a.from_ms:
        continue
    if a.to_ms is not None and tm >= a.to_ms:
        continue
    ph = phase_of(tm)
    if a.phase and a.phase != "all" and ph != a.phase:
        continue
    stack = [name(pc, k) for k, pc in enumerate(fr)]
    while stack and stack[-1] == "[jit/anon]":  # dyld's start frame: dyld is not in the image list
        stack[-1:] = ["[dyld start]"] if len(stack) == len(fr) else []
        break
    if a.grep and not any(re.search(a.grep, s) for s in stack):
        continue
    groups.setdefault(ph, []).append((tm, ti, st, stack))

if a.timeline:
    for ph, rows in groups.items():
        for tm, ti, st, stack in rows:
            hits = [nm for nm in stack if re.search(a.timeline, nm)]
            if hits:
                print("  %7.1f ms %-14s %s" % (tm, names.get(ti, ti), " < ".join(h.split("  [")[0][:60] for h in hits[:3])))
    sys.exit(0)

# the sampler's interval sets the weight of one sample; estimate it from the main thread's sample spacing
mt = [s[0] for s in samples if s[1] == 0]
dt = (mt[-1] - mt[0]) / max(1, len(mt) - 1) / 1000 if len(mt) > 1 else 2.0
print("main-thread sample spacing %.2f ms" % dt)
for ph, rows in groups.items():
    run = [r for r in rows if r[2] == 1 or a.waiting]
    print("\n## phase %s: %d samples, %d running (~%.0f ms running)" % (ph, len(rows), len(run), len(run) * dt))
    if a.thread == "main" and run:
        # wall-clock span of main-thread activity in this phase
        ts = [r[0] for r in run]
        print("   first running sample %.0f ms, last %.0f ms (relative to phase start %.0f)" % (
            ts[0], ts[-1], ev_ms.get(ph, 0)))
    cats = collections.Counter(category(r[3]) for r in run)
    print("   categories: " + ", ".join("%s %d%%" % (c, 100 * n / len(run)) for c, n in cats.most_common()) if run else "")
    selfc = collections.Counter(r[3][0] if r[3] else "?" for r in run)
    print("   top self:")
    for nm, n in selfc.most_common(a.top):
        print("   %5.1f%% %s" % (100 * n / len(run), nm[:160]))
    inc = collections.Counter()
    for r in run:
        for nm in set(r[3]):
            inc[nm] += 1
    print("   top inclusive:")
    for nm, n in inc.most_common(a.top):
        print("   %5.1f%% %s" % (100 * n / len(run), nm[:160]))
    if a.tree is not None and run:
        root = {}
        for r in run:
            fr2 = list(reversed(r[3]))
            if a.root:
                idx = next((i for i, nm in enumerate(fr2) if re.search(a.root, nm)), None)
                if idx is None:
                    continue
                fr2 = fr2[idx:]
            node = root
            for nm in fr2:
                c = node.setdefault(nm, [0, {}])
                c[0] += 1
                node = c[1]
        tot = len(run)
        def show(node, depth):
            for nm, (n, ch) in sorted(node.items(), key=lambda x: -x[1][0]):
                if 100 * n / tot < a.tree:
                    continue
                chain = [nm]
                while len(ch) == 1 and list(ch.values())[0][0] == n:
                    (nm2, (n2, ch2)), = ch.items()
                    chain.append(nm2); ch = ch2
                short = [re.sub(r"\(.*\)", "()", c.split("  [")[0])[:70] for c in chain]
                if len(short) > 4:
                    short = short[:2] + ["..%d.." % (len(short) - 4)] + short[-2:]
                print("   %s%5.1f%% %s" % ("  " * depth, 100 * n / tot, " > ".join(short)))
                show(ch, depth + 1)
        print("   tree (>= %.1f%%):" % a.tree)
        show(root, 0)
    if a.callers:
        cc = collections.Counter()
        for r in run:
            for k, nm in enumerate(r[3]):
                if re.search(a.callers, nm) and k + 1 < len(r[3]):
                    cc[nm[:80] + "  <-  " + r[3][k + 1][:100]] += 1
                    break
        print("   callers of /%s/:" % a.callers)
        for nm, n in cc.most_common(a.top):
            print("   %5.1f%% %s" % (100 * n / len(run), nm))
