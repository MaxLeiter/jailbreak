#!/usr/bin/env bash
# Cross-builds Xwayland 23.2 (GPU-accelerated via ANGLE-Metal glamor -> IOSurface ->
# iosc_iosurface) + its new dep libxcvt, for rootless iOS. See recipes/xwayland.mk,
# recipes/libxcvt.mk, recipes/ports/xwayland/patches, recipes/build_info/xwayland-glamor-iosurface.c.
# Run on a volume that already has the wayland stack + libepoxy+angle (procursus-vol-gtk or
# procursus-vol-wayland).
#
#   docker run --rm --platform linux/arm64 --cpus=3 \
#     -v procursus-vol-wayland:/work/Procursus \
#     -v "$PWD/build-xwayland.sh:/work/build-xwayland.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/..:/work/x11:ro" \
#     -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-xwayland.sh
#
# --entrypoint bash, not sh: the image's sh is dash, which rejects this script's `set -o pipefail`.
#
# X0 (software wl_shm, first-light/bisect) vs X1 (default, GPU glamor):
#   docker run ... -e XWAYLAND_GLAMOR=false ...   # X0
set -euo pipefail
umask 022
cd /work

echo "==> [1/6] ensure Procursus clone"
if [ ! -d Procursus/.git ]; then
  git clone --depth 1 https://github.com/ProcursusTeam/Procursus.git
fi
cd Procursus

echo "==> [2/6] host build tools"
# libwayland-bin+dev = the NATIVE wayland-scanner + wayland-scanner.pc for
# `dependency('wayland-scanner', native:true)` (no version pin in xwayland).
# libexpat1-dev is needed if the wayland recipe's native-scanner pass runs.
need=""
for p in libwayland-bin libwayland-dev libexpat1-dev; do
  dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"
done
if [ -n "$need" ]; then
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends $need >/dev/null 2>&1 \
    || { echo "ERROR: could not install host tools:$need"; exit 1; }
fi

echo "==> [3/6] toolchain fixes (idempotent; needed on a fresh volume)"
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

python3 - <<'PY'
import re, pathlib
def edit(path, fn):
    p = pathlib.Path(path); s = p.read_text(); n = fn(s)
    if n != s: p.write_text(n); print(f"   patched {path}")
    else: print(f"   (already patched) {path}")
