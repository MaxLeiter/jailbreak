#!/usr/bin/env bash
# gir-build-mutter-ondevice.sh — generate the Mutter introspection typelibs (Meta-14,
# Clutter-14, Cogl-14, CoglPango-14, Mtk-14, Cally-14) ON the iPad, by building mutter 46.0
# natively with -Dintrospection=enabled and letting its own meson build drive g-ir-scanner.
#
# This is the Design-A (gir-build-ondevice.sh) pattern applied to mutter: cross can't run the
# gir dumper (an iOS Mach-O qemu can't exec — gnome-plan Blocker #2), so the scan must happen on
# the device. We let meson generate the (enormous) per-namespace scanner invocations rather than
# hand-writing them — see x11/linux-build/out/mutter-gir-commands.txt for the exact commands an
# off-device introspection *config* emits (proof the config resolves; harvested 2026-06-30).
#
# PREREQUISITES on the device (install via main's device window first):
#   1. The mutter-track runtime+dev debs installed (see install order in the message to main /
#      docs/mutter-on-iosc.md). libmutter-14-dev pulls the -dev stack the scan --includes.
#   2. The on-device GI toolchain bootstrapped: gir-ondevice.sh bootstrap (g-ir-scanner/compiler,
#      sljit_shim.dylib, clang-ios, ninja2) AND the GTK4 introspection stack already on-device
#      (graphene/gtk4/pango/cairo/atk girs) — both true per memory x11-gtk4-typelibs-ondevice.
#   3. Dependency girs the mutter scans --include must be installed:
#        GObject-2.0 Gio-2.0 (gir1.2-glib-2.0), Graphene-1.0, cairo-1.0, Atk-1.0, Pango-1.0,
#        PangoCairo-1.0, GL-1.0 xlib-2.0 xfixes-4.0 (gir1.2-freedesktop), GDesktopEnums-3.0
#        (gsettings-desktop-schemas), Json-1.0 (json-glib).
#   4. Native build tools: meson, ninja, clang, wayland-scanner, glib-mkenums, gdbus-codegen,
#      python3-mako, bison/flex, pkg-config (Procursus apt). wayland-scanner is the one most
#      likely missing — `apt-get install wayland` / the W0 wayland deb provides it.
#
# Usage (from the Mac build host):
#   DEVICE=root@MaxsiPad.local ./gir-build-mutter-ondevice.sh /path/to/mutter-46.0.tar
# (decompress the .tar.xz locally first — the device has no xz.)
set -euo pipefail

