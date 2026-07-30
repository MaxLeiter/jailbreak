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
import io
import re
import tarfile
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


def ar_members(data: bytes) -> dict[str, bytes]:
    if data[:8] != b"!<arch>\n":
        sys.exit("not an ar archive (is this really a .deb?)")
    out, off = {}, 8
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        off += 60
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        size = int(hdr[48:58].decode().strip())
        out[name] = data[off:off + size]
        off += size + (size & 1)
    return out


def unpack_deb(path: Path, dest: Path) -> None:
    """Unpack a .deb without dpkg-deb.

    The build host here is macOS, which has no dpkg. Shelling out to dpkg-deb
    would mean this check only ever runs in the container -- i.e. not where the
    debs actually land.
    """
    blob = path.read_bytes()
    members = ar_members(blob)
    for prefix, sub in (("control.tar", "DEBIAN"), ("data.tar", "")):
        name = next((n for n in members if n.startswith(prefix)), None)
        if name is None:
            sys.exit(f"{path.name}: no {prefix}* member")
        raw = members[name]
        mode = {".gz": "r:gz", ".xz": "r:xz", ".bz2": "r:bz2", "": "r:"}.get(
            name[len(prefix):], "r:*")
        if name.endswith(".zst"):
            zstd = shutil.which("zstd")
            if not zstd:
                sys.exit("zstd not found in PATH; needed to read this .deb")
            raw = subprocess.run([zstd, "-qdc"], input=raw, stdout=subprocess.PIPE,
                                 check=True).stdout
            mode = "r:"
        target = dest / sub if sub else dest
        target.mkdir(parents=True, exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(raw), mode=mode) as tf:
            for m in tf.getmembers():
                m.name = m.name.lstrip("./") or "."
                if m.name.startswith("/") or ".." in Path(m.name).parts:
                    continue  # never let a crafted archive escape the temp dir
            tf.extractall(target, filter="data")


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


MACHO_MAGIC = {
    b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe",   # 64/32-bit little-endian
    b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce",   # big-endian
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",   # fat
}


def is_macho(path: Path) -> bool:
    try:
        with path.open("rb") as f:
            return f.read(4) in MACHO_MAGIC
    except OSError:
        return False


def macho_foreign_paths(path: Path, foreign: list[str]) -> list[str]:
    """Find another target's prefix embedded in a Mach-O.

    Load commands carry absolute paths: LC_ID_DYLIB, LC_LOAD_DYLIB and LC_RPATH
    all hold install names. A rootful package whose dylib IDs still say
    /var/jb installs fine and then fails to load, which is exactly the class of
    breakage that only shows up on device. Scanning the raw bytes catches those
    plus any other embedded path, and needs no otool -- this has to run on Linux
    build hosts as well as macOS.
    """
    try:
        blob = path.read_bytes()
    except OSError:
        return []
    hits = []
    for bad in foreign:
        needle = bad.encode()
        start = 0
        while True:
            i = blob.find(needle, start)
            if i < 0:
                break
            end = i
            while end < len(blob) and 0x20 <= blob[end] < 0x7F:
                end += 1
            hits.append(blob[i:end].decode("ascii", "replace"))
            start = i + 1
    return sorted(set(hits))


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

    # Mach-O payload: install names and rpaths are absolute and invisible to the
    # text scan above.
    for path in payload:
        if not is_macho(path):
            continue
        for embedded in macho_foreign_paths(path, foreign):
            problems.append(
                f"{path.relative_to(root)}: Mach-O embeds {embedded} on target {target['target_id']}"
            )

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
            unpack_deb(src, tmp)
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
