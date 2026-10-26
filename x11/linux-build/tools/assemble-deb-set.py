#!/usr/bin/env python3
"""Assemble an install set: a staged lane, minus the debs a fix pass superseded, plus the fixed debs.

    assemble-deb-set.py <STAGED.txt> <staged-dir> <fixed-dir> <dest-dir>

STAGED.txt rows are `name version sha256 file` (KDE67-STAGED.txt). Every deb in <fixed-dir> replaces the
staged deb of the same package name (or is added if the staged set had none). <dest-dir> is recreated.
Stdout is the fixed-deb listing, one row per deb:

    name version sha256 file supersedes <name> <old version> (<old file>) | NEW

which is the body of KDE67-FIXED.txt. The final counts go to stderr.
"""
import hashlib
import os
import shutil
import sys

staged_txt, staged_dir, fixed_dir, final_dir = sys.argv[1:5]
staged = {}
for line in open(staged_txt):
    name, ver, sha, fn = line.split()
    staged[name] = (ver, sha, fn)
fixed = {}
for fn in sorted(os.listdir(fixed_dir)):
    if fn.endswith(".deb"):
        name, ver, _ = fn.split("_", 2)
        fixed[name] = (ver, fn)
shutil.rmtree(final_dir, ignore_errors=True)
os.makedirs(final_dir)
for name, (ver, sha, fn) in staged.items():
    if name not in fixed:
        shutil.copy(os.path.join(staged_dir, fn), os.path.join(final_dir, fn))
rows = []
for name, (ver, fn) in fixed.items():
    shutil.copy(os.path.join(fixed_dir, fn), os.path.join(final_dir, fn))
    with open(os.path.join(fixed_dir, fn), "rb") as f:
        sha = hashlib.sha256(f.read()).hexdigest()
    old = staged.get(name)
    rows.append("%s %s %s %s supersedes %s" % (
        name, ver, sha, fn, "%s %s (%s)" % (name, old[0], old[2]) if old else "NEW"))
print("\n".join(rows))
print("set: %d debs (staged %d, replaced %d, new %d)" % (
    len(os.listdir(final_dir)), len(staged),
    sum(1 for n in fixed if n in staged), sum(1 for n in fixed if n not in staged)), file=sys.stderr)
