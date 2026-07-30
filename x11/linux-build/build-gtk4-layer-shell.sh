#!/usr/bin/env bash
# Build gtk4-layer-shell for rootless iOS via the Procursus/Docker pipeline.
# Drops recipes/gtk4-layer-shell.mk into the clone and builds against the already-
# built GTK4 + Wayland stack (reuse the procursus-vol-gtk volume). See
# x11/docs/iosc-shell.md §4.
#
#   docker run --rm -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/recipes:/work/recipes:ro" -v "$PWD/build_info:/work/build_info:ro" \
#     -v "$PWD/out:/out" procursus-xbuild:bookworm-arm64 /work/build-gtk4-layer-shell.sh
# (build-gtk4-layer-shell.sh itself mounted read-only at /work/ — see run wrapper below.)
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

echo "==> installing host wayland-scanner (libwayland-bin) for protocol codegen"
# gtk4-layer-shell's protocol/meson.build falls back to find_program('wayland-scanner')
# on PATH when the native wayland-scanner dep isn't found (it lives in the iOS sysroot).
if ! command -v wayland-scanner >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends libwayland-bin >/dev/null 2>&1 \
    || { echo "ERROR: could not install libwayland-bin"; exit 1; }
fi

echo "==> installing the -Wno-unused-command-line-argument clang wrappers (meson probes)"
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

echo "==> installing recipe + control template"
cp -v /work/recipes/gtk4-layer-shell.mk makefiles/
[ -f /work/build_info/gtk4-layer-shell.control ] && cp -v /work/build_info/gtk4-layer-shell.control build_info/

# Pre-flight: the build needs gtk4 + wayland-client + wayland-protocols (with the staged
# xdg-shell.xml and staging/ext-session-lock-v1.xml) already in build_base. These came
# from the GTK4 build that populated this volume; fail loudly if the volume is wrong.
BB=build_base/$XIOS_TRIPLE$XIOS_PREFIX/usr
for f in lib/pkgconfig/gtk4.pc lib/pkgconfig/wayland-client.pc share/pkgconfig/wayland-protocols.pc \
         share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
         share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml; do
  [ -f "$BB/$f" ] || { echo "ERROR: missing staged dep $BB/$f — use the procursus-vol-gtk volume (post-GTK4 build)"; exit 1; }
done
echo "==> pre-flight ok: gtk4 + wayland deps staged"

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

echo "==> make gtk4-layer-shell-package"
make gtk4-layer-shell-package $COMMON -j"$(nproc)"

echo "==> collect deb -> /out"
mkdir -p /out
find . -name "gtk4-layer-shell_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
echo "==> done"
ls -l /out/gtk4-layer-shell_*.deb 2>/dev/null || echo "NOTE: no deb produced — check the build log above"
