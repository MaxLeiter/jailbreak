#!/usr/bin/env python3
"""Audit rootless/target-specific literals before target-matrix migration.

The goal is not to remove every `/var/jb` immediately. It is to keep a
repeatable inventory so rootless-only assumptions can be converted or marked
deliberately as package templating and rootful support land.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]

DEFAULT_LITERALS = (
    "/var/jb",
    "iphoneos-arm64-rootless",
    "MEMO_TARGET=iphoneos-arm64-rootless",
    "MEMO_CFVER=1900",
)

SKIP_DIRS = {
    ".git",
    ".next",
    "__pycache__",
    "artifacts",
    "node_modules",
    "out",
    "Procursus",
    "procursus-work",
    "src-tarballs",
}

SKIP_FILE_SUFFIXES = {
    ".a",
    ".dylib",
    ".deb",
    ".o",
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".zip",
    ".log",
    ".pyc",
    ".DS_Store",
}


@dataclass(frozen=True)
class Hit:
    path: str
    line: int
    literal: str
    category: str
    text: str


def is_probably_text(path: Path) -> bool:
    if path.name in SKIP_FILE_SUFFIXES:
        return False
    if path.suffix in SKIP_FILE_SUFFIXES:
        return False
    try:
        with path.open("rb") as f:
            chunk = f.read(4096)
    except OSError:
        return False
    return b"\0" not in chunk


def iter_files(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = Path(dirpath).relative_to(root)
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_DIRS and str(rel_dir / d) not in {
                "linux-build/out",
                "linux-build/stage",
                "wayland/out",
                "site/.next",
                # Xcode writes DerivedData here. It is build output, and its
                # PIFCache manifests quote every path the project references,
                # so scanning it reports the same literals dozens of times over.
                "apps/Xios/build",
            }
        ]
        for name in filenames:
            if name == "rootless-rootful-cfver-audit.md":
                continue
            path = Path(dirpath) / name
            rel = path.relative_to(root)
            if is_probably_text(path):
                yield rel, path


def categorize(rel: str, text: str, literal: str) -> str:
    if rel in {
        "linux-build/target-lib.sh",
        "linux-build/target-env.sh",
        "linux-build/print-target.sh",
        "linux-build/targets/rootless-1900.env",
        "linux-build/targets/rootful-1900.env",
        # The baseline records the literals it is measuring; counting its own
        # contents would make every update look like a regression.
        "linux-build/tools/target-literal-baseline.json",
        "linux-build/tools/audit-target-literals.py",
        # These two exist to detect a foreign prefix, so they must name one.
        "linux-build/tools/check-target-package.py",
        "linux-build/tools/lint-targets.sh",
    }:
        return "target-infra"
    if rel.startswith("docs/") or rel in {"README.md", "SCOPE.md", "AGENTS.md"}:
        return "docs"
    if rel.startswith("site/"):
        return "site-copy"
    if rel.endswith("-ent.xml") or "entitlement" in rel or "entitlements" in rel:
        return "entitlements"
    if rel.startswith("packages/"):
        return "package-payload"
    if rel.startswith("apps/Xios/") or rel.startswith("apps/iosc-host/"):
        return "app-runtime"
    if "/tmp" in text or "/var/jb/tmp" in text or "/var/jb/var" in text:
        return "runtime-path"
    if "MEMO_TARGET" in text or "MEMO_CFVER" in text or "iphoneos-arm64-rootless" in text:
        return "build-target"
    if "/var/jb/usr/lib" in text or "/var/jb/lib" in text or "rpath" in text.lower():
        return "linker-path"
    if rel.startswith("linux-build/recipes/") or rel.startswith("linux-build/build_info/"):
        return "recipe"
    if rel.startswith("linux-build/") or rel.startswith("wayland/") or rel.startswith("apps/"):
        return "script-or-source"
    return "other"


def scan(root: Path, literals: tuple[str, ...]) -> list[Hit]:
    hits: list[Hit] = []
    pattern = re.compile("|".join(re.escape(s) for s in sorted(literals, key=len, reverse=True)))
    for rel_path, path in iter_files(root):
        rel = rel_path.as_posix()
        try:
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            continue
        for idx, line in enumerate(lines, 1):
            for match in pattern.finditer(line):
                literal = match.group(0)
                hits.append(Hit(
                    path=rel,
                    line=idx,
                    literal=literal,
                    category=categorize(rel, line, literal),
                    text=line.strip(),
                ))
    return hits


def render_markdown(hits: list[Hit], limit_per_category: int) -> str:
    total_by_category = Counter(h.category for h in hits)
    total_by_literal = Counter(h.literal for h in hits)
    paths_by_category: dict[str, set[str]] = defaultdict(set)
    for hit in hits:
        paths_by_category[hit.category].add(hit.path)

    out = [
        "# Rootless / Target Literal Audit",
        "",
        "Generated by `linux-build/tools/audit-target-literals.py`.",
        "",
        "This report tracks remaining rootless and target-specific literals before",
        "the rootful / CFVER matrix migration. A hit is not automatically a bug;",
        "it is a place that must either become target-aware or be deliberately",
        "classified as rootless-only.",
        "",
        "## Summary",
        "",
        f"- Total hits: {len(hits)}",
        f"- Files with hits: {len({h.path for h in hits})}",
        "",
        "### By Category",
        "",
    ]
    for category, count in sorted(total_by_category.items()):
        out.append(f"- `{category}`: {count} hits across {len(paths_by_category[category])} files")

    out.extend(["", "### By Literal", ""])
    for literal, count in sorted(total_by_literal.items()):
        out.append(f"- `{literal}`: {count}")

    out.extend([
        "",
        "## Category Guidance",
        "",
        "- `target-infra`: allowed target descriptor or loader values.",
        "- `docs` / `site-copy`: documentation. Update when behavior changes.",
        "- `package-payload`: convert through package templates.",
        "- `runtime-path`: move behind target runtime variables.",
        "- `build-target`: load from `linux-build/targets/*.env`.",
        "- `linker-path`: derive from target prefix or keep rootless-only with a guard.",
        "- `entitlements`: target-specific path exceptions; review before rootful signing.",
        "- `recipe`: recipe source. Convert when that recipe joins the matrix.",
        "- `script-or-source` / `app-runtime`: inspect manually; often launch paths or sockets.",
        "",
        "## Samples",
        "",
    ])

    for category in sorted(total_by_category):
        out.extend([f"### {category}", ""])
        shown = 0
        for hit in hits:
            if hit.category != category:
                continue
            if shown >= limit_per_category:
                break
            text = hit.text.replace("|", "\\|")
            out.append(f"- `{hit.path}:{hit.line}` `{hit.literal}`: {text}")
            shown += 1
        remaining = total_by_category[category] - shown
        if remaining:
            out.append(f"- ... {remaining} more")
        out.append("")

    return "\n".join(out).rstrip() + "\n"


DEFAULT_BASELINE = ROOT / "linux-build" / "tools" / "target-literal-baseline.json"


def per_file_counts(hits: list[Hit]) -> dict[str, int]:
    counts: Counter[str] = Counter()
    for hit in hits:
        if hit.category in {"docs", "site-copy", "target-infra"}:
            continue
        counts[hit.path] += 1
    return dict(sorted(counts.items()))


def check_baseline(hits: list[Hit], baseline_path: Path) -> int:
    """Fail when a file gains rootless literals relative to the recorded baseline.

    Prose is excluded: docs describing the rootless layout are not debt. The
    point is to stop new build/packaging code from being written against
    /var/jb while the matrix migration is still in progress -- the drift that
    put this audit 400 hits underwater between July 3 and July 29.
    """
    if not baseline_path.exists():
        print(f"baseline not found: {baseline_path}", file=sys.stderr)
        print("record one with --update-baseline", file=sys.stderr)
        return 2

    baseline = json.loads(baseline_path.read_text())["files"]
    current = per_file_counts(hits)

    regressions = []
    for path, count in current.items():
        was = baseline.get(path, 0)
        if count > was:
            regressions.append((path, was, count))

    if not regressions:
        total = sum(current.values())
        recorded = sum(baseline.values())
        print(f"OK: {total} classified literals, baseline {recorded}, no file regressed.")
        return 0

    print("New rootless literals since the recorded baseline:\n", file=sys.stderr)
    for path, was, count in regressions:
        print(f"  {path}: {was} -> {count}", file=sys.stderr)
    print(
        "\nMake these target-aware (source linux-build/target-lib.sh host-side or"
        "\n/work/target-env.sh in-container, then use $XIOS_PREFIX / $XIOS_TRIPLE),"
        "\nor record the new state with --update-baseline if they are deliberate.",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=str(ROOT), help="repo root to scan")
    parser.add_argument("--limit-per-category", type=int, default=20)
    parser.add_argument("--fail-on-hits", action="store_true")
    parser.add_argument("--baseline", default=str(DEFAULT_BASELINE))
    parser.add_argument(
        "--fail-on-new",
        action="store_true",
        help="fail if any file gained literals vs the baseline (prose excluded)",
    )
    parser.add_argument(
        "--update-baseline",
        action="store_true",
        help="rewrite the baseline from the current tree",
    )
    args = parser.parse_args()

    hits = scan(Path(args.root).resolve(), DEFAULT_LITERALS)

    if args.update_baseline:
        counts = per_file_counts(hits)
        Path(args.baseline).write_text(
            json.dumps({"total": sum(counts.values()), "files": counts}, indent=2) + "\n"
        )
        print(f"baseline written: {args.baseline} ({sum(counts.values())} literals)")
        return 0

    if args.fail_on_new:
        return check_baseline(hits, Path(args.baseline))

    print(render_markdown(hits, args.limit_per_category))
    return 1 if args.fail_on_hits and hits else 0


if __name__ == "__main__":
    raise SystemExit(main())
