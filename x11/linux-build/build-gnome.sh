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
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/vapi:/work/vapi:ro" -v "$PWD/out:/out" \
#     -e TARGETS="gnome-console-package" procursus-xbuild:bookworm-arm64 /work/build-gnome.sh
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

# Host build tools missing from the image. gtk-doc-tools + native glib/gdk-pixbuf codegen are
# the same set build-gtk.sh installs; sassc (libadwaita SCSS), valac (Vala apps), itstool +
# desktop-file-utils (app translations/validation) are ours.
if ! command -v glib-mkenums >/dev/null 2>&1 || ! command -v sassc >/dev/null 2>&1 \
   || ! command -v valac >/dev/null 2>&1 || ! command -v gdk-pixbuf-pixdata >/dev/null 2>&1 \
   || ! command -v appstreamcli >/dev/null 2>&1 || ! command -v unifdef >/dev/null 2>&1 \
   || ! command -v g-ir-compiler >/dev/null 2>&1 \
   || [ ! -f /usr/share/gir-1.0/GObject-2.0.gir ] \
   || [ ! -f /usr/include/ruby-3.1.0/ruby.h ]; then
  echo "==> installing host build tools (glib/gdk-pixbuf codegen + sassc + valac + itstool + appstreamcli)"
  apt-get update >/dev/null 2>&1 || true
  # appstream (host appstreamcli) is the native tool AppStream's own cross-build invokes for
  # news-to-metainfo; the recipe patches out its >= version gate so the bookworm 0.16 cli works.
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      sassc valac itstool desktop-file-utils appstream gtk-update-icon-cache \
      gettext \
      gobject-introspection gir1.2-glib-2.0 libgirepository1.0-dev \
      libgcr-3-dev libgoa-1.0-dev \
      ruby ruby-dev tcl unifdef >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/
# gtk+3.0.mk compiles the libgtkintl proxy-libintl shim from this source ($(BUILD_TOOLS)).
cp -v /work/recipes/gtkintl_shim.c build_tools/ 2>/dev/null || true

TARGETS="${TARGETS:-\
  dbus-package \
  gsettings-desktop-schemas-package dconf-package \
  json-glib-package libxmlb-package appstream-package libadwaita-package \
  vte-package gtksourceview5-package enchant-package \
  libpsl-package libsoup3-package libgee-package \
  gnome-autoar-package libportal-package iso-codes-package tracker-package gnome-desktop-package \
  gnome-console-package gnome-text-editor-package gnome-font-viewer-package nautilus-package \
  gnome-calculator-package baobab-package file-roller-package hitori-package}"

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi
mkdir -p build_misc/entitlements
if compgen -G "/work/build_info/iosc-*.xml" >/dev/null 2>&1; then
  cp -v /work/build_info/iosc-*.xml build_misc/entitlements/
fi

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

if target_requests nghttp2 || target_requests curl || target_requests appstream || target_requests libsoup3; then
  stage_required_patch_stack nghttp2
fi
if target_requests curl || target_requests appstream; then
  stage_required_patch_stack curl
fi
target_requests appstream && stage_required_patch_stack appstream
if target_requests tracker || target_requests nautilus; then
  stage_required_patch_stack tracker
fi
if target_requests gnome-desktop || target_requests nautilus || target_requests gnome-font-viewer; then
  stage_required_patch_stack gnome-desktop
fi
target_requests gnome-text-editor && stage_required_patch_stack gnome-text-editor
target_requests nautilus && stage_required_patch_stack nautilus
target_requests folks && stage_required_patch_stack folks
target_requests gcr3 && stage_required_patch_stack gcr3
target_requests geary && stage_required_patch_stack geary
if [[ " $TARGETS " == *" webkitgtk"* ]]; then
  stage_required_patch_stack webkitgtk
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

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

