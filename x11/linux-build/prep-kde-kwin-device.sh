#!/usr/bin/env bash
# Stage and install the first-light KDE/KF6/KWin/Plasma runtime set on the device.
#
# This is intentionally a prep-only script: it copies and installs packages, writes
# a small "run later" note, and does not start iosc, kwin_wayland, Plasma, or any
# session daemon.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11_ROOT="$(cd "$HERE/.." && pwd)"
STAGE="${STAGE:-$HERE/kde-kwin-device-prep}"
REMOTE="${REMOTE:-/var/jb/tmp/kde-kwin-prep}"
VOLUME="${VOLUME:-procursus-vol-kf6}"
IMAGE="${IMAGE:-procursus-xbuild:bookworm-arm64}"

source "$X11_ROOT/apps/iosc-desktop/deploy-env.sh"

usage() {
  cat <<'EOF'
usage: linux-build/prep-kde-kwin-device.sh [--stage-only] [--install]

Stages the latest runtime Qt6/KF6/KWin/Plasma debs from procursus-vol-kf6,
overlays the fresh local Qt/KWin/Plasma/session debs from linux-build/out,
pushes them to the device, and installs them with dpkg. It never launches KWin
or Plasma.

Options:
  --stage-only   build the local staging directory, but do not contact device
  --install      also run the on-device installer after pushing (default)

Environment:
  STAGE=/path     local staging directory (default: linux-build/kde-kwin-device-prep)
  REMOTE=/path    device staging directory (default: /var/jb/tmp/kde-kwin-prep)
  VOLUME=name     Procursus Docker volume (default: procursus-vol-kf6)
  IMAGE=name      Docker image (default: procursus-xbuild:bookworm-arm64)
EOF
}

DO_PUSH=1
DO_INSTALL=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only)
      DO_PUSH=0
      DO_INSTALL=0
      ;;
    --install)
      DO_INSTALL=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

rm -rf "$STAGE"
mkdir -p "$STAGE/debs"

echo "==> staging runtime KDE/KF6/Qt6/KWin debs from Docker volume: $VOLUME"
docker run --rm --platform linux/arm64 \
  -v "$VOLUME:/work/Procursus" \
  -v "$STAGE/debs:/out" \
  "$IMAGE" \
  -c '
set -eu
SRC=/work/Procursus/build_dist/iphoneos-arm64-rootless/1900
TMP=/tmp/kde-kwin-runtime
rm -rf "$TMP"
mkdir -p "$TMP"
find "$SRC" -maxdepth 2 -type f -name "*.deb" | while IFS= read -r deb; do
  pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null || true)
  ver=$(dpkg-deb -f "$deb" Version 2>/dev/null || true)
  [ -n "$pkg" ] || continue
  case "$pkg" in
    *-dev) continue ;;
    qt6-*|kf6-*|kwin|kdecoration|kglobalacceld|kactivitymanagerd|kwayland|layer-shell-qt|libplasma|plasma-activities|plasma-activities-stats|plasma-workspace|plasma-desktop|plasma-nano|plasma-mobile|plasma5support|plasma-pa|plasma-wayland-protocols|qcoro6|libdrm2|libgbm1|libdisplay-info1) ;;
    *) continue ;;
  esac
  old=$(find "$TMP" -maxdepth 1 -type f -name "${pkg}_*.deb" -print -quit)
  if [ -z "$old" ]; then
    cp "$deb" "$TMP/"
    continue
  fi
  oldver=$(dpkg-deb -f "$old" Version 2>/dev/null || true)
  if dpkg --compare-versions "$ver" gt "$oldver"; then
    rm -f "$old"
    cp "$deb" "$TMP/"
  fi
