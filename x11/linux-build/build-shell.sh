#!/usr/bin/env bash
# Build the GNOME Shell chain for rootless iOS via the Procursus/Docker pipeline.
# Companion to build-gnome.sh — same preamble, our gnome-shell-track targets:
#   startup-notification -> at-spi2-core (incl. atk-bridge) -> libsecret -> gcr(4) ->
#   polkit (libs-only) -> ibus (lib+daemon) -> pulseaudio (client libs, for gvc) ->
#   gnome-shell (EDS patched out, girs deferred to the on-device pass)
#
# PRECONDITIONS (same Procursus volume, e.g. procursus-vol-gtk or an isolated clone):
#   1. The GTK4/GTK3 + mutter + gnome-desktop stacks are built (.build_complete present):
#      build-gtk.sh, build-gnome.sh, build-mutter.sh have all run here.
#   2. gjs/mozjs/gobject-introspection artifacts are staged in build_base (reconstructed
#      from the out/ debs — they are NOT make prereqs; see recipes/gnome-shell.mk).
#
#   docker run --rm --platform linux/arm64 --cpus=2 \
#     -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/build-shell.sh:/work/build-shell.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-shell.sh
set -euo pipefail
cd /work/Procursus

# Host build tools missing from the image — the build-gnome.sh set (glib codegen etc.);
# sassc is only needed if the dist tarball lacks the pre-built theme css.
if ! command -v glib-mkenums >/dev/null 2>&1 || ! command -v sassc >/dev/null 2>&1 \
   || ! command -v gdk-pixbuf-pixdata >/dev/null 2>&1 \
   || ! pkg-config --exists glib-2.0 2>/dev/null; then
  echo "==> installing host build tools (glib/gdk-pixbuf codegen + sassc + itstool + HOST glib)"
  apt-get update >/dev/null 2>&1 || true
  # libglib2.0-dev is the HOST glib: ibus compiles a compose-table generator with
  # CC_FOR_BUILD that runs on this arm64-Linux builder (GLIB_*_FOR_BUILD = host
  # pkg-config --cflags/--libs glib), so the host glib -dev must be present.
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin \
      pkg-config sassc itstool desktop-file-utils gtk-update-icon-cache >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/

echo "==> installing our control templates into build_info/"
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi

# Same clang wrapper build-gtk.sh/build-gnome.sh use (meson sizeof probes vs the Procursus
# wrapper's -Wl,-adhoc_codesign + -Werror=unused-command-line-argument).
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

# gjs-1.0.pc has `Requires.private: ... mozjs-115 ...`, so pkg-config needs a resolvable
# mozjs-115.pc even to emit gjs's public --cflags (gnome-shell's meson dep lookup). The
# gjs/mozjs reconstruction restored the runtime dylib but no mozjs-115.pc (the mozjs recipe
# never packaged one — and the libmozjs-115-dev deb is dangling symlinks into a vanished
# build tree). gjs 1.78's public headers are a clean C API that never include <jsapi.h>, so
# gnome-shell needs only the dylib (present) + a resolvable .pc. Synthesize a minimal, correct
# one (standalone SpiderMonkey: no NSPR). Idempotent.
SYSROOT=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr
if [ ! -f "$SYSROOT/lib/pkgconfig/mozjs-115.pc" ] && [ -f "$SYSROOT/lib/libmozjs-115.dylib" ]; then
  echo "==> synthesizing missing mozjs-115.pc into the sysroot"
  cat > "$SYSROOT/lib/pkgconfig/mozjs-115.pc" <<'PC'
prefix=/var/jb/usr
includedir=${prefix}/include
libdir=${prefix}/lib

Name: SpiderMonkey 115
Description: The Mozilla library for JavaScript
Version: 115.12.0
Libs: -L${libdir} -lmozjs-115
Cflags: -I${includedir}/mozjs-115
PC
fi

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

# Dependency order per docs: the shell's C-link closure first, gnome-shell last.
TARGETS="${TARGETS:-\
  startup-notification-package \
  at-spi2-core-package \
  libsecret-package \
  gcr-package \
  polkit-package \
  ibus-package \
  pulseaudio-package \
  gnome-shell-package}"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libstartup-notification libatspi libatk-bridge at-spi2-core \
           libsecret libgcr gcr4-dev libpolkit polkit-dev libibus ibus \
           libpulse gnome-shell; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Shared libgtkintl pass: anything here that linked GTK's bundled proxy-libintl gets
# relinked onto the libgtkintl shim + Depends: libgtkintl (idempotent; skips clean debs).
echo "==> shared libgtkintl relink pass"
bash /work/recipes/relink-gtkintl.sh /out

echo "==> done"
