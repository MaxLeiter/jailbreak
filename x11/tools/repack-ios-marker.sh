#!/usr/bin/env bash
# Runs INSIDE procursus-xbuild. Appends +ios1 to upstream-port debs in /debs.
# MODE=plan (default) lists old->new; MODE=apply repacks + renames in place.
#
# LANDMINE (cost 44 uninstallable packages, 2026-08-09): this rewrites `Version:`
# only. A library and its -dev sibling interpolate the SAME @DEB_*_V@ in their
# control templates, so the -dev carries `Depends: lib (= <version>)`. Bumping
# both Versions here without touching that pin left the -dev depending on a
# version that no longer existed -- kf6-archive-dev 6.3.0+ios1 wanting
# kf6-archive (= 6.3.0). The solvable gate was name-only then and did not catch it.
# The pass below rewrites those pins for packages bumped in the SAME run.
# Repairing the already-published debs is x11/tools/relax-dev-exact-pins.py.
set -eu
DEBS=/debs
MODE="${MODE:-plan}"

# Our own originals (never marked). xios-* / com.max.* matched broadly.
skip_name_re='^(iosc|iosc-shell|xios-[a-z0-9-]+|com\.max\..*|libgtkintl|bun-preflight|x11-fonts-sf|qt-wayland-gl-smoke)$'
# Already-marked upstream ports (our build tag already present).
marker_re='[+~](ios|wl|angle|rootless|es3|xios)'

n_bump=0 n_ours=0 n_mark=0
for f in "$DEBS"/*.deb; do
  pkg=$(dpkg-deb -f "$f" Package)
  ver=$(dpkg-deb -f "$f" Version)
  arch=$(dpkg-deb -f "$f" Architecture)
  if echo "$pkg" | grep -qE "$skip_name_re"; then
    echo "SKIP-OURS  $pkg  $ver"; n_ours=$((n_ours+1)); continue
  fi
  if echo "$ver" | grep -qE "$marker_re"; then
    echo "SKIP-MARK  $pkg  $ver"; n_mark=$((n_mark+1)); continue
  fi
  newver="${ver}+ios1"
  echo "BUMP       $pkg  $ver -> $newver"
  n_bump=$((n_bump+1))
  if [ "$MODE" = apply ]; then
    tmp=$(mktemp -d)
    dpkg-deb -R "$f" "$tmp"
    sed -i -E "s/^Version:[[:space:]].*/Version: ${newver}/" "$tmp/DEBIAN/control"
    got=$(grep -E '^Version:' "$tmp/DEBIAN/control" | awk '{print $2}')
    [ "$got" = "$newver" ] || { echo "ERROR: control rewrite failed for $pkg ($got)"; exit 1; }
    out="$DEBS/${pkg}_${newver}_${arch}.deb"
    dpkg-deb -Zzstd --build "$tmp" "$out" >/dev/null
    rm -f "$f"; rm -rf "$tmp"
  fi
done
echo "---"
echo "bump=$n_bump  skip-ours=$n_ours  skip-already-marked=$n_mark"

# Second pass: repoint intra-batch `= <old>` pins at the versions we just bumped.
# Without this a -dev keeps depending on its sibling's pre-bump version, which no
# longer exists anywhere -- see the LANDMINE note at the top.
if [ "$MODE" = apply ]; then
  echo "--- repointing exact pins onto the bumped versions"
  n_fix=0
  for f in "$DEBS"/*.deb; do
    deps=$(dpkg-deb -f "$f" Depends 2>/dev/null || true)
    case "$deps" in *"(= "*) ;; *) continue ;; esac
    new_deps="$deps"
    # for each `name (= ver)`, if `name` was bumped this run, point at its new version
    for ref in $(echo "$deps" | grep -oE '[a-zA-Z0-9.+-]+ \(= [^)]+\)' | sed 's/ (= /=/; s/)$//'); do
      rname="${ref%%=*}"; rver="${ref#*=}"
      bumped=$(ls "$DEBS/${rname}_"*.deb 2>/dev/null | while read -r c; do
                 [ "$(dpkg-deb -f "$c" Package)" = "$rname" ] && dpkg-deb -f "$c" Version; done \
               | grep -E "^${rver}\+ios[0-9]+$" | head -1)
      [ -n "$bumped" ] || continue
      new_deps=$(echo "$new_deps" | sed "s|${rname} (= ${rver})|${rname} (= ${bumped})|")
    done
    [ "$new_deps" = "$deps" ] && continue
    pkg=$(dpkg-deb -f "$f" Package); ver=$(dpkg-deb -f "$f" Version); arch=$(dpkg-deb -f "$f" Architecture)
    echo "REPIN      $pkg  $ver"
    echo "             - $deps"
    echo "             + $new_deps"
    tmp=$(mktemp -d)
    dpkg-deb -R "$f" "$tmp"
    python3 - "$tmp/DEBIAN/control" "$new_deps" <<'PY'
import sys, re
path, deps = sys.argv[1], sys.argv[2]
text = open(path).read()
open(path, "w").write(re.sub(r"^Depends: .*$", "Depends: " + deps, text, count=1, flags=re.M))
PY
    rm -f "$f"
    dpkg-deb -Zzstd --build "$tmp" "$DEBS/${pkg}_${ver}_${arch}.deb" >/dev/null
    rm -rf "$tmp"
    n_fix=$((n_fix+1))
  done
  echo "repinned=$n_fix"
fi
