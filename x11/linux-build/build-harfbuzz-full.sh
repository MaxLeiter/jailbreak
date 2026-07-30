#!/usr/bin/env bash
# Rebuild harfbuzz 10.2.0 with EVERY backend enabled, so the deb that shadows
# Procursus harfbuzz 2.8.1 is a strict superset of it instead of a subset.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-harfbuzz-full.sh:/work/build-harfbuzz-full.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-harfbuzz-full.sh
#
# Why: 10.2.0+ios1 was built -Dglib=disabled -Dgobject=disabled -Dcoretext=disabled
# -Dgraphite2=disabled for the Ladybird closure, and it kept the Procursus package
# name. Installing it removed _hb_glib_*, _hb_coretext_* and _hb_graphite2_* from
# libharfbuzz.0.dylib; libgtk-4.1.dylib binds _hb_glib_script_to_script, so every
# GTK4 app died with "dyld: Symbol not found" (reproduced on device 2026-07-29).
# glib-2.0, gobject-2.0, graphite2, freetype2 and icu are all already staged in
# this volume, so this is a flag flip plus the family packages the old build left
# stranded at 2.8.1 (libharfbuzz-bin, libharfbuzz-gobject0).
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

echo "==> installing the full-backend harfbuzz recipe into makefiles/"
cp -v /work/recipes-ladybird/harfbuzz.mk makefiles/

echo "==> installing harfbuzz control templates into build_info/"
cp -v /work/build_info-ladybird/libharfbuzz0b.control \
      /work/build_info-ladybird/libharfbuzz-icu0.control \
      /work/build_info-ladybird/libharfbuzz-subset0.control \
      /work/build_info-ladybird/libharfbuzz-dev.control build_info/

# -Dgobject=enabled runs glib-mkenums/glib-genmarshal on the HOST to generate the
# enum sources; the xbuild image has cross glib staged but not the host codegen tools.
if ! command -v glib-mkenums >/dev/null 2>&1; then
  echo "==> installing host glib codegen tools (glib-mkenums)"
  apt-get update -qq && apt-get install -y -qq libglib2.0-dev-bin >/dev/null \
    || echo "!!! could not install libglib2.0-dev-bin; gobject backend will fail"
fi

echo "==> (re)installing -Wno-unused-command-line-argument clang wrappers"
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

BW=$XIOS_BUILD_WORK
BS=$XIOS_BUILD_STAGE
BB=$XIOS_SYSROOT
mkdir -p /out

# Same stale-shadow wipe wave 2 uses: build_work/.build_complete and build_stage must
# go or the recipe no-ops and repackages the old backend-less binaries under +ios2.
echo "--- wiping stale harfbuzz (build_work + build_stage + build_base)"
rm -rf "$BW/harfbuzz" "$BS/harfbuzz"
rm -rf $BB/usr/lib/libharfbuzz* $BB/usr/lib/pkgconfig/harfbuzz*.pc \
       $BB/usr/include/harfbuzz $BB/usr/lib/cmake/harfbuzz $BB/usr/bin/hb-*

echo ""
echo "==> make harfbuzz-package"
if make harfbuzz-package $COMMON -j"$(nproc)"; then
  RESULT=OK
else
  RESULT=FAILED
fi

echo ""
echo "==> collect debs -> /out"
for pat in libharfbuzz0b libharfbuzz-icu0 libharfbuzz-subset0 \
           libharfbuzz-gobject0 libharfbuzz-bin libharfbuzz-dev; do
  find . -name "${pat}_*_iphoneos-arm64.deb" -newermt "-8 hours" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo ""
echo "==> exported symbol sanity (must contain hb_glib / hb_coretext / hb_graphite2)"
HB="$BS/harfbuzz$BB/usr/lib/libharfbuzz.0.dylib"
[ -f "$HB" ] || HB="$(find "$BS/harfbuzz" -name 'libharfbuzz.0.dylib' | head -1)"
if [ -n "$HB" ] && [ -f "$HB" ]; then
  for sym in hb_glib_script_to_script hb_glib_get_unicode_funcs hb_coretext_font_create \
             hb_graphite2_face_get_gr_face; do
    if strings -a "$HB" | grep -q "^_\{0,1\}${sym}\$"; then echo "  OK   $sym"; else echo "  MISS $sym"; fi
  done
else
  echo "  (staged dylib not found for symbol check)"
fi

echo ""
echo "==================== HARFBUZZ SUMMARY ===================="
printf '  %-16s %s\n' harfbuzz "$RESULT"
echo "=========================================================="
[ "$RESULT" = OK ]
