#!/usr/bin/env bash
# Build the post-ICU batch for rootless iOS via the Procursus/Docker pipeline:
#   icu4c (idempotent; seeds this volume's BUILD_BASE if ICU was built elsewhere)
#   -> libical (native-then-cross ical-glib-src-generator, see recipes/libical.mk)
#   -> evolution-data-server (the package ICU was built FOR — gnome-shell calendar backend)
#   -> tracker REBUILD with -Dunicode_support=icu (was unistring; deb rev 3.7.3-2)
# Companion to build-icu.sh/build-shell.sh — same preamble. The tracker step auto-wipes a
# stale unistring-flavored build_work/tracker (its .build_complete would otherwise short-
# circuit the recipe and silently hand back the old library).
#
# PRECONDITIONS (same Procursus volume, e.g. procursus-vol-shell):
#   the GNOME base chain is built (.build_complete: glib/sqlite3/libxml2/json-glib/libsoup3/
#   libsecret) — true on any volume that ran build-gnome.sh + build-shell.sh.
#
#   docker run --rm --platform linux/arm64 --cpus=2 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/build-eds.sh:/work/build-eds.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-eds.sh
# (the image's ENTRYPOINT is /bin/bash, so the bare script path runs under bash)
set -euo pipefail
cd /work/Procursus

BW=/work/Procursus/build_work/iphoneos-arm64-rootless/1900
BS=/work/Procursus/build_stage/iphoneos-arm64-rootless/1900

# Host build tools: the usual glib codegen set, plus gperf (EDS hard-requires it) and HOST
# glib/libxml2 -dev + pkg-config for libical's NATIVE ical-glib-src-generator half.
if ! command -v gperf >/dev/null 2>&1 || ! command -v glib-mkenums >/dev/null 2>&1 \
   || ! pkg-config --exists glib-2.0 libxml-2.0 2>/dev/null; then
  echo "==> installing host build tools (gperf + glib codegen + host glib/libxml2 -dev)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      gperf pkg-config libglib2.0-dev libglib2.0-dev-bin libglib2.0-bin libxml2-dev \
      >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi

# Same clang wrapper the other drivers use (meson/cmake probes vs the Procursus wrapper's
# -Wl,-adhoc_codesign + -Werror=unused-command-line-argument).
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

# Tracker: if the existing build tree is the unistring flavor, wipe it so the recipe
# actually reconfigures with -Dunicode_support=icu (EXTRACT_TAR + .build_complete would
# both no-op). Detection = the configured backend recorded in the meson build dir.
if [ -d "$BW/tracker" ] && grep -rqs 'unistring' "$BW/tracker/build/build.ninja" 2>/dev/null; then
  echo "==> tracker build tree is the unistring flavor — wiping for the ICU rebuild"
  rm -rf "$BW/tracker" "$BS/tracker"
fi

TARGETS="${TARGETS:-\
  icu4c-package \
  libical-package \
  evolution-data-server-package \
  tracker-package}"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libicu icu-devtools libical evolution-data-server libtracker; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Shared libgtkintl pass: libical-glib/EDS/tracker link glib and would import the renamed
# g_libintl_* via @rpath/libintl.dylib like every other GNOME deb. Idempotent, skips clean debs.
echo "==> shared libgtkintl relink pass"
bash /work/recipes/relink-gtkintl.sh /out

echo "==> done"
