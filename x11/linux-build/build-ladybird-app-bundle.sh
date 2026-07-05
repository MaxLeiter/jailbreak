#!/usr/bin/env bash
# build-ladybird-app-bundle.sh — Phase C: assemble a SELF-CONTAINED Ladybird.app + deb.
# Runs INSIDE the container (needs cctools otool/install_name_tool + ldid + the build_base
# leaf dylibs the engine linked against). Consumes /out/app-stage (6 binaries + share/Lagom
# from build-ladybird-app-engine.sh) and the frontend's Info.plist/entitlements/icon mounted
# at /work/ladybird-app.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-app-bundle.sh:/work/build-ladybird-app-bundle.sh:ro" \
#     -v "$PWD/../packages/ladybird-app:/work/ladybird-app:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:skia -c /work/build-ladybird-app-bundle.sh
#
# Self-contained rationale: every leaf dylib (icu78, harfbuzz10, freetype, fontconfig, curl,
# openssl3, sqlite3, xml2, png/jpeg/webp, fmt, simd*, mimalloc[LSE-free], tommath, iosexec, ...)
# is copied INTO Ladybird.app/lib and every LC_LOAD_DYLIB is rewritten to @executable_path/lib/<base>
# (all 6 executables sit at the bundle root, so @executable_path == bundle root for each). The app
# then depends on NOTHING under /var/jb/usr/lib and cannot collide with the GNOME desktop stack's
# harfbuzz-10.2 / freetype / fontconfig.
set -uo pipefail
PROC=/work/Procursus
BB=$PROC/build_base/iphoneos-arm64-rootless/1900/var/jb
LIBDIR=$BB/usr/lib
OTOOL=/root/cctools/bin/aarch64-apple-darwin-otool
INT=/root/cctools/bin/aarch64-apple-darwin-install_name_tool
LDID=/root/cctools/bin/ldid
STAGE=/out/app-stage
VER="${LADYBIRD_APP_VERSION:-0.1.0+ios1}"
APPROOT=/tmp/lbapp
APP=$APPROOT/var/jb/Applications/Ladybird.app
BINS="Ladybird WebContent RequestServer ImageDecoder WebWorker Compositor"
step() { echo; echo "########## $* ##########"; }

[ -d "$STAGE" ] || { echo "!! $STAGE missing — run build-ladybird-app-engine.sh first"; exit 2; }

step "assemble bundle skeleton"
rm -rf "$APPROOT"; mkdir -p "$APP/lib" "$APP/share"
for b in $BINS; do
  [ -f "$STAGE/$b" ] || { echo "!! missing binary $b"; MISSING=1; continue; }
  cp "$STAGE/$b" "$APP/$b"; chmod +x "$APP/$b"
done
cp -a "$STAGE/share/Lagom" "$APP/share/Lagom" 2>/dev/null || echo "(no share/Lagom in stage)"
cp /work/ladybird-app/Resources/Info.plist "$APP/Info.plist"
[ -f /work/ladybird-app/Resources/AppIcon.png ] && cp /work/ladybird-app/Resources/AppIcon.png "$APP/AppIcon.png"

# ---- bundle real text fonts (BUG 1 fix) ------------------------------------------------------
# The sandboxed FrontBoard app cannot read /System/Library/Fonts, so the engine's
# PathFontProvider finds nothing and Web::Platform::FontPlugin's VERIFY(m_default_fixed_width_font)
# trips (WebContent crash). Ship the Liberation family (metric-compatible with Arial/Times New
# Roman/Courier New; the family names "Liberation Sans/Serif/Mono" are ALL in the engine's
# sans_serif/serif/monospace fallback lists -> no engine patch needed). The UI process copies
# these into $XDG_DATA_HOME/fonts before spawning helpers.
step "bundle text fonts (Liberation)"
FONTS_DIR="$APP/share/Lagom/fonts"
mkdir -p "$FONTS_DIR"
LIB_CACHE=/work/Procursus/.font-cache
mkdir -p "$LIB_CACHE"
LIB_TARBALL="$LIB_CACHE/liberation-fonts-ttf-2.1.5.tar.gz"
LIB_URL="https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz"
if [ ! -s "$LIB_TARBALL" ]; then
  echo "  downloading Liberation fonts ..."
  curl -sL --connect-timeout 20 --retry 3 -o "$LIB_TARBALL" "$LIB_URL" || echo "  [warn] Liberation download failed"
fi
if [ -s "$LIB_TARBALL" ]; then
  TMPF=$(mktemp -d); tar xzf "$LIB_TARBALL" -C "$TMPF" 2>/dev/null
  # Regular + Bold + Italic + BoldItalic for Sans/Serif/Mono (family names match fallback lists).
  find "$TMPF" -name 'Liberation*.ttf' -exec cp -f {} "$FONTS_DIR/" \;
  rm -rf "$TMPF"
fi
echo "  bundled fonts:"; ls "$FONTS_DIR" | sed 's/^/    /'
# NB: iOS builds do NOT compile fontconfig (USE_FONTCONFIG is gated `if (NOT APPLE)`), so the
# engine finds fonts via the XDG font_directories() branch. The app copies these bundled fonts
# into $XDG_DATA_HOME/fonts at boot (see IOSApplication.mm main()); no fontconfig conf is used.

