#!/usr/bin/env bash
# Build librsvg + the GdkPixbuf SVG loader for rootless iOS.
#
# This is deliberately separate from build-gnome.sh because it pulls in Rust.
# Usage:
#   docker run --rm --platform linux/arm64 --cpus=3 \
#     -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/build-librsvg.sh:/work/build-librsvg.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-librsvg.sh
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

if ! command -v gdk-pixbuf-query-loaders >/dev/null 2>&1 || ! command -v rst2man >/dev/null 2>&1; then
  echo "==> installing host librsvg helpers"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      libgdk-pixbuf2.0-bin python3-docutils ca-certificates curl >/dev/null 2>&1 \
    || { echo "ERROR: could not install host librsvg helpers"; exit 1; }
fi
if ! command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
  loader_query="$(find /usr/lib -path '*/gdk-pixbuf-2.0/gdk-pixbuf-query-loaders' -type f | head -1)"
  if [ -n "$loader_query" ]; then
    ln -sf "$loader_query" /usr/local/bin/gdk-pixbuf-query-loaders
  fi
fi

if ! command -v rustc >/dev/null 2>&1 || ! rustup target list --installed 2>/dev/null | grep -qx aarch64-apple-ios; then
  echo "==> installing rustup + aarch64-apple-ios target"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env"
  rustup target add aarch64-apple-ios
else
  # shellcheck disable=SC1091
  . "$HOME/.cargo/env" 2>/dev/null || true
fi

echo "==> installing recipes/control templates"
cp -v /work/recipes/*.mk makefiles/
[ -d /work/build_info ] && cp -v /work/build_info/* build_info/ 2>/dev/null || true

# Rust's aarch64-apple-ios target invokes the configured linker directly. Make
# sure clang resolves plain "ld" to cctools' ld64 instead of Debian's GNU ld.
ln -sf aarch64-apple-darwin-ld /root/cctools/bin/ld

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

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

TARGETS="${TARGETS:-librsvg-package}"
if [ "${LIBRSVG_CLEAN:-0}" = "1" ]; then
  echo "==> LIBRSVG_CLEAN=1: wiping previous librsvg work tree"
  rm -rf build_work/*/*/librsvg 2>/dev/null || true
fi
for t in $TARGETS; do
  echo "==> make $t"
  make "$t" $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
find . -name "librsvg2*_*_$XIOS_DEB_ARCH.deb" -exec cp -v {} /out/ \; 2>/dev/null || true

echo "==> done"
