#!/usr/bin/env bash
# Build GNOME Settings (gnome-control-center) for rootless iOS via the Procursus/Docker pipeline.
# Companion to build-shell.sh — same preamble, targeting the gnome-control-center config panels.
#
# PRECONDITIONS (procursus-vol-shell, the GNOME-chain volume — all `.build_complete` present):
#   1. build-shell.sh has run (gtk4, libadwaita, gnome-desktop, gsettings-desktop-schemas,
#      colord, accountsservice, polkit, gcr, pulseaudio, upower, gnome-settings-daemon).
#   2. COMPANION deps that gnome-control-center REQUIRES but that are not upstream-portable to
#      iOS as-is (build these first — see recipes/gnome-control-center.mk header):
#        - gudev-1.0 STUB    (REQUIRED: panels/common + system link it; iOS has no udev)
#        - libpwquality      (REQUIRED: password-strength meter in system>users)
#        - gnome-bluetooth   (ONLY for GCC_WITH_BLUETOOTH=1 — Max's Bluetooth panel)
#      These are implemented by the published `xios-desktop-stublibs` package/sysroot
#      producers plus the gnome-bluetooth recipe. Build/stage them first on a fresh volume;
#      without them `meson setup` fails on the missing deps.
#
#   docker run --rm --platform linux/arm64 --cpus=4 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/build-settings.sh:/work/build-settings.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e GCC_WITH_BLUETOOTH=1 \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-settings.sh
set -euo pipefail
cd /work/Procursus

# Host codegen tools (same set build-shell.sh installs).
if ! command -v glib-mkenums >/dev/null 2>&1 || ! command -v xmllint >/dev/null 2>&1 \
   || ! pkg-config --exists glib-2.0 2>/dev/null; then
  echo "==> installing host build tools (glib/gdk-pixbuf codegen + itstool + xmllint + HOST glib)"
  apt-get update >/dev/null 2>&1 || true
  # libxml2-utils => xmllint (gnome-bluetooth's lib/meson.build validates its gresource XML).
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      pkg-config sassc itstool desktop-file-utils gtk-update-icon-cache libxml2-utils >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

# The stack's GTK4 gdkkeysyms.h predates a batch of Unicode GDK_KEY_dead_* keysyms that gcc's
# bundled `tecla` (keyboard-layout preview) references (dead_hamza, dead_belowmacron, …), so the
# tecla subproject fails to compile. Keysyms are pure compile-time #defines (additive, no ABI),
# so refresh the header from upstream GTK. Guarded + idempotent; no GTK4 rebuild.
GDKKS="$(find /work/Procursus/build_base -path '*gtk-4.0/gdk/gdkkeysyms.h' 2>/dev/null | head -1)"
if [ -n "$GDKKS" ] && ! grep -q GDK_KEY_dead_hamza "$GDKKS"; then
  echo "==> refreshing $GDKKS from upstream GTK (missing dead_* keysyms)"
  curl -fsSL "https://gitlab.gnome.org/GNOME/gtk/-/raw/main/gdk/gdkkeysyms.h" -o "$GDKKS" \
    && echo "   refreshed gdkkeysyms.h" || echo "   WARNING: gdkkeysyms.h refresh failed"
fi

# libgtop packaging gap: the libgtop build staged its glibtop/*.h headers but never copied them
# into build_base's sysroot (only the .pc + lib), so gcc's privacy panel (cc-firmware-security-
# dialog.c -> <glibtop/fsusage.h>) can't find them. Copy the staged include tree into the sysroot.
SR=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr
GTOP_STAGE=/work/Procursus/build_stage/iphoneos-arm64-rootless/1900/libgtop/var/jb/usr
if [ ! -e "$SR/include/glibtop/fsusage.h" ] && [ -d "$GTOP_STAGE/include/glibtop" ]; then
  echo "==> staging libgtop headers into the sysroot (packaging gap)"
  cp -av "$GTOP_STAGE/include/glibtop" "$SR/include/" 2>/dev/null || true
  [ -f "$GTOP_STAGE/include/glibtop.h" ] && cp -av "$GTOP_STAGE/include/glibtop.h" "$SR/include/" 2>/dev/null || true
  [ -d "$GTOP_STAGE/lib/glibtop-2.0" ] && cp -av "$GTOP_STAGE/lib/glibtop-2.0" "$SR/lib/" 2>/dev/null || true
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/

echo "==> staging gnome-control-center patch series"
bash /work/recipes/stage-port-patches.sh gnome-control-center /work/ports build_patch
if [ "${GCC_WITH_BLUETOOTH:-0}" = 1 ]; then
  BT_PATCH_DIR=/work/ports/gnome-control-center/patches-bluetooth
  BT_SERIES="$BT_PATCH_DIR/series"
  [ -f "$BT_SERIES" ] || { echo "missing $BT_SERIES" >&2; exit 1; }
  echo "==> staging gnome-control-center Bluetooth patch series"
  mkdir -p build_patch/gnome-control-center
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    set -- $line
    [ "$#" -gt 0 ] || continue
    patch="$BT_PATCH_DIR/$1"
    [ -f "$patch" ] || { echo "missing $patch" >&2; exit 1; }
    cp -v "$patch" build_patch/gnome-control-center/
  done < "$BT_SERIES"
fi

echo "==> installing our control templates into build_info/"
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
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused \
  GCC_WITH_BLUETOOTH=${GCC_WITH_BLUETOOTH:-0}"

# The panel set is selected at configure time (GCC_WITH_BLUETOOTH + the iOS patch stacks), but
# the recipe short-circuits on .build_complete and would just re-package a stale tree. So when
# (re)building gnome-control-center, wipe its work/stage/marker to force a pristine re-extract +
# re-patch + reconfigure (same reason gnome-shell's WITH_EDS path wipes). gnome-bluetooth is a
# plain lib and doesn't need this.
BW=/work/Procursus/build_work/iphoneos-arm64-rootless/1900
BS=/work/Procursus/build_stage/iphoneos-arm64-rootless/1900
case " ${TARGETS:-gnome-control-center-package} " in
  *gnome-control-center*)
    echo "==> wiping gnome-control-center tree for a pristine (re)configure"
    rm -rf "$BW/gnome-control-center" "$BS/gnome-control-center" ;;
esac

TARGETS="${TARGETS:-gnome-control-center-package}"
for t in $TARGETS; do
  echo "==> make $t (GCC_WITH_BLUETOOTH=${GCC_WITH_BLUETOOTH:-0})"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for stem in gnome-control-center gnome-bluetooth libgtop-2.0-11; do
  find . -name "${stem}_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo "==> shared libgtkintl relink pass"
bash /work/recipes/relink-gtkintl.sh /out || true
echo "==> done"
