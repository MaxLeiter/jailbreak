#!/usr/bin/env python3
"""Verify a staged package tree (or a built .deb) matches its target descriptor.

This is the local half of the migration plan's Phase 8 gate. It is what stops a
rootful package shipping rootless paths -- the failure the publish gate would
otherwise only catch on a device, long after the build.

  check-target-package.py <staged-root|package.deb> [target-id]

Checks:
  * payload paths sit under the target's package_path_prefix
  * no foreign prefix leaks into payload paths
  * maintainer scripts and text payload carry no other target's prefix
  * DEBIAN/control Architecture matches the descriptor
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ROOT / "targets"

# Prefixes owned by some target in the matrix. A package built for one of them
# must not mention any of the others.
KNOWN_PREFIXES = ("/var/jb",)

TEXT_SUFFIXES = {
    "", ".sh", ".conf", ".desktop", ".service", ".txt", ".md", ".xml", ".plist",
    ".json", ".ini", ".cfg", ".pc", ".rules", ".policy", ".gschema", ".control",
}


def load_target(target_id: str) -> dict[str, str]:
    path = TARGETS / f"{target_id}.env"
    if not path.exists():
        sys.exit(f"unknown target: {target_id} ({path})")
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        values[key.strip()] = val.strip().strip('"').strip("'")
    return values


def is_texty(path: Path) -> bool:
    if path.suffix in TEXT_SUFFIXES:
        try:
            chunk = path.read_bytes()[:4096]
        except OSError:
            return False
        return b"\0" not in chunk
    return False


def check(root: Path, target: dict[str, str]) -> list[str]:
    prefix = target["package_path_prefix"]
    foreign = [p for p in KNOWN_PREFIXES if p != prefix]
    problems: list[str] = []

    debian = root / "DEBIAN"
    payload = [p for p in root.rglob("*") if p.is_file() and debian not in p.parents]

    for path in payload:
        rel = "/" + str(path.relative_to(root))
        if prefix:
            if not rel.startswith(prefix + "/"):
                problems.append(f"payload path outside {prefix}: {rel}")
        else:
            for bad in foreign:
                if rel.startswith(bad + "/"):
                    problems.append(f"payload path uses {bad} on a rootful target: {rel}")

    # Maintainer scripts plus any shipped text: a stale /var/jb in a postinst is
    # just as broken as one in a path, and far easier to miss.
    scripts = [p for p in debian.rglob("*") if p.is_file()] if debian.is_dir() else []
    for path in scripts + [p for p in payload if is_texty(p)]:
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        rel = str(path.relative_to(root))
        for bad in foreign:
            for num, line in enumerate(text.splitlines(), 1):
                if bad in line:
                    problems.append(f"{rel}:{num}: {bad} literal on target {target['target_id']}: {line.strip()[:90]}")

    control = debian / "control"
    if control.exists():
        match = re.search(r"^Architecture:\s*(\S+)", control.read_text(), re.M)
        if match and match.group(1) != target["deb_arch"]:
            problems.append(
                f"DEBIAN/control Architecture={match.group(1)}, descriptor says {target['deb_arch']}"
            )

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("path", help="staged package root, or a .deb")
    parser.add_argument("target", nargs="?", default="rootless-1900")
    args = parser.parse_args()

    target = load_target(args.target)
    src = Path(args.path)
    tmp = None
    try:
        if src.is_file() and src.suffix == ".deb":
            tmp = Path(tempfile.mkdtemp(prefix="xios-pkgcheck-"))
            subprocess.run(["dpkg-deb", "-R", str(src), str(tmp)], check=True)
            root = tmp
        elif src.is_dir():
            root = src
        else:
            sys.exit(f"not a staged root or .deb: {src}")

        problems = check(root, target)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)

    if problems:
        print(f"FAIL {src} does not match target {args.target}:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print(f"OK   {src.name} matches {args.target} (prefix {target['package_path_prefix'] or '/'})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
