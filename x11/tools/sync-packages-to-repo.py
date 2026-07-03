#!/usr/bin/env python3
"""Sync X11 packages from x11/linux-build/out/ to repo/debs/.

Usage:
    x11/tools/sync-packages-to-repo.py --dry-run   # just print what would be done
    x11/tools/sync-packages-to-repo.py             # do it
"""

import os
import re
import shutil
import sys
from collections import defaultdict

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

        versions = sorted(entries.keys(), key=lambda v: v)
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
