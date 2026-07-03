#!/usr/bin/env python3
"""Audit the static jailbreak repo for deb/index drift.

The publisher intentionally regenerates Packages from repo/debs. This audit is
the belt after those suspenders: it verifies every indexed deb still exists and
that Size/MD5/SHA1/SHA256 match the file bytes that will be deployed.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys


HASH_FIELDS = {
    "MD5sum": "md5",
    "SHA1": "sha1",
    "SHA256": "sha256",
}
EXPECTED_PUBLISHER = "Max Leiter <maxwell.leiter@gmail.com>"


def parse_stanzas(path: str) -> list[dict[str, str]]:
    with open(path, encoding="utf-8") as f:
        raw = f.read().strip()
    if not raw:
        return []

    stanzas: list[dict[str, str]] = []
    for block in raw.split("\n\n"):
        fields: dict[str, str] = {}
        last_key: str | None = None
        for line in block.splitlines():
            if line.startswith(" ") and last_key:
                fields[last_key] += "\n" + line
            elif ": " in line:
                key, value = line.split(": ", 1)
                fields[key] = value
                last_key = key
        if fields:
            stanzas.append(fields)
    return stanzas


def digest(path: str, algo: str) -> str:
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo",
        default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "repo")),
        help="repo root containing Packages and debs/",
    )
    args = parser.parse_args()

    packages = os.path.join(args.repo, "Packages")
    if not os.path.exists(packages):
        print(f"ERROR: missing Packages: {packages}", file=sys.stderr)
        return 1

    errors: list[str] = []
    seen: set[str] = set()
    for stanza in parse_stanzas(packages):
        filename = stanza.get("Filename")
        ident = f"{stanza.get('Package', '?')} {stanza.get('Version', '?')}"
        if not filename:
            errors.append(f"{ident}: missing Filename")
            continue

        for field in ("Maintainer", "Author"):
            if stanza.get(field) != EXPECTED_PUBLISHER:
                errors.append(
                    f"{ident}: {field} {stanza.get(field)!r} != {EXPECTED_PUBLISHER!r}"
                )

        seen.add(filename)
        deb = os.path.join(args.repo, filename)
        if not os.path.exists(deb):
            errors.append(f"{ident}: indexed file missing: {filename}")
            continue

        size = os.path.getsize(deb)
        if stanza.get("Size") != str(size):
            errors.append(f"{ident}: Size {stanza.get('Size')} != {size} for {filename}")

        for field, algo in HASH_FIELDS.items():
            actual = digest(deb, algo)
            if stanza.get(field) != actual:
                errors.append(f"{ident}: {field} mismatch for {filename}")

    deb_files = set()
    deb_dir = os.path.join(args.repo, "debs")
    for name in os.listdir(deb_dir):
        if name.endswith(".deb"):
            deb_files.add(f"debs/{name}")

    for filename in sorted(deb_files - seen):
        errors.append(f"unindexed deb: {filename}")

    if errors:
        print("Repo audit failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print(f"Repo audit OK: {len(seen)} deb(s) indexed and hash-matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
