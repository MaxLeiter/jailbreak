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
REPO_DEBS="${REPO_DEBS:-$X11_ROOT/../repo/debs}"

source "$X11_ROOT/apps/iosc-desktop/deploy-env.sh"

docker_linux() {
  docker run --rm --platform linux/arm64 "$@"
}

usage() {
  cat <<'EOF'
usage: linux-build/prep-kde-kwin-device.sh [--stage-only] [--install] [--include-meta] [--use-existing]

Stages the latest runtime Qt6/KF6/KWin/Plasma debs from procursus-vol-kf6,
overlays the fresh local Qt/KWin/Plasma/session debs from linux-build/out,
pushes them to the device, and installs them with dpkg. It never launches KWin
or Plasma.

Options:
  --stage-only   build the local staging directory, but do not contact device
  --install      also run the on-device installer after pushing (default)
  --include-meta include the current finalized xios-kde release candidate and
                 its repo-local direct dependencies
  --use-existing push/install the already assembled STAGE without rebuilding it

Environment:
  STAGE=/path     local staging directory (default: linux-build/kde-kwin-device-prep)
  REMOTE=/path    device staging directory (default: /var/jb/tmp/kde-kwin-prep)
  VOLUME=name     Procursus Docker volume (default: procursus-vol-kf6)
  IMAGE=name      Docker image (default: procursus-xbuild:bookworm-arm64)
  REPO_DEBS=/path finalized package directory (default: top-level repo/debs)
EOF
}

DO_PUSH=1
DO_INSTALL=1
INCLUDE_META=0
USE_EXISTING=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only)
      DO_PUSH=0
      DO_INSTALL=0
      ;;
    --install)
      DO_INSTALL=1
      ;;
    --include-meta)
      INCLUDE_META=1
      ;;
    --use-existing)
      USE_EXISTING=1
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

if [ "$USE_EXISTING" -eq 1 ]; then
  [ -d "$STAGE/debs" ] || { echo "ERROR: existing stage has no debs/: $STAGE" >&2; exit 1; }
  [ -f "$STAGE/SHA256SUMS" ] || { echo "ERROR: existing stage has no SHA256SUMS: $STAGE" >&2; exit 1; }
  echo "==> verifying frozen host bundle: $STAGE"
  (cd "$STAGE" && shasum -a 256 -c SHA256SUMS)
else
rm -rf "$STAGE"
mkdir -p "$STAGE/debs"

echo "==> staging runtime KDE/KF6/Qt6/KWin debs from Docker volume: $VOLUME"
docker_linux \
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
    qt6-*|kf6-*|kwin|kdecoration|kglobalacceld|kactivitymanagerd|kwayland|layer-shell-qt|libkscreen|kscreen|systemsettings|breeze|plasma-integration|libplasma|plasma-activities|plasma-activities-stats|plasma-workspace|plasma-desktop|plasma-nano|plasma-mobile|plasma5support|plasma-pa|plasma-wayland-protocols|qcoro6|libdrm2|libgbm1|libdisplay-info1|xios-media-server) ;;
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
  libkscreen_*_iphoneos-arm64.deb \
  kscreen_*_iphoneos-arm64.deb \
  systemsettings_*_iphoneos-arm64.deb \
  breeze_*_iphoneos-arm64.deb \
  plasma-integration_*_iphoneos-arm64.deb \
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
  kf6-kirigami-addons_*_iphoneos-arm64.deb \
  kf6-kquickcharts_*_iphoneos-arm64.deb \
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
  xios-media-server_*_iphoneos-arm64.deb \
  xios-session_*_iphoneos-arm64.deb

