#!/usr/bin/env python3
"""Relax unsatisfiable exact-version Depends pins in repo/debs.

The +ios rebuild wave ships runtime libs at e.g. 1.78.0+ios1 but their -dev
siblings still pin `Depends: foo (= 1.78.0)` (the plain upstream version). apt
then cannot co-install the -dev with the +ios runtime, so a full dist-upgrade
orphans the -dev (removal) or falls back to Procursus (downgrade).

Rule: for a Depends relation `name (= V)`, if the repo provides `name` but NOT
at exactly V (only a higher +ios/… variant), relax the relation to `name (>= V)`.
This is a pure widening: the device's installed plain V and the repo's +ios V
both satisfy `>= V`. Packages whose exact V IS in the repo, or whose `name` is
not in the repo at all (satisfied by Procursus), are left untouched.

Dry-run by default. --apply repacks affected .debs in place. Use
--apply --bump-ios for already-published packages; it bumps the final +iosN
marker and writes a new .deb filename instead of replacing immutable bytes.
"""
import importlib.util, os, io, re, sys, tarfile, subprocess, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
DEBS = os.path.join(ROOT, "repo", "debs")
BUILD = os.path.join(HERE, "build-deb.py")
MAKE_REPO = os.path.join(ROOT, "bin", "lib", "make-repo.py")

spec = importlib.util.spec_from_file_location("make_repo", MAKE_REPO)
make_repo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(make_repo)

def ar_members(data):
    out, off = {}, 8
    while off + 60 <= len(data):
        hdr = data[off:off+60]; off += 60
        name = hdr[0:16].decode("ascii","replace").strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        out[name] = data[off:off+size]; off += size + (size & 1)
    return out

def read_control(path):
    m = ar_members(open(path, "rb").read())
    cn = next(n for n in m if n.startswith("control.tar"))
    raw = (subprocess.run(["zstd","-dc"], input=m[cn], stdout=subprocess.PIPE, check=True).stdout
           if cn.endswith(".zst") else m[cn])
    tf = tarfile.open(fileobj=io.BytesIO(raw), mode="r:*")
    txt = tf.extractfile(next(x for x in tf.getmembers() if x.name.lstrip("./")=="control")).read().decode()
    return txt

def field(txt, key):
    for ln in txt.splitlines():
        if ln.startswith(key + ": "):
            return ln[len(key)+2:]
    return None

# ---- pass 1: repo inventory -------------------------------------------------
repo = {}
controls = {}
latest = {}
for fn in sorted(os.listdir(DEBS)):
    if not fn.endswith(".deb"): continue
    txt = read_control(os.path.join(DEBS, fn))
    controls[fn] = txt
    pkg = field(txt, "Package")
    ver = field(txt, "Version")
    repo.setdefault(pkg, set()).add(ver)
    if pkg not in latest or make_repo.compare_deb_versions(latest[pkg], ver) < 0:
        latest[pkg] = ver

REL = re.compile(r'^\s*([a-z0-9][a-z0-9+.\-]*)\s*(?:\(\s*(=)\s*([^)]+)\)\s*)?$', re.I)

def relax_depends(dep):
    """Return (new_dep_str, [changes]) for a Depends/Recommends value."""
    changes = []
    groups = []
    for grp in dep.split(","):
        alts = []
        for alt in grp.split("|"):
            m = REL.match(alt.strip())
            if m and m.group(2) == "=":
                name, ver = m.group(1), m.group(3).strip()
                if name in repo and ver not in repo[name]:
                    alts.append(f"{name} (>= {ver})")
                    changes.append(f"{name} (= {ver}) -> (>= {ver})")
                    continue
            alts.append(alt.strip())
        groups.append(" | ".join(alts))
    return ", ".join(groups), changes

apply = "--apply" in sys.argv
bump_ios = "--bump-ios" in sys.argv
if bump_ios and not apply:
    raise SystemExit("ERROR: --bump-ios only makes sense with --apply")

IOS_REV = re.compile(r"^(.*\+ios)([0-9]+)$")

def bump_ios_version(ver):
    m = IOS_REV.match(ver)
    if not m:
        raise SystemExit(f"ERROR: cannot --bump-ios version without final +iosN marker: {ver}")
    return f"{m.group(1)}{int(m.group(2)) + 1}"

def replace_field(lines, key, value):
    out = []
    replaced = False
    for ln in lines:
        if ln.startswith(key + ": "):
            out.append(key + ": " + value)
            replaced = True
        else:
            out.append(ln)
    if not replaced:
        raise SystemExit(f"ERROR: control missing {key}")
    return out

# Leave the KDE/Qt family untouched (not installed on device; owned by other work).
KDE_QT = re.compile(r"^(kf6|kwin|plasma|qt6|kde|kglobal|kwayland|layer-shell-qt)", re.I)
touched = 0
for fn in sorted(os.listdir(DEBS)):
    if not fn.endswith(".deb"): continue
    if KDE_QT.match(fn): continue
    path = os.path.join(DEBS, fn)
    txt = controls[fn]
    pkg = field(txt, "Package")
    ver = field(txt, "Version")
    if latest.get(pkg) != ver:
        continue
    dep = field(txt, "Depends")
    if not dep: continue
    new_dep, changes = relax_depends(dep)
    if not changes: continue
    touched += 1
    print(f"{fn}:")
    for c in changes: print(f"    {c}")
    if apply:
        # unpack, edit DEBIAN/control, repack
        stage = tempfile.mkdtemp(prefix="relax-")
        try:
            card = os.path.join(stage, "_ar"); os.makedirs(card)
            subprocess.run(["ar","x",path], cwd=card, check=True)
            deb = os.path.join(stage, "deb"); os.makedirs(os.path.join(deb,"DEBIAN"))
            # control members
            cn = next(f for f in os.listdir(card) if f.startswith("control.tar"))
            subprocess.run(f"zstd -dc '{os.path.join(card,cn)}' | tar -xf - -C '{os.path.join(deb,'DEBIAN')}'",
                           shell=True, check=True)
            dn = next(f for f in os.listdir(card) if f.startswith("data.tar"))
            subprocess.run(f"zstd -dc '{os.path.join(card,dn)}' | tar -xf - -C '{deb}'",
                           shell=True, check=True)
            # rewrite control Depends
            ctlp = os.path.join(deb, "DEBIAN", "control")
            lines = open(ctlp).read().splitlines()
            lines = replace_field(lines, "Depends", new_dep)
            if bump_ios:
                old_ver = field(txt, "Version")
                new_ver = bump_ios_version(old_ver)
                lines = replace_field(lines, "Version", new_ver)
                print(f"    Version: {old_ver} -> {new_ver}")
            with open(ctlp, "w") as f:
                for ln in lines:
                    f.write(ln + "\n")
            outdir = tempfile.mkdtemp(prefix="relaxout-")
            built = subprocess.run([sys.executable, BUILD, deb, outdir],
                                   stdout=subprocess.PIPE, check=True).stdout.decode().strip()
            if bump_ios:
                dest = os.path.join(DEBS, os.path.basename(built))
                if os.path.exists(dest):
                    raise SystemExit(f"ERROR: refusing to overwrite existing bumped deb: {dest}")
                shutil.copy2(built, dest)
            else:
                shutil.copy2(built, path)  # overwrite in place (same filename/version)
            shutil.rmtree(outdir)
        finally:
            shutil.rmtree(stage)

mode = "APPLIED"
if not apply:
    mode = "DRY-RUN"
elif bump_ios:
    mode = "APPLIED+BUMPED"
print(f"\n{mode}: {touched} deb(s) with unsatisfiable exact pins")