edit("Makefile", lambda s: re.sub(r'(\n\t)@(cp -af\s+\$\(MACOSX_SYSROOT\))', r'\1-@\2', s))
def cxxflags(s):
    if "-stdlib=libc++" in s: return s
    s = s.replace("CXXFLAGS            := $(CFLAGS)",
                  "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
    s = s.replace("-Wl,-not_for_dyld_shared_cache",
                  "-Wl,-not_for_dyld_shared_cache -stdlib=libc++", 1)
    return s
edit("Makefile", cxxflags)
def darwinsrc(s):
    s = s.replace("-D_DARWIN_C_SOURCE -include dlfcn.h", "-D_DARWIN_C_SOURCE")
    if "-D_DARWIN_C_SOURCE" in s: return s
    return s.replace("CXXFLAGS            := $(CFLAGS) -stdlib=libc++",
                     "CFLAGS              += -D_DARWIN_C_SOURCE\n"
                     "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
edit("Makefile", darwinsrc)
edit("Makefile", lambda s: s.replace(
    "/usr/include/{arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}",
    "/usr/include/{_bounds.h,arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}"))
PY

echo "==> [4/6] install recipes + build_info assets into the clone"
# xorgproto.mk overwrites the stock 2021.5 recipe in makefiles/ (bumped to 2024.1, for presentproto 1.3).
for r in xwayland.mk libxcvt.mk libxshmfence.mk xorgproto.mk libepoxy.mk libdrm.mk; do
  [ -f /work/recipes/$r ] && cp -v /work/recipes/$r makefiles/
done
# Force xorgproto rebuild at 2024.1 (base volume has 2021.5 with the .build_complete marker
# short-circuiting a rebuild). Gate on installed presentproto.pc: 2021.5 = 1.2, 2024.1 = 1.4.
PPC=build_base/iphoneos-arm64-rootless/1900/var/jb/usr/share/pkgconfig/presentproto.pc
if ! grep -qE '^Version:\s*1\.[3-9]' "$PPC" 2>/dev/null; then
  echo "   presentproto < 1.3 installed -> forcing xorgproto rebuild at 2024.1"
  rm -rf build_work/*/*/xorgproto 2>/dev/null || true
fi
# control templates + backend .c + iosc protocol XML land in build_info/ (== BUILD_INFO,
# where xwayland.mk reads them).
mkdir -p build_info build_misc/entitlements
cp -v /work/recipes/build_info/*.control build_info/ 2>/dev/null || true
cp -v /work/recipes/build_info/xwayland-glamor-iosurface.c build_info/
cp -v /work/recipes/build_info/iosc-iosurface.xml build_info/
# The SIGN macro reads entitlements from build_misc/entitlements/ (NOT build_info/).
cp -v /work/recipes/build_info/xwayland-ent.xml build_misc/entitlements/

echo "==> staging xwayland patch series"
bash /work/recipes/stage-port-patches.sh xwayland /work/ports build_patch

# xwayland-input.c includes <linux/input.h> for the evdev codes (BTN_*, KEY_*) the Wayland
# input protocol uses; iOS has no linux/ uapi headers. The vendored input-event-codes.h is the
# canonical kernel header — its evdev values must match what the compositor sends. Same pattern
# as build-mutter.sh's linux/dma-buf.h stub.
LINUX_INC=build_base/iphoneos-arm64-rootless/1900/var/jb/usr/include/linux
mkdir -p "$LINUX_INC"
cp -v /work/recipes/build_info/linux-input-event-codes.h "$LINUX_INC/input-event-codes.h"
cp -v /work/recipes/build_info/linux-input.h "$LINUX_INC/input.h"

echo "==> [5/6] stage ANGLE egl.pc + libEGL into the cross sysroot (fresh-volume safety)"
# Xwayland's brokered GPU fence calls EGL/GL directly, so both the configure
# metadata and the exact current ANGLE libraries must be present at link time.
SYSROOT=build_base/iphoneos-arm64-rootless/1900/var/jb/usr
ANGLE_DEB=$(find /out -maxdepth 1 -name 'angle_*_iphoneos-arm64.deb' -print |
  sort -V | tail -1)
[ -n "$ANGLE_DEB" ] || {
  echo "ERROR: current angle package missing from /out" >&2
  exit 1
}
echo "   staging ANGLE from $(basename "$ANGLE_DEB")"
rm -rf /tmp/angle-x && mkdir -p /tmp/angle-x
dpkg-deb -x "$ANGLE_DEB" /tmp/angle-x
mkdir -p "$SYSROOT/lib/pkgconfig"
EGL=$(find /tmp/angle-x -name libEGL.dylib | head -1)
GLES=$(find /tmp/angle-x -name libGLESv2.dylib | head -1)
[ -n "$EGL" ] && [ -n "$GLES" ] || {
  echo "ERROR: angle package is missing EGL/GLES libraries" >&2
  exit 1
}
cp -v "$EGL" "$SYSROOT/lib/libEGL.dylib"
cp -v "$GLES" "$SYSROOT/lib/libGLESv2.dylib"
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

echo "==> [6/6] build libxcvt + xwayland (glamor=${XWAYLAND_GLAMOR:-true})"
COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  XWAYLAND_GLAMOR=${XWAYLAND_GLAMOR:-true} \
  DEB_LIBIOSEXEC_V=1.3.1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
# Package the runtime deps Xwayland links that aren't already Procursus debs, plus xwayland itself.
XW=build_work/iphoneos-arm64-rootless/1900/xwayland
XS=build_stage/iphoneos-arm64-rootless/1900/xwayland
XF="$XW/.xios_patch_series.sha256"
NEW_FP="$(sha256sum \
  /work/ports/xwayland/patches/series \
  /work/ports/xwayland/patches/*.patch \
  /work/recipes/build_info/xwayland-glamor-iosurface.c \
  /work/recipes/build_info/iosc-iosurface.xml | sha256sum | awk '{print $1}')"
OLD_FP="$(cat "$XF" 2>/dev/null || true)"
if [ -d "$XW" ] && [ "$NEW_FP" != "$OLD_FP" ]; then
  echo "==> wiping stale xwayland build after patch/backend changes"
  rm -rf "$XW" "$XS"
fi
TARGETS="${TARGETS:-libxcvt-package libxshmfence-package libdrm-package xwayland-package}"
for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$XW" ]; then
  printf '%s\n' "$NEW_FP" > "$XF"
fi

echo "==> collect debs -> /out"
mkdir -p /out
found=0
DIST_ROOT=build_dist/iphoneos-arm64-rootless/1900
for dir in libxcvt libxshmfence libdrm xwayland; do
  [ -d "$DIST_ROOT/$dir" ] || continue
  for d in "$DIST_ROOT/$dir"/*_*_iphoneos-arm64.deb; do
    [ -e "$d" ] || continue
    cp -v "$d" /out/; found=1
  done
done
[ "$found" = 1 ] || { echo "!! no xwayland debs produced"; exit 1; }
echo "==> done. xwayland X0 bundle in /out:"
ls -1 /out/xwayland*.deb /out/libxcvt0*.deb /out/libxshmfence1*.deb /out/libdrm2*.deb 2>/dev/null || true
