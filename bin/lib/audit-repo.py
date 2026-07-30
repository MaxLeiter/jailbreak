#!/usr/bin/env python3
"""Audit the static jailbreak repo for deb/index drift.

The publisher intentionally regenerates Packages from repo/debs. This audit is
the belt after those suspenders: it verifies every indexed deb still exists and
that Size/MD5/SHA1/SHA256 match the file bytes that will be deployed.

--no-payloads drops every check that needs the .deb bytes and keeps the ones
that read the index alone (Filename present, publisher fields normalized). CI
runs it that way: repo/debs is gitignored, so a plain checkout has no payloads
and the hash cross-check belongs to the authoring host that built them.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import sys


def _load_make_repo():
    path = os.path.join(os.path.dirname(__file__), "make-repo.py")
    spec = importlib.util.spec_from_file_location("make_repo", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


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
    parser.add_argument(
        "--no-payloads",
        action="store_true",
        help="skip checks that need repo/debs/*.deb (for CI checkouts)",
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
        if args.no_payloads:
            continue
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

    # The deb pool is additive (make-repo indexes only the newest version per
    # package), so a superseded on-disk deb is expected. Real drift is a deb
    # whose package is absent from the index, or one NEWER than its indexed
    # stanza (index is stale).
    make_repo = _load_make_repo()
    indexed_version: dict[str, str] = {}
    for stanza in parse_stanzas(packages):
        pkg, ver = stanza.get("Package"), stanza.get("Version")
        if pkg and ver:
            indexed_version[pkg] = ver

    deb_dir = os.path.join(args.repo, "debs")
    pool = [] if args.no_payloads or not os.path.isdir(deb_dir) else sorted(os.listdir(deb_dir))
    for name in pool:
        if not name.endswith(".deb") or f"debs/{name}" in seen:
            continue
        parts = name[:-4].split("_")
        if len(parts) < 2:
            errors.append(f"unindexed deb (unparseable name): debs/{name}")
            continue
        pkg, ver = parts[0], parts[1]
        if pkg not in indexed_version:
            errors.append(f"unindexed deb (package not in index): debs/{name}")
        elif make_repo.compare_deb_versions(ver, indexed_version[pkg]) > 0:
            errors.append(
                f"stale index: debs/{name} is newer than indexed "
                f"{pkg} {indexed_version[pkg]}"
            )

    if errors:
        print("Repo audit failed:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    if args.no_payloads:
        print(f"Repo audit OK (index only): {len(seen)} stanza(s) checked")
    else:
        print(f"Repo audit OK: {len(seen)} deb(s) indexed and hash-matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