# ---- discover the recursive leaf-dylib closure -----------------------------------------------
step "discover dylib closure (otool -L recursion)"
is_system() { case "$1" in /usr/lib/*|/System/*) return 0;; *) return 1;; esac; }
resolve() { # basename -> real file in build_base libdir
  local base="$1"
  if [ -f "$LIBDIR/$base" ]; then echo "$LIBDIR/$base"; return 0; fi
  find "$LIBDIR" -maxdepth 2 -name "$base" 2>/dev/null | head -1
}
declare -A SEEN
WORK=()
enqueue_deps() { # $1 = mach-o file to scan
  local f="$1" line dep base
  "$OTOOL" -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
    [ -z "$dep" ] && continue
    is_system "$dep" && continue
    base=$(basename "$dep")
    echo "$base"
  done
}
# BFS
for b in $BINS; do [ -f "$APP/$b" ] && for d in $(enqueue_deps "$APP/$b"); do WORK+=("$d"); done; done
while [ ${#WORK[@]} -gt 0 ]; do
  base="${WORK[0]}"; WORK=("${WORK[@]:1}")
  [ -n "${SEEN[$base]:-}" ] && continue
  src=$(resolve "$base")
  if [ -z "$src" ]; then echo "  [warn] unresolved dep: $base (assuming system/absent)"; SEEN[$base]=MISSING; continue; fi
  SEEN[$base]="$src"
  cp -f "$src" "$APP/lib/$base"; chmod +w "$APP/lib/$base"
  for d in $(enqueue_deps "$src"); do WORK+=("$d"); done
done
echo "bundled $(ls "$APP/lib" | wc -l) dylibs:"; ls "$APP/lib" | sort | sed 's/^/  /'

# ---- LSE sanity on mimalloc (must be 0 for A10) ---------------------------------------------
MM=$(ls "$APP/lib"/libmimalloc*.dylib 2>/dev/null | head -1)
if [ -n "$MM" ]; then
  LSE=$("$OTOOL" -tv "$MM" 2>/dev/null | grep -Eiwc 'casal|casa|casl|cas|ldadd|swp|stadd' || true)
  echo "mimalloc LSE mnemonics = ${LSE:-?} (want 0)  [$MM]"
fi

# ---- rewrite install names -> @executable_path/lib/<base> ------------------------------------
step "rewrite install_names (self-contained @executable_path/lib)"
rewrite() { # $1 = mach-o
  local f="$1" dep base
  "$OTOOL" -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
    [ -z "$dep" ] && continue
    is_system "$dep" && continue
    base=$(basename "$dep")
    [ -f "$APP/lib/$base" ] || continue
    "$INT" -change "$dep" "@executable_path/lib/$base" "$f" 2>/dev/null || true
  done
}
for b in $BINS; do
  [ -f "$APP/$b" ] || continue
  rewrite "$APP/$b"
  # Primary rpath: the bundled leaf dylibs (searched FIRST, so the app's harfbuzz/freetype/
  # fontconfig/etc win and never collide with the desktop stack).
  "$INT" -add_rpath "@executable_path/lib" "$APP/$b" 2>/dev/null || true
  # Fallback rpath: the base-jailbreak libs that ship only as .tbd link stubs in build_base and
  # therefore can't be bundled (libiosexec.1.dylib — the exec helper, a Depends: libiosexec1 lib
  # present on every jailbroken device). Added SECOND so it never shadows a bundled lib.
  "$INT" -add_rpath "/var/jb/usr/lib" "$APP/$b" 2>/dev/null || true
done
for d in "$APP"/lib/*.dylib; do
  base=$(basename "$d")
  "$INT" -id "@executable_path/lib/$base" "$d" 2>/dev/null || true
  rewrite "$d"
done

# ---- sign (ldid, DER entitlements) ----------------------------------------------------------
step "sign (ldid, DER ents)"
APP_ENT=/work/ladybird-app/entitlements/ladybird-app.entitlements
HELPER_ENT=/work/ladybird-app/entitlements/ladybird-helper.entitlements
for d in "$APP"/lib/*.dylib; do "$LDID" -S "$d" 2>/dev/null || true; done
"$LDID" -S"$APP_ENT" "$APP/Ladybird"
for h in WebContent RequestServer ImageDecoder WebWorker Compositor; do
  [ -f "$APP/$h" ] && "$LDID" -S"$HELPER_ENT" "$APP/$h"
done
echo "signed. verifying entitlement markers on Ladybird:"; "$LDID" -e "$APP/Ladybird" 2>/dev/null | grep -o 'can-allow-non-platform' | head -1 || echo "(none?)"

# ---- deb --------------------------------------------------------------------------------------
step "package deb"
mkdir -p "$APPROOT/DEBIAN"
INSTALLED_KB=$(du -sk "$APPROOT/var/jb" | cut -f1)
sed -e "s/@VER@/$VER/" /work/ladybird-app/DEBIAN/control > "$APPROOT/DEBIAN/control"
# Self-contained: every leaf is bundled EXCEPT libiosexec (ships as .tbd link-stub only; resolved
# at runtime from /var/jb/usr/lib via the fallback rpath). So the only real external dep is
# libiosexec1; drop libicu78 et al (bundled) so the deb installs cleanly without pulling the
# system icu/font/codec stack.
sed -i 's/^Depends:.*/Depends: libiosexec1/' "$APPROOT/DEBIAN/control"
grep -q '^Installed-Size' "$APPROOT/DEBIAN/control" || echo "Installed-Size: $INSTALLED_KB" >> "$APPROOT/DEBIAN/control"
cp /work/ladybird-app/DEBIAN/postinst "$APPROOT/DEBIAN/postinst"; chmod 0755 "$APPROOT/DEBIAN/postinst"
DEB=/out/ladybird-app_${VER}_iphoneos-arm64.deb
dpkg-deb -Zxz -b "$APPROOT" "$DEB" && echo "== packaged $DEB ==" && ls -la "$DEB"
echo "app tree:"; find "$APP" -maxdepth 1 | sed 's/^/  /'
echo; echo "########## BUNDLE done (self-contained) ##########"
