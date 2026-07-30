#!/bin/bash
# Package the ES3-patched ANGLE (DisplayMtl getMaxSupportedESVersion -> Apple3 gets ES3)
# as an upgraded `angle` deb. Identical pipeline to package-angle.sh, new version suffix.
# -1 revision: ships the six compat symlinks (libEGL.2.dylib/.so/.so.1, libGLESv2.2.dylib/
# .so/.so.2) that were hand-made and dpkg-unowned on the dev device; without them a fresh
# install can't load libmutter (links libGLESv2.2.dylib) or satisfy cogl's dlopen of the
# .so sonames.
# -3 revision: updates the iosc Wayland-platform shim so toolkit EGL extension probes work
# before an EGLDisplay exists.
# -10 revision: ships the protocol-v4 shim with brokered MTLSharedEvent acquire fences,
# so Wayland clients hand GPU completion directly to iosc without serializing opaque
# Metal handles or blocking the CPU at every swap.
# -11 revision: accepts QtWayland's core eglCreateWindowSurface entry point and routes
# it through the same IOSurface swapchain as the EGL platform entry points.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

BUILD=/private/tmp/angle-ios-build/angle/out/ios-arm64
INC=/private/tmp/angle-ios-build/angle/include
OUTDIR=/Users/max/Documents/jailbreak/x11/linux-build/out
SHIM=${IOSC_EGL_SHIM:-/Users/max/Documents/jailbreak/x11/wayland/out/libiosc_egl.dylib}
BASE_DEB=${ANGLE_BASE_DEB:-}
STAGEROOT=/private/tmp/angle-deb-es3
STAGE="$STAGEROOT/angle"
BASE_STAGE="$STAGEROOT/base"
VER="2.1.0+git20260630.a32d31d+es3-11"
DEB="angle_${VER}_iphoneos-arm64.deb"

rm -rf "$STAGEROOT"
mkdir -p "$STAGE/var/jb/lib/angle" "$STAGE/var/jb/include" "$STAGE/DEBIAN"

# 1. framework binary -> plain dylib. libEGL.dylib is the iosc Wayland-platform
# shim when available; the real ANGLE libEGL stays beside it for forwarding.
if [ -f "$BUILD/libEGL.framework/libEGL" ] &&
   [ -f "$BUILD/libGLESv2.framework/libGLESv2" ] &&
   [ -d "$INC/EGL" ]; then
  cp "$BUILD/libEGL.framework/libEGL"       "$STAGE/var/jb/lib/angle/libEGL.angle.dylib"
  cp "$BUILD/libGLESv2.framework/libGLESv2" "$STAGE/var/jb/lib/angle/libGLESv2.dylib"
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
  cp "$BASE_STAGE/var/jb/lib/angle/libEGL.angle.dylib" "$STAGE/var/jb/lib/angle/libEGL.angle.dylib"
  cp "$BASE_STAGE/var/jb/lib/angle/libGLESv2.dylib" "$STAGE/var/jb/lib/angle/libGLESv2.dylib"
  ANGLE_INCLUDE_ROOT="$BASE_STAGE/var/jb/include"
  echo "ANGLE binaries/headers: explicit immutable base $(basename "$BASE_DEB")"
else
  echo "ERROR: ANGLE source-build artifacts are missing under $BUILD." >&2
  echo "       Rebuild with build-angle.sh, or explicitly set ANGLE_BASE_DEB for a shim-only repack." >&2
  exit 1
fi
chmod 0755 "$STAGE/var/jb/lib/angle/"*.dylib
[ -f "$SHIM" ] || {
  echo "ERROR: protocol-v4 iosc EGL shim not found at $SHIM; run wayland/build-iosc.sh first" >&2
  exit 1
}
cp "$SHIM" "$STAGE/var/jb/lib/angle/libEGL.dylib"
chmod 0755 "$STAGE/var/jb/lib/angle/libEGL.dylib"

# 2. absolute install names
install_name_tool -id /var/jb/lib/angle/libEGL.angle.dylib "$STAGE/var/jb/lib/angle/libEGL.angle.dylib"
install_name_tool -id /var/jb/lib/angle/libEGL.dylib       "$STAGE/var/jb/lib/angle/libEGL.dylib"
install_name_tool -id /var/jb/lib/angle/libGLESv2.dylib  "$STAGE/var/jb/lib/angle/libGLESv2.dylib"