stage_geary_deps() {
  target_requests geary || return 0

  local build_base=$XIOS_BUILD_BASE
  local pkg deb
  echo "==> staging packaged Geary/WebKitGTK development dependencies"
  for pkg in \
    libgmime-3.0-0 libgmime-3.0-dev \
    libstemmer0d libstemmer-dev \
    libgspell-1-2 libgspell-1-dev \
    libpeas-1.0-0 libpeas-1.0-dev \
    libfolks26 libfolks-dev \
    libgck-1-0 libgcr-3-1 libgcr-3-dev \
    libgoa-1.0-0b libgoa-1.0-dev \
    libjavascriptcoregtk-4.1-0 libjavascriptcoregtk-4.1-dev \
    libwebkit2gtk-4.1-0 libwebkit2gtk-4.1-dev; do
    deb="$(find /out /repo-debs -maxdepth 1 -type f \
      -name "${pkg}_*_iphoneos-arm64.deb" -printf '%f\t%p\n' 2>/dev/null |
      sort -V | tail -1 | cut -f2-)"
    if [ -z "$deb" ]; then
      echo "ERROR: Geary needs $pkg in /out or /repo-debs" >&2
      exit 1
    fi
    echo "    staging $deb"
    dpkg-deb -x "$deb" "$build_base"
  done

  local pc_root="$build_base$XIOS_PREFIX/usr/lib/pkgconfig"
  for pc in gmime-3.0 libstemmer gspell-1 libpeas-1.0 folks gck-1 gcr-3 \
    goa-1.0 javascriptcoregtk-4.1 webkit2gtk-4.1; do
    if [ ! -f "$pc_root/$pc.pc" ]; then
      echo "ERROR: staged Geary dependency is missing $pc.pc" >&2
      exit 1
    fi
  done
}

stage_geary_deps

# Dependency order: foundation bus+settings -> app libraries -> the GTK4 apps. The GTK4 base
# (gtk4/graphene/gdk-pixbuf) and libxkbcommon are pulled in as make prerequisites (their
# .build_complete markers skip rebuilds). gnome-terminal is omitted (optional GTK3 pass).
# VALA targets (libgee, gnome-calculator) also need valac + the vendored .vapi staged above.

APPSTREAM_W=build_work/$XIOS_TRIPLE/appstream
APPSTREAM_S=build_stage/$XIOS_TRIPLE/appstream
APPSTREAM_F="$APPSTREAM_W/.xios_patch_series.sha256"
if target_requests appstream; then
  APPSTREAM_FP="$(sha256sum \
    /work/ports/appstream/patches/series \
    /work/ports/appstream/patches/*.patch | sha256sum | awk '{print $1}')"
  APPSTREAM_OLD_FP="$(cat "$APPSTREAM_F" 2>/dev/null || true)"
  if [ -d "$APPSTREAM_W" ] && [ "$APPSTREAM_FP" != "$APPSTREAM_OLD_FP" ]; then
    echo "==> wiping stale appstream build after patch changes"
    rm -rf "$APPSTREAM_W" "$APPSTREAM_S"
  fi
fi

TRACKER_W=build_work/$XIOS_TRIPLE/tracker
TRACKER_S=build_stage/$XIOS_TRIPLE/tracker
TRACKER_F="$TRACKER_W/.xios_patch_series.sha256"
if target_requests tracker || target_requests nautilus; then
  TRACKER_FP="$(sha256sum \
    /work/ports/tracker/patches/series \
    /work/ports/tracker/patches/*.patch | sha256sum | awk '{print $1}')"
  TRACKER_OLD_FP="$(cat "$TRACKER_F" 2>/dev/null || true)"
  if [ -d "$TRACKER_W" ] && [ "$TRACKER_FP" != "$TRACKER_OLD_FP" ]; then
    echo "==> wiping stale tracker build after patch changes"
    rm -rf "$TRACKER_W" "$TRACKER_S"
  fi
fi

CURL_W=build_work/$XIOS_TRIPLE/curl
CURL_S=build_stage/$XIOS_TRIPLE/curl
CURL_F="$CURL_W/.xios_patch_series.sha256"
if target_requests curl || target_requests appstream; then
  CURL_FP="$(sha256sum \
    /work/ports/curl/patches/series \
    /work/ports/curl/patches/*.patch | sha256sum | awk '{print $1}')"
  CURL_OLD_FP="$(cat "$CURL_F" 2>/dev/null || true)"
  if [ -d "$CURL_W" ] && [ "$CURL_FP" != "$CURL_OLD_FP" ]; then
    echo "==> wiping stale curl build after patch changes"
    rm -rf "$CURL_W" "$CURL_S"
  fi
