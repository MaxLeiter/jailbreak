#!/usr/bin/env python3
"""Fail when a package template has drifted from the package dir it mirrors.

Usage:
    check-template-drift.py <package> <rendered-DEBIAN> <package-dir-DEBIAN>

<rendered-DEBIAN> is the template's DEBIAN/ rendered for rootless-1900 (what
build-template-package.sh produces); <package-dir-DEBIAN> is packages/<pkg>/DEBIAN
or packages/meta/<pkg>/DEBIAN. Both sides are edited by hand, so nothing else
keeps them together: xios-fhs went to 1.0.5 and grew a torch LED block in its
postinst while the template stayed at 1.0.1, and a template build would have
emitted 1.0.1 again under an already-public filename.

Compared:
  control   every field except Description (templates word it target-neutrally)
  scripts   every other DEBIAN file, ignoring comment and blank lines
A file present on only one side is drift too. Exit 0 in sync, 1 drifted.
"""

from __future__ import annotations

import difflib
import sys
from pathlib import Path


def control_fields(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    key = None
    for line in text.splitlines():
        if line[:1] in (" ", "\t") and key:
            fields[key] += "\n" + line
        elif ":" in line:
            key, _, value = line.partition(":")
            fields[key] = value.strip()
    fields.pop("Description", None)
    return fields


def code_lines(text: str) -> list[str]:
    out = []
    for i, line in enumerate(text.splitlines()):
        line = line.rstrip()
        if i == 0 and line.startswith("#!"):
            out.append(line)
        elif line.strip() and not line.lstrip().startswith("#"):
            out.append(line)
    return out


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    package, rendered, mirror = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    problems: list[str] = []

    names = sorted({p.name for p in rendered.iterdir() if p.is_file()} |
                   {p.name for p in mirror.iterdir() if p.is_file()})
    for name in names:
        a, b = rendered / name, mirror / name
        if not a.exists() or not b.exists():
            problems.append(f"{name}: only in the {'template' if a.exists() else 'package dir'}")
            continue
        ta, tb = a.read_text(), b.read_text()
        if name == "control":
            fa, fb = control_fields(ta), control_fields(tb)
            for key in sorted(set(fa) | set(fb)):
                if fa.get(key) != fb.get(key):
                    problems.append(f"control {key}: template {fa.get(key)!r}, "
                                    f"package dir {fb.get(key)!r}")
        else:
            la, lb = code_lines(ta), code_lines(tb)
            if la != lb:
                diff = difflib.unified_diff(la, lb, "template", "package dir",
                                            lineterm="", n=0)
                problems.append(f"{name} (comments ignored):\n    " + "\n    ".join(diff))

    if not problems:
        return 0
    print(f"{package}: template has drifted from its package dir", file=sys.stderr)
    for problem in problems:
        print(f"  {problem}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
