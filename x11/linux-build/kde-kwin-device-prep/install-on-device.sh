#!/bin/sh
set -eu

BASE="$(cd "$(dirname "$0")" && pwd)"
DEBS="$BASE/debs"
PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if ! ls "$DEBS"/*.deb >/dev/null 2>&1; then
  echo "no debs found in $DEBS" >&2
  exit 1
fi

cd "$BASE"

if ls "$DEBS"/xios-kde_*.deb >/dev/null 2>&1 && [ ! -f "$BASE/ALLOW-XIOS-KDE" ]; then
  echo "refusing to install the unfinished full KDE meta set from this prep script" >&2
  exit 1
fi

if [ -f "$BASE/SHA256SUMS" ] && command -v sha256sum >/dev/null 2>&1; then
  echo "==> verifying staged package checksums"
  (cd "$BASE" && sha256sum -c SHA256SUMS)
fi

echo "==> KDE/KF6/KWin prep: installing package set only; nothing will be launched"
apt-get update >/dev/null 2>&1 || true

SKIPPED="$BASE/skipped-newer-installed"
rm -rf "$SKIPPED"
mkdir -p "$SKIPPED"
for f in "$DEBS"/*.deb; do
  pkg="$(dpkg-deb -f "$f" Package 2>/dev/null || true)"
  ver="$(dpkg-deb -f "$f" Version 2>/dev/null || true)"
  [ -n "$pkg" ] || continue
  [ -n "$ver" ] || continue
  inst="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  [ -n "$inst" ] || continue
  if dpkg --compare-versions "$inst" gt "$ver"; then
    echo "   - skipping older staged $pkg $ver; installed is $inst"
    mv "$f" "$SKIPPED/"
  fi
done

LOCAL_PKGS="$(for f in "$DEBS"/*.deb; do dpkg-deb -f "$f" Package 2>/dev/null || true; done | sort -u)"

has_local_pkg() {
  printf '%s\n' "$LOCAL_PKGS" | grep -qx "$1"
}

dep_names_from_deb() {
  { dpkg-deb -f "$1" Pre-Depends 2>/dev/null || true; \
    dpkg-deb -f "$1" Depends 2>/dev/null || true; } \
    | tr ',' '\n' \
    | sed 's/|.*//' \
    | sed 's/(.*)//' \
    | sed 's/^[[:space:]]*//' \
    | sed 's/[[:space:]]*$//' \
    | sed '/^$/d' \
    | sort -u
}

FRONTIER="$(for f in "$DEBS"/*.deb; do dep_names_from_deb "$f"; done | sort -u)"
CLOSURE="$(for p in $FRONTIER; do
  has_local_pkg "$p" && continue
  apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances "$p" 2>/dev/null \
    | awk "/^[[:alnum:]][[:alnum:].+:-]*/ { print \$1 }"
done | sort -u)"

cd "$DEBS"
for p in $FRONTIER $CLOSURE; do
  case "$p" in ""|"<"*) continue ;; esac
  has_local_pkg "$p" && continue
  dpkg -s "$p" >/dev/null 2>&1 && continue
  ls "${p}_"*.deb >/dev/null 2>&1 && continue
  apt-get download "$p" 2>/dev/null && echo "   + fetched $p" || true
done

echo "==> dpkg installing staged debs"
dpkg -i --force-overwrite ./*.deb

echo "==> apt consistency check"
apt-get check

cat > "$BASE/RUN-LATER.txt" <<'NOTE'
KDE/KF6/KWin/Plasma packages were staged for first-light testing.

This prep script did not start iosc, kwin_wayland, plasmashell, xios-session,
or any other compositor/session process.

Next run can install the `xios-session` launcher package and explicitly smoke
test `xios-session kde`, with the foreground app awake and logs open, so outer
iosc startup, KWin socket creation, plasmashell startup, frame callbacks,
teardown, and the QtWayland/ANGLE path can be observed deliberately.
NOTE

echo "==> ready at $BASE; no compositor was launched"
