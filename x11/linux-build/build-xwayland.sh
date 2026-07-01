#!/usr/bin/env bash
# build-xwayland.sh — cross-build Xwayland 23.2 (GPU-accelerated on ANGLE-Metal,
# glamor pixmaps -> IOSurface -> iosc_iosurface) + its one new dep libxcvt, for
# rootless iOS. See recipes/xwayland.mk, recipes/libxcvt.mk, recipes/
# xwayland-ios-fixes.sh, recipes/build_info/xwayland-glamor-iosurface.c.
#
# PREP/HOLD status: this is the build DRIVER; the build is gated on a free volume
# slot (do NOT collide with the running ICU/gnome-shell/Qt builds). When cleared,
# fire host-side on a volume that already has the wayland stack + libepoxy+angle
# (warmest: procursus-vol-gtk or procursus-vol-wayland), e.g.:
#
#   docker run --rm --platform linux/arm64 --cpus=3 \
#     -v procursus-vol-wayland:/work/Procursus \
#     -v "$PWD/build-xwayland.sh:/work/build-xwayland.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-xwayland.sh
#
# NOTE: --entrypoint bash (NOT sh): the image's sh is dash, which rejects this
# script's `set -o pipefail`. The image ships bash (its default entrypoint).
#
# X0 (software wl_shm, first-light / bisect) vs X1 (default, GPU glamor):
#   docker run ... -e XWAYLAND_GLAMOR=false ...   # X0
#
# On a warm volume this is small (only libxcvt + Xwayland compile from source;
# every other dep is cached). On a fresh volume it also does `setup` + the whole
# X/Wayland cascade — slow but self-contained.
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
# xwayland.mk + libxcvt.mk + libxshmfence.mk + the ANGLE-repointed libepoxy.mk +
# the libdrm shim + the bumped xorgproto.mk (2024.1, for presentproto 1.3). The
# xorgproto.mk OVERWRITES the stock 2021.5 recipe in makefiles/.
for r in xwayland.mk libxcvt.mk libxshmfence.mk xorgproto.mk libepoxy.mk libdrm.mk; do
  [ -f /work/recipes/$r ] && cp -v /work/recipes/$r makefiles/
done
# xorgproto was built at 2021.5 on the base volume; force a rebuild at 2024.1 by
# dropping its work dir + marker (the .build_complete marker short-circuits
# otherwise). Gate on the INSTALLED presentproto.pc: 2021.5 = 1.2, 2024.1 = 1.4.
PPC=build_base/iphoneos-arm64-rootless/1900/var/jb/usr/share/pkgconfig/presentproto.pc
if ! grep -qE '^Version:\s*1\.[3-9]' "$PPC" 2>/dev/null; then
  echo "   presentproto < 1.3 installed -> forcing xorgproto rebuild at 2024.1"
  rm -rf build_work/*/*/xorgproto 2>/dev/null || true
fi
# control templates + the backend .c + iosc protocol XML + the source-fix script
# all live in recipes/build_info/ and land in the clone's build_info/ (== BUILD_INFO,
# where xwayland.mk reads xwayland-ios-fixes.sh / the backend / the XML).
mkdir -p build_info build_misc/entitlements
cp -v /work/recipes/build_info/*.control build_info/ 2>/dev/null || true
cp -v /work/recipes/build_info/xwayland-glamor-iosurface.c build_info/
cp -v /work/recipes/build_info/iosc-iosurface.xml build_info/
cp -v /work/recipes/xwayland-ios-fixes.sh build_info/
# The SIGN macro reads entitlements from build_misc/entitlements/ (NOT build_info/).
cp -v /work/recipes/build_info/xwayland-ent.xml build_misc/entitlements/

# Stage a <linux/input.h> + <linux/input-event-codes.h> shim into the cross
# sysroot: xwayland-input.c includes <linux/input.h> for the evdev codes (BTN_*,
# KEY_*) the Wayland input protocol uses. iOS has no linux/ uapi headers. The
# vendored input-event-codes.h is the canonical kernel header (exact evdev values
# — they must match what the compositor sends). Same pattern as build-mutter.sh's
# linux/dma-buf.h stub.
LINUX_INC=build_base/iphoneos-arm64-rootless/1900/var/jb/usr/include/linux
mkdir -p "$LINUX_INC"
cp -v /work/recipes/build_info/linux-input-event-codes.h "$LINUX_INC/input-event-codes.h"
cp -v /work/recipes/build_info/linux-input.h "$LINUX_INC/input.h"

echo "==> [5/6] stage ANGLE egl.pc + libEGL into the cross sysroot (fresh-volume safety)"
# The X server links libepoxy (repointed at ANGLE), which dlopens ANGLE at runtime; but
# glamor's meson also probes epoxy/egl. On a warm mutter volume egl.pc is already staged;
# stage it here too so a fresh volume links. Harmless if it already exists.
SYSROOT=build_base/iphoneos-arm64-rootless/1900/var/jb/usr
if [ ! -e "$SYSROOT/lib/pkgconfig/egl.pc" ]; then
  ANGLE_DEB=$(ls /out/angle_*_iphoneos-arm64.deb 2>/dev/null | grep -v "+es3" | head -1)
  if [ -n "$ANGLE_DEB" ]; then
    echo "   staging ANGLE from $(basename "$ANGLE_DEB")"
    rm -rf /tmp/angle-x && mkdir -p /tmp/angle-x && dpkg-deb -x "$ANGLE_DEB" /tmp/angle-x
    mkdir -p "$SYSROOT/lib/pkgconfig"
    EGL=$(find /tmp/angle-x -name libEGL.dylib | head -1)
    GLES=$(find /tmp/angle-x -name libGLESv2.dylib | head -1)
    [ -n "$EGL" ]  && cp -v "$EGL"  "$SYSROOT/lib/libEGL.dylib"
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
  else
    echo "   NOTE: no angle deb in /out — relying on libepoxy's runtime dlopen only"
  fi
fi

echo "==> [6/6] build libxcvt + xwayland (glamor=${XWAYLAND_GLAMOR:-true})"
COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  XWAYLAND_GLAMOR=${XWAYLAND_GLAMOR:-true} \
  DEB_LIBIOSEXEC_V=1.3.1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
# Package the runtime deps Xwayland links that aren't already Procursus debs:
# libxcvt0, libxshmfence1, libdrm2 (the shim) — plus xwayland itself. All except
# xwayland are quick (libs already built as deps; -package just wraps the deb).
TARGETS="${TARGETS:-libxcvt-package libxshmfence-package libdrm-package xwayland-package}"
for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
found=0
for pat in libxcvt libxshmfence libdrm2 libdrm-dev xwayland; do
  for d in $(find . -name "${pat}*_*_iphoneos-arm64.deb" 2>/dev/null); do
    cp -v "$d" /out/; found=1
  done
done
[ "$found" = 1 ] || { echo "!! no xwayland debs produced"; exit 1; }
echo "==> done. xwayland X0 bundle in /out:"
ls -1 /out/xwayland*.deb /out/libxcvt0*.deb /out/libxshmfence1*.deb /out/libdrm2*.deb 2>/dev/null || true
