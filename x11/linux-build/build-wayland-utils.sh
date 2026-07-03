#!/usr/bin/env bash
# Build small Wayland desktop utilities (slurp region selector, mako notification daemon) and
# mako's sd-bus provider (basu) for rootless iOS via the Procursus/Docker pipeline. These pair
# with the iosc compositor: slurp + grim = region screenshots, mako = org.freedesktop.Notifications.
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
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e TARGETS="slurp-package" procursus-xbuild:bookworm-arm64 /work/build-wayland-utils.sh
set -euo pipefail
cd /work/Procursus

BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
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

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/ 2>/dev/null || true
fi
mkdir -p build_misc/entitlements
if compgen -G "/work/build_info/iosc-*.xml" >/dev/null 2>&1; then
  cp -v /work/build_info/iosc-*.xml build_misc/entitlements/ 2>/dev/null || true
fi

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

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
# Default: just slurp (the safe quick win). basu-package + mako-package are opt-in via TARGETS
# because mako's sd-bus provider (basu) is a Linux-centric port with real Darwin walls.
TARGETS="${TARGETS:-slurp-package}"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in slurp mako basu; do
  find . -name "${pat}_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo "==> done"
