#!/bin/sh
# Target-matrix values for the container-side build scripts.
#
# The host-side loader (target-lib.sh) reads linux-build/targets/<id>.env and
# exports XIOS_MEMO_TARGET / XIOS_MEMO_CFVER / XIOS_PREFIX / XIOS_SUBPREFIX.
# Those cross into the container through `docker run -e ...`. This file turns
# them into the handful of derived paths every build script needs, and supplies
# the rootless-1900 values when nothing was passed, so a bare
#
#   docker run ... procursus-xbuild:bookworm-arm64 /work/build-kwin.sh
#
# keeps doing exactly what it did before the target matrix existed.
#
# Baked into the toolchain image (see Dockerfile) and also bind-mounted by the
# host wrappers, so a stale image still picks up edits made here.
#
# Sourced, not executed. POSIX sh only: some callers are dash.

: "${XIOS_MEMO_TARGET:=iphoneos-arm64-rootless}"
: "${XIOS_MEMO_CFVER:=1900}"
: "${XIOS_SUBPREFIX:=/usr}"

# XIOS_PREFIX is empty for rootful, so it cannot use `:=` — an exported empty
# string is a real value, not "unset". Only default it when genuinely unset.
if [ -z "${XIOS_PREFIX+set}" ]; then
  XIOS_PREFIX=/var/jb
fi

: "${XIOS_PROC:=/work/Procursus}"

# Procursus lays its trees out as <tree>/<MEMO_TARGET>/<MEMO_CFVER>/...
XIOS_TRIPLE="$XIOS_MEMO_TARGET/$XIOS_MEMO_CFVER"

# build_base/<triple> is the packaging *root* (a deb unpacked here lands at
# build_base/<triple>/var/jb/usr/... for rootless, build_base/<triple>/usr/...
# for rootful). XIOS_SYSROOT is that root plus the install prefix, i.e. the
# directory the cross-toolchain treats as the on-device filesystem root.
XIOS_BUILD_BASE="$XIOS_PROC/build_base/$XIOS_TRIPLE"
XIOS_BUILD_WORK="$XIOS_PROC/build_work/$XIOS_TRIPLE"
XIOS_BUILD_STAGE="$XIOS_PROC/build_stage/$XIOS_TRIPLE"
XIOS_BUILD_DIST="$XIOS_PROC/build_dist/$XIOS_TRIPLE"
XIOS_SYSROOT="$XIOS_BUILD_BASE$XIOS_PREFIX"
XIOS_USR="$XIOS_SYSROOT$XIOS_SUBPREFIX"

# The two make arguments every recipe invocation needs.
XIOS_MEMO_ARGS="MEMO_TARGET=$XIOS_MEMO_TARGET MEMO_CFVER=$XIOS_MEMO_CFVER"

# Debian architecture, i.e. the _<arch>.deb suffix Procursus writes. NOT the
# same string as MEMO_TARGET, and not derivable by chopping "-rootless" off it:
# Procursus gives the rootless target iphoneos-arm64 and the rootful one
# iphoneos-arm. Scripts that glob for built debs need this, not a literal.
# The host loader exports it from the descriptor; this is the in-container
# fallback for a bare docker run.
if [ -z "${XIOS_DEB_ARCH:-}" ]; then
  case "$XIOS_MEMO_TARGET" in
    *-rootless) XIOS_DEB_ARCH=iphoneos-arm64 ;;
    iphoneos-arm64|iphoneos-arm64-ramdisk) XIOS_DEB_ARCH=iphoneos-arm ;;
    *e-rootless|*e) XIOS_DEB_ARCH=iphoneos-arm64e ;;
    *) XIOS_DEB_ARCH=iphoneos-arm64 ;;
  esac
fi

# On-device paths. Rootless has no /bin/sh (/ and /bin are read-only), which is
# why the X server / Xwayland popen patches exist; rootful uses the real one.
if [ -n "$XIOS_PREFIX" ]; then
  XIOS_SHELL_PATH="$XIOS_PREFIX/bin/sh"
  XIOS_RUNTIME_TMP="${XIOS_RUNTIME_TMP:-$XIOS_PREFIX/tmp}"
  XIOS_RUNTIME_VAR="${XIOS_RUNTIME_VAR:-$XIOS_PREFIX/var}"
  XIOS_PATH_DIRS="$XIOS_PREFIX$XIOS_SUBPREFIX/bin:$XIOS_PREFIX$XIOS_SUBPREFIX/sbin:$XIOS_PREFIX/bin:$XIOS_PREFIX/sbin"
else
  XIOS_SHELL_PATH="/bin/sh"
  XIOS_RUNTIME_TMP="${XIOS_RUNTIME_TMP:-/var/tmp}"
  XIOS_RUNTIME_VAR="${XIOS_RUNTIME_VAR:-/var}"
  XIOS_PATH_DIRS="$XIOS_SUBPREFIX/bin:$XIOS_SUBPREFIX/sbin:/bin:/sbin"
fi

export XIOS_MEMO_TARGET XIOS_MEMO_CFVER XIOS_PREFIX XIOS_SUBPREFIX XIOS_PROC \
       XIOS_TRIPLE XIOS_BUILD_BASE XIOS_BUILD_WORK XIOS_BUILD_STAGE \
       XIOS_BUILD_DIST XIOS_SYSROOT XIOS_USR XIOS_MEMO_ARGS XIOS_DEB_ARCH XIOS_SHELL_PATH \
       XIOS_RUNTIME_TMP XIOS_RUNTIME_VAR XIOS_PATH_DIRS

xios_target_banner() {
  echo "==> target: $XIOS_MEMO_TARGET / CFVER $XIOS_MEMO_CFVER / prefix ${XIOS_PREFIX:-/}"
}

# Refuse a non-rootless target where the recipe genuinely has no rootful story
# yet. Better a loud stop than a rootful deb full of /var/jb paths — which is
# the failure the publish gate exists to catch, only found much later.
xios_require_rootless() {
  [ -n "$XIOS_PREFIX" ] && return 0
  echo "ERROR: ${0##*/} does not support $XIOS_MEMO_TARGET yet: ${1:-rootless-only build step}" >&2
  echo "       See x11/docs/rootless-rootful-cfver-migration-plan.md (Phase 4/7)." >&2
  exit 2
}

# The install prefix as a sandbox path exception, one plist <string> element.
# Rootless yields /var/jb/; rootful ships into /usr, which needs its own entry
# because the /var/ exceptions these binaries already carry do not cover it.
#
# Deliberately just the one path: entitlements that also want the /private/var
# alias spell it out themselves, and adding it here would silently widen the
# exception set of every rootless binary that adopts this helper.
xios_ent_prefix_paths() {
  if [ -n "$XIOS_PREFIX" ]; then
    printf '        <string>%s/</string>\n' "$XIOS_PREFIX"
  else
    printf '        <string>%s/</string>\n' "$XIOS_SUBPREFIX"
  fi
}
