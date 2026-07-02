#!/usr/bin/env bash
# build-mutter.sh — cross-build mutter 46 + its missing deps for rootless iOS, OFF-DEVICE.
# Companion to build-gnome.sh (shares its host-tool preamble + cc-nounused wrappers). Produces
# libmutter/libcogl/libclutter (+ deps) so the Meta/Clutter/Cogl typelibs can be scanned on-device
# in a brief separate step. Mutter is built introspection=OFF here (cross can't run the dumper);
# the typelib scan is Design A on-device against the installed libs.
#
#   docker run --rm --platform linux/arm64 --cpus=3 \
#     -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/build-mutter.sh:/work/build-mutter.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/tools:/work/tools:ro" -v "$PWD/out:/out" \
#     -v "$PWD/..:/work/x11:ro" \
#     -e TARGETS="mutter mutter-package" -e MUTTER_CLEAN=1 \
#     procursus-xbuild:bookworm-arm64 /work/build-mutter.sh
#
# The tools/ mount is REQUIRED for the mutter-package X11/xcb weaken step (macho-weaken.py); the
# mutter recipe hard-errors if the tool is not staged into build_tools/.
# The x11 mount (/work/x11) is REQUIRED to build the REAL MetaBackendIOS: mutter-setup runs
# /work/x11/linux-build/integrate-ios-backend.sh (stages src/backends/ios/* + the 5 integration
# patches). Without it the recipe builds a STOCK typelib-only mutter (no iOS backend).
# MUTTER_CLEAN=1 wipes the mutter work tree first so the integrate runs from a pristine extract
# (an incremental relink drops the meson-staged ios objects and regresses the stage/present path).
set -euo pipefail
cd /work/Procursus

# --- host codegen tools (same set build-gnome.sh installs) ---
if ! command -v glib-mkenums >/dev/null 2>&1 || ! command -v gdbus-codegen >/dev/null 2>&1; then
  echo "==> installing host build tools"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      sassc valac itstool desktop-file-utils gtk-update-icon-cache tcl python3-mako >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi
# Host build deps: expat (wayland-scanner XML), and a HOST wayland-scanner itself (mutter runs it
# at build time to generate protocol code — must be a runnable host binary, not the iOS one).
for hp in libexpat1-dev libwayland-bin; do
  dpkg -s "$hp" >/dev/null 2>&1 || { echo "==> installing host $hp"; \
    apt-get install -y --no-install-recommends "$hp" >/dev/null 2>&1 || echo "WARN: $hp install failed"; }
done

# --- cc-nounused wrappers (meson sizeof probes vs -Wl,-adhoc_codesign) ---
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# --- install OUR new recipes (do NOT clobber the Wayland track's libxkbcommon.mk) ---
echo "==> installing mutter recipes into makefiles/"
for r in libxcomposite.mk gusb.mk colord.mk libpixman.mk libxfixes.mk libdrm.mk libei.mk mutter.mk; do
  [ -f /work/recipes/$r ] && cp -v /work/recipes/$r makefiles/
done
[ -d /work/build_info ] && cp -v /work/build_info/* build_info/ 2>/dev/null || true

# --- MUTTER_CLEAN: wipe the mutter work tree for a from-pristine integrate + full build ---
# Route A needs the real MetaBackendIOS staged into a PRISTINE mutter tree (integrate applies
# patches that expect unmodified sources) and a full ninja build (an incremental relink drops
# the meson-staged ios objects — meta-stage-ios/meta-onscreen-ios — and regresses). Wiping the
# work dir forces mutter-setup to re-extract + re-run integrate-ios-backend.sh.
if [ "${MUTTER_CLEAN:-0}" = "1" ]; then
  echo "==> MUTTER_CLEAN=1: wiping mutter work tree (from-scratch integrate + build)"
  rm -rf build_work/*/*/mutter 2>/dev/null || true
fi

# --- stage the Mach-O weaken tool (mutter-package weak-links the dead X11/xcb closure with it) ---
if [ -d /work/tools ]; then
  cp -v /work/tools/macho-weaken.py build_tools/ 2>/dev/null || true
  chmod +x build_tools/macho-weaken.py 2>/dev/null || true