# 3. ad-hoc sign (the libs carry no entitlements; the GPU-using *process* is the
#    one that must be ldid-signed with the AGX/IOSurface set, see control below)
xsign "$STAGE/var/jb/lib/angle/libEGL.angle.dylib"
xsign "$STAGE/var/jb/lib/angle/libEGL.dylib"
xsign "$STAGE/var/jb/lib/angle/libGLESv2.dylib"

# 3b. compat symlinks (Debian soname + .so aliases consumers link/dlopen)
ln -s libEGL.dylib     "$STAGE/var/jb/lib/angle/libEGL.2.dylib"
ln -s libEGL.dylib     "$STAGE/var/jb/lib/angle/libEGL.so"
ln -s libEGL.dylib     "$STAGE/var/jb/lib/angle/libEGL.so.1"
ln -s libGLESv2.dylib  "$STAGE/var/jb/lib/angle/libGLESv2.2.dylib"
ln -s libGLESv2.dylib  "$STAGE/var/jb/lib/angle/libGLESv2.so"
ln -s libGLESv2.dylib  "$STAGE/var/jb/lib/angle/libGLESv2.so.2"

# 4. headers
cp -R "$ANGLE_INCLUDE_ROOT/EGL" "$ANGLE_INCLUDE_ROOT/GLES" "$ANGLE_INCLUDE_ROOT/GLES2" \
  "$ANGLE_INCLUDE_ROOT/GLES3" "$ANGLE_INCLUDE_ROOT/KHR" "$ANGLE_INCLUDE_ROOT/platform" \
  "$STAGE/var/jb/include/"
cp "$ANGLE_INCLUDE_ROOT/angle_gl.h" "$ANGLE_INCLUDE_ROOT/export.h" "$STAGE/var/jb/include/"

INSTKB=$(du -sk "$STAGE/var/jb" | cut -f1)

# 5. control
cat > "$STAGE/DEBIAN/control" <<EOF
Package: angle
Name: ANGLE (GLES via Metal)
Version: ${VER}
Architecture: iphoneos-arm64
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Section: Development
Priority: optional
Installed-Size: ${INSTKB}
Depends: firmware (>= 15.0)
Description: Hardware OpenGL ES via Google ANGLE's Metal backend (GLES -> Metal/AGX).
 libEGL + libGLESv2 translating EGL 1.5 / OpenGL ES 2.0/3.0 to Metal on the Apple
 GPU, built from upstream google/angle for arm64 iOS. Installs under /var/jb/lib/angle
 (does not collide with Mesa's software libEGL/libGLESv2). Supports
 EGL_ANGLE_iosurface_client_buffer for zero-copy GLES-into-IOSurface rendering.
 libEGL.dylib is the iosc Wayland-platform shim when built; it forwards non-Wayland
 EGL calls to the real ANGLE library at libEGL.angle.dylib and lets GTK4/GSK create
 wl_egl_window surfaces that render into IOSurfaces zero-copy. Protocol-v4 clients
 export ANGLE Metal shared-event acquire fences through the package-owned XPC broker
 for GPU-side synchronization; the frame path carries only an opaque capability token.
 This build admits Apple GPU Family 3 (A10) to the ES3 tier so EGL configs advertise
 EGL_OPENGL_ES3_BIT and ES3 contexts validate (needed for GTK4/GSK GL renderer).
 Ships the Debian soname and .so alias symlinks (libEGL.2.dylib, libEGL.so, libEGL.so.1,
 libGLESv2.2.dylib, libGLESv2.so, libGLESv2.so.2) so linked and dlopened consumers
 resolve on a fresh install.
 The GPU-using *process* must be ldid-signed with the AGX/IOSurface IOKit entitlements.
EOF

echo "=== staged tree ==="
find "$STAGE/var/jb" -maxdepth 3 -type f | sed "s#$STAGE##" | sort | head -40
echo "installed=${INSTKB}KB"

# 6. build the deb via the container's dpkg-deb
# (debian:bookworm-slim; the procursus-xbuild image's bash stopped exec'ing on this
# host — plain dpkg-deb + chown is all this step needs)
docker run --rm -v "$STAGEROOT":/stage debian:bookworm-slim \
  bash -c "chown -R 0:0 /stage/angle && dpkg-deb -Zzstd --build /stage/angle /stage/${DEB}"

cp "$STAGEROOT/${DEB}" "$OUTDIR/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}"
