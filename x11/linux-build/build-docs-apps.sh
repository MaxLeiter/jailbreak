#!/usr/bin/env bash
# Build the document-viewer stack (poppler + exempi, and — when a Rust->iOS cross toolchain
# exists — Papers) for rootless iOS via the Procursus/Docker pipeline. Companion to
# build-gnome.sh; shares its preamble (host codegen tools + the cc-nounused clang wrapper meson
# probes require). Runs on the GTK4-warmed volume (procursus-vol-gtk-calc).
#
# NOTE: Papers 46.x builds its shell as a Rust crate (shell-rs, gtk-rs/gtk4-rs from git) that
# must cross-compile to aarch64-apple-ios; the image has no Rust toolchain, so papers-package
# is NOT in the default TARGETS. poppler + exempi (its dependency layer) build fine and land
# as debs. See recipes/papers.mk for the full blocker note.
#
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-gtk-calc:/work/Procursus \
#     -v "$PWD/build-docs-apps.sh:/work/build-docs-apps.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e TARGETS="poppler-package exempi-package" procursus-xbuild:bookworm-arm64 /work/build-docs-apps.sh
set -euo pipefail
cd /work/Procursus

# Host build tools missing from the image (same set as build-gnome.sh — poppler-glib runs
# glib-mkenums, and Papers, if ever built, needs the full GNOME app codegen set).
if ! command -v glib-mkenums >/dev/null 2>&1 || ! command -v gdk-pixbuf-pixdata >/dev/null 2>&1 \
   || ! command -v appstreamcli >/dev/null 2>&1 || ! command -v desktop-file-validate >/dev/null 2>&1; then
  echo "==> installing host build tools (glib/gdk-pixbuf codegen + appstream + desktop-file-utils)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      itstool desktop-file-utils appstream gtk-update-icon-cache >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/

TARGETS="${TARGETS:-exempi-package poppler-package girara-package zathura-package zathura-pdf-poppler-package}"

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi
mkdir -p build_misc/entitlements
if compgen -G "/work/build_info/iosc-*.xml" >/dev/null 2>&1; then
  cp -v /work/build_info/iosc-*.xml build_misc/entitlements/
fi

if [[ " $TARGETS " == *" zathura"* ]]; then
  echo "==> staging zathura patch series"
  bash /work/recipes/stage-port-patches.sh zathura /work/ports build_patch
fi

# Same clang wrapper build-gtk.sh/build-gnome.sh use: neutralise the
# -Werror=unused-command-line-argument that breaks meson's cc.sizeof() probes.
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

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

# exempi (libexempi8) is Papers' unconditional XMP dep; poppler (libpoppler140 +
# libpoppler-glib8) is the PDF backend. Both land regardless of the Rust/Papers blocker.
# The zathura stack is the pragmatic PDF viewer (Papers is Rust-blocked): girara (GTK3 UI lib) ->
# zathura (app) -> zathura-pdf-poppler (the poppler PDF backend plugin), built in that order.

ZW=build_work/iphoneos-arm64-rootless/1900/zathura
ZS=build_stage/iphoneos-arm64-rootless/1900/zathura
ZF="$ZW/.xios_patch_series.sha256"
if [[ " $TARGETS " == *" zathura"* ]]; then
  NEW_FP="$(sha256sum \
    /work/ports/zathura/patches/series \
    /work/ports/zathura/patches/*.patch | sha256sum | awk '{print $1}')"
  OLD_FP="$(cat "$ZF" 2>/dev/null || true)"
  if [ -d "$ZW" ] && [ "$NEW_FP" != "$OLD_FP" ]; then
    echo "==> wiping stale zathura build after patch changes"
    rm -rf "$ZW" "$ZS"
  fi
fi

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$ZW" ] && [ -n "${NEW_FP:-}" ]; then
  printf '%s\n' "$NEW_FP" > "$ZF"
fi

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libexempi libpoppler papers libgirara zathura; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Shared libgtkintl relink pass (same as build-gnome.sh): poppler-glib imports the proxy
# libintl (g_libintl_*) and links @rpath/libintl.dylib, so it would dyld-abort exactly like
# the GTK debs. Relink onto the libgtkintl shim, re-sign, add Depends: libgtkintl. Idempotent
# and self-skipping for debs that don't import g_libintl_* (libpoppler140, libexempi8).
if [ -f /work/recipes/relink-gtkintl.sh ]; then
  echo "==> shared libgtkintl relink pass"
  bash /work/recipes/relink-gtkintl.sh /out
fi

echo "==> done"
