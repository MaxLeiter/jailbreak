#!/usr/bin/env bash
# Runs INSIDE procursus-xbuild. Appends +ios1 to upstream-port debs in /debs.
# MODE=plan (default) lists old->new; MODE=apply repacks + renames in place.
set -eu
DEBS=/debs
MODE="${MODE:-plan}"

# Our own originals (never marked). xios-* / com.max.* matched broadly.
skip_name_re='^(iosc|iosc-shell|xios-[a-z0-9-]+|com\.max\..*|libgtkintl|bun-preflight|x11-fonts-sf|qt-wayland-gl-smoke|ladybird-xios-launcher)$'
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