if [ "$INCLUDE_META" -eq 1 ]; then
  echo "==> including finalized xios-kde release candidate and direct repo dependencies"
  for pattern in \
    xios-kde_*_iphoneos-arm64.deb \
    xios-core_*_iphoneos-arm64.deb \
    iosc_*_iphoneos-arm64.deb \
    xios-session_*_iphoneos-arm64.deb \
    xios-desktop-theme_*_iphoneos-arm64.deb \
    libjpeg62-turbo_*_iphoneos-arm64.deb \
    kwin_*_iphoneos-arm64.deb \
    breeze_*_iphoneos-arm64.deb \
    plasma-workspace_*_iphoneos-arm64.deb \
    plasma-desktop_*_iphoneos-arm64.deb \
    plasma-mobile_*_iphoneos-arm64.deb \
    plasma-nano_*_iphoneos-arm64.deb \
    systemsettings_*_iphoneos-arm64.deb \
    kscreen_*_iphoneos-arm64.deb \
    kf6-kded_*_iphoneos-arm64.deb \
    qt6-wayland_*_iphoneos-arm64.deb \
    kf6-breeze-icons_*_iphoneos-arm64.deb \
    ark_*_iphoneos-arm64.deb \
    gwenview_*_iphoneos-arm64.deb \
    kwrite_*_iphoneos-arm64.deb; do
    for deb in "$REPO_DEBS"/$pattern; do
      [ -f "$deb" ] || continue
      case "$(basename "$deb")" in *-dev_*) continue ;; esac
      cp -v "$deb" "$STAGE/debs/"
    done
  done

  echo "==> folding repo-local runtime dependency closure into the bundle"
  docker_linux \
    -v "$REPO_DEBS:/repo:ro" \
    -v "$STAGE/debs:/debs" \
    "$IMAGE" \
    -c '
set -eu
best=/tmp/repo-best
rm -rf "$best"
mkdir -p "$best"
for deb in /repo/*.deb; do
  [ -f "$deb" ] || continue
  pkg=$(dpkg-deb -f "$deb" Package 2>/dev/null || true)
  ver=$(dpkg-deb -f "$deb" Version 2>/dev/null || true)
  [ -n "$pkg" ] && [ -n "$ver" ] || continue
  if [ ! -f "$best/$pkg.path" ] || dpkg --compare-versions "$ver" gt "$(cat "$best/$pkg.version")"; then
    printf "%s\n" "$deb" > "$best/$pkg.path"
    printf "%s\n" "$ver" > "$best/$pkg.version"
  fi
done

changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  for deb in /debs/*.deb; do
    [ -f "$deb" ] || continue
    dependencies=$({
      dpkg-deb -f "$deb" Pre-Depends 2>/dev/null || true
      dpkg-deb -f "$deb" Depends 2>/dev/null || true
    } | tr "," "\n")
    while IFS= read -r clause; do
      [ -n "$clause" ] || continue
      normalized=$(printf "%s\n" "$clause" | tr "|" "\n" \
        | sed "s/(.*)//; s/\[[^]]*\]//g; s/:any//g; s/^[[:space:]]*//; s/[[:space:]]*$//" \
        | sed "/^$/d")
      satisfied=0
      candidate=""
      while IFS= read -r alternative; do
        [ -n "$alternative" ] || continue
        if find /debs -maxdepth 1 -type f -name "${alternative}_*.deb" -print -quit | grep -q .; then
          satisfied=1
          break
        fi
        if [ -z "$candidate" ] && [ -f "$best/$alternative.path" ]; then
          candidate=$(cat "$best/$alternative.path")
        fi
      done <<EOF
$normalized
EOF
      [ "$satisfied" -eq 0 ] || continue
      [ -n "$candidate" ] || continue
      cp -v "$candidate" /debs/
      changed=1
    done <<EOF
$dependencies
EOF
  done
done
'
fi

echo "==> keeping only the newest staged deb for each package"
docker_linux \
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

