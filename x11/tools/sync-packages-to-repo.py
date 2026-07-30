#!/usr/bin/env python3
"""Copy selected X11 packages from x11/linux-build/out/ to repo/debs/.

Usage:
    x11/tools/sync-packages-to-repo.py
    x11/tools/sync-packages-to-repo.py --only iosc,xios-session
    x11/tools/sync-packages-to-repo.py --apply --only iosc,xios-session

The command is deliberately additive:

* dry-run is the default;
* applying requires both --apply and an explicit --only package list;
* existing repo/debs files are never removed or overwritten;
* linux-build/out is never pruned.

Published .deb URLs are immutable, and linux-build/out is shared build evidence.
Pruning either tree does not belong in a package-copy helper.
"""

import argparse
import filecmp
import functools
import os
import re
import shutil
from collections import defaultdict

try:
    import apt_pkg as _apt_pkg
    _apt_pkg.init_system()
except Exception:
    _apt_pkg = None


def _order_char(ch):
    if not ch:
        return 0
    if ch == "~":
        return -1
    if ch.isalpha():
        return ord(ch)
    return ord(ch) + 256


def _verrevcmp(a, b):
    ia = ib = 0
    la, lb = len(a), len(b)
    while ia < la or ib < lb:
        while (ia < la and not a[ia].isdigit()) or (ib < lb and not b[ib].isdigit()):
            ca = a[ia] if ia < la and not a[ia].isdigit() else ""
            cb = b[ib] if ib < lb and not b[ib].isdigit() else ""
            oa, ob = _order_char(ca), _order_char(cb)
            if oa != ob:
                return -1 if oa < ob else 1
            ia += 1 if ca else 0
            ib += 1 if cb else 0
        while ia < la and a[ia] == "0":
            ia += 1
        while ib < lb and b[ib] == "0":
            ib += 1
        enda = ia
        while enda < la and a[enda].isdigit():
            enda += 1
        endb = ib
        while endb < lb and b[endb].isdigit():
            endb += 1
        lena, lenb = enda - ia, endb - ib
        if lena != lenb:
            return -1 if lena < lenb else 1
        if a[ia:enda] != b[ib:endb]:
            return -1 if a[ia:enda] < b[ib:endb] else 1
        ia, ib = enda, endb
    return 0


def version_compare(a, b):
    """dpkg version-comparison semantics. Returns <0 / 0 / >0.

    Prefers apt_pkg's libapt implementation when importable; otherwise uses the
    vendored dpkg algorithm above. A naive lexicographic string sort is wrong
    here — e.g. "+ios9" sorts *after* "+ios10", and "-3+ios1" vs "-4+ios1" can
    tie-break wrong — which is what made the newest version selection pick a
    stale deb once versions crossed a single->double digit boundary.
    """
    if _apt_pkg is not None:
        return _apt_pkg.version_compare(a, b)

    def split(v):
        epoch, rest = v.split(":", 1) if ":" in v else ("0", v)
        upstream, revision = rest.rsplit("-", 1) if "-" in rest else (rest, "0")
        try:
            epoch_i = int(epoch)
        except ValueError:
            epoch_i = 0
        return epoch_i, upstream, revision

    ea, ua, ra = split(a)
    eb, ub, rb = split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    c = _verrevcmp(ua, ub)
    if c:
        return c
    return _verrevcmp(ra, rb)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_DIR = os.environ.get(
    "XIOS_SYNC_OUT_DIR", os.path.join(REPO_ROOT, "x11", "linux-build", "out")
)
REPO_DIR = os.environ.get(
    "XIOS_SYNC_REPO_DIR", os.path.join(REPO_ROOT, "repo", "debs")
)

# Parse {name}_{version}_{arch}.deb
DEB_RE = re.compile(r"^(.+?)_(.+?)\.deb$")


def parse_deb_filename(fname):
    """Parse a .deb filename into (name, version, arch) or None."""
    if not fname.endswith(".deb"):
        return None
    # Strip .deb
    base = fname[:-4]
    # Split on underscores — arch is after last _, name before first _, version in between
    parts = base.split("_")
    if len(parts) < 3:
        return None
    arch = parts[-1]
    version = "_".join(parts[1:-1])
    name = parts[0]
    return (name, version, arch)


