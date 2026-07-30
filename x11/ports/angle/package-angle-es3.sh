#!/bin/bash
# Package the ES3-patched ANGLE (DisplayMtl getMaxSupportedESVersion -> Apple3 gets ES3)
# as an upgraded `angle` deb. Identical pipeline to package-angle.sh, new version suffix.
# -1 revision: ships the six compat symlinks (libEGL.2.dylib/.so/.so.1, libGLESv2.2.dylib/
# .so/.so.2) that were hand-made and dpkg-unowned on the dev device; without them a fresh
# install can't load libmutter (links libGLESv2.2.dylib) or satisfy cogl's dlopen of the
# .so sonames.
# -3 revision: updates the iosc Wayland-platform shim so toolkit EGL extension probes work
# before an EGLDisplay exists.
# -10 revision: ships the broker-fenced shim with MTLSharedEvent acquire fences,
# so Wayland clients hand GPU completion directly to iosc without serializing opaque
# Metal handles or blocking the CPU at every swap.
# -11 revision: accepts QtWayland's core eglCreateWindowSurface entry point and routes
# it through the same IOSurface swapchain as the EGL platform entry points.
# -12 revision: derives the Wayland connection from each wl_egl_window's wl_surface,
# so Qt's split GUI/render threads cannot lose the connection at surface creation.
# -13 revision: reports the shim's real non-blocking swap contract to QtWayland,
# avoiding serialized render loops and broken subsurface scheduling.
# -14 revision: collapses the private IOSurface wire to its sole supported,
# mandatory broker-fence contract and removes legacy version negotiation.
# -15 revision: shares the one process-wide ANGLE Metal display between
# QtWayland's facade and nested compositor requests.
set -euo pipefail
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target_arg "${1:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

BUILD="${ANGLE_BUILD_DIR:-/private/tmp/angle-ios-build/angle/out/ios-arm64}"
INC="${ANGLE_INC_DIR:-/private/tmp/angle-ios-build/angle/include}"
# Was an absolute path into a specific checkout, so running this from a worktree
# wrote its output into a different tree entirely. Derive it, and split
# non-rootless targets into their own directory like every other builder.
OUTDIR="$XLIB_ROOT/linux-build/out"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  OUTDIR="$OUTDIR/targets/$XIOS_TARGET_ID"
fi
SHIM="${IOSC_EGL_SHIM:-$XLIB_ROOT/wayland/out/libiosc_egl.dylib}"
BASE_DEB=${ANGLE_BASE_DEB:-}
STAGEROOT=/private/tmp/angle-deb-es3
STAGE="$STAGEROOT/angle"
BASE_STAGE="$STAGEROOT/base"
VER="2.1.0+git20260630.a32d31d+es3-15"
DEB="angle_${VER}_$XIOS_DEB_ARCH.deb"

rm -rf "$STAGEROOT"
mkdir -p "$STAGE$XIOS_PREFIX/lib/angle" "$STAGE$XIOS_PREFIX/include" "$STAGE/DEBIAN"

# 1. framework binary -> plain dylib. libEGL.dylib is the iosc Wayland-platform
# shim when available; the real ANGLE libEGL stays beside it for forwarding.
if [ -f "$BUILD/libEGL.framework/libEGL" ] &&
   [ -f "$BUILD/libGLESv2.framework/libGLESv2" ] &&
   [ -d "$INC/EGL" ]; then
  cp "$BUILD/libEGL.framework/libEGL"       "$STAGE$XIOS_PREFIX/lib/angle/libEGL.angle.dylib"
  cp "$BUILD/libGLESv2.framework/libGLESv2" "$STAGE$XIOS_PREFIX/lib/angle/libGLESv2.dylib"
  ANGLE_INCLUDE_ROOT="$INC"
elif [ -n "$BASE_DEB" ]; then
  [ -f "$BASE_DEB" ] || {
    echo "ERROR: ANGLE_BASE_DEB does not exist: $BASE_DEB" >&2
    exit 1
  }
  mkdir -p "$BASE_STAGE"
  docker run --rm -v "$(dirname "$BASE_DEB")":/input:ro -v "$BASE_STAGE":/base \
    debian:bookworm-slim \
    bash -ceu 'test "$(dpkg-deb -f "/input/$1" Package)" = angle; dpkg-deb -x "/input/$1" /base' \
    _ "$(basename "$BASE_DEB")"
  # The base deb carries whichever prefix IT was built for, which has nothing to
  # do with the target being packaged now -- restaging a published rootless deb
  # into a rootful package is the whole point of this path. Read the base at its
  # own prefix and write at the target's.
  if [ -d "$BASE_STAGE/var/jb/lib/angle" ]; then
    BASE_PREFIX=/var/jb
  else
    BASE_PREFIX=
  fi
  echo "base deb prefix: ${BASE_PREFIX:-/} -> target prefix: ${XIOS_PREFIX:-/}"
  cp "$BASE_STAGE$BASE_PREFIX/lib/angle/libEGL.angle.dylib" "$STAGE$XIOS_PREFIX/lib/angle/libEGL.angle.dylib"
  cp "$BASE_STAGE$BASE_PREFIX/lib/angle/libGLESv2.dylib" "$STAGE$XIOS_PREFIX/lib/angle/libGLESv2.dylib"
  ANGLE_INCLUDE_ROOT="$BASE_STAGE$BASE_PREFIX/include"
  echo "ANGLE binaries/headers: explicit immutable base $(basename "$BASE_DEB")"
