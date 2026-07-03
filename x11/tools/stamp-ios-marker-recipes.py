#!/usr/bin/env python3
# Append +ios1 to the deb-version seam (DEB_*_V ?= $(*_VERSION)[-N]) in Procursus
# recipes, so a future rebuild keeps the marker. Skips lines that already carry an
# our-build marker (+ios/+wl/+angle/+rootless/+es3/+xios/~ios).
import re, sys, glob, os
RECIPES = sys.argv[1]
seam = re.compile(r'^(\s*DEB_[A-Z0-9_-]+_V\s*[:?]?=\s*\$\([A-Z0-9_-]+_VERSION\))(\S*)(\s*)$')
marker = re.compile(r'[+~](ios|wl|angle|rootless|es3|xios)')
changed = []
for path in sorted(glob.glob(os.path.join(RECIPES, '*.mk'))):
    lines = open(path).read().splitlines(keepends=True)
    hit = False
    for i, ln in enumerate(lines):
        m = seam.match(ln.rstrip('\n'))
        if not m:
            continue
        suffix = m.group(2)
        if marker.search(suffix):
            continue  # already marked
        nl = ln[-1] == '\n'
        lines[i] = m.group(1) + suffix + '+ios1' + (m.group(3) or '') + ('\n' if nl else '')
        hit = True
        changed.append((os.path.basename(path), m.group(1).split('?=')[0].strip(), suffix or '(none)'))
    if hit:
        open(path, 'w').write(''.join(lines))
for c in changed:
    print(f'STAMP {c[0]:28} {c[1]:22} suffix={c[2]}')
print(f'--- {len(changed)} deb-version lines stamped across {len(set(c[0] for c in changed))} recipes')
