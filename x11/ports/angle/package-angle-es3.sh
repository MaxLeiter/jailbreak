#!/bin/bash
# Package the ES3-patched ANGLE (DisplayMtl getMaxSupportedESVersion -> Apple3 gets ES3)
# as an upgraded `angle` deb. Identical pipeline to package-angle.sh, new version suffix.
set -euo pipefail

BUILD=/private/tmp/angle-ios-build/angle/out/ios-arm64
INC=/private/tmp/angle-ios-build/angle/include
OUTDIR=/Users/max/Documents/jailbreak/x11/linux-build/out
STAGEROOT=/private/tmp/angle-deb-es3
STAGE="$STAGEROOT/angle"
VER="2.1.0+git20260630.a32d31d+es3"
DEB="angle_${VER}_iphoneos-arm64.deb"

rm -rf "$STAGEROOT"
mkdir -p "$STAGE/var/jb/lib/angle" "$STAGE/var/jb/include" "$STAGE/DEBIAN"

# 1. framework binary -> plain dylib
cp "$BUILD/libEGL.framework/libEGL"       "$STAGE/var/jb/lib/angle/libEGL.dylib"
cp "$BUILD/libGLESv2.framework/libGLESv2" "$STAGE/var/jb/lib/angle/libGLESv2.dylib"
chmod 0755 "$STAGE/var/jb/lib/angle/"*.dylib

# 2. absolute install names
install_name_tool -id /var/jb/lib/angle/libEGL.dylib     "$STAGE/var/jb/lib/angle/libEGL.dylib"
install_name_tool -id /var/jb/lib/angle/libGLESv2.dylib  "$STAGE/var/jb/lib/angle/libGLESv2.dylib"

# 3. ad-hoc sign
ldid -S "$STAGE/var/jb/lib/angle/libEGL.dylib"
ldid -S "$STAGE/var/jb/lib/angle/libGLESv2.dylib"

# 4. headers
cp -R "$INC/EGL" "$INC/GLES" "$INC/GLES2" "$INC/GLES3" "$INC/KHR" "$INC/platform" "$STAGE/var/jb/include/"
cp "$INC/angle_gl.h" "$INC/export.h" "$STAGE/var/jb/include/"

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
 This build admits Apple GPU Family 3 (A10) to the ES3 tier so EGL configs advertise
 EGL_OPENGL_ES3_BIT and ES3 contexts validate (needed for GTK4/GSK GL renderer).
 The GPU-using *process* must be ldid-signed with the AGX/IOSurface IOKit entitlements.
EOF

echo "=== staged tree ==="
find "$STAGE/var/jb" -maxdepth 3 -type f | sed "s#$STAGE##" | sort | head -40
echo "installed=${INSTKB}KB"

# 6. build the deb via the container's dpkg-deb
docker run --rm -v "$STAGEROOT":/stage procursus-xbuild:bookworm-arm64 \
  bash -c "chown -R 0:0 /stage/angle && dpkg-deb -Zzstd --build /stage/angle /stage/${DEB}"

cp "$STAGEROOT/${DEB}" "$OUTDIR/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}"