fi

NGHTTP2_W=build_work/$XIOS_TRIPLE/nghttp2
NGHTTP2_S=build_stage/$XIOS_TRIPLE/nghttp2
NGHTTP2_F="$NGHTTP2_W/.xios_patch_series.sha256"
if target_requests nghttp2 || target_requests curl || target_requests appstream || target_requests libsoup3; then
  NGHTTP2_FP="$(sha256sum \
    /work/ports/nghttp2/patches/series \
    /work/ports/nghttp2/patches/*.patch | sha256sum | awk '{print $1}')"
  NGHTTP2_OLD_FP="$(cat "$NGHTTP2_F" 2>/dev/null || true)"
  if [ -d "$NGHTTP2_W" ] && [ "$NGHTTP2_FP" != "$NGHTTP2_OLD_FP" ]; then
    echo "==> wiping stale nghttp2 build after patch changes"
    rm -rf "$NGHTTP2_W" "$NGHTTP2_S"
  fi
fi

GTE_W=build_work/$XIOS_TRIPLE/gnome-text-editor
GTE_S=build_stage/$XIOS_TRIPLE/gnome-text-editor
GTE_F="$GTE_W/.xios_patch_series.sha256"
if target_requests gnome-text-editor; then
  GTE_FP="$(sha256sum \
    /work/ports/gnome-text-editor/patches/series \
    /work/ports/gnome-text-editor/patches/*.patch | sha256sum | awk '{print $1}')"
  GTE_OLD_FP="$(cat "$GTE_F" 2>/dev/null || true)"
  if [ -d "$GTE_W" ] && [ "$GTE_FP" != "$GTE_OLD_FP" ]; then
    echo "==> wiping stale gnome-text-editor build after patch changes"
    rm -rf "$GTE_W" "$GTE_S"
  fi
fi

NAU_W=build_work/$XIOS_TRIPLE/nautilus
NAU_S=build_stage/$XIOS_TRIPLE/nautilus
NAU_F="$NAU_W/.xios_patch_series.sha256"
if target_requests nautilus; then
  NAU_FP="$(sha256sum \
    /work/ports/nautilus/patches/series \
    /work/ports/nautilus/patches/*.patch | sha256sum | awk '{print $1}')"
  NAU_OLD_FP="$(cat "$NAU_F" 2>/dev/null || true)"
  if [ -d "$NAU_W" ] && [ "$NAU_FP" != "$NAU_OLD_FP" ]; then
    echo "==> wiping stale nautilus build after patch changes"
    rm -rf "$NAU_W" "$NAU_S"
  fi
fi

GNOME_DESKTOP_W=build_work/$XIOS_TRIPLE/gnome-desktop
GNOME_DESKTOP_S=build_stage/$XIOS_TRIPLE/gnome-desktop
GNOME_DESKTOP_F="$GNOME_DESKTOP_W/.xios_patch_series.sha256"
if target_requests gnome-desktop || target_requests nautilus || target_requests gnome-font-viewer; then
  GNOME_DESKTOP_FP="$(sha256sum \
    /work/ports/gnome-desktop/patches/series \
    /work/ports/gnome-desktop/patches/*.patch | sha256sum | awk '{print $1}')"
  GNOME_DESKTOP_OLD_FP="$(cat "$GNOME_DESKTOP_F" 2>/dev/null || true)"
  if [ -d "$GNOME_DESKTOP_W" ] && [ "$GNOME_DESKTOP_FP" != "$GNOME_DESKTOP_OLD_FP" ]; then
    echo "==> wiping stale gnome-desktop build after patch changes"
    rm -rf "$GNOME_DESKTOP_W" "$GNOME_DESKTOP_S"
  fi
fi

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$GTE_W" ] && [ -n "${GTE_FP:-}" ]; then
  printf '%s\n' "$GTE_FP" > "$GTE_F"
fi
if [ -d "$NAU_W" ] && [ -n "${NAU_FP:-}" ]; then
  printf '%s\n' "$NAU_FP" > "$NAU_F"
