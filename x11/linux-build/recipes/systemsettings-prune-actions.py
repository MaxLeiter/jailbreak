#!/usr/bin/env python3
"""Prune System Settings quick actions for KCMs not shipped in the iOS package set."""
from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) < 3:
        print(
            "usage: systemsettings-prune-actions.py <systemsettings.desktop> <action>...",
            file=sys.stderr,
        )
        return 2

    path = Path(sys.argv[1])
    remove = set(sys.argv[2:])
    text = path.read_text()
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    actions_line_seen = False
    drop = False

    for line in lines:
        if line.startswith("Actions="):
            actions_line_seen = True
            actions = [a for a in line.removeprefix("Actions=").strip().rstrip(";").split(";") if a]
            actions = [a for a in actions if a not in remove]
            out.append(f"Actions={';'.join(actions)};\n" if actions else "Actions=\n")
            drop = False
            continue

        if line.startswith("[Desktop Action "):
            action = line[len("[Desktop Action ") :].split("]", 1)[0]
            drop = action in remove

        if not drop:
            out.append(line)

    if not actions_line_seen:
        print(f"{path}: no Actions= line found", file=sys.stderr)
        return 1

    path.write_text("".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
