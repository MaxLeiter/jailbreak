#!/usr/bin/env bash
# Build the GNOME apps stack (GTK4 + libadwaita + the apps) for rootless iOS via the
# Procursus/Docker pipeline. Companion to build-gtk.sh — does NOT edit it. Drops our
# recipes/*.mk + build_info/* into the clone (the main Makefile globs makefiles/*.mk) and
# builds our dependency chain in order. Shares build-gtk.sh's proven preamble (host codegen
# tools + the cc-nounused clang wrapper that meson probes require).
#
# PRECONDITIONS (same Procursus volume, e.g. procursus-vol-gtk):
#   1. build-gtk.sh has built the GTK4 base: graphene/gdk-pixbuf/gtk4 (+ their build_complete).
#   2. The Wayland track's libxkbcommon is built WITH -Denable-xkbregistry=true (gnome-desktop
#      needs libxkbregistry). (dbus is lightde's recipe; idempotent if already built.)
#
#   docker run --rm --platform linux/arm64 --cpus=2 \
#     -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/build-gnome.sh:/work/build-gnome.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/vapi:/work/vapi:ro" -v "$PWD/out:/out" \
#     -e TARGETS="gnome-console-package" procursus-xbuild:bookworm-arm64 /work/build-gnome.sh
set -euo pipefail
cd /work/Procursus

# Host build tools missing from the image. gtk-doc-tools + native glib/gdk-pixbuf codegen are
# the same set build-gtk.sh installs; sassc (libadwaita SCSS), valac (Vala apps), itstool +
# desktop-file-utils (app translations/validation) are ours.
if ! command -v glib-mkenums >/dev/null 2>&1 || ! command -v sassc >/dev/null 2>&1 \
   || ! command -v valac >/dev/null 2>&1 || ! command -v gdk-pixbuf-pixdata >/dev/null 2>&1 \
   || ! command -v appstreamcli >/dev/null 2>&1; then
  echo "==> installing host build tools (glib/gdk-pixbuf codegen + sassc + valac + itstool + appstreamcli)"
  apt-get update >/dev/null 2>&1 || true
  # appstream (host appstreamcli) is the native tool AppStream's own cross-build invokes for
  # news-to-metainfo; the recipe patches out its >= version gate so the bookworm 0.16 cli works.
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      sassc valac itstool desktop-file-utils appstream gtk-update-icon-cache tcl >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/
# gtk+3.0.mk compiles the libgtkintl proxy-libintl shim from this source ($(BUILD_TOOLS)).
cp -v /work/recipes/gtkintl_shim.c build_tools/ 2>/dev/null || true

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi
mkdir -p build_misc/entitlements
if compgen -G "/work/build_info/iosc-*.xml" >/dev/null 2>&1; then
  cp -v /work/build_info/iosc-*.xml build_misc/entitlements/
fi

# Same clang wrapper build-gtk.sh uses: the Procursus wrapper injects -Wl,-adhoc_codesign, and
# meson's compile-only probes add -Werror=unused-command-line-argument, so every cc.sizeof()
# fails. Append -Wno-unused-command-line-argument (last flag wins) to neutralise it.
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

# Stage vendored Vala .vapi (if any) onto valac's search path — only needed by the Vala
# targets (libgee/gnome-calculator); a no-op for the pure-C apps. See linux-build/vapi/README.md.
if compgen -G "/work/vapi/*.vapi" >/dev/null 2>&1; then
  VALA_API=$(valac --api-version 2>/dev/null || echo "")
  VAPIDIR="/usr/share/vala${VALA_API:+-$VALA_API}/vapi"
  echo "==> staging vendored .vapi into $VAPIDIR"
  mkdir -p "$VAPIDIR"
  cp -v /work/vapi/*.vapi "$VAPIDIR"/ 2>/dev/null || true
  cp -v /work/vapi/*.deps "$VAPIDIR"/ 2>/dev/null || true
fi

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

# Dependency order: foundation bus+settings -> app libraries -> the GTK4 apps. The GTK4 base
# (gtk4/graphene/gdk-pixbuf) and libxkbcommon are pulled in as make prerequisites (their
# .build_complete markers skip rebuilds). gnome-terminal is omitted (optional GTK3 pass).
# VALA targets (libgee, gnome-calculator) also need valac + the vendored .vapi staged above.
TARGETS="${TARGETS:-\
  dbus-package \
  gsettings-desktop-schemas-package dconf-package \
  json-glib-package libxmlb-package appstream-package libadwaita-package \
  vte-package gtksourceview5-package enchant-package \
  libpsl-package libsoup3-package libgee-package \
  gnome-autoar-package libportal-package iso-codes-package tracker-package gnome-desktop-package \
  gnome-console-package gnome-text-editor-package gnome-font-viewer-package nautilus-package \
  gnome-calculator-package}"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in dbus dconf gsettings-desktop-schemas curl libcurl \
           libjson-glib libxmlb libappstream libadwaita \
           libvte libgtksourceview libenchant \
           libpsl libsoup libgee \
           libgnome-autoar libportal iso-codes libtracker libgnome-desktop \
           gnome-console gnome-text-editor gnome-font-viewer nautilus gnome-calculator; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Shared libgtkintl pass: GNOME app libs/binaries link GTK's bundled proxy-libintl and
# import the same g_libintl_* symbols, so they'd dyld-abort exactly like GTK did. Rather
# than relink per-recipe, fix every collected deb in one idempotent pass — relink onto the
# libgtkintl shim, re-sign, and add Depends: libgtkintl. See recipes/relink-gtkintl.sh.
echo "==> shared libgtkintl relink pass (makes every GNOME deb libintl-immune)"
bash /work/recipes/relink-gtkintl.sh /out

echo "==> done"
