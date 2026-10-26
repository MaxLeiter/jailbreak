#!/usr/bin/env python3
"""Repack the staged KDE 6.7 debs with the device-run-1 packaging fixes, without rebuilding.

Runs INSIDE the procursus-xbuild container (dpkg-deb, ldid, python3); use repack-kde67-run1.sh
to launch it. The fixes are the same ones the recipes now make (see the commit that adds this file
and docs/handoff/kde-kf6.md "Device run 1"), applied to the already built payloads:

  plasma-mobile      drop the brightnesscontrolplugin QML stand-in (powerdevil owns the module)
  powerdevil         Replaces plasma-mobile (<< 6.7.5+ios24)
  kate               drop kio_kateexec.so + bin/exec_inspect.sh (kwrite owns them)
  kwrite             Replaces kate (<< 26.08.1+ios2)
  libdisplay-info-dev Replaces libdisplay-info1 (<< 0.2.0)  (+ libdisplay-info2 follows the version)
  qt6-wayland(-dev)  a real file instead of directories only (dpkg drops dirs-only packages)
  *-dev with no files  same marker file (kscreen, plasma-desktop, plasma-mobile, plasma-nano, plasma-pa, systemsettings)
  kf6-breeze-icons   ldid-sign libKF6BreezeIcons (it shipped with no signature)
  plasma-desktop     folder view defaults to ~/Desktop (recipes/plasma-desktop-ios-qml-fixes.sh)
  xios-kde           0.1.24, pins follow

Every output gets a new +iosN so its filename differs from the staged deb.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys

STAGED = os.environ.get("STAGED", "/staged")
OUT = os.environ.get("OUT", "/out")
WORK = os.environ.get("WORK", "/work")
REPO_X11 = os.environ.get("REPO_X11", "/repo/x11")
ARCH = "iphoneos-arm64"
JB = "var/jb"


def run(*a, **k):
    subprocess.run(list(a), check=True, **k)


class Ctl:
    """Debian control file, order preserving, continuation lines kept with their field."""

    def __init__(self, text):
        self.fields = []  # [key, value] ; value may contain "\n " continuations
        for line in text.rstrip("\n").split("\n"):
            if line[:1] in (" ", "\t") and self.fields:
                self.fields[-1][1] += "\n" + line
            else:
                k, _, v = line.partition(":")
                self.fields.append([k, v.strip()])

    def get(self, k):
        for f in self.fields:
            if f[0] == k:
                return f[1]
        return None

    def set(self, k, v, after=None):
        for f in self.fields:
            if f[0] == k:
                f[1] = v
                return
        if after:
            for i, f in enumerate(self.fields):
                if f[0] == after:
                    self.fields.insert(i + 1, [k, v])
                    return
        self.fields.append([k, v])

    def text(self):
        return "".join("%s: %s\n" % (k, v) for k, v in self.fields)


class Pkg:
    def __init__(self, name, oldver):
        self.name = name
        self.oldver = oldver
        self.dir = os.path.join(WORK, name)
        shutil.rmtree(self.dir, ignore_errors=True)
        deb = os.path.join(STAGED, "%s_%s_%s.deb" % (name, oldver, ARCH))
        run("dpkg-deb", "-R", deb, self.dir)
        self.ctl = Ctl(open(os.path.join(self.dir, "DEBIAN", "control")).read())
        assert self.ctl.get("Package") == name and self.ctl.get("Version") == oldver, (name, oldver)
        self.newver = oldver

    def path(self, rel):
        return os.path.join(self.dir, rel)

    def version(self, v):
        self.newver = v
        self.ctl.set("Version", v)

    def depends_sub(self, old, new):
        d = self.ctl.get("Depends")
        assert d and old in d, (self.name, old, d)
        self.ctl.set("Depends", d.replace(old, new))

    def replaces_add(self, rel):
        cur = self.ctl.get("Replaces")
        self.ctl.set("Replaces", (cur + ", " if cur else "") + rel, after="Depends")

    def rm(self, rel):
        p = self.path(rel)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        elif os.path.lexists(p):
            os.remove(p)
        else:
            raise SystemExit("%s: expected %s to exist" % (self.name, rel))

    def rm_empty_dirs(self):
        for dp, dn, fn in os.walk(self.dir, topdown=False):
            if dp != self.dir and not os.listdir(dp) and os.path.basename(dp) != "DEBIAN":
                os.rmdir(dp)

    def write(self, rel, text, mode=0o644):
        p = self.path(rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
        os.chmod(p, mode)

    def has_regular_files(self):
        for dp, dn, fn in os.walk(self.dir):
            if os.path.relpath(dp, self.dir).startswith("DEBIAN"):
                continue
            if fn or any(os.path.islink(os.path.join(dp, d)) for d in dn):
                return True
        return False

    def pack(self):
        # md5sums (regular files only, dpkg layout) and Installed-Size (du -sk, as PACK computes it)
        sums = []
        for dp, dn, fn in os.walk(self.dir):
            dn.sort()
            if os.path.relpath(dp, self.dir) == ".":
                dn[:] = [d for d in dn if d != "DEBIAN"]
            for n in sorted(fn):
                p = os.path.join(dp, n)
                if os.path.islink(p):
                    continue
                h = hashlib.md5()
                with open(p, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                sums.append("%s  %s\n" % (h.hexdigest(), os.path.relpath(p, self.dir)))
        if sums:
            open(self.path("DEBIAN/md5sums"), "w").write("".join(sums))
        elif os.path.exists(self.path("DEBIAN/md5sums")):
            os.remove(self.path("DEBIAN/md5sums"))
        du = subprocess.run(["du", "-sk", "--exclude=DEBIAN", self.dir], check=True, capture_output=True, text=True)
        self.ctl.set("Installed-Size", du.stdout.split()[0])
        open(self.path("DEBIAN/control"), "w").write(self.ctl.text())
        run("chown", "-R", "0:0", self.dir)
        out = os.path.join(OUT, "%s_%s_%s.deb" % (self.name, self.newver, ARCH))
        if os.path.exists(out):
            os.remove(out)
        run("dpkg-deb", "-Zzstd", "--build", self.dir, out, stdout=subprocess.DEVNULL)
        print("packed", os.path.basename(out))
        return out


def marker_for_empty_dev(p):
    if p.has_regular_files():
        return
    p.write(
        "%s/usr/share/xios-empty-dev/%s.txt" % (JB, p.name),
        "%s has no headers or CMake files of its own. This file keeps the package from being all "
        "directories, which dpkg treats as completely replaced and drops on install.\n" % p.name,
    )


def main():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    pins = {}  # package -> new version, for the xios-kde pins

    # ---- plasma-mobile / powerdevil: one owner for brightnesscontrolplugin ----
    p = Pkg("plasma-mobile", "6.7.5+ios23")
    p.rm(JB + "/usr/lib/qt6/qml/org/kde/plasma/private/brightnesscontrolplugin")
    p.version("6.7.5+ios24")
    p.pack()
    pins["plasma-mobile"] = p.newver
    p = Pkg("plasma-mobile-dev", "6.7.5+ios23")
    p.depends_sub("plasma-mobile (= 6.7.5+ios23)", "plasma-mobile (= 6.7.5+ios24)")
    marker_for_empty_dev(p)
    p.version("6.7.5+ios24")
    p.pack()

    p = Pkg("powerdevil", "6.7.5+ios2")
    p.replaces_add("plasma-mobile (<< 6.7.5+ios24)")
    p.version("6.7.5+ios3")
    p.pack()
    pins["powerdevil"] = p.newver

    # ---- kate / kwrite: kwrite owns kio_kateexec + exec_inspect.sh ----
    p = Pkg("kate", "26.08.1+ios1")
    p.rm(JB + "/usr/lib/qt6/plugins/kf6/kio/kio_kateexec.so")
    p.rm(JB + "/usr/lib/qt6/plugins/plugins/kf6/kio/kio_kateexec.so")
    p.rm(JB + "/usr/bin/exec_inspect.sh")
    p.rm_empty_dirs()
    p.depends_sub("kwrite (>= 24.08.0+ios2)", "kwrite (>= 26.08.1+ios2)")
    p.version("26.08.1+ios2")
    p.pack()
    pins["kate"] = p.newver
    p = Pkg("kwrite", "26.08.1+ios1")
    p.replaces_add("kate (<< 26.08.1+ios2)")
    p.version("26.08.1+ios2")
    p.pack()
    pins["kwrite"] = p.newver

    # ---- libdisplay-info: the unversioned dylib symlink is -dev's; -dev Replaces the 0.1.1 shim ----
    p = Pkg("libdisplay-info2", "0.2.0+ios1")
    p.version("0.2.0+ios2")
    p.pack()
    pins["libdisplay-info2"] = p.newver
    p = Pkg("libdisplay-info-dev", "0.2.0+ios1")
    p.depends_sub("libdisplay-info2 (= 0.2.0+ios1)", "libdisplay-info2 (= 0.2.0+ios2)")
    p.replaces_add("libdisplay-info1 (<< 0.2.0)")
    p.version("0.2.0+ios2")
    p.pack()

    # ---- qt6-wayland(-dev): transitional packages with a real file ----
    p = Pkg("qt6-wayland", "6.10.3-1+ios1")
    p.write(JB + "/usr/share/xios-transitional/qt6-wayland.txt",
            "Transitional: the Qt Wayland client now ships in qt6-base.\n")
    p.depends_sub("qt6-base (>= 6.10)", "qt6-base (>= 6.10.3)")
    p.version("6.10.3-1+ios2")
    p.pack()
    pins["qt6-wayland"] = p.newver
    p = Pkg("qt6-wayland-dev", "6.10.3-1+ios1")
    p.write(JB + "/usr/share/xios-transitional/qt6-wayland-dev.txt",
            "Transitional: the Qt Wayland client headers now ship in qt6-base-dev.\n")
    p.depends_sub("qt6-wayland (= 6.10.3-1+ios1)", "qt6-wayland (= 6.10.3-1+ios2)")
    p.depends_sub("qt6-base-dev (>= 6.10)", "qt6-base-dev (>= 6.10.3)")
    p.version("6.10.3-1+ios2")
    p.pack()

    # ---- kf6-breeze-icons: sign the dylib the recipe never signed ----
    p = Pkg("kf6-breeze-icons", "6.30.0+ios1")
    dylib = p.path(JB + "/usr/lib/libKF6BreezeIcons.6.30.0.dylib")
    assert os.path.isfile(dylib) and not os.path.islink(dylib)
    # Same signature the SIGN macro gives its siblings: Procursus ldid (sha256 only), ad-hoc flag, no entitlements.
    run("/usr/local/bin/ldid", "-Cadhoc", "-S", dylib)
    p.version("6.30.0+ios2")
    p.pack()
    pins["kf6-breeze-icons"] = p.newver

    # ---- plasma-desktop: folder view default ----
    p = Pkg("plasma-desktop", "6.7.5+ios10")
    run("bash", os.path.join(REPO_X11, "linux-build/recipes/plasma-desktop-ios-qml-fixes.sh"), p.dir)
    p.version("6.7.5+ios11")
    p.pack()
    pins["plasma-desktop"] = p.newver
    p = Pkg("plasma-desktop-dev", "6.7.5+ios10")
    p.depends_sub("plasma-desktop (= 6.7.5+ios10)", "plasma-desktop (= 6.7.5+ios11)")
    marker_for_empty_dev(p)
    p.version("6.7.5+ios11")
    p.pack()

    # ---- remaining runtime/dev pairs whose -dev is an empty (dropped) package ----
    for name, old, new in (("kscreen", "6.7.5+ios2", "6.7.5+ios3"),
                           ("plasma-nano", "6.7.5+ios3", "6.7.5+ios4"),
                           ("plasma-pa", "6.7.5+ios2", "6.7.5+ios3"),
                           ("systemsettings", "6.7.5+ios8", "6.7.5+ios9")):
        p = Pkg(name, old)
        p.version(new)
        p.pack()
        p = Pkg(name + "-dev", old)
        p.depends_sub("%s (= %s)" % (name, old), "%s (= %s)" % (name, new))
        marker_for_empty_dev(p)
        assert p.has_regular_files()
        p.version(new)
        p.pack()

    # ---- xios-kde: pins ----
    p = Pkg("xios-kde", "0.1.23")
    dep = p.ctl.get("Depends")
    for name, newver in pins.items():
        m = re.search(r"(?<![\w.+-])%s \(>= ([^)]+)\)" % re.escape(name), dep)
        assert m, "no pin for %s in xios-kde" % name
        dep = dep[:m.start(1)] + newver + dep[m.end(1):]
    p.ctl.set("Depends", dep)
    p.version("0.1.24")
    p.pack()
    print("pins:", pins)


if __name__ == "__main__":
    main()
