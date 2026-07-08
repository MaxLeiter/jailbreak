#!/usr/bin/env python3
"""Sync X11 packages from x11/linux-build/out/ to repo/debs/.

Usage:
    x11/tools/sync-packages-to-repo.py --dry-run   # just print what would be done
    x11/tools/sync-packages-to-repo.py             # do it
"""

import functools
import os
import re
import shutil
import sys
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
OUT_DIR = os.path.join(REPO_ROOT, "x11", "linux-build", "out")
REPO_DIR = os.path.join(REPO_ROOT, "repo", "debs")

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


def main():
    dry_run = "--dry-run" in sys.argv

    out_pkgs = collect_packages(OUT_DIR)
    repo_pkgs = collect_packages(REPO_DIR)

    # Build a unified set of package keys from both directories
    all_keys = set(out_pkgs.keys()) | set(repo_pkgs.keys())

    # Filter out com.max.* packages
    all_keys = {k for k in all_keys if not k[0].startswith("com.max.")}

    actions = []  # list of (type, src, dst_or_path)  type: "copy"|"remove-repo"|"remove-out"

    for key in sorted(all_keys):
        name, arch = key
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

        copy_needed = False
        if latest_src == "out" and repo_path_for_latest is None:
            # Latest version is in out/ but not in repo/ — copy it
            dst = os.path.join(REPO_DIR, os.path.basename(latest_path))
            actions.append(("copy", latest_path, dst))
            copy_needed = True

        # Remove stale versions from repo/
        for version, path in repo_pkgs.get(key, []):
            if version != latest_version:
                actions.append(("remove-repo", path, None))

        # Remove stale versions from out/
        for version, path in out_pkgs.get(key, []):
            if version != latest_version:
                actions.append(("remove-out", path, None))

    # Print summary
    copies = [a for a in actions if a[0] == "copy"]
    removes_repo = [a for a in actions if a[0] == "remove-repo"]
    removes_out = [a for a in actions if a[0] == "remove-out"]

    print(f"=== Dry Run ===\n" if dry_run else "=== Executing ===\n")
    print(f"Packages to copy from out/ to repo/debs/ ({len(copies)}):")
    for _, src, dst in copies:
        fname = os.path.basename(src)
        print(f"  cp  {fname}")

    print(f"\nPackages to remove from repo/debs/ ({len(removes_repo)}):")
    for _, path, _ in removes_repo:
        print(f"  rm  {os.path.basename(path)}")

    print(f"\nPackages to remove from out/ ({len(removes_out)}):")
    for _, path, _ in removes_out:
        print(f"  rm  {os.path.basename(path)}")

    if dry_run:
        print("\nThis was a dry run. Re-run without --dry-run to execute.")
        return

    # Execute
    for action_type, src, dst in actions:
        if action_type == "copy":
            shutil.copy2(src, dst)
            print(f"cp  {os.path.basename(src)} -> repo/debs/")
        elif action_type == "remove-repo":
            os.remove(src)
            print(f"rm  (repo) {os.path.basename(src)}")
        elif action_type == "remove-out":
            os.remove(src)
            print(f"rm  (out)  {os.path.basename(src)}")

    print("\nDone.")


if __name__ == "__main__":
    main()
