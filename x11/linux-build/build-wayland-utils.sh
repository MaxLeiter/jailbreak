#!/usr/bin/env bash
# Build small Wayland desktop utilities (slurp region selector, dunst notification daemon,
# mako, and its basu sd-bus provider) for rootless iOS via the Procursus/Docker pipeline. These
# pair with the iosc compositor: slurp + grim = region screenshots, dunst = org.freedesktop.Notifications.
#
#   -e TARGETS="mako-package" builds mako and the Darwin-ported basu dependency.
#
# Runs on the GTK4-warmed volume (procursus-vol-gtk-calc) because mako needs cairo/pango/
# pangocairo/glib/gobject/gdk-pixbuf, all already built+staged there (and slurp needs cairo).
# wayland/wayland-protocols/libxkbcommon/epoll-shim are staged there too. These recipes don't
# exist in Procursus, so we drop ours (recipes/*.mk) into the clone (the main Makefile globs
# makefiles/*.mk).
#
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-gtk-calc:/work/Procursus \
#     -v "$PWD/build-wayland-utils.sh:/work/build-wayland-utils.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e TARGETS="slurp-package" procursus-xbuild:bookworm-arm64 /work/build-wayland-utils.sh
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

BB=$XIOS_SYSROOT
BBINC="$BB/usr/include"

# Host build tools missing from the image:
#  - libwayland-bin: NATIVE wayland-scanner (protocol codegen); slurp/mako run it at build time.
#  - linux-libc-dev: source of linux/input-event-codes.h (BTN_* codes slurp's main.c references).
#  - gperf: basu's meson runs gperf at configure time to build its keyword lookup tables.
#  - python3: meson host runtime.
if ! command -v wayland-scanner >/dev/null 2>&1 || ! command -v gperf >/dev/null 2>&1; then
  echo "==> installing host build tools (wayland-scanner + gperf + linux-libc-dev)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      libwayland-bin gperf linux-libc-dev python3 wget >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/ 2>/dev/null || true

TARGETS="${TARGETS:-slurp-package}"

target_requests() {
  [[ " $TARGETS " == *" $1"* ]]
}

stage_port_patch_stack() {
  local pkg="$1"
  [ -d "/work/ports/$pkg/patches" ] || return 0
  echo "==> staging $pkg source patches"
  bash /work/recipes/stage-port-patches.sh "$pkg" /work/ports build_patch
}

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/ 2>/dev/null || true
fi
mkdir -p build_misc/entitlements
if compgen -G "/work/build_info/iosc-*.xml" >/dev/null 2>&1; then
  cp -v /work/build_info/iosc-*.xml build_misc/entitlements/ 2>/dev/null || true
fi

target_requests slurp && stage_port_patch_stack slurp
target_requests dunst && stage_port_patch_stack dunst
if target_requests mako || target_requests basu; then
  stage_port_patch_stack basu
fi
target_requests mako && stage_port_patch_stack mako

# The Procursus clang wrapper unconditionally injects -Wl,-adhoc_codesign. meson's compile-only
# probes add -Werror=unused-command-line-argument, so every cc.sizeof()/cc.has_function() fails
# ("'linker' input unused") and meson aborts. Route the compiler through a thin wrapper that
# appends -Wno-unused-command-line-argument (last flag wins). Same shim the other drivers use.
echo "==> installing -Wno-unused-command-line-argument clang wrappers"
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# slurp's main.c references the Linux input button codes (BTN_LEFT/RIGHT...) the compositor sends
# via wl_pointer. The real linux/input.h drags in the linux/types.h UAPI chain, but it only needs
# the code #defines, so ship the lightweight input-event-codes.h + a 1-line input.h shim into
# build_base (same approach as build-wayland-apps.sh for foot/imv).
echo "==> installing linux/input-event-codes.h shim into build_base"
mkdir -p "$BBINC/linux"
cp /usr/include/linux/input-event-codes.h "$BBINC/linux/" 2>/dev/null || true
echo '#include <linux/input-event-codes.h>' > "$BBINC/linux/input.h"

# basu uses the C11 char32_t conversion subset, which is absent from the iOS SDK.
# Darwin wchar_t is 32-bit, so the conversions map directly to the wchar APIs.
echo "==> installing uchar.h shim into build_base"
cat > "$BBINC/uchar.h" <<'EOF'
#ifndef _XIOS_UCHAR_H
#define _XIOS_UCHAR_H
#include <stdint.h>
#include <wchar.h>
typedef uint_least16_t char16_t;
typedef uint_least32_t char32_t;
static inline size_t mbrtoc32(char32_t *pc32, const char *s, size_t n, mbstate_t *ps) {
  return mbrtowc((wchar_t *)pc32, s, n, ps);
}
static inline size_t c32rtomb(char *s, char32_t c32, mbstate_t *ps) {
  return wcrtomb(s, (wchar_t)c32, ps);
}
#endif
EOF

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
# Default: just slurp. basu-package + mako-package remain opt-in via TARGETS.

refresh_patch_build_tree() {
  local pkg="$1"
  local patch_dir="/work/ports/$pkg/patches"
  [ -d "$patch_dir" ] || return 0
  local work="build_work/iphoneos-arm64-rootless/1900/$pkg"
  local stage="build_stage/iphoneos-arm64-rootless/1900/$pkg"
  local fp_file="$work/.xios_patch_series.sha256"
  local new_fp old_fp
  new_fp="$(find "$patch_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  old_fp="$(cat "$fp_file" 2>/dev/null || true)"
  if [ -d "$work" ] && [ "$new_fp" != "$old_fp" ]; then
    echo "==> wiping stale $pkg build after patch changes or missing patch marker"
    rm -rf "$work" "$stage"
  fi
}

record_patch_fingerprint() {
  local pkg="$1"
  local patch_dir="/work/ports/$pkg/patches"
  local work="build_work/iphoneos-arm64-rootless/1900/$pkg"
  [ -d "$patch_dir" ] && [ -d "$work" ] || return 0
  find "$patch_dir" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}' > "$work/.xios_patch_series.sha256"
}

for pkg in slurp dunst basu mako; do
  target_requests "$pkg" && refresh_patch_build_tree "$pkg"
done

DW=build_work/$XIOS_TRIPLE/dunst
DS=build_stage/$XIOS_TRIPLE/dunst
DF="$DW/.xios_patch_series.sha256"
if [[ " $TARGETS " == *" dunst"* ]]; then
  NEW_FP="$(sha256sum \
    /work/ports/dunst/patches/series \
    /work/ports/dunst/patches/*.patch | sha256sum | awk '{print $1}')"
  OLD_FP="$(cat "$DF" 2>/dev/null || true)"
  if [ -d "$DW" ] && [ "$NEW_FP" != "$OLD_FP" ]; then
    echo "==> wiping stale dunst build after patch changes"
    rm -rf "$DW" "$DS"
  fi
fi

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
for pkg in slurp dunst basu mako; do
  target_requests "$pkg" && record_patch_fingerprint "$pkg"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in slurp dunst mako basu; do
  find . -name "${pat}_*_$XIOS_DEB_ARCH.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo "==> done"
