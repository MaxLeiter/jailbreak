#!/usr/bin/env bash
# Rebuild ONLY the ffmpeg 5.1 runtime (libavcodec59 and siblings, used by mpv) on procursus-vol-wayland.
# build-wayland-apps.sh is deliberately not used: its preamble force-rebuilds wayland-protocols and mpv
# markers in the volume. The stale ffmpeg build_work/build_stage/build_base files are removed by a
# separate scoped `docker run ... bash -c` beforehand, never by this script.
#
#   docker run --rm --platform linux/arm64 -v procursus-vol-wayland:/work/Procursus \
#     -v .../target-env.sh:/work/target-env.sh:ro -v .../build-upd-core-ffmpeg51.sh:/work/b.sh:ro \
#     -v .../recipes:/work/recipes:ro -v .../build_info:/work/build_info:ro -v OUT:/out \
#     procursus-xbuild:bookworm-arm64 /work/b.sh
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus
cp -v /work/recipes/ffmpeg.mk makefiles/
cp -v /work/build_info/libav*.control /work/build_info/libsw*.control build_info/
cat > build_tools/cc-nounused <<'X'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
X
cat > build_tools/cxx-nounused <<'X'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
X
chmod +x build_tools/cc-nounused build_tools/cxx-nounused
# same ephemeral SDK backport build-wayland-apps.sh applies (VideoToolbox/AudioToolbox probes need it)
OSOBJ=/root/cctools/SDK/iPhoneOS16.5.sdk/usr/include/os/object.h
if [ -f "$OSOBJ" ] && ! grep -q OS_OBJECT_DECL_SENDABLE_CLASS "$OSOBJ"; then
  cat >> "$OSOBJ" <<'X'

#ifndef OS_OBJECT_DECL_SENDABLE_CLASS
#define OS_OBJECT_DECL_SENDABLE_CLASS(name) OS_OBJECT_DECL_CLASS(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SWIFT(name) OS_OBJECT_DECL_SWIFT(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT(name, super) OS_OBJECT_DECL_SUBCLASS_SWIFT(name, super)
#endif
X
fi
COMMON="$XIOS_MEMO_ARGS NO_PGP=1 CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
START=$(date +%s)
make ffmpeg-package $COMMON -j"$(nproc)" || { echo "SUMMARY ffmpeg FAILED"; exit 1; }
mkdir -p /out
find ./build_dist/$XIOS_TRIPLE/ffmpeg -name "*_$XIOS_DEB_ARCH.deb" -newermt "@$START" -exec cp -v {} /out/ \;
echo "SUMMARY ffmpeg OK"
