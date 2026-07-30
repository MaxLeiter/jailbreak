#!/usr/bin/env python3
"""Git merge driver for repo/Packages.

A textual 3-way merge of an APT index is meaningless: the file is a set of
stanzas keyed on Package, generated from an additive deb pool, so two branches
that each publish a different package produce edits git sees as adjacent-line
conflicts even though the merge is unambiguous.

This driver merges the way the generator would: per package id, keep the newer
version (dpkg version semantics), then re-sort stanzas into deb-filename order
so the result is byte-identical to what regenerating from a merged deb pool
would emit. A package deleted on one side is honored as a deletion only when
the other side left it untouched, which is how apt retirements survive a merge.

The one genuinely ambiguous case fails the merge loudly: both sides claim the
same Package+Version with different SHA256. That is a real problem, not a merge
artifact -- the payload filename is immutable in Blob -- so it wants a version
bump and a rebuild, not a resolved text file.

Wired up by .gitattributes:  repo/Packages merge=aptindex
Register the driver once per clone:  bin/setup-git-merge-driver.sh

Invoked by git as:  merge-packages.py %O %A %B %P
  %O ancestor   %A ours (also the output file)   %B theirs   %P real pathname
Exit 0 = merged cleanly, 1 = conflict left to the human.
"""
from __future__ import annotations

import functools
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_make_repo():
    path = os.path.join(HERE, "make-repo.py")
    spec = importlib.util.spec_from_file_location("make_repo", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def parse(path: str) -> dict[str, tuple[str, dict[str, str]]]:
    """Packages file -> {package: (raw_stanza, fields)}."""
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        raw = fh.read()
    out: dict[str, tuple[str, dict[str, str]]] = {}
    for block in raw.split("\n\n"):
        stanza = block.strip("\n")
        if not stanza.strip():
            continue
        fields: dict[str, str] = {}
        for line in stanza.splitlines():
            if ": " in line and not line.startswith((" ", "\t")):
                k, v = line.split(": ", 1)
                fields[k] = v
        pkg = fields.get("Package")
        if pkg:
            out[pkg] = (stanza, fields)
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: merge-packages.py %O %A %B [%P]", file=sys.stderr)
        return 2
    base_path, ours_path, theirs_path = argv[0], argv[1], argv[2]
    label = argv[3] if len(argv) > 3 else "repo/Packages"

    make_repo = _load_make_repo()
    base, ours, theirs = parse(base_path), parse(ours_path), parse(theirs_path)

    merged: dict[str, tuple[str, dict[str, str]]] = {}
    conflicts: list[str] = []

    for pkg in sorted(set(ours) | set(theirs)):
        mine, other = ours.get(pkg), theirs.get(pkg)

        # Present on one side only: a deletion the other side did not touch is a
        # real retirement; otherwise the surviving side wins.
        if mine and not other:
            if pkg in base and base[pkg][0] == mine[0]:
                continue  # theirs retired it, we left it alone
            merged[pkg] = mine
            continue
        if other and not mine:
            if pkg in base and base[pkg][0] == other[0]:
                continue  # we retired it, theirs left it alone
            merged[pkg] = other
            continue

        assert mine and other
        if mine[0] == other[0]:
            merged[pkg] = mine
            continue

        my_ver = mine[1].get("Version", "")
        their_ver = other[1].get("Version", "")
        cmp = make_repo.compare_deb_versions(my_ver, their_ver)
        if cmp > 0:
            merged[pkg] = mine
        elif cmp < 0:
            merged[pkg] = other
        else:
            my_sha = mine[1].get("SHA256", "")
            their_sha = other[1].get("SHA256", "")
            if my_sha == their_sha:
                # Same payload, cosmetic stanza difference (a metadata or
                # description edit). Ours wins; the next regeneration settles it.
                merged[pkg] = mine
            else:
                conflicts.append(
                    f"{pkg} {my_ver}: both sides publish this version with "
                    f"different payloads (ours {my_sha[:12]}, theirs {their_sha[:12]})"
                )
                merged[pkg] = mine

    def sort_key(item):
        _pkg, (_stanza, fields) = item
        return os.path.basename(fields.get("Filename", ""))

    ordered = sorted(merged.items(),
                     key=functools.cmp_to_key(
                         lambda a, b: make_repo.compare_deb_filenames(sort_key(a), sort_key(b))))

    with open(ours_path, "w", encoding="utf-8") as fh:
        fh.write("\n\n".join(stanza for _pkg, (stanza, _f) in ordered) + "\n")

    if conflicts:
        print(f"CONFLICT ({label}): same version published twice with different bytes:",
              file=sys.stderr)
        for msg in conflicts:
            print(f"  - {msg}", file=sys.stderr)
        print("  Bump the version on this branch and rebuild; deb filenames in Blob "
              "are immutable.", file=sys.stderr)
        return 1

    print(f"Merged {label}: {len(ordered)} package(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
