#!/usr/bin/env python3
"""Dependency-closure report for a target's built packages.

Phase 7 of the migration plan asks for a closure report per expansion step. The
question it answers is not "did the debs build" -- check-target-package.py covers
that -- but "could this set actually be installed", which is a different thing:
a package set that builds fine can still be uninstallable because it depends on
packages that exist for one root and not another.

  report-closure.py [target-id] [--markdown]

Reads every .deb for the target, resolves Depends within the set, and lists what
is left over. Those leftovers must come from a Procursus base repo built for the
SAME target -- which for a non-rootless target is exactly the open question, so
the report says so rather than implying the set is ready to ship.
"""
from __future__ import annotations

import argparse
import collections
import importlib.util
import re
import shutil
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent

_spec = importlib.util.spec_from_file_location("ctp", HERE / "check-target-package.py")
_ctp = importlib.util.module_from_spec(_spec)
try:
    _spec.loader.exec_module(_ctp)
except SystemExit:
    pass


def out_dir(target: str) -> Path:
    base = ROOT / "out"
    return base if target == "rootless-1900" else base / "targets" / target


def field(control: str, name: str) -> str | None:
    m = re.search(rf"^{name}:\s*(.+)$", control, re.M)
    return m.group(1) if m else None


def scan(target: str):
    provides: dict[str, str] = {}
    depends: dict[str, list[str]] = {}
    debs = sorted(out_dir(target).glob("*.deb"))
    for deb in debs:
        tmp = Path(tempfile.mkdtemp(prefix="xios-closure-"))
        try:
            _ctp.unpack_deb(deb, tmp)
            control = (tmp / "DEBIAN" / "control").read_text()
        except Exception as exc:                     # noqa: BLE001
            print(f"  !! unreadable: {deb.name} ({exc})", file=sys.stderr)
            continue
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

        pkg = field(control, "Package")
        if not pkg:
            continue
        provides[pkg] = deb.name
        extra = field(control, "Provides")
        if extra:
            for p in extra.split(","):
                provides[p.strip().split()[0]] = deb.name
        dep = field(control, "Depends")
        depends[pkg] = [d.strip().split()[0] for d in dep.split(",")] if dep else []
    return debs, provides, depends


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", nargs="?", default="rootless-1900")
    ap.add_argument("--markdown", action="store_true")
    args = ap.parse_args()

    debs, provides, depends = scan(args.target)
    if not debs:
        print(f"no packages built for {args.target} (looked in {out_dir(args.target)})",
              file=sys.stderr)
        return 2

    external: dict[str, list[str]] = collections.defaultdict(list)
    for pkg, deps in depends.items():
        for dep in deps:
            if dep not in provides:
                external[dep].append(pkg)

    if args.markdown:
        print(f"# Dependency closure: {args.target}\n")
        print(f"- packages built: {len(depends)} ({len(provides)} names incl. Provides)")
        print(f"- dependencies outside the set: {len(external)}\n")
        print("These must be satisfied by a Procursus base repo built for this same")
        print("target. The set is not installable on its own.\n")
        print("| dependency | required by |")
        print("|---|---|")
        for dep, who in sorted(external.items()):
            print(f"| `{dep}` | {', '.join(sorted(who))} |")
    else:
        print(f"target {args.target}: {len(depends)} debs, {len(provides)} names")
        print(f"unsatisfied within the set: {len(external)}")
        for dep, who in sorted(external.items()):
            print(f"  {dep:28} <- {', '.join(sorted(who)[:3])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