else
  echo "ERROR: ANGLE source-build artifacts are missing under $BUILD." >&2
  echo "       Rebuild with build-angle.sh, or explicitly set ANGLE_BASE_DEB for a shim-only repack." >&2
  exit 1
fi
chmod 0755 "$STAGE$XIOS_PREFIX/lib/angle/"*.dylib
[ "${ANGLE_NO_SHIM:-0}" = 1 ] || [ -f "$SHIM" ] || {
  echo "ERROR: current fenced iosc EGL shim not found at $SHIM; run wayland/build-iosc.sh first" >&2
  echo "       For a NEW target this is a bootstrap cycle: the shim links against ANGLE," >&2
  echo "       and ANGLE ships the shim. Break it with ANGLE_NO_SHIM=1 to emit a" >&2
  echo "       link-only package, build the shim against that, then re-run without it." >&2
  exit 1
}
if [ "${ANGLE_NO_SHIM:-0}" = 1 ]; then
  echo "NOTE: ANGLE_NO_SHIM=1 -- emitting a bootstrap package with no iosc EGL shim."
  echo "      Link-only, for building the shim for a new target. Do NOT publish it:"
  echo "      libEGL.dylib is the shim, and GPU clients dlopen that name."
else
  cp "$SHIM" "$STAGE$XIOS_PREFIX/lib/angle/libEGL.dylib"
  chmod 0755 "$STAGE$XIOS_PREFIX/lib/angle/libEGL.dylib"
fi

# 2. absolute install names
install_name_tool -id $XIOS_PREFIX/lib/angle/libEGL.angle.dylib "$STAGE$XIOS_PREFIX/lib/angle/libEGL.angle.dylib"
[ -f "$STAGE$XIOS_PREFIX/lib/angle/libEGL.dylib" ] && install_name_tool -id $XIOS_PREFIX/lib/angle/libEGL.dylib       "$STAGE$XIOS_PREFIX/lib/angle/libEGL.dylib"
install_name_tool -id $XIOS_PREFIX/lib/angle/libGLESv2.dylib  "$STAGE$XIOS_PREFIX/lib/angle/libGLESv2.dylib"

# 2b. ...and the references BETWEEN them. -id only rewrites a library's own name;
# the shim's LC_LOAD_DYLIB entries still carry whatever prefix they were built
# or previously packaged with. That matters most on the ANGLE_BASE_DEB path,
# which restages binaries from an already-published deb: without this a rootful
# package installs cleanly and then fails to load, pointing at a /var/jb that is
# not there. tools/check-target-package.py scans Mach-O load commands for
# exactly this.
for lib in libEGL.angle.dylib libEGL.dylib libGLESv2.dylib; do
  target="$STAGE$XIOS_PREFIX/lib/angle/$lib"
  [ -f "$target" ] || continue
  while read -r ref; do
    case "$ref" in
      */lib/angle/*)
        want="$XIOS_PREFIX/lib/angle/${ref##*/}"
        [ "$ref" = "$want" ] || install_name_tool -change "$ref" "$want" "$target"
        ;;
    esac
  done <<REFS
