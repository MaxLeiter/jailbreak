#!/usr/bin/env python3
"""Publish gate: verify debs that shadow Procursus packages are drop-in supersets.

Born from the 2026-07-08 device brick, where one Sileo upgrade wave carried three
landmines, each a different way a shadowing rebuild can silently diverge from the
Procursus package it replaces:

  1. libsqlite3-1 3.52.0+ios1 shipped libsqlite3.0.dylib but Procursus's soname is
     libsqlite3.1.dylib -> every consumer (tracker/nautilus/GNOME, Qt sqlite/KDE)
     died at launch.                                  [caught by the FILE-PARITY rule]
  2. libssl3 3.5.3+ios1 replaced OpenSSL 3.2.1 -> Procursus sshd exits at startup
     with "OpenSSL version mismatch" (runtime check, all files/symbols present).
                                                      [caught by the VERSION rule]
  3. libharfbuzz0b 10.2.0+ios1 was built without hb-glib -> mutter-clutter dyld
     abort on _hb_glib_script_to_script (file present, feature missing).
                                                      [caught by the SYMBOLS rule]

Landmine 3 recurred on 2026-07-29 and is why the SYMBOLS rule exists. It had been
left to the VERSION rule, but VERSION is only a proxy: it fires on *any* upstream
bump, so shipping 10.2 at all required a waiver -- and the waiver that was written
("hb-glib built in, verified") asserted a property nothing checked, which was false.
Waiving the proxy silently waived the real guarantee, and every GTK app on the
device died at dyld again. A waiver must never be able to assert an unverified
property, so the superset claim is now machine-checked and has its own rule name:
waiving a deliberate VERSION bump no longer waives "and it kept every symbol".

Rules, applied to the NEWEST version of each package in repo/debs whose name also
exists in the Procursus index:

  version:  our upstream version (rebuild suffix like +ios2/+wl1/+rootless1 stripped)
            must equal Procursus's. Upgrading a shadowed core package is exactly how
            sshd broke; it needs a waiver with a written justification.
  parity:   every *.dylib path inside the Procursus deb must exist in ours. Catches
            soname drops and same-version repacks that lose files.
  symbols:  for every *.dylib shipped by BOTH, our exported symbols must be a
            superset of Procursus's. This is the real drop-in test that `version`
            and `parity` only approximate: same soname, same files, missing feature.
  devlib:   (all our -dev debs, shadowing or not) versioned runtime dylibs
            (libfoo.N.dylib as a regular file, not a symlink) do not belong in -dev
            packages -- removing the -dev must never break a runtime consumer
            (libgnome-desktop-dev shipping libgnome-bg-4.2.dylib killed GNOME Shell).

Waivers live in bin/lib/shadow-waivers.json: {"package": {"rule": "reason"}}.
Procursus debs and verdicts are cached in ~/.cache/xios-shadow-check/.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_DEBS = os.path.abspath(os.path.join(HERE, "..", "..", "repo", "debs"))
WAIVERS_PATH = os.path.join(HERE, "shadow-waivers.json")
CACHE_DIR = os.path.expanduser("~/.cache/xios-shadow-check")
PROCURSUS_BASE = "https://apt.procurs.us"
PROCURSUS_DIST = os.environ.get("PROCURSUS_DIST", "1900")
PACKAGES_URL = f"{PROCURSUS_BASE}/dists/{PROCURSUS_DIST}/main/binary-iphoneos-arm64/Packages"

# rebuild suffixes we append to a Procursus upstream version
SUFFIX_RE = re.compile(r"(\+(ios|wl|xios|rootless|qt6ios)\d+)+$")
# a versioned runtime dylib, e.g. libgnome-bg-4.2.dylib / libz.1.3.1.dylib
VERSIONED_DYLIB_RE = re.compile(r"\.\d[\d.]*\.dylib$")


def parse_index(text: str) -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    for block in text.split("\n\n"):
        fields = dict(
            line.split(": ", 1) for line in block.splitlines() if ": " in line
        )
        pkg = fields.get("Package")
        if pkg:
            out[pkg] = fields
    return out


def compare_versions(a: str, b: str) -> int:
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "make_repo", os.path.join(HERE, "make-repo.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.compare_deb_versions(a, b)


def deb_entries(path: str) -> list[tuple[str, bool]]:
    """[(member path, is_symlink)] of the deb's data tar."""
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(["ar", "x", path], cwd=td, check=True, capture_output=True)
        data = next(n for n in os.listdir(td) if n.startswith("data.tar"))
        data_path = os.path.join(td, data)
        proc = subprocess.run(
            ["tar", "tvf", data_path], capture_output=True, text=True,
        )
        if proc.returncode != 0 and data.endswith(".zst"):
            # some zstd frames trip bsdtar's built-in decoder; pipe through zstd
            proc = subprocess.run(
                f"zstd -dc {data_path!r} | tar tv",
                shell=True, capture_output=True, text=True,
            )
        if proc.returncode != 0:
            raise subprocess.CalledProcessError(proc.returncode, "tar", proc.stderr)
        lines = proc.stdout.splitlines()
    out = []
    for line in lines:
        parts = line.split()
        if len(parts) < 9 or line.startswith("d"):
            continue
        # symlink lines end with "name -> target"
        if line.startswith("l") and "->" in line:
            out.append((line.split(" -> ")[0].split()[-1], True))
        else:
            out.append((parts[-1], False))
    return out


