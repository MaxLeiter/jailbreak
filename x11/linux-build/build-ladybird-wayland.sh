#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
X11DIR="$(cd "$HERE/.." && pwd)"
. "$X11DIR/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"
OUT="${OUT:-$HERE/out}"
PROC_VOL="${LADYBIRD_PROC_VOL:-procursus-vol-ladybird}"
IMAGE="${LADYBIRD_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}"
BUILD_DIR="${LADYBIRD_WAYLAND_BUILD_DIR:-/work/Procursus/ladybird-wayland-gtk-build}"
SRC_DIR="${LADYBIRD_SRC_DIR:-/work/Procursus/ladybird-src}"
INSTALL_DIR="$OUT/ladybird-wayland-install"
CPUS="${XIOS_BUILD_CPUS:-4}"

mkdir -p "$OUT"

docker run --rm --platform linux/arm64 --cpus="$CPUS" \
  -e XIOS_MEMO_TARGET -e XIOS_MEMO_CFVER -e XIOS_PREFIX -e XIOS_SUBPREFIX \
  -v "$PROC_VOL:/work/Procursus" \
  -v "$X11DIR/linux-build/target-env.sh:/work/target-env.sh:ro" \
  -v "$HERE/recipes-ladybird:/work/recipes-ladybird:ro" \
  -v "$OUT:/out" \
  "$IMAGE" -lc '
set -euo pipefail
. /work/target-env.sh

PROC=$XIOS_PROC
BB=$XIOS_SYSROOT
SDK=/root/cctools/SDK/iPhoneOS16.5.sdk
SHIM=/work/shim
SRC="'"$SRC_DIR"'"
BUILD="'"$BUILD_DIR"'"
HOST=$PROC/ladybird-hosttools
INSTALL=/out/ladybird-wayland-install

[ -d "$SRC" ] || { echo "missing Ladybird source at $SRC" >&2; exit 2; }
[ -d "$BB" ] || { echo "missing build_base at $BB" >&2; exit 2; }

apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  cmake ninja-build quilt pkg-config libglib2.0-bin libglib2.0-dev-bin >/dev/null

# See build-ladybird-wave4c.sh: the staged prefix is exposed at its device path.
xios_require_rootless "the engine build stages the device prefix as a container symlink"
if [ ! -e "$XIOS_PREFIX" ]; then ln -s "$BB" "$XIOS_PREFIX"; fi
mkdir -p "$SHIM"
for t in ld ranlib libtool install_name_tool otool nm strip lipo dsymutil codesign_allocate \
         segedit size nmedit; do
  [ -e /root/cctools/bin/aarch64-apple-darwin-$t ] && ln -sf /root/cctools/bin/aarch64-apple-darwin-$t "$SHIM/$t"
done
cat > "$SHIM/ar" <<'\''EOF'\''
#!/bin/sh
n=$#; i=0
while [ "$i" -lt "$n" ]; do
  a=$1; shift
  case "$a" in
    @*) f="${a#@}"; for o in $(cat "$f"); do set -- "$@" "$o"; done ;;
    *)  set -- "$@" "$a" ;;
  esac
  i=$((i+1))
done
exec /root/cctools/bin/aarch64-apple-darwin-ar "$@"
EOF
chmod +x "$SHIM/ar"
cat > "$SHIM/lb-cc" <<EOF
#!/bin/sh
exec clang-19 --target=arm64-apple-ios16.0 -isysroot $SDK \
  -B$SHIM -fuse-ld=$SHIM/ld -D__IOS__ "\$@" -Wno-error
EOF
cat > "$SHIM/lb-cxx" <<EOF
#!/bin/sh
exec clang++-19 --target=arm64-apple-ios16.0 -isysroot $SDK -stdlib=libc++ \
  -B$SHIM -fuse-ld=$SHIM/ld -D__IOS__ "\$@" -Wno-error
