#!/usr/bin/env python3
"""Repack the published debs with the packaging fixes from the Procursus dependency audit.

docs/handoff/procursus-dependency-audit-2026-10-25.md found loads that a fresh install
cannot satisfy. The recipe and control-source fixes are in the tree (stamp-minos.py
DEPENDS_ADD, build_info/*.control, recipes/relink-gtkintl.sh, the EDS and gsd recipes,
the ladybird-wayland and stublibs packaging). This applies the same fixes to the already
published payloads, so nothing has to be rebuilt:

  Depends     add stamp-minos.py DEPENDS_ADD (the single table), drop libintl-dev and
              libexpat1-dev, and move the exact (=) pins of -dev packages to the new version
  libintl     @rpath/libintl.dylib -> @rpath/libintl.8.dylib, plus Depends: libintl8
  EDS         add LC_RPATH /var/jb/usr/lib/evolution-data-server where libedbus-private loads
  gsd         LC_RPATH @loader_path/../../gnome-settings-daemon -> lib/gnome-settings-daemon-46
  mutter      add LC_RPATH /var/jb/usr/lib/mutter-14 where the mutter sublibs load
  ladybird-tls  libssl.3's @rpath/libcrypto.3.dylib -> @loader_path/libcrypto.3.dylib

Every edited Mach-O is re-signed by tools/resign-like.sh, which first finds the signer
invocation that reproduces the shipped file byte for byte (in-container ldid, plain or with
the Procursus -Hsha256 -Cadhoc flags, host ldid, or codesign) and then signs the edited
file the same way. The signature therefore differs from the shipped one only by the load
commands. Unedited members keep their bytes and tar metadata; a control-only fix keeps
data.tar byte-identical (asserted).

Every output gets a new version so no published filename is reused, and FIXED.txt in the
output dir lists package, version, sha256, file, the change and the deb it supersedes.

Usage (host, needs otool/install_name_tool/ldid/codesign and Docker for the container ldid):
    python3 tools/repack-loose-ends-20261025.py --src <dir with the published debs> \
        [--out out/loose-ends-20261025] [--work <scratch dir>]
"""
import argparse
import hashlib
import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
IMAGE = "procursus-xbuild:bookworm-arm64"
PREFIX = "/var/jb"

_spec = importlib.util.spec_from_file_location("stamp_minos", os.path.join(HERE, "stamp-minos.py"))
sm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sm)

# Mach-O edits. Each takes (member path, loads, rpaths) and returns install_name_tool argv
# fragments (one list per invocation), or [] when the file needs nothing.
EDS_PRIV = f"{PREFIX}/usr/lib/evolution-data-server"
GSD_OLD = "@loader_path/../../gnome-settings-daemon"
GSD_NEW = f"{PREFIX}/usr/lib/gnome-settings-daemon-46"


def op_intl8(path, loads, rpaths):
    return [["-change", "@rpath/libintl.dylib", "@rpath/libintl.8.dylib"]] \
        if "@rpath/libintl.dylib" in loads else []


def op_eds_rpath(path, loads, rpaths):
    return [["-add_rpath", EDS_PRIV]] \
        if "@rpath/libedbus-private.dylib" in loads and EDS_PRIV not in rpaths else []


def op_gsd_rpath(path, loads, rpaths):
    return [["-rpath", GSD_OLD, GSD_NEW]] if GSD_OLD in rpaths else []


MUTTER_DIR = f"{PREFIX}/usr/lib/mutter-14"


def op_mutter_rpath(path, loads, rpaths):
    return [["-add_rpath", MUTTER_DIR]] \
        if any(re.fullmatch(r"@rpath/libmutter-[a-z-]+-14\.0\.dylib", l) for l in loads) \
        and MUTTER_DIR not in rpaths else []


def op_tls_crypto(path, loads, rpaths):
    return [["-change", "@rpath/libcrypto.3.dylib", "@loader_path/libcrypto.3.dylib"]] \
        if path.endswith("/ladybird-tls/libssl.3.dylib") and "@rpath/libcrypto.3.dylib" in loads else []


