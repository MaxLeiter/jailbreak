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
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-eds.sh
# (the image's ENTRYPOINT is /bin/bash, so the bare script path runs under bash)
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

BW=$XIOS_BUILD_WORK
BS=$XIOS_BUILD_STAGE

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

TARGETS="${TARGETS:-\
  icu4c-package \
  libical-package \
  evolution-data-server-package \
  tracker-package}"

target_requests() {
  [[ " $TARGETS " == *" $1"* ]]
}

stage_required_patch_stack() {
  local pkg="$1"
  if [ ! -d "/work/ports/$pkg/patches" ]; then
    echo "ERROR: missing /work/ports/$pkg/patches; mount ports with -v \\$PWD/../ports:/work/ports:ro" >&2
    exit 1
  fi
  echo "==> staging $pkg source patches"
  bash /work/recipes/stage-port-patches.sh "$pkg" /work/ports build_patch
}

target_requests evolution-data-server && stage_required_patch_stack evolution-data-server
target_requests tracker && stage_required_patch_stack tracker

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

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

# Tracker: if the existing build tree is the unistring flavor, wipe it so the recipe
# actually reconfigures with -Dunicode_support=icu (EXTRACT_TAR + .build_complete would
# both no-op). Detection = the configured backend recorded in the meson build dir.
if [ -d "$BW/tracker" ] && grep -rqs 'unistring' "$BW/tracker/build/build.ninja" 2>/dev/null; then
  echo "==> tracker build tree is the unistring flavor — wiping for the ICU rebuild"
  rm -rf "$BW/tracker" "$BS/tracker"
fi

EDS_W=build_work/$XIOS_TRIPLE/evolution-data-server
EDS_S=build_stage/$XIOS_TRIPLE/evolution-data-server
EDS_F="$EDS_W/.xios_patch_series.sha256"
if target_requests evolution-data-server; then
  EDS_FP="$(sha256sum \
    /work/ports/evolution-data-server/patches/series \
    /work/ports/evolution-data-server/patches/*.patch | sha256sum | awk '{print $1}')"
  EDS_OLD_FP="$(cat "$EDS_F" 2>/dev/null || true)"
  if [ -d "$EDS_W" ] && [ "$EDS_FP" != "$EDS_OLD_FP" ]; then
    echo "==> wiping stale evolution-data-server build after patch changes"
    rm -rf "$EDS_W" "$EDS_S"
  fi
fi

TRACKER_W=build_work/$XIOS_TRIPLE/tracker
TRACKER_S=build_stage/$XIOS_TRIPLE/tracker
TRACKER_F="$TRACKER_W/.xios_patch_series.sha256"
if target_requests tracker; then
  TRACKER_FP="$(sha256sum \
    /work/ports/tracker/patches/series \
    /work/ports/tracker/patches/*.patch | sha256sum | awk '{print $1}')"
  TRACKER_OLD_FP="$(cat "$TRACKER_F" 2>/dev/null || true)"
  if [ -d "$TRACKER_W" ] && [ "$TRACKER_FP" != "$TRACKER_OLD_FP" ]; then
    echo "==> wiping stale tracker build after patch changes"
    rm -rf "$TRACKER_W" "$TRACKER_S"
  fi
fi

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$EDS_W" ] && [ -n "${EDS_FP:-}" ]; then
  printf '%s\n' "$EDS_FP" > "$EDS_F"
fi
if [ -d "$TRACKER_W" ] && [ -n "${TRACKER_FP:-}" ]; then
  printf '%s\n' "$TRACKER_FP" > "$TRACKER_F"
fi

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
