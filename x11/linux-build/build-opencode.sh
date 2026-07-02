#!/usr/bin/env bash
# Reproducible OpenCode package build for rootless iOS.
#
# OpenCode's upstream release binaries embed a macOS Bun runtime, which is not
# viable on the A10 iPad target. This path builds a Bun-targeted JS bundle from
# pinned OpenCode source and packages it with a small wrapper that runs under
# the repo's iPhoneOS Bun package.
set -euo pipefail
umask 022
export LC_ALL=C
export TZ=UTC

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/out}"
WORK="${WORK:-$OUT/opencode-source-work}"
LOCK="${OPENCODE_LOCK:-$HERE/build_info/opencode.lock}"
CONTROL="${OPENCODE_CONTROL:-$HERE/build_info/opencode.control}"
BUNDLE_SCRIPT="${OPENCODE_BUNDLE_SCRIPT:-$HERE/tools/opencode-ios-bundle.ts}"

[ -f "$LOCK" ] || { echo "OpenCode lock file not found: $LOCK" >&2; exit 1; }
[ -f "$CONTROL" ] || { echo "OpenCode package control file not found: $CONTROL" >&2; exit 1; }
[ -f "$BUNDLE_SCRIPT" ] || { echo "OpenCode bundle script not found: $BUNDLE_SCRIPT" >&2; exit 1; }
# shellcheck disable=SC1090
. "$LOCK"

VERSION="${OPENCODE_VERSION:?OPENCODE_VERSION missing from $LOCK}"
GIT_REPO="${OPENCODE_GIT_REPO:?OPENCODE_GIT_REPO missing from $LOCK}"
GIT_COMMIT="${OPENCODE_GIT_COMMIT:?OPENCODE_GIT_COMMIT missing from $LOCK}"
PKG_VERSION="${OPENCODE_DEB_VERSION:-${VERSION}~ios0.2}"
ARCH="${ARCH:-iphoneos-arm64}"
PKG="opencode_${PKG_VERSION}_${ARCH}.deb"

need() { command -v "$1" >/dev/null || { echo "$1 not found" >&2; exit 1; }; }
need git
need bun

build_deb() {
  local stage="$1"
  local deb="$2"
  if command -v dpkg-deb >/dev/null && dpkg-deb --version >/dev/null 2>&1; then
    dpkg-deb -Zxz -b "$stage" "$deb"
    return
  fi
  need docker
  docker run --rm \
    -v "$stage:/pkg:ro" \
    -v "$(dirname "$deb"):/out" \
    debian:bookworm \
    dpkg-deb -Zxz -b /pkg "/out/$(basename "$deb")"
}

mkdir -p "$WORK" "$OUT"
SRC="$WORK/opencode"

if [ ! -d "$SRC/.git" ]; then
  git clone "$GIT_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$GIT_COMMIT"
git -C "$SRC" checkout --quiet "$GIT_COMMIT"
git -C "$SRC" reset --quiet --hard "$GIT_COMMIT"
git -C "$SRC" clean -fd --quiet

echo "==> install pinned OpenCode dependencies"
(
  cd "$SRC"
  bun install --ignore-scripts
  bun install --os="*" --cpu="*" @opentui/core@0.3.4
  bun install --os="*" --cpu="*" @parcel/watcher@2.5.1
  bun install --os="*" --cpu="*" @ff-labs/fff-bun@0.9.4
)

echo "==> bundle OpenCode for Bun on iOS"
(
  cd "$SRC/packages/opencode"
  cp "$BUNDLE_SCRIPT" ./build-ios-bundle.ios.ts
  bun ./build-ios-bundle.ios.ts
  rm -f ./build-ios-bundle.ios.ts
)

BUNDLE="$SRC/packages/opencode/dist/opencode-ios-js"
[ -f "$BUNDLE/src/index.js" ] || { echo "OpenCode bundle missing src/index.js" >&2; exit 1; }

echo "==> local smoke"
bun "$BUNDLE/src/index.js" --version | grep -Fx "$VERSION" >/dev/null

rm -rf "$WORK/pkg"
mkdir -p "$WORK/pkg/DEBIAN" "$WORK/pkg/var/jb/usr/bin" "$WORK/pkg/var/jb/usr/libexec/opencode-js"
cp -R "$BUNDLE"/. "$WORK/pkg/var/jb/usr/libexec/opencode-js/"
find "$WORK/pkg/var/jb/usr/libexec/opencode-js" -type d -exec chmod 0755 {} +
find "$WORK/pkg/var/jb/usr/libexec/opencode-js" -type f -exec chmod 0644 {} +

# @opentui/core dlopen()s this dylib at TUI startup (the bundle aliases the
# platform package to this fixed path; see tools/opencode-ios-bundle.ts). The
# artifact is produced by $HERE/build-opentui-ios.sh and MUST already be
# fakesigned (ldid -S) before it lands here -- we deliberately do not re-sign in
# this script.
OPENTUI_IOS_DYLIB="${OPENTUI_IOS_DYLIB:-$HERE/out/opentui-ios/libopentui.dylib}"
[ -f "$OPENTUI_IOS_DYLIB" ] || {
  echo "iOS OpenTUI dylib not found: $OPENTUI_IOS_DYLIB" >&2
  echo "Build it first with $HERE/build-opentui-ios.sh (or set OPENTUI_IOS_DYLIB)." >&2
  exit 1
}
cp "$OPENTUI_IOS_DYLIB" "$WORK/pkg/var/jb/usr/libexec/opencode-js/libopentui.dylib"
chmod 0644 "$WORK/pkg/var/jb/usr/libexec/opencode-js/libopentui.dylib"

cat > "$WORK/pkg/var/jb/usr/bin/opencode" <<'EOF'
#!/var/jb/usr/bin/sh
export TMPDIR="${TMPDIR:-/var/jb/tmp}"
export TMP="${TMP:-$TMPDIR}"
export TEMP="${TEMP:-$TMPDIR}"
exec /var/jb/usr/bin/bun /var/jb/usr/libexec/opencode-js/src/index.js "$@"
EOF
chmod 0755 "$WORK/pkg/var/jb/usr/bin/opencode"

sed \
  -e "s/@DEB_VERSION@/$PKG_VERSION/g" \
  -e "s/@DEB_ARCH@/$ARCH/g" \
  -e "s/@OPENCODE_VERSION@/$VERSION/g" \
  -e "s/@OPENCODE_COMMIT@/$GIT_COMMIT/g" \
  "$CONTROL" > "$WORK/pkg/DEBIAN/control"

if [ "${PACKAGE:-1}" = 1 ]; then
  echo "==> package OpenCode"
  build_deb "$WORK/pkg" "$OUT/$PKG"
  echo "==> built $OUT/$PKG"
else
  echo "==> staged package at $WORK/pkg"
fi

if [ "${SMOKE_DEVICE:-0}" = 1 ]; then
  SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519")
  DEVICE="${DEVICE:-root@MaxsiPad.local}"
  echo "==> on-device smoke"
  scp "${SSH_OPTS[@]}" "$OUT/$PKG" "$DEVICE:/var/jb/tmp/"
  ssh "${SSH_OPTS[@]}" "$DEVICE" "
    set -e
    dpkg -i /var/jb/tmp/$PKG
    TMPDIR=/var/jb/tmp TMP=/var/jb/tmp TEMP=/var/jb/tmp /var/jb/usr/bin/opencode --version
  "
fi