$(otool -L "$target" | tail -n +2 | awk '{print $1}')
REFS
  # LC_RPATH too: -change only touches LC_ID_DYLIB/LC_LOAD_DYLIB.
  while read -r rp; do
    case "$rp" in
      /var/jb/*|/usr/*)
        want="$XIOS_PREFIX${rp#/var/jb}"
        [ "$rp" = "$want" ] || install_name_tool -rpath "$rp" "$want" "$target" 2>/dev/null || true
        ;;
    esac
  done <<RPATHS
$(otool -l "$target" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')
RPATHS
done

# The iosc EGL shim is compiled for one prefix; its embedded paths are string
# constants and rpaths, not just load commands, so it cannot be laundered from
# one target to another by install_name_tool. Refuse rather than ship a package
# that installs and then cannot resolve its own libraries.
for lib in libEGL.dylib libEGL.angle.dylib libGLESv2.dylib; do
  f="$STAGE$XIOS_PREFIX/lib/angle/$lib"
  [ -f "$f" ] || continue
  for other in /var/jb; do
    [ "$other" = "$XIOS_PREFIX" ] && continue
    # Load commands only. install_name_tool rewrites names in place and leaves
    # the tail of a longer old string in the binary, so grepping raw bytes flags
    # dylibs that were in fact retargeted correctly.
    if otool -l "$f" 2>/dev/null |
         awk '/LC_ID_DYLIB|LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|LC_REEXPORT_DYLIB|LC_RPATH/{c=1}
              c && / (name|path) /{print $2; c=0}' |
         grep -q "^$other/"; then
      echo "ERROR: $lib still embeds $other on target $XIOS_TARGET_ID." >&2
      echo "       Its shim/binaries were built for a different prefix. Rebuild them for" >&2
      echo "       this target (wayland/build-iosc.sh, ports/angle/build-angle.sh) instead" >&2
      echo "       of restaging a package built for another root." >&2
      exit 1
    fi
  done
done

# 3. ad-hoc sign (the libs carry no entitlements; the GPU-using *process* is the
#    one that must be ldid-signed with the AGX/IOSurface set, see control below)
xsign "$STAGE$XIOS_PREFIX/lib/angle/libEGL.angle.dylib"
[ -f "$STAGE$XIOS_PREFIX/lib/angle/libEGL.dylib" ] && xsign "$STAGE$XIOS_PREFIX/lib/angle/libEGL.dylib"
xsign "$STAGE$XIOS_PREFIX/lib/angle/libGLESv2.dylib"

# 3b. compat symlinks (Debian soname + .so aliases consumers link/dlopen)
if [ -f "$STAGE$XIOS_PREFIX/lib/angle/libEGL.dylib" ]; then
ln -s libEGL.dylib     "$STAGE$XIOS_PREFIX/lib/angle/libEGL.2.dylib"
ln -s libEGL.dylib     "$STAGE$XIOS_PREFIX/lib/angle/libEGL.so"
ln -s libEGL.dylib     "$STAGE$XIOS_PREFIX/lib/angle/libEGL.so.1"
fi
ln -s libGLESv2.dylib  "$STAGE$XIOS_PREFIX/lib/angle/libGLESv2.2.dylib"
ln -s libGLESv2.dylib  "$STAGE$XIOS_PREFIX/lib/angle/libGLESv2.so"
ln -s libGLESv2.dylib  "$STAGE$XIOS_PREFIX/lib/angle/libGLESv2.so.2"

# 4. headers
cp -R "$ANGLE_INCLUDE_ROOT/EGL" "$ANGLE_INCLUDE_ROOT/GLES" "$ANGLE_INCLUDE_ROOT/GLES2" \
  "$ANGLE_INCLUDE_ROOT/GLES3" "$ANGLE_INCLUDE_ROOT/KHR" "$ANGLE_INCLUDE_ROOT/platform" \
  "$STAGE$XIOS_PREFIX/include/"
cp "$ANGLE_INCLUDE_ROOT/angle_gl.h" "$ANGLE_INCLUDE_ROOT/export.h" "$STAGE$XIOS_PREFIX/include/"

INSTKB=$(du -sk "$STAGE${XIOS_PREFIX:-/lib}" | cut -f1)

# 5. control
cat > "$STAGE/DEBIAN/control" <<EOF
Package: angle
Name: ANGLE (GLES via Metal)
Version: ${VER}
Architecture: $XIOS_DEB_ARCH
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Section: Development
Priority: optional
Installed-Size: ${INSTKB}
Depends: firmware (>= 15.0)
Description: Hardware OpenGL ES via Google ANGLE's Metal backend (GLES -> Metal/AGX).
 libEGL + libGLESv2 translating EGL 1.5 / OpenGL ES 2.0/3.0 to Metal on the Apple
 GPU, built from upstream google/angle for arm64 iOS. Installs under $XIOS_PREFIX/lib/angle
 (does not collide with Mesa's software libEGL/libGLESv2). Supports
 EGL_ANGLE_iosurface_client_buffer for zero-copy GLES-into-IOSurface rendering.
 libEGL.dylib is the iosc Wayland-platform shim when built; it forwards non-Wayland
 EGL calls to the real ANGLE library at libEGL.angle.dylib and lets GTK4/GSK create
 wl_egl_window surfaces that render into IOSurfaces zero-copy. Clients export
 ANGLE Metal shared-event acquire fences through the package-owned XPC broker
 for GPU-side synchronization; the frame path carries only an opaque capability token.
 This build admits Apple GPU Family 3 (A10) to the ES3 tier so EGL configs advertise
 EGL_OPENGL_ES3_BIT and ES3 contexts validate (needed for GTK4/GSK GL renderer).
 Ships the Debian soname and .so alias symlinks (libEGL.2.dylib, libEGL.so, libEGL.so.1,
 libGLESv2.2.dylib, libGLESv2.so, libGLESv2.so.2) so linked and dlopened consumers
 resolve on a fresh install.
 The GPU-using *process* must be ldid-signed with the AGX/IOSurface IOKit entitlements.
EOF

echo "=== staged tree ==="
find "$STAGE$XIOS_PREFIX" -maxdepth 3 -type f | sed "s#$STAGE##" | sort | head -40
echo "installed=${INSTKB}KB"

# 6. build the deb via the container's dpkg-deb
# (debian:bookworm-slim; the procursus-xbuild image's bash stopped exec'ing on this
# host — plain dpkg-deb + chown is all this step needs)
docker run --rm -v "$STAGEROOT":/stage debian:bookworm-slim \
  bash -c "chown -R 0:0 /stage/angle && dpkg-deb -Zzstd --build /stage/angle /stage/${DEB}"

cp "$STAGEROOT/${DEB}" "$OUTDIR/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}"