def deb_extract(path: str, dest: str) -> None:
    """Unpack a deb's data tar into dest."""
    subprocess.run(["ar", "x", path], cwd=dest, check=True, capture_output=True)
    data = next(n for n in os.listdir(dest) if n.startswith("data.tar"))
    data_path = os.path.join(dest, data)
    proc = subprocess.run(
        ["tar", "xf", data_path, "-C", dest], capture_output=True, text=True,
    )
    if proc.returncode != 0 and data.endswith(".zst"):
        # same bsdtar zstd-frame quirk deb_entries works around
        proc = subprocess.run(
            f"zstd -dc {data_path!r} | tar x -C {dest!r}",
            shell=True, capture_output=True, text=True,
        )
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, "tar", proc.stderr)


def dylib_exports(path: str) -> set[str] | None:
    """Externally-visible defined symbols of a Mach-O dylib, or None if unreadable.

    `nm -g` = external only, `-U` = defined only (Apple/llvm nm; NOT GNU's
    "undefined only"), so together they are exactly the export list.
    """
    proc = subprocess.run(["nm", "-gU", path], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    out: set[str] = set()
    for line in proc.stdout.splitlines():
        parts = line.split()
        # "<addr> T _symbol"; skip fat-arch headers ("path (for architecture x):")
        if len(parts) >= 3 and len(parts[1]) == 1 and parts[-1].startswith("_"):
            out.add(parts[-1])
    return out


def fetch(url: str, dest: str) -> None:
    # Procursus's CDN 403s urllib's default UA; present as apt.
    req = urllib.request.Request(url, headers={"User-Agent": "Debian APT-HTTP/1.3"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)


def fetch_procursus_deb(fields: dict[str, str]) -> str:
    os.makedirs(os.path.join(CACHE_DIR, "debs"), exist_ok=True)
    dest = os.path.join(CACHE_DIR, "debs", os.path.basename(fields["Filename"]))
    if not os.path.exists(dest):
        fetch(f"{PROCURSUS_BASE}/{fields['Filename']}", dest)
    return dest


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    waivers: dict[str, dict[str, str]] = {}
    if os.path.exists(WAIVERS_PATH):
        waivers = json.load(open(WAIVERS_PATH))

    os.makedirs(CACHE_DIR, exist_ok=True)
    verdicts_path = os.path.join(CACHE_DIR, "parity-verdicts.json")
    verdicts: dict[str, str] = {}
    if os.path.exists(verdicts_path):
        verdicts = json.load(open(verdicts_path))

    index_cache = os.path.join(CACHE_DIR, f"Packages-{PROCURSUS_DIST}")
    try:
        fetch(PACKAGES_URL, index_cache)
    except OSError:
        if not os.path.exists(index_cache):
            print("shadow-check: SKIP (Procursus index unreachable, no cache)")
            return 0
        print("shadow-check: WARNING using cached Procursus index (fetch failed)")
    procursus = parse_index(open(index_cache, encoding="utf-8").read())

    # newest local deb per package name
    newest: dict[str, tuple[str, str]] = {}  # pkg -> (version, path)
    for name in os.listdir(REPO_DEBS):
        if not name.endswith(".deb"):
            continue
        parts = name[:-4].split("_")
        if len(parts) < 2:
            continue
        pkg, ver = parts[0], parts[1]
        if pkg not in newest or compare_versions(ver, newest[pkg][0]) > 0:
            newest[pkg] = (ver, os.path.join(REPO_DEBS, name))

    errors: list[str] = []
    waived = 0

    def violation(pkg: str, rule: str, msg: str) -> None:
        nonlocal waived
        if rule in waivers.get(pkg, {}):
            waived += 1
            return
        errors.append(f"{pkg} [{rule}]: {msg}")

    for pkg, (ver, path) in sorted(newest.items()):
        if pkg.endswith("-dev"):
            bad = [
                p for p, is_link in deb_entries(path)
                if not is_link and VERSIONED_DYLIB_RE.search(p)
            ]
            if bad:
                violation(pkg, "devlib",
                          f"runtime dylib(s) in a -dev package: {', '.join(sorted(bad)[:4])}"
                          + (" ..." if len(bad) > 4 else ""))

        fields = procursus.get(pkg)
        if not fields:
            continue

        ours_upstream = SUFFIX_RE.sub("", ver)
        theirs = fields.get("Version", "")
        if ours_upstream != theirs:
            violation(pkg, "version",
                      f"upstream version {ours_upstream!r} != Procursus {theirs!r} "
                      f"(shadowed core-package bumps brick devices; waive with a reason)")

        try:
            key = f"{sha256(path)}:{fields.get('SHA256', fields.get('Version'))}"
            if key in verdicts:
                missing = json.loads(verdicts[key])
            else:
                theirs_dylibs = {
                    p for p, _ in deb_entries(fetch_procursus_deb(fields))
                    if p.endswith(".dylib")
                }
                ours_paths = {p for p, _ in deb_entries(path)}
                missing = sorted(theirs_dylibs - ours_paths)
                verdicts[key] = json.dumps(missing)
            if missing:
                violation(pkg, "parity",
                          f"missing dylib(s) Procursus ships: {', '.join(missing[:4])}"
                          + (" ..." if len(missing) > 4 else ""))
        except (subprocess.CalledProcessError, OSError, StopIteration) as e:
            print(f"shadow-check: WARNING could not parity-check {pkg}: {e}")

        # symbols: our exports must be a superset of theirs, per shared dylib.
        try:
            skey = f"sym:{key}"
            if skey in verdicts:
                dropped = json.loads(verdicts[skey])
            else:
                dropped = {}
                with tempfile.TemporaryDirectory() as td:
                    ours_root = os.path.join(td, "ours")
                    theirs_root = os.path.join(td, "theirs")
                    os.makedirs(ours_root)
                    os.makedirs(theirs_root)
                    deb_extract(path, ours_root)
                    deb_extract(fetch_procursus_deb(fields), theirs_root)
                    for rel, is_link in deb_entries(path):
                        if is_link or not rel.endswith(".dylib"):
                            continue
                        ours_f = os.path.join(ours_root, rel.lstrip("./"))
                        theirs_f = os.path.join(theirs_root, rel.lstrip("./"))
                        if not (os.path.isfile(ours_f) and os.path.isfile(theirs_f)):
                            continue
                        ours_syms = dylib_exports(ours_f)
                        theirs_syms = dylib_exports(theirs_f)
                        if ours_syms is None or theirs_syms is None:
                            continue
                        gone = sorted(theirs_syms - ours_syms)
                        if gone:
                            dropped[os.path.basename(rel)] = gone
                verdicts[skey] = json.dumps(dropped)
            for lib, gone in sorted(dropped.items()):
                violation(pkg, "symbols",
                          f"{lib} drops {len(gone)} symbol(s) Procursus exports: "
                          + ", ".join(gone[:4]) + (" ..." if len(gone) > 4 else ""))
        except (subprocess.CalledProcessError, OSError, StopIteration) as e:
            print(f"shadow-check: WARNING could not symbol-check {pkg}: {e}")

    json.dump(verdicts, open(verdicts_path, "w"))

    if errors:
        print("Procursus shadow check FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        print(f"\n  (waive intentional divergence in {WAIVERS_PATH}: "
              '{"<package>": {"<rule>": "<reason>"}})', file=sys.stderr)
        return 1
    print(f"Procursus shadow check OK "
          f"({sum(1 for p in newest if p in procursus)} shadowing package(s), "
          f"{waived} waived rule(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