EOF
cat > "$SHIM/xcrun" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in --show-sdk-path*) echo $SDK; exit 0;; esac; done
if [ "\$1" = "--find" ] || [ "\$1" = "-find" ]; then command -v "$SHIM/\$2" || command -v "\$2" || true; exit 0; fi
echo $SDK
EOF
cat > "$SHIM/sw_vers" <<'\''EOF'\''
#!/bin/sh
case "$1" in -productVersion) echo 13.4;; -buildVersion) echo 22F66;; *) echo macOS;; esac
EOF
chmod +x "$SHIM"/lb-cc "$SHIM"/lb-cxx "$SHIM"/xcrun "$SHIM"/sw_vers
ln -sf "$SHIM/xcrun" /usr/local/bin/xcrun
ln -sf "$SHIM/sw_vers" /usr/local/bin/sw_vers

SKIA_PC=$BB/usr/lib/pkgconfig/skia.pc
if [ -f "$SKIA_PC" ] && grep -q -- "-framework CoreFoundation -framework" "$SKIA_PC"; then
  sed -i "s/-framework \([A-Za-z0-9_]*\)/-Wl,-framework,\1/g" "$SKIA_PC"
fi

export RUSTUP_HOME=$PROC/build_tools/rustup
export CARGO_HOME=$PROC/build_tools/cargo
export PATH=$CARGO_HOME/bin:$SHIM:$PATH
export LB_STAGED_PREFIX=$XIOS_PREFIX
export PKG_CONFIG_PATH=$XIOS_PREFIX/usr/lib/pkgconfig:$XIOS_PREFIX/usr/share/pkgconfig
export PKG_CONFIG_LIBDIR=$XIOS_PREFIX/usr/lib/pkgconfig:$XIOS_PREFIX/usr/share/pkgconfig
export LB_SHIM="$SHIM"
export LB_HOST_GEN_ASM_OFFSETS="$HOST/gen_asm_offsets"
export LB_HOST_ASMINTGEN="$HOST/asmintgen"
export LB_APP_BUILD=1
export LB_APP_GPU=1

if [ ! -x "$LB_HOST_GEN_ASM_OFFSETS" ] || [ ! -x "$LB_HOST_ASMINTGEN" ]; then
  echo "missing Ladybird host asm tools under $HOST; run the Ladybird hosttools stage first" >&2
  exit 2
fi

bash /work/recipes-ladybird/ladybird-m0-patches.sh "$SRC"

if [ "${LADYBIRD_WAYLAND_CLEAN:-0}" = "1" ]; then
  rm -rf "$BUILD"
fi
cmake -GNinja -B "$BUILD" -S "$SRC" \
  -DCMAKE_TOOLCHAIN_FILE=/work/recipes-ladybird/ios-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release \
  -DLADYBIRD_GUI_FRAMEWORK=Gtk \
  -DLADYBIRD_IOS_DESKTOP_FRONTEND=ON \
  -DENABLE_GUI_TARGETS=ON \
  -DENABLE_INSTALL_FREEDESKTOP_FILES=ON \
  -DENABLE_INSTALL_HEADERS=OFF \
  -DENABLE_NETWORK_DOWNLOADS=ON \
  -DENABLE_CLANG_PLUGINS=OFF \
  -DENABLE_CRANELIFT_JIT=OFF \
  -DRUST_TARGET_TRIPLE=aarch64-apple-ios \
  -DLADYBIRD_CACHE_DIR="${XIOS_PREFIX:-/var}/lib/ladybird" \
  -DGLIB_COMPILE_RESOURCES=/usr/bin/glib-compile-resources \
  -DVCPKG_ROOT=

ninja -C "$BUILD" -j"$(nproc)" ladybird WebContent RequestServer ImageDecoder WebWorker Compositor
rm -rf "$INSTALL"
DESTDIR="$INSTALL" cmake --install "$BUILD" --component ladybird_Runtime --prefix "$XIOS_PREFIX/usr"
'

LADYBIRD_WAYLAND_INSTALL_ROOT="$INSTALL_DIR" "$X11DIR/packages/ladybird-wayland/build.sh"
