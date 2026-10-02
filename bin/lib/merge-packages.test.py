#!/usr/bin/env python3
"""Exercise bin/lib/merge-packages.py (the repo/Packages merge driver)."""
import os, subprocess, sys, tempfile

DRIVER = "bin/lib/merge-packages.py"


def stanza(pkg, ver, sha="a" * 64, section="Tweaks"):
    return (f"Package: {pkg}\nVersion: {ver}\nSection: {section}\n"
            f"Filename: debs/{pkg}_{ver}_iphoneos-arm64.deb\nSHA256: {sha}")


def index(*stanzas):
    return "\n\n".join(stanzas) + "\n"


def merge(base, ours, theirs):
    with tempfile.TemporaryDirectory() as td:
        paths = []
        for name, text in (("O", base), ("A", ours), ("B", theirs)):
            paths.append(os.path.join(td, name))
            with open(paths[-1], "w") as fh:
                fh.write(text)
        p = subprocess.run([sys.executable, DRIVER, *paths, "repo/Packages"],
                           capture_output=True, text=True)
        with open(paths[1]) as fh:
            return p.returncode, fh.read()


foo1, bar1 = stanza("foo", "1.0"), stanza("bar", "1.0")
foo1_edited = stanza("foo", "1.0", section="Utilities")   # same payload, new stanza
foo2 = stanza("foo", "1.1", sha="b" * 64)
foo1_rebuilt = stanza("foo", "1.0", sha="c" * 64)          # same version, new bytes
baz1 = stanza("baz", "1.0")

CASES = [
    # name, base, ours, theirs, want exit, want output
    ("cosmetic edit on theirs only", index(bar1, foo1), index(bar1, foo1),
     index(bar1, foo1_edited), 0, index(bar1, foo1_edited)),
    ("cosmetic edit on ours only", index(bar1, foo1), index(bar1, foo1_edited),
     index(bar1, foo1), 0, index(bar1, foo1_edited)),
    ("newer version wins", index(bar1, foo1), index(bar1, foo1),
     index(bar1, foo2), 0, index(bar1, foo2)),
    ("retired on theirs, untouched on ours", index(bar1, foo1), index(bar1, foo1),
     index(bar1), 0, index(bar1)),
    ("each side adds a package", index(foo1), index(bar1, foo1),
     index(baz1, foo1), 0, index(bar1, baz1, foo1)),
    ("same version, different bytes", index(foo1), index(foo1),
     index(foo1_rebuilt), 1, None),
]

fails = 0
for name, base, ours, theirs, want_rc, want_out in CASES:
    rc, out = merge(base, ours, theirs)
    ok = rc == want_rc and (want_out is None or out == want_out)
    fails += not ok
    print(f"{'ok  ' if ok else 'FAIL'}  {name:38} exit={rc} want={want_rc}")

print("\nall passed" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