else
  echo "WARN: /work/tools not mounted — mutter-package will fail at the X11/xcb weaken step"
fi

# --- build-local libxkbcommon x11 enable (mutter needs xkbcommon-x11; leave repo recipe clean) ---
# Additive: adds the x11 sub-library + xkbcommon-x11.pc into build_base; wayland stays as-is.
if grep -q "enable-x11=false" makefiles/libxkbcommon.mk; then
  echo "==> patching libxkbcommon.mk: enable-x11=true (+ libxcb prereq) for this build"
  sed -i 's/-Denable-x11=false/-Denable-x11=true/' makefiles/libxkbcommon.mk
  sed -i 's/^libxkbcommon: libxkbcommon-setup libxml2/libxkbcommon: libxkbcommon-setup libxml2 libxcb/' makefiles/libxkbcommon.mk
fi
# Force libxkbcommon to rebuild so the x11 sublib is produced. BUILD_WORK is
# build_work/<target>/<cfver>/, so glob the marker (a bare build_work/ path misses it).
if [ ! -e build_base/iphoneos-arm64-rootless/1900/var/jb/usr/lib/pkgconfig/xkbcommon-x11.pc ]; then
  rm -f build_work/*/*/libxkbcommon/.build_complete 2>/dev/null || true
  # also wipe the meson build dir — a stale x11=false configure would otherwise stick
  # ("Directory already configured", new -D flags ignored). Force a clean reconfigure.
  rm -rf build_work/*/*/libxkbcommon/build 2>/dev/null || true
fi
# Force pixman rebuild to 0.42.2 (mutter needs >= 0.42; mainline ships 0.40 autotools). The meson
# recipe replaces it; wipe the old autotools build dir + marker so the new meson build takes.
if ! pkg-config --atleast-version=0.42 build_base/iphoneos-arm64-rootless/1900/var/jb/usr/lib/pkgconfig/pixman-1.pc 2>/dev/null \
   && ! grep -q "0.4[2-9]" build_base/iphoneos-arm64-rootless/1900/var/jb/usr/lib/pkgconfig/pixman-1.pc 2>/dev/null; then
  # wipe the WHOLE libpixman work dir — the old 0.40 autotools source is still there and
  # EXTRACT_TAR skips re-extraction when the dir exists, so 0.42.2 never unpacked.
  rm -rf build_work/*/*/libpixman 2>/dev/null || true
fi
# libxfixes >= 6 needed by mutter (mainline ships 5.0.3). Force a clean rebuild to 6.0.1.
if ! grep -q "Version: 6" build_base/iphoneos-arm64-rootless/1900/var/jb/usr/lib/pkgconfig/xfixes.pc 2>/dev/null; then
  rm -rf build_work/*/*/libxfixes 2>/dev/null || true
fi

# --- stage ANGLE libEGL + egl.pc into the cross sysroot (mesa here has no EGL; mutter's
#     wayland/Cogl path links -lEGL). GLESv2 headers + mesa libGLESv2 already present. The
#     angle deb is mounted via /out. install_name stays @rpath/libEGL.dylib -> ANGLE on-device.
SYSROOT=build_base/iphoneos-arm64-rootless/1900/var/jb/usr
# Cogl's cogl-egl.h includes <EGL/eglmesaext.h> (mesa EGL extension declarations); ANGLE's headers
# lack it. It's a portable declarations-only header; Cogl resolves the actual MESA fns via
# eglGetProcAddress at runtime (no link dep). Stage it from the Khronos EGL-Registry.
if [ ! -e "$SYSROOT/include/EGL/eglmesaext.h" ]; then
  echo "==> staging EGL/eglmesaext.h (from the mesa source tarball) for Cogl"
  MESA_TAR=$(ls build_source/mesa-*.tar.* 2>/dev/null | head -1)
  if [ -n "$MESA_TAR" ]; then
    tar xf "$MESA_TAR" -C /tmp $(tar tf "$MESA_TAR" 2>/dev/null | grep -m1 'include/EGL/eglmesaext.h') 2>/dev/null
    F=$(find /tmp -path '*include/EGL/eglmesaext.h' 2>/dev/null | head -1)
    [ -n "$F" ] && cp -v "$F" "$SYSROOT/include/EGL/eglmesaext.h" || echo "WARN: eglmesaext.h not in mesa tar"
  else
    echo "WARN: no mesa source tarball found for eglmesaext.h"
  fi
