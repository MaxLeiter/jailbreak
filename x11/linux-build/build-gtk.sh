#!/usr/bin/env bash
# Build the GTK3 desktop stack for rootless iOS via the Procursus/Docker pipeline.
# These recipes don't exist in Procursus, so we drop ours (recipes/*.mk) into the clone
# (the main Makefile globs makefiles/*.mk) and build the dep chain. Dep recipes that DO
# exist in Procursus (glib/cairo/harfbuzz/freetype/fontconfig/libpng/...) cascade.
#
# Run in the container with procursus-vol mounted at /work/Procursus, recipes at
# /work/recipes, ports at /work/ports, and out at /out. Select targets via TARGETS env:
#   docker run -e TARGETS="fribidi-package pango-package" ... /work/build-gtk.sh
set -euo pipefail
cd /work/Procursus

# Host build tools missing from this image:
#  - gtk-doc-tools: cairo & other autotools deps run `gtkdocize` during autoreconf.
#  - libglib2.0-dev-bin/-bin: NATIVE glib codegen tools (glib-mkenums, glib-genmarshal,
#    glib-compile-resources) that the meson GNOME packages (pango/atk/gdk-pixbuf/gtk)
#    must run on the BUILD machine. Without them meson falls back to pango's bundled
#    glib wrap (needs newer meson) and gtk can't compile its GResources.
#  - libgdk-pixbuf2.0-bin: native gdk-pixbuf-pixdata, needed by gtk's GResource
#    `to-pixdata` preprocessing during the build.
if ! command -v gtkdocize >/dev/null 2>&1 || ! command -v glib-mkenums >/dev/null 2>&1 \
   || ! command -v gdk-pixbuf-pixdata >/dev/null 2>&1; then
  echo "==> installing host build tools (gtk-doc-tools + native glib/gdk-pixbuf codegen)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
      gtk-doc-tools libglib2.0-dev-bin libglib2.0-bin libgdk-pixbuf2.0-bin >/dev/null 2>&1 \
    || { echo "ERROR: could not install host build tools"; exit 1; }
fi

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/*.mk makefiles/
# gtk+3.0.mk compiles the libgtkintl proxy-libintl shim from this source ($(BUILD_TOOLS)).
cp -v /work/recipes/gtkintl_shim.c build_tools/

# Procursus' libxcursor.mk extracts to build_work/libXcursor but its build target
# cd's into build_work/libxcursor. Identical on case-insensitive macOS (where Procursus
# runs), but fatal on this case-sensitive Linux build host. Lowercase the extract dir.
sed -i 's/,libXcursor)/,libxcursor)/' makefiles/libxcursor.mk
# libepoxy EGL is handled by our recipes/libepoxy.mk (GTK4 needs <epoxy/egl.h>).

echo "==> installing our control templates into build_info/"
# pango/atk/gdk-pixbuf/gtk have no upstream Procursus build_info templates; ship ours.
if [ -d /work/build_info ] && compgen -G "/work/build_info/*" >/dev/null; then
  cp -v /work/build_info/* build_info/
fi
# The wayland track keeps its build inputs under recipes/build_info/ — not just control
# templates but also wayland-darwin.patch (applied by wayland.mk for Darwin portability),
# input-event-codes shims, etc. Copy them all so the wayland/epoll/xkb recipes resolve.
if [ -d /work/recipes/build_info ] && compgen -G "/work/recipes/build_info/*" >/dev/null 2>&1; then
  cp -v /work/recipes/build_info/* build_info/ 2>/dev/null || true
fi
# gtk4-package signs gtk-4-bin with iosc-gpu-client-ent.xml; SIGN reads from build_misc/entitlements.
mkdir -p build_misc/entitlements
for x in /work/build_info/iosc-*.xml /work/recipes/build_info/iosc-*.xml; do
  [ -f "$x" ] && cp -v "$x" build_misc/entitlements/ || true
done

TARGETS="${TARGETS:-fribidi-package pango-package gdk-pixbuf-package atk-package gtk+3.0-package}"

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

target_requests gtk+3.0 && stage_required_patch_stack gtk+3.0
target_requests gtk4 && stage_required_patch_stack gtk4
target_requests libadwaita && stage_required_patch_stack libadwaita

# The Procursus clang wrapper unconditionally injects -Wl,-adhoc_codesign. meson's
# compile-only probes add -Werror=unused-command-line-argument, so every cc.sizeof()
# fails ("'linker' input unused") and meson aborts (e.g. glib: "no native 16-bit
# integer type"). Route the compiler through a thin wrapper that appends
# -Wno-unused-command-line-argument (last flag wins) to neutralise it. Harmless for
# the autotools deps (they don't pass that -Werror).
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

# epoxy's EGL dispatch (needed by GTK4's X11 backend, which #includes <epoxy/egl.h>
# unconditionally) requires the Khronos EGL/KHR headers. mesa here was built without
# EGL so they're absent — drop in the canonical header-only files. epoxy still dlopens
# libEGL at runtime (graceful if absent; GTK4 then falls back to GLX/cairo).
BBINC=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr/include
if [ ! -f "$BBINC/EGL/egl.h" ]; then
  echo "==> installing Khronos EGL/KHR headers into build_base"
  mkdir -p "$BBINC/EGL" "$BBINC/KHR"
  kbase=https://raw.githubusercontent.com/KhronosGroup/EGL-Registry/main/api
  for h in EGL/egl.h EGL/eglext.h EGL/eglplatform.h KHR/khrplatform.h; do
    curl -fsSL "$kbase/$h" -o "$BBINC/$h" || { echo "ERROR: could not fetch $h"; exit 1; }
  done
fi
# Khronos eglplatform.h defaults EGLNativeDisplayType to `int` on __APPLE__, which
# breaks GTK4's X11 backend (it casts the X Display pointer to it). Force the USE_X11
# branch (Display*), which precedes the __APPLE__ one. Idempotent.
if [ -f "$BBINC/EGL/eglplatform.h" ] && ! grep -q 'X11-on-iOS USE_X11' "$BBINC/EGL/eglplatform.h"; then
  sed -i '1i #define USE_X11 1 /* X11-on-iOS USE_X11 */' "$BBINC/EGL/eglplatform.h"
