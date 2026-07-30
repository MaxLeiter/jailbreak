#!/usr/bin/env python3
"""Build a private cross SDK from the newest matching debs in the Xios repo."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
from pathlib import Path


def field(deb: Path, name: str) -> str:
    return subprocess.check_output(
        ["dpkg-deb", "-f", str(deb), name],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()


def newer(candidate: str, current: str) -> bool:
    return subprocess.run(
        ["dpkg", "--compare-versions", candidate, "gt", current],
        check=False,
    ).returncode == 0


def dependency_names(value: str) -> list[list[str]]:
    groups: list[list[str]] = []
    for raw_group in value.replace("\n", " ").split(","):
        alternatives: list[str] = []
        for raw in raw_group.split("|"):
            name = re.sub(r"\s*\(.*?\)", "", raw).strip()
            name = name.split(":", 1)[0]
            if name:
                alternatives.append(name)
        if alternatives:
            groups.append(alternatives)
    return groups


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("seeds", nargs="+")
    args = parser.parse_args()

    selected: dict[str, tuple[str, Path]] = {}
    for deb in sorted(args.repo.glob("*.deb")):
        try:
            package = field(deb, "Package")
            version = field(deb, "Version")
        except subprocess.CalledProcessError:
            continue
        old = selected.get(package)
        if old is None or newer(version, old[0]):
            selected[package] = (version, deb)

    missing_seeds = [seed for seed in args.seeds if seed not in selected]
    if missing_seeds:
        raise SystemExit(f"missing SDK seed packages: {', '.join(missing_seeds)}")

    queue = list(args.seeds)
    wanted: dict[str, tuple[str, Path]] = {}
    while queue:
        package = queue.pop(0)
        if package in wanted:
            continue
        item = selected.get(package)
        if item is None:
            continue
        wanted[package] = item
        depends = " ".join(
            part
            for part in (
                field(item[1], "Pre-Depends"),
                field(item[1], "Depends"),
            )
            if part
        )
        for alternatives in dependency_names(depends):
            chosen = next((name for name in alternatives if name in selected), None)
            if chosen and chosen not in wanted:
                queue.append(chosen)

    if args.sdk.exists():
        shutil.rmtree(args.sdk)
    args.sdk.mkdir(parents=True)

    for package in sorted(wanted):
        version, deb = wanted[package]
        print(f"  + {package} {version}")
        result = subprocess.run(
            ["dpkg-deb", "-x", str(deb), str(args.sdk)],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise SystemExit(result.stderr or f"failed to extract {deb}")

    manifest = args.sdk / ".xios-gimp-sdk-manifest"
    manifest.write_text(
        "".join(f"{name}\t{wanted[name][0]}\n" for name in sorted(wanted))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
