#!/usr/bin/env python3
"""Repack debs whose intra-repo `Depends: foo (= V)` pins can no longer be satisfied.

Runs INSIDE procursus-xbuild (needs dpkg-deb). Mount the deb dir at /debs and feed
`<package>\t<current-version>` lines on stdin (take them from repo/Packages, so the
caller decides which deb is current rather than this script guessing).
MODE=plan (default) prints the rewrite; MODE=apply repacks.

WHY THIS EXISTS: x11/tools/repack-ios-marker.sh appended +ios1 to every upstream
port by rewriting only the `Version:` field. Packages built as a matched pair -- a
library and its -dev sibling, whose control templates both interpolate the same
@DEB_*_V@ -- came out of that pass with a bumped Version but a Depends still naming
the PRE-bump version, e.g. kf6-archive-dev 6.3.0+ios1 depending on kf6-archive
(= 6.3.0) when only 6.3.0+ios1 exists. That left 44 packages uninstallable.

The fix relaxes `=` to `>=` rather than re-pinning to the current version. An exact
pin re-breaks every time the runtime alone is rebuilt (that is how kwin-dev drifted
to +ios29 against kwin +ios33), and within one upstream version the +iosN suffix is
our packaging revision, not an API change. `>= <version it was built against>` is
the honest statement: these headers need at least that build.

ALL exact pins in a repacked deb are relaxed, not just the unsatisfiable one --
bumping gtk-3-bin while libgtk-3-dev still pinned it exactly would have traded one
broken package for another.
"""
import os
import re
import subprocess
import sys

DEBS = "/debs"
ARCH = "iphoneos-arm64"


def field(deb, name):
    out = subprocess.run(["dpkg-deb", "-f", deb, name], capture_output=True, text=True)
    return out.stdout.strip()


def bump(version):
    """6.3.0+ios1 -> 6.3.0+ios2; 1.2.3 -> 1.2.3+ios1."""
    m = re.search(r"\+ios(\d+)$", version)
    if m:
        return version[:m.start()] + f"+ios{int(m.group(1)) + 1}"
    return version + "+ios1"


def main():
    apply_ = os.environ.get("MODE") == "apply"
    count = 0
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        pkg, cur = line.split("\t")
        src = os.path.join(DEBS, f"{pkg}_{cur}_{ARCH}.deb")
        if not os.path.exists(src):
            print(f"  SKIP {pkg}: {os.path.basename(src)} not present", file=sys.stderr)
            continue
        deps = field(src, "Depends")
        if not re.search(r"\(\s*=\s*", deps):
            print(f"  SKIP {pkg} {cur}: no exact pins")
            continue
        new_v = bump(cur)
        new_deps = re.sub(r"\(\s*=\s*", "(>= ", deps)
        out = os.path.join(DEBS, f"{pkg}_{new_v}_{ARCH}.deb")
        if os.path.exists(out):
            print(f"  SKIP {pkg}: {new_v} already on disk", file=sys.stderr)
            continue
        print(f"  {pkg}: {cur} -> {new_v}")
        for d in re.findall(r"[^,]*\(\s*=\s*[^)]*\)", deps):
            d = d.strip()
            relaxed = re.sub(r"\(\s*=\s*", "(>= ", d)
            print("      %s  ->  %s" % (d, relaxed))
        if apply_:
            tmp = f"/tmp/repack-{pkg}"
            subprocess.run(["rm", "-rf", tmp], check=True)
            subprocess.run(["dpkg-deb", "-R", src, tmp], check=True)
            ctl = os.path.join(tmp, "DEBIAN", "control")
            text = open(ctl).read()
            text = re.sub(r"^Version: .*$", f"Version: {new_v}", text, count=1, flags=re.M)
            text = re.sub(r"^Depends: .*$", "Depends: " + new_deps, text, count=1, flags=re.M)
            open(ctl, "w").write(text)
            subprocess.run(["dpkg-deb", "-Zzstd", "--build", tmp, out],
                           check=True, capture_output=True)
            subprocess.run(["rm", "-rf", tmp], check=True)
            got_v, got_d = field(out, "Version"), field(out, "Depends")
            assert got_v == new_v, f"{pkg}: version not applied ({got_v})"
            assert not re.search(r"\(\s*=\s*", got_d), f"{pkg}: exact pin survived"
        count += 1
    print(f"--- {'repacked' if apply_ else 'planned'}: {count}")


if __name__ == "__main__":
    main()