fi

# GTK4's Wayland backend (gdk/wayland) needs three things absent on the Darwin host:
#   - a host wayland-scanner (protocol codegen) -> libwayland-bin
#   - the Linux input button codes (BTN_LEFT/RIGHT/STYLUS...) gdk references; the real
#     linux/input.h drags in the linux/types.h UAPI chain, but gdk only needs the BTN_*
#     #defines, so ship the lightweight input-event-codes.h + a 1-line input.h shim
#   - <sys/sysmacros.h> (Linux major()/minor()); Darwin has them in <sys/types.h>
# Plus the W0 Wayland libs (built by build-wayland.sh, shipped as debs) staged from /out
# so wayland-client/egl + wayland-protocols + xkbcommon resolve at configure time.
# (gtk4.mk applies a source patch for GTK4's `if os_darwin: wayland_enabled=false` gate.)
echo "==> staging Wayland backend prerequisites for GTK4"
# libexpat1-dev/libffi-dev are HOST deps for wayland.mk's native wayland-scanner (pass 1),
# which links host expat to parse protocol XML. (The cross wayland libs get expat/ffi from
# build_base.) Without them the native scanner's meson aborts: "Dependency expat not found".
apt-get install -y --no-install-recommends libwayland-bin linux-libc-dev libexpat1-dev libffi-dev >/dev/null 2>&1 || true
for d in libwayland0 libwayland-dev wayland-protocols libxkbcommon0 libxkbcommon-dev libepoll-shim0 libepoll-shim-dev; do
  f=$(ls /out/${d}_*.deb 2>/dev/null | head -1) || true
  [ -n "$f" ] && dpkg-deb -x "$f" /work/Procursus/build_base/iphoneos-arm64-rootless/1900 2>/dev/null || true
done
mkdir -p "$BBINC/linux" "$BBINC/sys"
cp /usr/include/linux/input-event-codes.h "$BBINC/linux/" 2>/dev/null || true
echo '#include <linux/input-event-codes.h>' > "$BBINC/linux/input.h"
echo '#include <sys/types.h>' > "$BBINC/sys/sysmacros.h"

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libfribidi libpango libgdk-pixbuf gdk-pixbuf libatk libgtk gtk \
           libglib2.0 libcairo libharfbuzz libfontconfig libfreetype \
           libgraphite2 libicu libepoxy libpixman libpng libjpeg libtiff \
           libxcursor libxinerama libgraphene; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done

# Shared libgtkintl pass — relink any deb importing g_libintl_* onto the shim + add the
# Depends. gtk+3.0.mk/gtk4.mk already do this in-recipe, so here it is an idempotent
# safety net (reports "already shimmed") that also covers any future gtk-adjacent binary.
echo "==> shared libgtkintl relink pass (idempotent safety net)"
bash /work/recipes/relink-gtkintl.sh /out

echo "==> done"