done
cp -v "$TMP"/*.deb /out/
'

echo "==> overlaying fresh local Qt/KWin/Plasma/session runtime debs from linux-build/out"
overlay_out() {
  local pattern deb base pkg
  for pattern in "$@"; do
    for deb in "$HERE/out"/$pattern; do
      [ -f "$deb" ] || continue
      base="$(basename "$deb")"
      pkg="${base%%_*}"
      case "$pkg" in
        *-dev|xios-kde) continue ;;
      esac
      cp -v "$deb" "$STAGE/debs/"
    done
  done
}

overlay_out \
  qt6-*_*_iphoneos-arm64.deb \
  kwin_*_iphoneos-arm64.deb \
  libdrm2_*_iphoneos-arm64.deb \
  libgbm1_*_iphoneos-arm64.deb \
  libdisplay-info1_*_iphoneos-arm64.deb \
  libplasma_*_iphoneos-arm64.deb \
  plasma-activities-stats_*_iphoneos-arm64.deb \
  kactivitymanagerd_*_iphoneos-arm64.deb \
  plasma-workspace_*_iphoneos-arm64.deb \
  plasma-desktop_*_iphoneos-arm64.deb \
  plasma-nano_*_iphoneos-arm64.deb \
  plasma-mobile_*_iphoneos-arm64.deb \
  plasma5support_*_iphoneos-arm64.deb \
  plasma-pa_*_iphoneos-arm64.deb \
  kf6-bluezqt_*_iphoneos-arm64.deb \
  kf6-pulseaudio-qt_*_iphoneos-arm64.deb \
  libpulse0_*_iphoneos-arm64.deb \
  qcoro6_*_iphoneos-arm64.deb \
  kf6-attica_*_iphoneos-arm64.deb \
  kf6-declarative_*_iphoneos-arm64.deb \
  kf6-runner_*_iphoneos-arm64.deb \
  kf6-kded_*_iphoneos-arm64.deb \
  kf6-statusnotifieritem_*_iphoneos-arm64.deb \
  kf6-unitconversion_*_iphoneos-arm64.deb \
  kf6-parts_*_iphoneos-arm64.deb \
  kf6-newstuff_*_iphoneos-arm64.deb \
  kf6-wallet_*_iphoneos-arm64.deb \
  kf6-notifyconfig_*_iphoneos-arm64.deb \
  kf6-qqc2-desktop-style_*_iphoneos-arm64.deb \
  xios-session_*_iphoneos-arm64.deb

echo "==> keeping only the newest staged deb for each package"
docker run --rm --platform linux/arm64 \
  -v "$STAGE/debs:/debs" \
  "$IMAGE" \
  -c '
set -eu
TMP=/tmp/kde-prep-dedupe
rm -rf "$TMP"
mkdir -p "$TMP"
for deb in /debs/*.deb; do
  [ -f "$deb" ] || continue
  pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null || true)
  ver=$(dpkg-deb -f "$deb" Version 2>/dev/null || true)
  [ -n "$pkg" ] || continue
  [ -n "$ver" ] || continue
  old=$(find "$TMP" -maxdepth 1 -type f -name "${pkg}_*.deb" -print -quit)
  if [ -z "$old" ]; then
    cp "$deb" "$TMP/"
    continue
  fi
  oldver=$(dpkg-deb -f "$old" Version 2>/dev/null || true)
  if dpkg --compare-versions "$ver" gt "$oldver"; then
    rm -f "$old"
    cp "$deb" "$TMP/"
  fi
done
rm -f /debs/*.deb
cp "$TMP"/*.deb /debs/
'

echo "==> normalizing KWin app wrappers to the rootless app path"
docker run --rm --platform linux/arm64 \
  -v "$STAGE/debs:/debs" \
  "$IMAGE" \
  -c '
set -eu
deb=$(find /debs -maxdepth 1 -type f -name "kwin_*_iphoneos-arm64.deb" -print -quit)
[ -n "$deb" ] || exit 0
work=$(mktemp -d)
dpkg-deb -R "$deb" "$work/pkg"
if [ -d "$work/pkg/Applications" ]; then
  mkdir -p "$work/pkg/var/jb"
  rm -rf "$work/pkg/var/jb/Applications"
  mv "$work/pkg/Applications" "$work/pkg/var/jb/Applications"
  dpkg-deb -Zzstd -b "$work/pkg" "$work/kwin-rootless.deb" >/dev/null
  mv "$work/kwin-rootless.deb" "$deb"
  echo "   repacked $(basename "$deb") with /var/jb/Applications"
else
  echo "   $(basename "$deb") already uses a rootless app path"
fi
'

cat > "$STAGE/install-on-device.sh" <<'EOF'
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

if ls "$DEBS"/xios-kde_*.deb >/dev/null 2>&1; then
  echo "refusing to install the unfinished full KDE meta set from this prep script" >&2
  exit 1
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
  dpkg-deb -f "$1" Pre-Depends Depends 2>/dev/null \
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
EOF
chmod +x "$STAGE/install-on-device.sh"

cat > "$STAGE/README.txt" <<EOF
KDE/KF6/KWin/Plasma first-light device prep bundle.

Created by: linux-build/prep-kde-kwin-device.sh
Remote path: $REMOTE

Contents:
- debs/: runtime Qt6, KF6, KWayland/KWin, Plasma Workspace/Nano/Mobile, xios-session, and shim packages
- install-on-device.sh: installs the package set and writes RUN-LATER.txt

This bundle deliberately excludes xios-kde.
It does not launch any compositor or session process.
EOF

printf "==> staged %s debs in %s\n" "$(find "$STAGE/debs" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')" "$STAGE"

if [ "$DO_PUSH" -eq 0 ]; then
  echo "==> stage-only requested; not contacting device"
  exit 0
fi

echo "==> checking device reachability: root@$IP:$PORT"
ssh_ "true"

echo "==> pushing prep bundle to $REMOTE"
ssh_ "rm -rf '$REMOTE' && mkdir -p '$REMOTE/debs'"
scp_ "$STAGE/install-on-device.sh" "$STAGE/README.txt" "root@$IP:$REMOTE/"
scp_ "$STAGE/debs/"*.deb "root@$IP:$REMOTE/debs/"

if [ "$DO_INSTALL" -eq 0 ]; then
  echo "==> pushed only; not installing"
  exit 0
fi

echo "==> running on-device installer; this will not launch KWin or Plasma"
ssh_ "cd '$REMOTE' && sh ./install-on-device.sh"

echo "==> device prep complete; nothing was launched"