fi
if [ -d "$GNOME_DESKTOP_W" ] && [ -n "${GNOME_DESKTOP_FP:-}" ]; then
  printf '%s\n' "$GNOME_DESKTOP_FP" > "$GNOME_DESKTOP_F"
fi
if [ -d "$CURL_W" ] && [ -n "${CURL_FP:-}" ]; then
  printf '%s\n' "$CURL_FP" > "$CURL_F"
fi
if [ -d "$NGHTTP2_W" ] && [ -n "${NGHTTP2_FP:-}" ]; then
  printf '%s\n' "$NGHTTP2_FP" > "$NGHTTP2_F"
fi
if [ -d "$APPSTREAM_W" ] && [ -n "${APPSTREAM_FP:-}" ]; then
  printf '%s\n' "$APPSTREAM_FP" > "$APPSTREAM_F"
fi
if [ -d "$TRACKER_W" ] && [ -n "${TRACKER_FP:-}" ]; then
  printf '%s\n' "$TRACKER_FP" > "$TRACKER_F"
fi

# Configure and compile milestones do not produce debs. Avoid sweeping and
# rewriting every pre-existing artifact in /out when TARGETS contains no
# package target (for example webkitgtk-configure or webkitgtk-jsc).
HAS_PACKAGE_TARGET=0
for t in $TARGETS; do
  if [[ "$t" == *-package ]]; then
    HAS_PACKAGE_TARGET=1
    break
  fi
done
if [ "$HAS_PACKAGE_TARGET" -eq 0 ]; then
  echo "==> no package targets requested; skipping deb collection and relink pass"
  echo "==> done"
  exit 0
fi

echo "==> collect debs -> /out"
mkdir -p /out
DIST_ROOT="build_dist/$XIOS_TRIPLE"
OUT_STAGING="$(mktemp -d /tmp/xios-gnome-out.XXXXXX)"
trap 'rm -rf "$OUT_STAGING"' EXIT
for spec in \
  dbus:dbus \
  dconf:dconf \
  gsettings-desktop-schemas:gsettings-desktop-schemas \
  curl:curl \
  libcurl:curl \
  libjson-glib:json-glib \
  libxmlb:libxmlb \
  libappstream:appstream \
  libadwaita:libadwaita \
  libarchive:libarchive \
  libvte:vte \
  libgtksourceview:gtksourceview5 \
  libenchant:enchant \
  libjavascriptcoregtk:webkitgtk \
  libwebkit2gtk:webkitgtk \
  libpsl:libpsl \
  libsoup:libsoup3 \
  libgee:libgee \
  libgnome-autoar:gnome-autoar \
  libportal:libportal \
  iso-codes:iso-codes \
  libtracker:tracker \
  libgnome-desktop:gnome-desktop \
  libstemmer:libstemmer \
  libytnef:libytnef \
  libgmime:gmime \
  libgspell:gspell \
  libpeas:libpeas \
  libfolks:folks \
  libgck:gcr3 \
  libgcr:gcr3 \
  libgoa:gnome-online-accounts \
  gnome-console:gnome-console \
  gnome-text-editor:gnome-text-editor \
  gnome-font-viewer:gnome-font-viewer \
  nautilus:nautilus \
  gnome-calculator:gnome-calculator \
  baobab:baobab \
  file-roller:file-roller \
  geary:geary \
  hitori:hitori; do
  pat="${spec%%:*}"
  req="${spec#*:}"
  target_requests "$req" || continue
  find "$DIST_ROOT" -name "${pat}*_*_$XIOS_DEB_ARCH.deb" -exec cp -v {} "$OUT_STAGING"/ \; 2>/dev/null || true
done

# Shared libgtkintl pass: GNOME app libs/binaries link GTK's bundled proxy-libintl and
# import the same g_libintl_* symbols, so they'd dyld-abort exactly like GTK did. Rather
# than relink per-recipe, fix the freshly collected debs in one idempotent pass,
# then copy only those artifacts into /out. See recipes/relink-gtkintl.sh.
echo "==> shared libgtkintl relink pass for collected debs"
bash /work/recipes/relink-gtkintl.sh "$OUT_STAGING"
cp -v "$OUT_STAGING"/*.deb /out/ 2>/dev/null || true

echo "==> done"
