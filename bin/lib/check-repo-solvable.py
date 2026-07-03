#!/usr/bin/env python3
"""Pre-publish solvability check for the APT repo.

Fails (exit 1) if any package's Depends/Pre-Depends names a package that is not
present in repo/Packages (as a real Package or via Provides), so the store never
advertises an impossible install (e.g. a flavor meta depending on an unbuilt pkg).

Run over the WHOLE repo, not just metas. A small allowlist covers virtual/base
names that live outside our repo (firmware, the Procursus base, etc.).

Usage: bin/lib/check-repo-solvable.py [repo/Packages]   (default: repo/Packages)
Exit 0 = clean, 1 = at least one unresolvable dependency.
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PACKAGES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "repo", "Packages")

# Names satisfied outside our repo (Procursus base / virtual / bootstrap). These are
# assumed present on any target device. Keep this list tight and intentional.
ALLOW = {
    "firmware",            # iOS version virtual (firmware (>= 16.x))
    "apt", "dpkg", "base", # bootstrap
}


def parse(path):
    stanzas = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for block in fh.read().split("\n\n"):
            if not block.strip():
                continue
            d = {}
            key = None
            for line in block.splitlines():
                if line[:1] in (" ", "\t") and key:
                    d[key] += " " + line.strip()
                elif ":" in line:
                    key, _, val = line.partition(":")
                    key = key.strip()
                    d[key] = val.strip()
            if d.get("Package"):
                stanzas.append(d)
    return stanzas


def dep_names(field):
    """Yield the set of alternative names for each comma-separated dependency."""
    for clause in field.split(","):
        clause = clause.strip()
        if not clause:
            continue
        alts = []
        for alt in clause.split("|"):
            name = alt.strip().split()[0] if alt.strip() else ""
            name = name.split(":")[0]  # strip :any arch-qualifier
            if name:
                alts.append(name)
        if alts:
            yield alts


def main():
    stanzas = parse(PACKAGES)
    available = set(ALLOW)

    # Base universe: names satisfiable outside this repo. Refresh
    # bin/lib/procursus-base-names.txt from a device by collecting Package/Provides
    # from non-Max apt lists plus dpkg status, then stripping versions/arch quals.
    base_file = os.path.join(REPO, "bin", "lib", "procursus-base-names.txt")
    if os.path.exists(base_file):
        with open(base_file, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                n = line.strip()
                if n:
                    available.add(n)
    else:
        print(f"WARN: {base_file} missing — Procursus base deps will be flagged as "
              "false positives.", file=sys.stderr)
    for s in stanzas:
        available.add(s["Package"])
        for pv in s.get("Provides", "").split(","):
            pv = pv.strip().split()[0].split(":")[0] if pv.strip() else ""
            if pv:
                available.add(pv)

    problems = []  # (package, dep-clause-as-text)
    for s in stanzas:
        for field in ("Pre-Depends", "Depends"):
            val = s.get(field, "")
            if not val:
                continue
            for alts in dep_names(val):
                if not any(a in available for a in alts):
                    problems.append((s["Package"], " | ".join(alts)))

    if problems:
        print(f"UNRESOLVABLE DEPENDENCIES ({len(problems)}):", file=sys.stderr)
        for pkg, dep in sorted(problems):
            print(f"  {pkg}  ->  {dep}", file=sys.stderr)
        print(
            "\nFAIL: repo advertises impossible installs. Fix the Depends or drop the "
            "package from the published set before publishing.",
            file=sys.stderr,
        )
        return 1
    print(f"OK: all Depends/Pre-Depends resolvable across {len(stanzas)} packages.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
