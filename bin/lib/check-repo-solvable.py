#!/usr/bin/env python3
"""Pre-publish solvability check for the APT repo.

Fails (exit 1) if any package's Depends/Pre-Depends either names a package that is
not present in repo/Packages (as a real Package or via Provides), or names one we
publish at a version too old to satisfy the constraint -- so the store never
advertises an impossible install (e.g. a flavor meta depending on an unbuilt pkg,
or a meta pinned to a leaf deb that was never rebuilt).

Version constraints are only enforced against packages WE publish; deps satisfied
by the Procursus base or by a Provides carry no version here and are accepted.

Run over the WHOLE repo, not just metas. A small allowlist covers virtual/base
names that live outside our repo (firmware, the Procursus base, etc.).

Usage: bin/lib/check-repo-solvable.py [repo/Packages]   (default: repo/Packages)
Exit 0 = clean, 1 = at least one unresolvable dependency.
"""
import json
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


ALT_RE = re.compile(r"^(?P<name>[^\s(]+)\s*(?:\(\s*(?P<op>[<>=]+)\s*(?P<ver>[^)]+?)\s*\))?$")


def dep_clauses(field):
    """Yield each comma-separated dependency as a list of (name, op, ver) alternatives.

    op/ver are None when the dependency carries no version constraint.
    """
    for clause in field.split(","):
        clause = clause.strip()
        if not clause:
            continue
        alts = []
        for alt in clause.split("|"):
            alt = alt.strip()
            if not alt:
                continue
            m = ALT_RE.match(alt)
            if not m:  # unparseable -> treat as a bare name, never as a hard fail
                alts.append((alt.split()[0].split(":")[0], None, None))
                continue
            name = m.group("name").split(":")[0]  # strip :any arch-qualifier
            if name:
                alts.append((name, m.group("op"), m.group("ver")))
        if alts:
            yield alts


def _order(c):
    """dpkg character collation: '~' sorts before everything, letters before punctuation."""
    if c == "":
        return 0
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    if c == "~":
        return -1
    return ord(c) + 256


def _verrevcmp(a, b):
    """dpkg's upstream/revision comparison (see deb-version(7))."""
    i = j = 0
    while i < len(a) or j < len(b):
        first_diff = 0
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = _order(a[i]) if i < len(a) else 0
            bc = _order(b[j]) if j < len(b) else 0
            if ac != bc:
                return ac - bc
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        while i < len(a) and a[i].isdigit() and j < len(b) and b[j].isdigit():
            if not first_diff:
                first_diff = ord(a[i]) - ord(b[j])
            i += 1
            j += 1
        if i < len(a) and a[i].isdigit():
            return 1
        if j < len(b) and b[j].isdigit():
            return -1
        if first_diff:
            return first_diff
    return 0


def _split_version(v):
    v = v.strip()
    epoch = 0
    if ":" in v:
        head, _, rest = v.partition(":")
        if head.isdigit():
            epoch, v = int(head), rest
    if "-" in v:
        upstream, _, revision = v.rpartition("-")
    else:
        upstream, revision = v, ""
    return epoch, upstream, revision


def version_compare(v1, v2):
    """Return <0, 0, >0 like dpkg --compare-versions."""
    e1, u1, r1 = _split_version(v1)
    e2, u2, r2 = _split_version(v2)
    if e1 != e2:
        return -1 if e1 < e2 else 1
    c = _verrevcmp(u1, u2)
    return c if c else _verrevcmp(r1, r2)


def constraint_ok(have, op, want):
    c = version_compare(have, want)
    if op in (">=", ">"):  # ">" is the deprecated dpkg spelling of ">="
        return c >= 0
    if op == ">>":
        return c > 0
    if op in ("<=", "<"):
        return c <= 0
    if op == "<<":
        return c < 0
    if op == "=":
        return c == 0
    return True  # unknown operator: do not invent a failure


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

    # Versions of the packages WE publish. Only these can have a version constraint
    # checked: base/Provides names carry no version we can see from here, so a
    # constraint against one is accepted rather than guessed at.
    ours = {s["Package"]: s.get("Version", "") for s in stanzas if s.get("Version")}

    problems = []  # (package, dep-clause-as-text, reason)
    for s in stanzas:
        for field in ("Pre-Depends", "Depends"):
            val = s.get(field, "")
            if not val:
                continue
            for alts in dep_clauses(val):
                if any(
                    name in available
                    and (op is None or name not in ours or constraint_ok(ours[name], op, ver))
                    for name, op, ver in alts
                ):
                    continue
                text = " | ".join(
                    f"{n} ({o} {v})" if o else n for n, o, v in alts
                )
                # Distinguish "no such package" from "package is here but too old",
                # because the two have completely different fixes.
                if any(n in available for n, _, _ in alts):
                    have = ", ".join(
                        f"{n} {ours[n]}" for n, _, _ in alts if n in ours
                    )
                    reason = f"version too low (published: {have or 'unknown'})"
                else:
                    reason = "no such package"
                problems.append((s["Package"], text, reason))

    # Known-broken pairs that predate this check (see the file's own _comment).
    # They are reported every run but do not fail the publish, so the gate can be
    # enforcing for NEW breakage without first requiring a 48-package cleanup.
    baseline = {}
    base_path = os.path.join(REPO, "bin", "lib", "solvable-baseline.json")
    if os.path.exists(base_path):
        with open(base_path, encoding="utf-8") as fh:
            baseline = {k: v for k, v in json.load(fh).items() if not k.startswith("_")}

    fatal, known = [], []
    for pkg, dep, reason in problems:
        (known if dep in baseline.get(pkg, {}) else fatal).append((pkg, dep, reason))

    if known:
        print(f"KNOWN-BROKEN, not failing ({len(known)}):", file=sys.stderr)
        for pkg, dep, _ in sorted(known):
            print(f"  {pkg}  ->  {dep}", file=sys.stderr)

    # A baseline entry that no longer fires has been fixed -- say so, so the file
    # shrinks instead of quietly accumulating waivers for problems that are gone.
    live = {(p, d) for p, d, _ in problems}
    stale = [(p, d) for p, deps in baseline.items() for d in deps if (p, d) not in live]
    if stale:
        print(f"\nSTALE baseline entries ({len(stale)}) -- fixed, drop them from "
              f"{os.path.relpath(base_path, REPO)}:", file=sys.stderr)
        for pkg, dep in sorted(stale):
            print(f"  {pkg}  ->  {dep}", file=sys.stderr)

    if fatal:
        print(f"\nUNRESOLVABLE DEPENDENCIES ({len(fatal)}):", file=sys.stderr)
        for pkg, dep, reason in sorted(fatal):
            print(f"  {pkg}  ->  {dep}   [{reason}]", file=sys.stderr)
        print(
            "\nFAIL: repo advertises impossible installs. Fix the Depends or drop the "
            "package from the published set before publishing.",
            file=sys.stderr,
        )
        return 1
    print(f"OK: all Depends/Pre-Depends resolvable across {len(stanzas)} packages"
          + (f" ({len(known)} known-broken ignored)." if known else "."))
    return 0


if __name__ == "__main__":
    sys.exit(main())
