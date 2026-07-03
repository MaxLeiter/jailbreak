#!/usr/bin/env python3
"""Fold linux-build/out/*.deb into repo/debs, newest-version-per-package.

Excludes KDE/Qt (kf6*, kwin*, plasma*, qt6*) and libmutter* (held for the
buffer-bridge fix). Also de-dups packages that already have multiple versions
in repo/debs. Dry-run by default; pass --apply to move files.
"""
import os, io, sys, tarfile, shutil, re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEBS = os.path.join(ROOT, "repo", "debs")
OUT  = os.path.join(HERE, "out")
ATTIC = os.path.join(DEBS, "_superseded")

EXCLUDE = re.compile(r"^(kf6|kwin|plasma|qt6|libmutter)", re.I)

# ---- deb control parsing (ar + tar) ----------------------------------------
def ar_members(data):
    assert data[:8] == b"!<arch>\n"
    out, off = {}, 8
    while off + 60 <= len(data):
        hdr = data[off:off+60]; off += 60
        name = hdr[0:16].decode("ascii","replace").strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        out[name] = data[off:off+size]; off += size + (size & 1)
    return out

def control_fields(path):
    with open(path, "rb") as f:
        m = ar_members(f.read())
    cn = next(n for n in m if n.startswith("control.tar"))
    mode = {"control.tar.gz":"r:gz","control.tar.xz":"r:xz",
            "control.tar.zst":"r:*","control.tar":"r:"}.get(cn,"r:*")
    if cn.endswith(".zst"):
        import subprocess
        raw = subprocess.run(["zstd","-dc"], input=m[cn],
                             stdout=subprocess.PIPE, check=True).stdout
        tf = tarfile.open(fileobj=io.BytesIO(raw), mode="r:")
    else:
        tf = tarfile.open(fileobj=io.BytesIO(m[cn]), mode=mode)
    with tf:
        mem = next(x for x in tf.getmembers() if x.name.lstrip("./") == "control")
        text = tf.extractfile(mem).read().decode("utf-8")
    d = {}
    for ln in text.splitlines():
        if ": " in ln and not ln.startswith(" "):
            k, v = ln.split(": ", 1); d[k] = v
    return d["Package"], d["Version"]

# ---- Debian version comparison (port of dpkg verrevcmp) ---------------------
def _order(c):
    if c == "" : return 0
    if c.isdigit(): return 0
    if c == "~": return -1
    if c.isalpha(): return ord(c)
    return ord(c) + 256

def _verrevcmp(val, ref):
    i = j = 0
    lv, lr = len(val), len(ref)
    while i < lv or j < lr:
        first = 0
        while (i < lv and not val[i].isdigit()) or (j < lr and not ref[j].isdigit()):
            vc = _order(val[i]) if i < lv else 0
            rc = _order(ref[j]) if j < lr else 0
            if vc != rc:
                return -1 if vc < rc else 1
            if i < lv: i += 1
            if j < lr: j += 1
        while i < lv and val[i] == "0": i += 1
        while j < lr and ref[j] == "0": j += 1
        while i < lv and j < lr and val[i].isdigit() and ref[j].isdigit():
            if first == 0: first = ord(val[i]) - ord(ref[j])
            i += 1; j += 1
        if i < lv and val[i].isdigit(): return 1
        if j < lr and ref[j].isdigit(): return -1
        if first: return -1 if first < 0 else 1
    return 0

def deb_cmp(a, b):
    def split(v):
        epoch, v = (v.split(":",1) if ":" in v else ("0", v))
        up, rev = (v.rsplit("-",1) if "-" in v else (v, "0"))
        return int(epoch), up, rev
    ea, ua, ra = split(a); eb, ub, rb = split(b)
    if ea != eb: return -1 if ea < eb else 1
    c = _verrevcmp(ua, ub)
    if c: return c
    return _verrevcmp(ra, rb)

# ---- gather ----------------------------------------------------------------
def scan(d, exclude=False):
    res = {}
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".deb"): continue
        if exclude and EXCLUDE.match(fn): continue
        pkg, ver = control_fields(os.path.join(d, fn))
        res.setdefault(pkg, []).append((ver, fn))
    return res

repo = scan(DEBS)
out  = scan(OUT, exclude=True)

apply = "--apply" in sys.argv
copies = []   # (src_path, fn)  new debs to place in repo/debs
removes = []  # fn already in repo/debs to retire (older dup)

allpkgs = sorted(set(repo) | set(out))
print(f"{'PACKAGE':40} {'REPO':22} {'OUT':22} ACTION")
for pkg in allpkgs:
    rvers = sorted(repo.get(pkg, []), key=lambda t: t[0])
    overs = sorted(out.get(pkg, []), key=lambda t: t[0])
    # newest in each pool
    rbest = max(rvers, key=lambda t: __import__("functools").cmp_to_key(deb_cmp)(t[0])) if rvers else None
    obest = max(overs, key=lambda t: __import__("functools").cmp_to_key(deb_cmp)(t[0])) if overs else None
    rv = rbest[0] if rbest else "-"
    ov = obest[0] if obest else "-"
    action = ""
    # decide winner
    winner_pool = None
    if rbest and obest:
        winner_pool = "repo" if deb_cmp(rbest[0], obest[0]) >= 0 else "out"
    elif rbest:
        winner_pool = "repo"
    elif obest:
        winner_pool = "out"
    # if OUT wins, copy it and retire ALL repo versions
    if winner_pool == "out":
        copies.append((os.path.join(OUT, obest[1]), obest[1]))
        for v, fn in rvers:
            removes.append(fn)
        action = f"ADD out {obest[0]}" + (f"  retire repo {rv}" if rvers else "  (new)")
    else:
        # repo wins; retire any older duplicate repo versions
        dups = [fn for v, fn in rvers if fn != rbest[1]]
        for fn in dups: removes.append(fn)
        if dups:
            action = f"keep repo {rv}  dedup {len(dups)} older"
        elif obest and deb_cmp(rbest[0], obest[0]) == 0:
            action = "same (no change)"
        elif obest:
            action = f"keep repo {rv} (newer than out {ov})"
    if action:
        print(f"{pkg:40} {rv:22} {ov:22} {action}")

print(f"\nSUMMARY: {len(copies)} deb(s) to add from out/, {len(removes)} old deb(s) to retire")
if apply:
    os.makedirs(ATTIC, exist_ok=True)
    for fn in removes:
        src = os.path.join(DEBS, fn)
        if os.path.exists(src):
            shutil.move(src, os.path.join(ATTIC, fn))
    for src, fn in copies:
        shutil.copy2(src, os.path.join(DEBS, fn))
    print(f"APPLIED: added {len(copies)}, retired {len(removes)} -> {ATTIC}")
