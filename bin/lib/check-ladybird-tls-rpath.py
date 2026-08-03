#!/usr/bin/env python3
"""Publish gate: Ladybird's @rpath OpenSSL must resolve to ladybird-tls, not base.

Born from ladybird-wayland 0.1.0+wl4, which shipped and could not start a renderer.

Ladybird needs OpenSSL >= 3.5 (`EVP_PKEY_sign_message_init`). Base Procursus ships
3.2.1, and deliberately keeps it: a base libssl3 3.5.x once broke sshd and apt on
device, which is the whole reason the private stack is vendored as `ladybird-tls`
under `usr/lib/ladybird-tls` where it shadows nothing.

That vendoring only works if Ladybird's binaries *find* it. The wayland flavor links
`@rpath/libcrypto.3.dylib`, so `packages/ladybird-wayland/build.sh:prepend_tls_rpath`
puts `@executable_path/../lib/ladybird-tls` ahead of every other LC_RPATH. In wl4 the
shipped binaries carried only `@executable_path/../lib`, so `libcrypto` resolved to the
base 3.2.1 and every helper died at dyld:

    Symbol not found: _EVP_PKEY_sign_message_init
      Referenced from: .../usr/libexec/WebContent
      Expected in:     .../usr/lib/libcrypto.3.dylib

The packaging script was already correct when wl4 was cut (the rpath fix landed in
879cfd7c, the version bump in 1a5655b6) and it fails closed per binary -- so the fault
was never the logic, it was that a deb reached users without anything re-checking the
property on the *artifact*. That is the gap this gate closes: every other Ladybird
guarantee is verified at build time, on the machine that happened to run the build.

Note the failure mode is a dead browser, not a silent downgrade to weaker crypto: the
missing symbol is a hard dyld abort. Fails closed, but shipped broken.

The `.app` flavor is structurally immune and is checked anyway: it links
`@executable_path/lib/libcrypto.3.dylib` by path and bundles 3.5.3 inside the bundle,
so no rpath search is involved.

Usage:
    check-ladybird-tls-rpath.py [--debs DIR]     # default: <repo>/repo/debs
    check-ladybird-tls-rpath.py --self-test      # logic only, no debs needed
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DEBS = REPO_ROOT / "repo" / "debs"

# Dylibs whose provider actually matters here.
OPENSSL_LEAVES = ("libcrypto.3.dylib", "libssl.3.dylib")

# Directories, as they appear after @executable_path expansion relative to the install
# prefix, that are known to provide an OpenSSL and which one.
#   good: the vendored 3.5 stack shipped by the ladybird-tls package
#   base: Procursus's 3.2.1, pinned there on purpose -- resolving here is the bug
TLS_DIR_SUFFIX = "/usr/lib/ladybird-tls"
BASE_DIR_SUFFIX = "/usr/lib"


def rpath_verdict(loads: list[str], rpaths: list[str], binary_path: str,
                  shipped: set[str]) -> tuple[str, str]:
    """Decide how this binary resolves its OpenSSL. Pure: no filesystem access.

    loads       -- LC_LOAD_DYLIB names, e.g. ["@rpath/libcrypto.3.dylib", ...]
    rpaths      -- LC_RPATH entries, IN ORDER (dyld takes the first that resolves)
    binary_path -- path of the binary inside the package, e.g. "/var/jb/usr/libexec/WebContent"
    shipped     -- every file path the package ships, used to resolve @executable_path

    Returns (verdict, detail) where verdict is one of:
      "ok"            resolves to ladybird-tls, or does not use @rpath for OpenSSL
      "base"          resolves to the base 3.2.1 -- the wl4 bug
      "unresolved"    no rpath resolves to any OpenSSL at all
    """
    if not any(ld.startswith("@rpath/") and ld.rsplit("/", 1)[-1] in OPENSSL_LEAVES
               for ld in loads):
        # Linked by path (the .app flavor) or does not link OpenSSL. Nothing to search.
        return "ok", "no @rpath OpenSSL dependency"

    bindir = os.path.dirname(binary_path)
    for rp in rpaths:
        if rp.startswith("@executable_path"):
            cand = os.path.normpath(rp.replace("@executable_path", bindir, 1))
        elif rp.startswith("@loader_path"):
            cand = os.path.normpath(rp.replace("@loader_path", bindir, 1))
        elif rp.startswith("@"):
            continue  # @rpath-in-rpath and friends: not something we ship
        else:
            cand = os.path.normpath(rp)

        # Does this directory provide an OpenSSL? Either the package ships it, or it is
        # a well-known external directory. The base prefix is provided by Procursus and
        # will not be in `shipped`, so match it by suffix.
        provides = any(f"{cand}/{leaf}" in shipped for leaf in OPENSSL_LEAVES)
        if provides or cand.endswith(TLS_DIR_SUFFIX):
            if cand.endswith(TLS_DIR_SUFFIX):
                return "ok", f"resolves to {cand}"
            return "ok", f"resolves to {cand} (shipped in-package)"
        if cand.endswith(BASE_DIR_SUFFIX):
            return "base", (f"first resolving rpath is {cand} -- that is Procursus "
                            f"OpenSSL 3.2.1; ladybird-tls must come first")
    return "unresolved", f"no LC_RPATH resolves an OpenSSL (rpaths: {rpaths or 'none'})"


def otool_loads_and_rpaths(path: Path) -> tuple[list[str], list[str]]:
    out = subprocess.run(["otool", "-l", str(path)], capture_output=True, text=True).stdout
    loads, rpaths = [], []
    # LC_LOAD_DYLIB / LC_RPATH blocks both carry a "name"/"path" line with an offset.
    for block in out.split("Load command")[1:]:
        if "LC_LOAD_DYLIB" in block or "LC_LOAD_WEAK_DYLIB" in block:
            m = re.search(r"^\s*name (.+?) \(offset", block, re.M)
            if m:
                loads.append(m.group(1).strip())
        elif "LC_RPATH" in block:
            m = re.search(r"^\s*path (.+?) \(offset", block, re.M)
            if m:
                rpaths.append(m.group(1).strip())
    return loads, rpaths


MH_EXECUTE = 0x2


def macho_filetype(path: Path) -> int | None:
    """Mach-O filetype, or None if this is not a thin little-endian Mach-O.

    Only MH_EXECUTE is worth checking here -- see check_deb for why a dylib is not.
    """
    try:
        with open(path, "rb") as fh:
            head = fh.read(16)
    except OSError:
        return None
    if len(head) < 16 or head[:4] not in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        return None
    return int.from_bytes(head[12:16], "little")


def deb_version_key(deb: Path) -> tuple:
    """Sort key from the filename's version field (name_VERSION_arch.deb).

    Naturally ordered so 0.1.0+wl5 > 0.1.0+wl4 > 0.1.0+wl2, and 0.1.25 > 0.1.9.
    mtime is NOT a version: cloning or re-staging a pool rewrites timestamps and would
    silently pick an older build as "the one that ships".
    """
    parts = deb.name.split("_")
    version = parts[1] if len(parts) > 2 else ""
    return tuple(int(t) if t.isdigit() else t
                 for t in re.split(r"(\d+)", version))


def newest_ladybird_debs(debs_dir: Path) -> list[Path]:
    """Newest *version* of each ladybird-* deb -- that is the one the index will carry."""
    by_pkg: dict[str, Path] = {}
    for deb in sorted(debs_dir.glob("ladybird-*.deb")):
        pkg = deb.name.split("_", 1)[0]
        if pkg not in by_pkg or deb_version_key(deb) > deb_version_key(by_pkg[pkg]):
            by_pkg[pkg] = deb
    return sorted(by_pkg.values())


def check_deb(deb: Path) -> list[str]:
    failures: list[str] = []
    tmp = Path(tempfile.mkdtemp(prefix="tlsrpath."))
    try:
        # Absolute: `ar` runs with cwd=tmp, so a relative --debs path would not resolve.
        subprocess.run(["ar", "x", str(deb.resolve())], cwd=tmp, check=True,
                       capture_output=True)
        data = next((p for p in tmp.iterdir() if p.name.startswith("data.tar")), None)
        if data is None:
            return [f"{deb.name}: no data.tar member"]
        root = tmp / "x"
        root.mkdir()
        subprocess.run(["tar", "-xf", str(data), "-C", str(root)], check=True,
                       capture_output=True)

        shipped = {"/" + str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()}
        for p in sorted(root.rglob("*")):
            if not p.is_file() or p.is_symlink():
                continue
            # EXECUTABLES ONLY, and that is a correctness requirement, not a shortcut.
            # `@executable_path` in a dylib means the directory of whatever executable
            # loaded it -- not the dylib's own directory. Expanding it against the dylib
            # gives a wrong answer, which is exactly what happened on the first run of
            # this gate: ladybird-tls's own libssl.3.dylib (which links
            # @rpath/libcrypto.3.dylib) resolved to "/var/jb/usr/lib" and blocked a
            # perfectly good publish. dyld searches the LC_RPATHs of the loading
            # executable, so the executable is where the property is decidable.
            if macho_filetype(p) != MH_EXECUTE:
                continue
            inpkg = "/" + str(p.relative_to(root))
            loads, rpaths = otool_loads_and_rpaths(p)
            verdict, detail = rpath_verdict(loads, rpaths, inpkg, shipped)
            if verdict != "ok":
                failures.append(f"{deb.name}: {inpkg}: {verdict}: {detail}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return failures


def self_test() -> int:
    """The wl4 regression and its fix, plus the shapes that must stay passing."""
    wc = "/var/jb/usr/libexec/WebContent"
    openssl_loads = ["@rpath/libcrypto.3.dylib", "@rpath/libssl.3.dylib"]
    cases = [
        ("wl4 as shipped (the bug)", openssl_loads, ["@executable_path/../lib"], wc, set(), "base"),
        ("wl4 with the rpath prepended (the fix)", openssl_loads,
         ["@executable_path/../lib/ladybird-tls", "@executable_path/../lib"], wc, set(), "ok"),
        ("tls rpath present but ordered last", openssl_loads,
         ["@executable_path/../lib", "@executable_path/../lib/ladybird-tls"], wc, set(), "base"),
        ("no rpaths at all", openssl_loads, [], wc, set(), "unresolved"),
        (".app flavor: linked by path, bundles its own",
         ["@executable_path/lib/libcrypto.3.dylib"], ["@executable_path/lib"],
         "/var/jb/Applications/Ladybird.app/WebContent", set(), "ok"),
        ("in-package openssl found via a shipped file",
         openssl_loads, ["@executable_path/lib"],
         "/var/jb/Applications/Ladybird.app/WebContent",
         {"/var/jb/Applications/Ladybird.app/lib/libcrypto.3.dylib"}, "ok"),
        ("binary that does not use OpenSSL", ["@rpath/libfoo.dylib"],
         ["@executable_path/../lib"], wc, set(), "ok"),
    ]
    bad = 0
    for name, loads, rpaths, path, shipped, want in cases:
        got, detail = rpath_verdict(loads, rpaths, path, shipped)
        ok = got == want
        bad += not ok
        print(f"{'ok   ' if ok else 'FAIL '} {name}: got={got} want={want}"
              + ("" if ok else f"  ({detail})"))

    # Version selection: mtime is not a version. Cloning a deb pool rewrites
    # timestamps, and picking the wrong deb means gating a build that will not ship.
    vcases = [
        ("wl5 beats wl4/wl3/wl2",
         ["ladybird-wayland_0.1.0+wl2_iphoneos-arm64.deb",
          "ladybird-wayland_0.1.0+wl4_iphoneos-arm64.deb",
          "ladybird-wayland_0.1.0+wl5_iphoneos-arm64.deb",
          "ladybird-wayland_0.1.0+wl3_iphoneos-arm64.deb"],
         "ladybird-wayland_0.1.0+wl5_iphoneos-arm64.deb"),
        ("0.1.25 beats 0.1.9 (not a string compare)",
         ["ladybird-app_0.1.9+ios1_iphoneos-arm64.deb",
          "ladybird-app_0.1.25+ios1_iphoneos-arm64.deb"],
         "ladybird-app_0.1.25+ios1_iphoneos-arm64.deb"),
    ]
    for name, names, want in vcases:
        got = max(names, key=lambda n: deb_version_key(Path(n)))
        ok = got == want
        bad += not ok
        print(f"{'ok   ' if ok else 'FAIL '} {name}: picked {got}")

    print("\nall passed" if not bad else f"\n{bad} case(s) failed")
    return 1 if bad else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--debs", type=Path, default=DEFAULT_DEBS)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if not shutil.which("otool"):
        print("check-ladybird-tls-rpath: otool not found; skipping (host gate only)")
        return 0
    if not args.debs.is_dir():
        print(f"check-ladybird-tls-rpath: no {args.debs}; nothing to check")
        return 0

    debs = newest_ladybird_debs(args.debs)
    if not debs:
        print("check-ladybird-tls-rpath: no ladybird-* debs staged; nothing to check")
        return 0

    failures: list[str] = []
    for deb in debs:
        failures += check_deb(deb)

    if failures:
        print("ERROR: Ladybird binaries would not resolve OpenSSL 3.5 at runtime.\n", file=sys.stderr)
        for f in failures:
            print(f"  {f}", file=sys.stderr)
        print("\n  Every helper dies at dyld with:\n"
              "    Symbol not found: _EVP_PKEY_sign_message_init\n"
              "  Rebuild the package so prepend_tls_rpath runs "
              "(packages/ladybird-wayland/build.sh); do not hand-edit the deb.\n",
              file=sys.stderr)
        return 1

    print(f"check-ladybird-tls-rpath: ok ({len(debs)} ladybird deb(s) resolve ladybird-tls)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
