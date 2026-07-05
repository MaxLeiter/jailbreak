#!/usr/bin/env bash
# Build the gnome-shell BOOT-CRITICAL client libraries for rootless iOS. gnome-shell's
# js/misc/dependencies.js statically imports these typelibs at startup, so the shell crashes
# at boot if any is missing. Each is built client-lib-only with introspection OFF; the typelib
# is generated ON-DEVICE (the St/Shell/AccountsService pattern - g-ir-scanner can't run on a
# Mach-O target under cross-build).
#   libupower-glib (UPowerGlib)  - battery indicator (status/system.js)
#   geocode-glib                 - build dep of libgweather-4
#   libgweather-4 (GWeather)     - weather in the clock (dateMenu.js)
#   libgeoclue (Geoclue)         - location (misc/weather.js)
#
# Same warm volume that built glib/gtk/gnome-shell (procursus-vol-shell):
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/build-shell-libs.sh:/work/build-shell-libs.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-shell-libs.sh
set -euo pipefail
cd /work/Procursus

if ! command -v glib-mkenums >/dev/null 2>&1 || ! pkg-config --exists glib-2.0 2>/dev/null \
   || ! python3 -c 'import gi' >/dev/null 2>&1; then
  echo "==> installing host build tools (glib codegen + HOST glib + python3-gi for gweather)"
  apt-get update >/dev/null 2>&1 || true
  # python3-gi (PyGObject): libgweather's gen_locations_variant.py builds the cities DB with it.
  apt-get install -y --no-install-recommends \
      libglib2.0-dev libglib2.0-dev-bin libglib2.0-bin pkg-config \
      python3 python3-gi gir1.2-glib-2.0 >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes + control templates"
cp -v /work/recipes/*.mk makefiles/

# geocode-glib before gweather4 (build dep). gdm added later if the lead confirms.
TARGETS="${TARGETS:-\
  upower-package \
  geocode-glib-package \
  gweather4-package \
  geoclue-package}"

if [[ " $TARGETS " == *" upower"* ]]; then
  echo "==> staging upower patch series"
  bash /work/recipes/stage-port-patches.sh upower /work/ports build_patch
fi

if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi

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

UPOW_W=build_work/iphoneos-arm64-rootless/1900/upower
UPOW_S=build_stage/iphoneos-arm64-rootless/1900/upower
UPOW_F="$UPOW_W/.xios_patch_series.sha256"
if [[ " $TARGETS " == *" upower"* ]]; then
  UPOW_FP="$(sha256sum \
    /work/ports/upower/patches/series \
    /work/ports/upower/patches/*.patch | sha256sum | awk '{print $1}')"
  UPOW_OLD_FP="$(cat "$UPOW_F" 2>/dev/null || true)"
  if [ -d "$UPOW_W" ] && [ "$UPOW_FP" != "$UPOW_OLD_FP" ]; then
    echo "==> wiping stale upower build after patch changes"
    rm -rf "$UPOW_W" "$UPOW_S"
  fi
fi

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$UPOW_W" ] && [ -n "${UPOW_FP:-}" ]; then
  printf '%s\n' "$UPOW_FP" > "$UPOW_F"
fi

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libupower-glib libgeocode-glib libgweather-4 libgeoclue libgdm; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo "==> done"