fi
# Cogl's cogl-dma-buf-handle.c includes <linux/dma-buf.h> (kernel uapi, no iOS equivalent) for the
# DMA_BUF_IOCTL_SYNC path. Stage a minimal stub so it compiles; the ioctl is INERT on iOS (the
# dmabuf path is replaced by IOSurface in MetaBackendIOS). Links-only, like libdrm.
# The stub is the CANONICAL file recipes/build_info/linux-dma-buf.h (also staged on-device by
# gir-build-mutter-ondevice.sh — the introspection build must see the same stub ABI).
echo "==> staging stub <linux/dma-buf.h> (dmabuf path inert on iOS; IOSurface in MetaBackendIOS)"
mkdir -p "$SYSROOT/include/linux"
cp /work/recipes/build_info/linux-dma-buf.h "$SYSROOT/include/linux/dma-buf.h"
# meta-context-main.c guards #include <systemd/sd-login.h> on HAVE_WAYLAND (on) but the sd_* USAGE
# on HAVE_LIBSYSTEMD (off) — so the header must exist but the functions aren't compiled. Stage a
# declarations-only stub. (logind/session tracking is inert on iOS; the logind D-Bus stub is the
# separate runtime piece — gnome-plan #4.)
# Canonical file recipes/build_info/systemd-sd-login.h (shared with gir-build-mutter-ondevice.sh).
echo "==> staging stub <systemd/sd-login.h> (session tracking inert on iOS; logind stub is runtime)"
mkdir -p "$SYSROOT/include/systemd"
cp /work/recipes/build_info/systemd-sd-login.h "$SYSROOT/include/systemd/sd-login.h"
if [ ! -e "$SYSROOT/lib/pkgconfig/egl.pc" ]; then
  ANGLE_DEB=$(ls /out/angle_*_iphoneos-arm64.deb 2>/dev/null | grep -v "+es3" | head -1)
  if [ -n "$ANGLE_DEB" ]; then
    echo "==> staging ANGLE libEGL + egl.pc into cross sysroot from $(basename "$ANGLE_DEB")"
    rm -rf /tmp/angle-x && mkdir -p /tmp/angle-x && dpkg-deb -x "$ANGLE_DEB" /tmp/angle-x
    EGL=$(find /tmp/angle-x -name libEGL.dylib | head -1)
    GLES=$(find /tmp/angle-x -name libGLESv2.dylib | head -1)
    [ -n "$EGL" ]  && cp -v "$EGL"  "$SYSROOT/lib/libEGL.dylib"
    # Use ANGLE's libGLESv2 too (not mesa's software one) so libmutter references the GPU/Metal
    # GLES at runtime — the native+fast path. Repoint glesv2.pc off mesa onto ANGLE.
    [ -n "$GLES" ] && cp -v "$GLES" "$SYSROOT/lib/libGLESv2.dylib"
    cat > "$SYSROOT/lib/pkgconfig/egl.pc" <<PC
prefix=/var/jb/usr
libdir=/var/jb/lib/angle
includedir=\${prefix}/include

Name: EGL
Description: ANGLE EGL (Metal) for iOS
Version: 1.5
Libs: -L/var/jb/usr/lib -lEGL
Cflags: -I\${includedir}
PC
    cat > "$SYSROOT/lib/pkgconfig/glesv2.pc" <<PC
prefix=/var/jb/usr
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: glesv2
Description: ANGLE OpenGL ES 2/3 (Metal) for iOS
Version: 3.2
Libs: -L\${libdir} -lGLESv2
Cflags: -I\${includedir}
PC
  else
    echo "WARN: no angle deb in /out — mutter egl link will fail"
  fi
fi

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

TARGETS="${TARGETS:-lcms2 libxcomposite libxkbcommon colord}"
for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

# collect any debs produced (package targets only)
mkdir -p /out
for pat in liblcms2 libxcomposite libcolord libmutter mutter; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done
echo "==> done"