INTL = ("intl8", op_intl8)
# pkg: (shipped version, new version, [mach-o ops], extra control edits, what changed)
#   extra: {"drop": [...], "add": [...], "pin": {dep: version}}
# Depends from stamp-minos.py DEPENDS_ADD are applied to every entry automatically.
FIXES = {
    # 1. Procursus libraries loaded outside the Depends closure (control only)
    "kf6-archive":              ("6.30.0+ios1", "6.30.0+ios2", [], {}, "Depends += libzstd1, libssl3"),
    "kf6-archive-dev":          ("6.30.0+ios1", "6.30.0+ios2", [], {"pin": {"kf6-archive": "6.30.0+ios2"}},
                                 "pin kf6-archive (= 6.30.0+ios2)"),
    "libappstream5":            ("1.0.3+ios1", "1.0.3+ios2", [], {}, "Depends += libzstd1"),
    "libxmlb2":                 ("0.3.14+ios1", "0.3.14+ios2", [], {}, "Depends += libzstd1"),
    "libaccountsservice0":      ("23.13.9+ios1", "23.13.9+ios2", [], {}, "Depends += libcrypt2"),
    # The rpath: its cogl/clutter/cogl-pango/mtk sublibs live in lib/mutter-14, which no
    # LC_RPATH named (only meson's build-tree paths), so they resolved only through
    # launch-gnome-session.sh's DYLD_LIBRARY_PATH.
    "libmutter-14-0":           ("46.0+ios11", "46.0+ios12", [("mutter-rpath", op_mutter_rpath)], {},
                                 "Depends += libxtst6, libx11-xcb1, libxcb-randr0, libxcb-res0; "
                                 "LC_RPATH += lib/mutter-14 where the mutter sublibs load"),
    "tigervnc-common":          ("1.11.0+rootless1", "1.11.0+rootless2", [], {},
                                 "Depends += libsm6, libice6, libx11-6, libxext6, libjpeg62-turbo, "
                                 "libpixman-1-0, libgnutls30 (DEPENDS_ADD entries never stamped in)"),
    "tigervnc-scraping-server": ("1.11.0+rootless1", "1.11.0+rootless2", [], {},
                                 "Depends += libxtst6, libxfixes3, libxrandr2, libsm6, libice6, libxext6 "
                                 "(DEPENDS_ADD entries never stamped in)"),
    "ladybird-tls":             ("3.5.3+wl1", "3.5.3+wl2", [("tls", op_tls_crypto)], {},
                                 "libssl.3 loads libcrypto via @loader_path, not the base 3.2.1 through @rpath"),
    # 3. libwayland-dev
    "libwayland-dev":           ("1.24.0+ios2", "1.24.0+ios3", [], {"drop": ["libexpat1-dev"]},
                                 "Depends -= libexpat1-dev (no repo provides it; nothing in the package needs it)"),
    # 4. EDS
    "evolution-data-server":    ("3.52.4+ios2", "3.52.4+ios3", [("eds-rpath", op_eds_rpath), INTL], {},
                                 "LC_RPATH += lib/evolution-data-server (libedbus-private); libintl.8; Depends += libintl8"),
    "evolution-data-server-dev": ("3.52.4+ios2", "3.52.4+ios3", [], {"pin": {"evolution-data-server": "3.52.4+ios3"}},
                                  "pin evolution-data-server (= 3.52.4+ios3)"),
    # 5. gsd
    "gnome-settings-daemon":    ("46.0+ios1", "46.0+ios2", [("gsd-rpath", op_gsd_rpath)], {},
                                 "gsd-{a11y-settings,housekeeping,keyboard,screensaver-proxy}: rpath -> lib/gnome-settings-daemon-46"),
    # 2. the libintl trap
    "ibus":                     ("1.5.29+ios1", "1.5.29+ios2", [INTL], {}, "libintl.8; Depends libintl-dev -> libintl8"),
    "libibus-1.0-5":            ("1.5.29+ios1", "1.5.29+ios2", [INTL], {}, "libintl.8; Depends libintl-dev -> libintl8"),
    "ladybird-wayland":         ("0.1.0+wl5", "0.1.0+wl6", [INTL], {}, "libintl.8; Depends += libintl8"),
    "libenchant-2-2":           ("2.6.1+ios1", "2.6.1+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "libexo-2-0":               ("4.16.4+ios1", "4.16.4+ios2", [INTL], {}, "libintl.8; Depends += libintl8, libice6, libsm6"),
    "libgee-0.8-2":             ("0.20.8+ios1", "0.20.8+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "libgmime-3.0-0":           ("3.2.7+ios1", "3.2.7+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "libgmime-3.0-dev":         ("3.2.7+ios1", "3.2.7+ios2", [], {"pin": {"libgmime-3.0-0": "3.2.7+ios2"}},
                                 "pin libgmime-3.0-0 (= 3.2.7+ios2)"),
    "libgoffice-0.10-10":       ("0.10.61+ios1", "0.10.61+ios2", [INTL], {}, "libintl.8 (9 plugins); Depends += libintl8"),
    "libgoffice-0.10-dev":      ("0.10.61+ios1", "0.10.61+ios2", [], {"pin": {"libgoffice-0.10-10": "0.10.61+ios2"}},
                                 "pin libgoffice-0.10-10 (= 0.10.61+ios2)"),
    "libgsf-1-114":             ("1.14.58+ios1", "1.14.58+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "libgsf-1-dev":             ("1.14.58+ios1", "1.14.58+ios2", [], {"pin": {"libgsf-1-114": "1.14.58+ios2"}},
                                 "pin libgsf-1-114 (= 1.14.58+ios2)"),
    "libical3":                 ("3.0.17+ios1", "3.0.17+ios2", [INTL], {}, "libintl.8 (libical-glib); Depends += libintl8"),
    "librsvg2-2":               ("2.56.5+ios1", "2.56.5+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "librsvg2-bin":             ("2.56.5+ios1", "2.56.5+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "librsvg2-common":          ("2.56.5+ios1", "2.56.5+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    # +ios2 and +ios4 exist as unpublished builds; +ios5 stays clear of both.
    "libwebkit2gtk-4.1-0":      ("2.44.4+ios1", "2.44.4+ios5", [INTL], {}, "libintl.8 (Network/WebProcess, injected bundle); Depends += libintl8"),
    "libwebkit2gtk-4.1-dev":    ("2.44.4+ios1", "2.44.4+ios5", [], {"pin": {"libwebkit2gtk-4.1-0": "2.44.4+ios5"}},
                                 "pin libwebkit2gtk-4.1-0 (= 2.44.4+ios5)"),
    "libxfce4ui-2-0":           ("4.16.0+ios1", "4.16.0+ios2", [INTL], {}, "libintl.8; Depends += libintl8, libice6, libsm6"),
    "libxfce4util7":            ("4.16.0+ios1", "4.16.0+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "thunar":                   ("4.16.11+ios1", "4.16.11+ios2", [INTL], {}, "libintl.8; Depends += libintl8, libice6, libsm6"),
    "xfconf":                   ("4.16.0+ios1", "4.16.0+ios2", [INTL], {}, "libintl.8; Depends += libintl8"),
    "xios-desktop-stublibs":    ("0.1.1", "0.1.2", [INTL], {}, "libintl.8 (libgudev, libgsound); Depends += libintl8"),
}

MACHO = (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")


def run(*a, **k):
    return subprocess.run(list(a), check=True, **k)


def otool(path):
    out = run("otool", "-l", path, capture_output=True, text=True).stdout
    loads, rpaths, cmd = [], [], None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith("cmd "):
            cmd = s.split()[1]
        elif s.startswith("name ") and cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB",
                                               "LC_REEXPORT_DYLIB", "LC_LAZY_LOAD_DYLIB",
                                               "LC_LOAD_UPWARD_DYLIB"):
            loads.append(re.sub(r"\s+\(offset \d+\)$", "", s[5:]))
        elif s.startswith("path ") and cmd == "LC_RPATH":
            rpaths.append(re.sub(r"\s+\(offset \d+\)$", "", s[5:]))
    return loads, rpaths


# ── control editing ──────────────────────────────────────────────────────────
def dep_name(entry):
    return re.split(r"[\s(]", entry.strip(), 1)[0]


def edit_depends(value, add, drop, pin):
    parts = [p.strip() for p in value.split(",") if p.strip()]
    out = []
    for p in parts:
        alts = [a.strip() for a in p.split("|")]
        if any(dep_name(a) in drop for a in alts):
            alts = [a for a in alts if dep_name(a) not in drop]
            if not alts:
                continue
        alts = [f"{dep_name(a)} (= {pin[dep_name(a)]})" if dep_name(a) in pin else a for a in alts]
        out.append(" | ".join(alts))
    have = {dep_name(a) for p in out for a in p.split("|")}
    out += [a for a in dict.fromkeys(add) if a not in have]
    return ", ".join(out)


def edit_control(text, pkg, version, add, drop, pin):
    lines = text.rstrip("\n").split("\n")
    out, seen_dep = [], False
    for ln in lines:
        key = ln.split(":", 1)[0] if (":" in ln and not ln.startswith((" ", "\t"))) else ""
        if key == "Version":
            ln = f"Version: {version}"
        elif key == "Depends":
            ln = "Depends: " + edit_depends(ln.split(":", 1)[1], add, drop, pin)
            seen_dep = True
        out.append(ln)
    if not seen_dep and add:
        at = next(i for i, l in enumerate(out) if l.startswith("Architecture:")) + 1
        out.insert(at, "Depends: " + ", ".join(add))
    return "\n".join(out) + "\n"


def field(text, key):
    m = re.search(rf"^{key}:\s*(.*)$", text, re.M)
    return m.group(1).strip() if m else None


# ── per-package plan ─────────────────────────────────────────────────────────
class Plan:
    def __init__(self, pkg, src, work):
        self.pkg, self.src = pkg, src
        self.ship_ver, self.new_ver, self.ops, self.extra, self.note = FIXES[pkg]
        self.raw = open(src, "rb").read()
        self.members = sm.ar_split(self.raw)
        self.dm = next(m for m in self.members if m["name"].startswith("data.tar"))
        self.cm = next(m for m in self.members if m["name"].startswith("control.tar"))
        with tarfile.open(fileobj=io.BytesIO(self.cm["body"]), mode=sm._tar_mode(self.cm["name"])) as tf:
            self.control = tf.extractfile(next(m for m in tf.getmembers()
                                               if m.name.lstrip("./") == "control")).read().decode()
        assert field(self.control, "Package") == pkg, (src, pkg)
        assert field(self.control, "Version") == self.ship_ver, \
            f"{src}: Version {field(self.control, 'Version')} != expected {self.ship_ver}"
        self.edits = {}   # tar member name -> sign dir
        self.changed_ops = set()
        self.work = os.path.join(work, "sign")

    def prepare_machos(self):
        if not self.ops:
            return
        tmp = tempfile.mkdtemp(dir=self.work)
        with tarfile.open(fileobj=io.BytesIO(self.dm["body"]), mode=sm._tar_mode(self.dm["name"])) as tf:
            for mi in tf.getmembers():
                if not mi.isreg():
                    continue
                data = tf.extractfile(mi).read()
                if data[:4] not in MACHO:
                    continue
                path = "/" + mi.name.lstrip("./")
                probe = os.path.join(tmp, "probe")
                open(probe, "wb").write(data)
                loads, rpaths = otool(probe)
                todo = []
                for name, fn in self.ops:
                    steps = fn(path, loads, rpaths)
                    if steps:
                        self.changed_ops.add(name)
                        todo += steps
                if not todo:
                    continue
                d = os.path.join(self.work, f"{self.pkg}.{len(self.edits):03d}")
                base = os.path.basename(path)
                os.makedirs(d + "/orig"); os.makedirs(d + "/mod")
                open(f"{d}/orig/{base}", "wb").write(data)
                open(f"{d}/mod/{base}", "wb").write(data)
                for step in todo:
                    run("install_name_tool", *step, f"{d}/mod/{base}", capture_output=True)
                open(f"{d}/path", "w").write(path + "\n")
                self.edits[mi.name] = d
        shutil.rmtree(tmp)

    def depends_changes(self):
        add = list(sm.DEPENDS_ADD.get(self.pkg, [])) + self.extra.get("add", [])
        drop = list(self.extra.get("drop", []))
        if "intl8" in self.changed_ops:
            add.append("libintl8")
            drop.append("libintl-dev")
        return add, drop, dict(self.extra.get("pin", {}))

    def build(self, out_dir):
        add, drop, pin = self.depends_changes()
        newctl = edit_control(self.control, self.pkg, self.new_ver, add, drop, pin)
        signed = {}
        for name, d in self.edits.items():
            base = os.listdir(d + "/orig")[0]
            signed[name] = open(f"{d}/signed/{base}", "rb").read()

        # data.tar: same member order and metadata; only edited files get new bytes.
        if signed:
            buf = io.BytesIO()
            with tarfile.open(fileobj=io.BytesIO(self.dm["body"]), mode=sm._tar_mode(self.dm["name"])) as src, \
                 tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as dst:
                for mi in src.getmembers():
                    if mi.name in signed:
                        ni = tarfile.TarInfo(mi.name)
                        for a in ("mode", "uid", "gid", "uname", "gname", "mtime"):
                            setattr(ni, a, getattr(mi, a))
                        ni.size = len(signed[mi.name])
                        dst.addfile(ni, io.BytesIO(signed[mi.name]))
                    elif mi.isreg():
                        dst.addfile(mi, src.extractfile(mi))
                    else:
                        dst.addfile(mi)
            data_body = sm._compress_like(self.dm["name"], buf.getvalue())
        else:
            data_body = self.dm["body"]

        # control.tar: new control, md5sums updated for the edited files.
        md5 = {n.lstrip("./"): hashlib.md5(b).hexdigest() for n, b in signed.items()}
        buf = io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(self.cm["body"]), mode=sm._tar_mode(self.cm["name"])) as src, \
             tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as dst:
            for mi in src.getmembers():
                leaf = mi.name.lstrip("./")
                if leaf in ("control", "md5sums") and mi.isreg():
                    body = src.extractfile(mi).read()
                    if leaf == "control":
                        body = newctl.encode()
                    else:
                        lines = []
                        for ln in body.decode().splitlines():
                            h, _, p = ln.partition("  ")
                            lines.append(f"{md5.get(p, h)}  {p}")
                        missing = set(md5) - {ln.partition("  ")[2] for ln in lines}
                        assert not missing, f"{self.pkg}: md5sums lacks {missing}"
                        body = ("\n".join(lines) + "\n").encode()
                    ni = tarfile.TarInfo(mi.name)
                    for a in ("mode", "uid", "gid", "uname", "gname", "mtime"):
                        setattr(ni, a, getattr(mi, a))
                    ni.size = len(body)
                    dst.addfile(ni, io.BytesIO(body))
                elif mi.isreg():
                    dst.addfile(mi, src.extractfile(mi))
                else:
                    dst.addfile(mi)
        ctl_body = sm._compress_like(self.cm["name"], buf.getvalue())

        members = []
        for m in self.members:
            if m is self.dm:
                members.append({"hdr": sm._hdr_size(m["hdr"], len(data_body)), "name": m["name"], "body": data_body})
            elif m is self.cm:
                members.append({"hdr": sm._hdr_size(m["hdr"], len(ctl_body)), "name": m["name"], "body": ctl_body})
            else:
                members.append(m)
        raw = sm.ar_build(members)
        if not signed:
            new_data = next(m for m in sm.ar_split(raw) if m["name"].startswith("data.tar"))["body"]
            assert new_data == self.dm["body"], f"{self.pkg}: data.tar changed on a control-only fix"
        arch = field(newctl, "Architecture")
        fn = f"{self.pkg}_{self.new_ver}_{arch}.deb"
        open(os.path.join(out_dir, fn), "wb").write(raw)
        return fn, hashlib.sha256(raw).hexdigest(), len(self.edits)


def verify_signed(d):
    """Edited file: entitlements unchanged, same signature slot layout, intended load commands."""
    base = os.listdir(d + "/orig")[0]
    o, s = f"{d}/orig/{base}", f"{d}/signed/{base}"
    eo = subprocess.run(["ldid", "-e", o], capture_output=True).stdout
    es = subprocess.run(["ldid", "-e", s], capture_output=True).stdout
    assert eo == es, f"{s}: entitlements changed"
    mo, ms = otool(f"{d}/mod/{base}"), otool(s)
    assert mo == ms, f"{s}: signing changed the load commands"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="dir holding the published debs")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "out", "loose-ends-20261025"))
    ap.add_argument("--work", default=None)
    ap.add_argument("--only", default="", help="comma list of packages (default: all)")
    args = ap.parse_args()
    out = os.path.abspath(args.out)
    work = os.path.abspath(args.work or tempfile.mkdtemp(prefix="loose-ends-"))
    shutil.rmtree(os.path.join(work, "sign"), ignore_errors=True)
    os.makedirs(os.path.join(work, "sign"))
    os.makedirs(out, exist_ok=True)
    only = [p for p in args.only.split(",") if p] or list(FIXES)

    plans = []
    for pkg in only:
        ship = FIXES[pkg][0]
        src = next((os.path.join(args.src, f) for f in os.listdir(args.src)
                    if f.startswith(f"{pkg}_{ship}_") and f.endswith(".deb")), None)
        assert src, f"{pkg} {ship}: no deb in {args.src}"
        p = Plan(pkg, src, work)
        p.prepare_machos()
        if p.ops and not p.edits:
            sys.exit(f"{pkg}: expected Mach-O edits, found nothing to change")
        plans.append(p)
        print(f"  planned {pkg:28} {p.ship_ver} -> {p.new_ver}  machos={len(p.edits)}")

    sign_root = os.path.join(work, "sign")
    if any(p.edits for p in plans):
        resign = os.path.join(HERE, "resign-like.sh")
        run("docker", "run", "--rm", "-v", f"{sign_root}:/w", "-v", f"{resign}:/resign-like.sh:ro",
            "--entrypoint", "bash", IMAGE, "/resign-like.sh", "container", "/w")
        run("bash", resign, "host", sign_root)
        for p in plans:
            for d in p.edits.values():
                if not os.path.exists(f"{d}/variant"):
                    sys.exit(f"{p.pkg}: no signer reproduces {open(d + '/path').read().strip()}")
                verify_signed(d)

    rows = []
    for p in plans:
        fn, sha, n = p.build(out)
        variants = sorted({open(d + "/variant").read().strip() for d in p.edits.values()})
        rows.append((p.pkg, p.new_ver, sha, fn,
                     p.note + (f" [{n} Mach-O re-signed: {', '.join(variants)}]" if n else " [data.tar unchanged]"),
                     os.path.basename(p.src)))
        print(f"  wrote   {fn}")

    with open(os.path.join(out, "FIXED.txt"), "w") as f:
        f.write("Procursus dependency audit fixes (docs/handoff/procursus-dependency-audit-2026-10-25.md),\n"
                "repacked from the published payloads by tools/repack-loose-ends-20261025.py.\n"
                "Nothing here is published. Each row supersedes the published deb named last.\n\n")
        f.write("package\tversion\tsha256\tfile\tchange\tsupersedes\n")
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"\n{len(rows)} debs in {out} (FIXED.txt); work dir {work}")


if __name__ == "__main__":
    main()
