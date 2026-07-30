#!/usr/bin/env python3
"""Publish gate: catch version drift between a branch and an already-published index.

Two failure classes, both born from parallel work in worktrees while main keeps
releasing:

  collision   The same Package+Version exists in both indexes with a different
              SHA256. Public deb filenames are immutable in Blob (a deb is
              addressed as debs/<pkg>_<ver>_<arch>.deb), so this can never be
              published: the upload would have to overwrite a payload devices
              may already have cached. The fix is always to bump the version.

  regression  The reference index has a NEWER version of a package than this
              index does. Deploying this index would advertise the older
              version and roll devices back on the next apt upgrade. The fix is
              to rebase on the reference (this is what the aptindex merge driver
              in .gitattributes resolves automatically).

Usage:
  check-version-collisions.py --against https://repo.maxleiter.com/Packages
  check-version-collisions.py --against git:origin/main
  check-version-collisions.py --against /path/to/Packages --warn-regressions

A reference that cannot be read (404 on a repo that was never deployed, a git
ref that does not exist) is skipped with a note, not an error, so the first
deploy of a fresh environment is not a chicken-and-egg failure.

Exit 0 = clean, 1 = at least one hard failure.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))


def _load_make_repo():
    path = os.path.join(HERE, "make-repo.py")
    spec = importlib.util.spec_from_file_location("make_repo", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse_index(text: str) -> dict[str, dict[str, str]]:
    """Packages text -> {package: {Version, SHA256, Filename}}."""
    out: dict[str, dict[str, str]] = {}
    for block in text.split("\n\n"):
        if not block.strip():
            continue
        d: dict[str, str] = {}
        for line in block.splitlines():
            if ": " in line and not line.startswith((" ", "\t")):
                k, v = line.split(": ", 1)
                d[k] = v
        pkg = d.get("Package")
        if pkg:
            out[pkg] = d
    return out


def read_reference(spec: str) -> tuple[str, str] | None:
    """Resolve a reference spec to (label, Packages text), or None if absent."""
    if spec.startswith(("http://", "https://")):
        try:
            with urllib.request.urlopen(spec, timeout=30) as resp:
                return spec, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise
        except urllib.error.URLError as exc:
            print(f"WARNING: cannot reach {spec}: {exc}", file=sys.stderr)
            return None

    if spec.startswith("git:"):
        ref = spec[4:]
        proc = subprocess.run(
            ["git", "show", f"{ref}:repo/Packages"],
            cwd=REPO_ROOT, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            return None
        return spec, proc.stdout

    if os.path.exists(spec):
        with open(spec, encoding="utf-8", errors="replace") as fh:
            return spec, fh.read()
    return None


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--index",
        default=os.path.join(REPO_ROOT, "repo", "Packages"),
        help="the index being published (default: repo/Packages)",
    )
    ap.add_argument(
        "--against",
        action="append",
        default=[],
        metavar="REF",
        help="reference index: a URL, git:<ref>, or a path. Repeatable.",
    )
    ap.add_argument(
        "--warn-regressions",
        action="store_true",
        help="report regressions without failing (use on PRs, where being "
             "behind main is expected until the branch rebases)",
    )
    args = ap.parse_args()

    if not args.against:
        ap.error("at least one --against reference is required")

    with open(args.index, encoding="utf-8", errors="replace") as fh:
        ours = parse_index(fh.read())
    make_repo = _load_make_repo()

    errors: list[str] = []
    warnings: list[str] = []
    checked = 0

    for spec in args.against:
        ref = read_reference(spec)
        if ref is None:
            print(f"==> skipping {spec} (no index there yet)")
            continue
        label, text = ref
        theirs = parse_index(text)
        checked += 1
        print(f"==> comparing {len(ours)} stanza(s) against {label} ({len(theirs)} stanza(s))")

        for pkg, mine in sorted(ours.items()):
            other = theirs.get(pkg)
            if not other:
                continue
            my_ver = mine.get("Version", "")
            their_ver = other.get("Version", "")
            cmp = make_repo.compare_deb_versions(my_ver, their_ver)

            if cmp == 0:
                my_sha = mine.get("SHA256", "")
                their_sha = other.get("SHA256", "")
                if my_sha and their_sha and my_sha != their_sha:
                    errors.append(
                        f"collision: {pkg} {my_ver} is already published at {label} "
                        f"with different bytes\n"
                        f"    published SHA256 {their_sha}\n"
                        f"    ours      SHA256 {my_sha}\n"
                        f"    bump {pkg} past {my_ver} and rebuild "
                        f"(deb filenames in Blob are immutable)"
                    )
            elif cmp < 0:
                msg = (
                    f"regression: {label} publishes {pkg} {their_ver}, "
                    f"this index only has {my_ver}\n"
                    f"    deploying as-is would roll devices back; rebase on the "
                    f"reference so the index picks up {their_ver}"
                )
                (warnings if args.warn_regressions else errors).append(msg)

    if checked == 0:
        print("==> no reference index available; nothing to compare")

    for msg in warnings:
        print(f"WARNING: {msg}", file=sys.stderr)

    if errors:
        print(f"\nVersion drift check failed ({len(errors)} problem(s)):", file=sys.stderr)
        for msg in errors:
            print(f"  - {msg}", file=sys.stderr)
        return 1

    print("==> version drift check OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