def collect_packages(directory):
    """Scan a directory for .deb files and return dict: (name, arch) -> [(version, path)]."""
    result = defaultdict(list)
    if not os.path.isdir(directory):
        return result
    for fname in os.listdir(directory):
        parsed = parse_deb_filename(fname)
        if parsed is None:
            continue
        name, version, arch = parsed
        key = (name, arch)
        result[key].append((version, os.path.join(directory, fname)))
    return result


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Add selected newest X11 package builds to repo/debs. "
            "Dry-run is the default; no files are ever deleted."
        )
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="perform copies (requires an explicit --only list)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="deprecated compatibility spelling; dry-run is already the default",
    )
    parser.add_argument(
        "--only",
        metavar="PKG[,PKG...]",
        help="limit consideration to these exact package names",
    )
    args = parser.parse_args()
    if args.apply and args.dry_run:
        parser.error("--apply and --dry-run are mutually exclusive")
    if args.apply and not args.only:
        parser.error("--apply requires an explicit --only package list")
    return args


def main():
    args = parse_args()
    selected = None
    if args.only:
        selected = {name.strip() for name in args.only.split(",") if name.strip()}
        if not selected:
            raise SystemExit("ERROR: --only did not name any packages")

    out_pkgs = collect_packages(OUT_DIR)
    repo_pkgs = collect_packages(REPO_DIR)

    # Build a unified set of package keys from both directories
    all_keys = set(out_pkgs.keys()) | set(repo_pkgs.keys())

    # com.max.* app packages use bin/package-app.sh and its signing/versioning
    # path; this helper is only for the x11 build-output lane.
    all_keys = {k for k in all_keys if not k[0].startswith("com.max.")}
    if selected is not None:
        all_keys = {k for k in all_keys if k[0] in selected}

    copies = []  # (src, dst)
    collisions = []  # (package, version, out_path, repo_path)

    for key in sorted(all_keys):
        name, _arch = key
        out_by_version = {version: path for version, path in out_pkgs.get(key, [])}
        repo_by_version = {version: path for version, path in repo_pkgs.get(key, [])}
        for version in sorted(
            out_by_version.keys() & repo_by_version.keys(),
            key=functools.cmp_to_key(version_compare),
        ):
            out_path = out_by_version[version]
            repo_path = repo_by_version[version]
            if not filecmp.cmp(out_path, repo_path, shallow=False):
                collisions.append((name, version, out_path, repo_path))

        entries = {}
        # Collect all (version, path, source) across both dirs
        for version, path in out_pkgs.get(key, []):
            entries[version] = (path, "out")
        for version, path in repo_pkgs.get(key, []):
            # repo doesn't overwrite out entry (out takes precedence for path tracking)
            if version not in entries:
                entries[version] = (path, "repo")

        versions = sorted(entries.keys(), key=functools.cmp_to_key(version_compare))
        latest_version = versions[-1]
        latest_path, latest_src = entries[latest_version]

        # If the latest is in out/, check if it needs to be copied to repo
        repo_path_for_latest = None
        for version, path in repo_pkgs.get(key, []):
            if version == latest_version:
                repo_path_for_latest = path
                break

        if latest_src == "out" and repo_path_for_latest is None:
            dst = os.path.join(REPO_DIR, os.path.basename(latest_path))
            copies.append((latest_path, dst))

    print("=== Executing additive copy ===\n" if args.apply else "=== Dry Run (default) ===\n")
    print(f"Packages to copy from out/ to repo/debs/ ({len(copies)}):")
    for src, _dst in copies:
        fname = os.path.basename(src)
        print(f"  cp  {fname}")

    print(f"\nImmutable version collisions ({len(collisions)}):")
    for name, version, out_path, repo_path in collisions:
        print(
            f"  ERROR {name} {version}: "
            f"{os.path.basename(out_path)} differs from {os.path.basename(repo_path)}"
        )

    print("\nPackages to remove: 0 (this tool is additive)")
    if collisions:
        raise SystemExit(
            "ERROR: package bytes differ at an existing name/version; "
            "bump the package version before copying"
        )
    if not args.apply:
        if selected:
            selected_arg = ",".join(sorted(selected))
            print(
                "\nThis was a dry run. To copy this exact package selection, run:\n"
                f"  {__file__} --apply --only {selected_arg}"
            )
        else:
            print(
                "\nThis was a dry run. Review the list, then rerun with "
                "--apply --only pkg[,pkg...]."
            )
        return

    os.makedirs(REPO_DIR, exist_ok=True)
    for src, dst in copies:
        if os.path.exists(dst):
            raise SystemExit(f"ERROR: refusing to overwrite existing package: {dst}")
        shutil.copy2(src, dst)
        print(f"cp  {os.path.basename(src)} -> repo/debs/")

    print("\nDone.")


if __name__ == "__main__":
    main()