DEVICE="${DEVICE:-root@MaxsiPad.local}"
SSHKEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY" "$DEVICE")
SCP=(scp -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY")

TAR="${1:?usage: gir-build-mutter-ondevice.sh <mutter-46.0.tar>}"
BASE="$(basename "$TAR" .tar)"   # mutter-46.0
WORK=/var/jb/tmp/mutter-gir
GISPIKE=/var/jb/tmp/gi-spike     # sljit_shim.dylib, clang-ios, ninja2 (gir-ondevice.sh bootstrap)

echo "==> [$BASE] pushing source to device"
"${SSH[@]}" "mkdir -p $WORK"
"${SCP[@]}" "$TAR" "$DEVICE:$WORK/" >/dev/null

echo "==> [$BASE] native introspection build + install typelibs on-device"
# shellcheck disable=SC2087
"${SSH[@]}" "BASE='$BASE' bash -s" <<'EOSH'
set -e
WORK=/var/jb/tmp/mutter-gir
GISPIKE=/var/jb/tmp/gi-spike
PREFIX=/var/jb/usr

# --- on-device build environment (the gir-ondevice.sh frictions) ---
export DYLD_LIBRARY_PATH=$PREFIX/lib
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib   # pcre2 flat-namespace shim for giscanner
export CC=$GISPIKE/clang-ios                             # force -target arm64-apple-ios
export CXX=$GISPIKE/clang-ios
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0
export XDG_DATA_DIRS=$PREFIX/share
export PATH=$PREFIX/bin:/var/jb/bin:/usr/bin:/bin
export M4=$PREFIX/bin/m4
NINJA=$GISPIKE/ninja2                                    # ninja byte-patched /bin/sh -> /var/sh
[ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh

# iOS ships libz but no zlib.pc (freetype2.pc Requires.private zlib) — drop a minimal one.
if [ ! -f $PREFIX/lib/pkgconfig/zlib.pc ]; then
  printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: zlib\nDescription: zlib\nVersion: 1.2.12\nLibs: -L${libdir} -lz\nCflags:\n' "$PREFIX" > $PREFIX/lib/pkgconfig/zlib.pc
fi

# --- stub headers mutter compiles against (inert on iOS; same as the cross build stages) ---
mkdir -p $PREFIX/include/linux $PREFIX/include/systemd
if [ ! -e $PREFIX/include/linux/dma-buf.h ]; then
  cat > $PREFIX/include/linux/dma-buf.h <<'DMABUF'
/* iOS links-only stub: dmabuf sync/export ioctls inert (IOSurface path in MetaBackendIOS). */
#ifndef _LINUX_DMA_BUF_H_IOS_STUB
#define _LINUX_DMA_BUF_H_IOS_STUB
#include <sys/ioctl.h>
#include <stdint.h>
struct dma_buf_sync { uint64_t flags; };
struct dma_buf_export_sync_file { uint32_t flags; int32_t fd; };
struct dma_buf_import_sync_file { uint32_t flags; int32_t fd; };
#define DMA_BUF_SYNC_READ (1<<0)
#define DMA_BUF_SYNC_WRITE (2<<0)
#define DMA_BUF_SYNC_RW (DMA_BUF_SYNC_READ|DMA_BUF_SYNC_WRITE)
#define DMA_BUF_SYNC_START (0<<2)
#define DMA_BUF_SYNC_END (1<<2)
#define DMA_BUF_BASE 'b'
#define DMA_BUF_IOCTL_SYNC _IOW(DMA_BUF_BASE,0,struct dma_buf_sync)
#define DMA_BUF_IOCTL_EXPORT_SYNC_FILE _IOWR(DMA_BUF_BASE,2,struct dma_buf_export_sync_file)
#define DMA_BUF_IOCTL_IMPORT_SYNC_FILE _IOW(DMA_BUF_BASE,3,struct dma_buf_import_sync_file)
#endif
DMABUF
fi
if [ ! -e $PREFIX/include/systemd/sd-login.h ]; then
  cat > $PREFIX/include/systemd/sd-login.h <<'SDLOGIN'
/* iOS declarations-only stub: usage is HAVE_LIBSYSTEMD-gated (off); header only needs to exist. */
#ifndef _SD_LOGIN_H_IOS_STUB
#define _SD_LOGIN_H_IOS_STUB
#include <sys/types.h>
int sd_pid_get_session(pid_t pid, char **session);
int sd_pid_get_user_unit(pid_t pid, char **unit);
int sd_session_get_type(const char *session, char **type);
int sd_uid_get_sessions(uid_t uid, int require_active, char ***sessions);
#endif
SDLOGIN
fi
# Cogl includes <EGL/eglmesaext.h>; ANGLE's EGL headers lack it. Stage a no-op if absent.
[ -e $PREFIX/include/EGL/eglmesaext.h ] || { mkdir -p $PREFIX/include/EGL; \
  printf '/* iOS stub: MESA EGL ext decls resolved via eglGetProcAddress at runtime. */\n' \
  > $PREFIX/include/EGL/eglmesaext.h; }

cd $WORK
rm -rf "$BASE"
tar xf "$BASE.tar"
cd "$BASE"

# --- iOS portability patches (identical to recipes/mutter.mk's accreting block) ---
sed -i "s/dependency('libeis-1.0', version: libei_req)/dependency('libeis-1.0', version: libei_req, required: false)/" meson.build
sed -i "s/dependency('libei-1.0', version: libei_req)/dependency('libei-1.0', version: libei_req, required: false)/" meson.build
perl -0pi -e 's{return create_native_backend \(context, error\);\n#endif /\* HAVE_NATIVE_BACKEND \*/}{return create_native_backend (context, error);\n#else\n      g_assert_not_reached ();\n      return NULL;\n#endif /* HAVE_NATIVE_BACKEND */}' src/core/meta-context-main.c
perl -0pi -e 's{else if \(sd_pid_get_user_unit \(0, &unit\) < 0\)\n        return META_X11_DISPLAY_POLICY_MANDATORY;\n      else\n        return META_X11_DISPLAY_POLICY_ON_DEMAND;}{else\n        \{\n#ifdef HAVE_LIBSYSTEMD\n          if (sd_pid_get_user_unit (0, &unit) < 0)\n            return META_X11_DISPLAY_POLICY_MANDATORY;\n          else\n            return META_X11_DISPLAY_POLICY_ON_DEMAND;\n#else\n          (void) unit;\n          return META_X11_DISPLAY_POLICY_MANDATORY;\n#endif\n        \}}' src/core/meta-context-main.c

echo "--- meson setup (introspection=enabled, native) ---"
# Native build (no cross file). Same feature flags as the cross recipe but introspection ON.
# c_args -DSOCK_CLOEXEC=0 mirrors the cross build (iOS has no SOCK_CLOEXEC).
meson setup _build --prefix=$PREFIX -Dc_args=-DSOCK_CLOEXEC=0 \
  -Dwayland=true -Dxwayland=false -Dsystemd=false -Dnative_backend=false -Dudev=false \
  -Dopengl=false -Dglx=false -Degl=true -Dgles2=true -Dintrospection=true -Dprofiler=false \
  -Dremote_desktop=false -Dwayland_eglstream=false -Degl_device=false -Dlibgnome_desktop=false \
  -Dsound_player=false -Dstartup_notification=false -Dsm=false -Dlibwacom=false \
  -Dlibdisplay_info=disabled -Dtests=false -Dcogl_tests=false -Dclutter_tests=false \
  -Dcore_tests=false -Dnative_tests=false -Dtty_tests=false -Dkvm_tests=false \
  -Dinstalled_tests=false -Ddocs=false 2>&1 | tail -8

echo "--- ninja: typelib targets only (still builds the libs they link) ---"
TL=$($NINJA -C _build -t targets all 2>/dev/null | sed -n 's/:.*//p' | grep -E '\.typelib$' || true)
echo "typelib targets: $TL"
$NINJA -C _build $TL 2>&1 | tail -20

echo "--- install produced gir + typelib ---"
GIRS=$(find _build -name '*.gir'); TLS=$(find _build -name '*.typelib')
[ -n "$TLS" ] || { echo "!! NO TYPELIB PRODUCED"; exit 3; }
mkdir -p $PREFIX/share/gir-1.0 $PREFIX/lib/girepository-1.0
for g in $GIRS; do cp -v "$g" $PREFIX/share/gir-1.0/; done
for t in $TLS;  do cp -v "$t" $PREFIX/lib/girepository-1.0/; done
echo "--- installed namespaces ---"; for t in $TLS; do basename "$t" .typelib; done
EOSH

echo "==> [$BASE] validate gjs can import Meta-14"
"${SSH[@]}" bash -s <<'EOSH'
export DYLD_LIBRARY_PATH=/var/jb/usr/lib
export GI_TYPELIB_PATH=/var/jb/usr/lib/girepository-1.0
gjs -c 'imports.gi.versions.Meta="14"; const Meta = imports.gi.Meta; const Clutter = imports.gi.Clutter; print("imports.gi.Meta + Clutter OK: " + typeof Meta.Display);' \
  && echo "==> MILESTONE: gjs loads Meta-14" || echo "!! gjs Meta import FAILED"
EOSH
echo "==> done"