# A filename in repo/debs is immutable and publish-finalized. If the same
# package/version was also collected from a build volume or linux-build/out,
# the repo byte is authoritative (notably for host-generated DER entitlements).
echo "==> selecting finalized repo bytes for exact staged filenames"
for staged in "$STAGE/debs"/*.deb; do
  canonical="$REPO_DEBS/$(basename "$staged")"
  [ -f "$canonical" ] || continue
  if ! cmp -s "$canonical" "$staged"; then
    cp -v "$canonical" "$staged"
  fi
done

echo "==> normalizing KWin app wrappers to the rootless app path"
docker_linux \
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

echo "==> DER re-signing graphics binaries in staged debs"
LDID="${LDID:-$(command -v ldid || true)}"
if [ -z "$LDID" ]; then
  echo "ERROR: ldid not found; cannot DER re-sign staged graphics packages" >&2
  exit 1
fi
python3 "$HERE/resign-graphics-packages.py" "$STAGE/debs" \
  --ldid "$LDID" \
  --gpu-ent "$HERE/build_info/iosc-gpu-client-ent.xml" \
  --gl-ent "$HERE/build_info/iosc-gl-ent.xml"

echo "==> verifying staged bytes against same-version finalized repo artifacts"
for staged in "$STAGE/debs"/*.deb; do
  canonical="$REPO_DEBS/$(basename "$staged")"
  [ -f "$canonical" ] || continue
  if ! cmp -s "$canonical" "$staged"; then
    echo "ERROR: staged artifact diverged from finalized repo byte: $(basename "$staged")" >&2
    exit 1
  fi
done

(cd "$STAGE" && shasum -a 256 debs/*.deb | LC_ALL=C sort > SHA256SUMS)
if [ "$INCLUDE_META" -eq 1 ]; then
  : > "$STAGE/ALLOW-XIOS-KDE"
fi

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
EOF
chmod +x "$STAGE/install-on-device.sh"

if [ "$INCLUDE_META" -eq 1 ]; then
  META_NOTE="This bundle includes the finalized xios-kde release candidate and its recursive repo-local runtime dependency closure."
else
  META_NOTE="This bundle deliberately excludes xios-kde."
fi

cat > "$STAGE/README.txt" <<EOF
KDE/KF6/KWin/Plasma first-light device prep bundle.

Created by: linux-build/prep-kde-kwin-device.sh
Remote path: $REMOTE

Contents:
- debs/: runtime Qt6, KF6, KWayland/KWin, Plasma Workspace/Nano/Mobile, xios-session, and shim packages
- install-on-device.sh: installs the package set and writes RUN-LATER.txt

$META_NOTE
It does not launch any compositor or session process.
EOF

cat > "$STAGE/DEVICE-READY-CHECKLIST.txt" <<EOF
KWin +ios5 / xios-kde 0.1.9 device gate

The bundle is already assembled and checksum-pinned at:
  $STAGE

When the iPad is available, run from the x11 directory:

  bin/xios-device doctor
  STAGE="$STAGE" linux-build/prep-kde-kwin-device.sh --use-existing --install
  bin/xios-device exec 'dpkg-query -W kwin xios-kde plasma-workspace plasma-mobile kscreen xios-session; apt-get check'
  bin/xios-kde-smoke desktop --slot kwin-ios5-desktop --warmup 12 --pointer-probe
  bin/xios-kde-smoke desktop --slot kwin-ios5-settings --warmup 12 --app systemsettings
  bin/xios-kde-smoke mobile --slot kwin-ios5-mobile --warmup 12 --drawer

Only after those isolated-slot checks pass, profile an active Desktop session:

  bin/xios-profile-session --duration 30 --shot kde-desktop

Do not publish +ios5 to production until the collected logs prove OpenGL
compositing, IOSurface client imports, clean frame pacing, input alignment,
rotation, and teardown without EGL/QRhi/protocol errors.
EOF

printf "==> staged %s debs in %s\n" "$(find "$STAGE/debs" -maxdepth 1 -type f -name '*.deb' | wc -l | tr -d ' ')" "$STAGE"
fi

if [ "$DO_PUSH" -eq 0 ]; then
  echo "==> stage-only requested; not contacting device"
  exit 0
fi

echo "==> checking device reachability: root@$IP:$PORT"
ssh_ "true"

echo "==> pushing prep bundle to $REMOTE"
ssh_ "rm -rf '$REMOTE' && mkdir -p '$REMOTE/debs'"
bundle_files=("$STAGE/install-on-device.sh" "$STAGE/README.txt" "$STAGE/DEVICE-READY-CHECKLIST.txt" "$STAGE/SHA256SUMS")
[ ! -f "$STAGE/ALLOW-XIOS-KDE" ] || bundle_files+=("$STAGE/ALLOW-XIOS-KDE")
scp_ "${bundle_files[@]}" "root@$IP:$REMOTE/"
scp_ "$STAGE/debs/"*.deb "root@$IP:$REMOTE/debs/"

if [ "$DO_INSTALL" -eq 0 ]; then
  echo "==> pushed only; not installing"
  exit 0
fi

echo "==> running on-device installer; this will not launch KWin or Plasma"
ssh_ "cd '$REMOTE' && sh ./install-on-device.sh"

echo "==> device prep complete; nothing was launched"
