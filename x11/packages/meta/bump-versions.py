#!/usr/bin/env python3
"""Update Xios meta-package versions in canonical and rendered controls together.

Usage:
    ./bump-versions.py xios-runtime=0.1.4 xios-core=0.1.10
    ./bump-versions.py --check

Dependency floors are deliberately not inferred: changing those is a release
decision and should remain an explicit control-file edit.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


HERE = Path(__file__).resolve().parent
PACKAGES = ("xios-runtime", "xios-core", "xios-gnome", "xios-kde",
            "xios-native", "xios-x11")
VERSION_RE = re.compile(r"^[0-9A-Za-z.+:~_-]+$")


def paths(package: str) -> tuple[Path, Path]:
    return (
        HERE.parent / "templates" / package / "DEBIAN" / "control.in",
        HERE / package / "DEBIAN" / "control",
    )


def field(text: str, name: str) -> str:
    matches = re.findall(rf"^{re.escape(name)}: (.+)$", text, re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {name} field")
    return matches[0]


def set_version(path: Path, package: str, version: str) -> None:
    text = path.read_text()
    if field(text, "Package") != package:
        raise SystemExit(f"{path}: Package field does not match {package}")
    old = field(text, "Version")
    updated, count = re.subn(
        r"^Version: .+$", f"Version: {version}", text, count=1,
        flags=re.MULTILINE,
    )
    if count != 1:
        raise SystemExit(f"{path}: could not update Version")
    if updated != text:
        path.write_text(updated)
    print(f"{path.relative_to(HERE.parent.parent)}: {old} -> {version}")


def parse_specs(values: list[str]) -> dict[str, str]:
    specs: dict[str, str] = {}
    for value in values:
        package, sep, version = value.partition("=")
        if not sep or package not in PACKAGES or not VERSION_RE.fullmatch(version):
            raise SystemExit(f"invalid package=version: {value}")
        if package in specs:
            raise SystemExit(f"duplicate package: {package}")
        specs[package] = version
    return specs


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                        help="verify canonical and rendered versions match")
    parser.add_argument("spec", nargs="*", metavar="PACKAGE=VERSION")
    args = parser.parse_args()
    specs = parse_specs(args.spec)

    if args.check:
        for package in specs or dict.fromkeys(PACKAGES):
            versions = [field(path.read_text(), "Version") for path in paths(package)]
            if versions[0] != versions[1]:
                raise SystemExit(
                    f"{package}: template {versions[0]} != rendered {versions[1]}")
            if package in specs and versions[0] != specs[package]:
                raise SystemExit(
                    f"{package}: found {versions[0]}, expected {specs[package]}")
            print(f"{package}: {versions[0]} OK")
        return

    if not specs:
        parser.error("provide at least one PACKAGE=VERSION, or use --check")
    for package, version in specs.items():
        for path in paths(package):
            set_version(path, package, version)


if __name__ == "__main__":
    main()
