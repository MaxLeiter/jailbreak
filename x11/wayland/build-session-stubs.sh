#!/usr/bin/env bash
# Build the Xios GNOME-session D-Bus stub daemons for rootless iOS:
#   xios-login1-stub    org.freedesktop.login1  (session/seat/inhibitor)
#   xios-polkit-stub    org.freedesktop.PolicyKit1.Authority (auto-allow, single-user root)
#   xios-accounts-stub  org.freedesktop.Accounts (one user, so the shell shows a name)
#
# All three are pure GLib/GIO (no Mutter/Wayland/ANGLE). They stand in for the freedesktop
# services gnome-shell/gsd/libaccountsservice talk to but that have no daemon on iOS.
#
# Runs INSIDE the Procursus cross-build image against the same warm volume that built glib
# (e.g. procursus-vol-shell), so gio-2.0 resolves from the sysroot:
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD:/work/wayland:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/wayland/build-session-stubs.sh
set -euo pipefail
umask 022

PROC=/work/Procursus
SRC=/work/wayland
OUT=/out
mkdir -p "$OUT"

SYSROOT="$PROC/build_base/iphoneos-arm64-rootless/1900/var/jb/usr"
[ -d "$SYSROOT/include/glib-2.0" ] || { echo "!! glib not in sysroot: $SYSROOT"; exit 1; }

echo "==> locate cross clang + tools"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cross clang not found"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
LDID="$(command -v ldid || true)"

# Point plain pkg-config at the cross sysroot (the .pc files use prefix=/var/jb/usr, so the
# sysroot root is the build_base tree and PKG_CONFIG_SYSROOT_DIR prepends it to -I/-L).
SYSROOT_ROOT="$PROC/build_base/iphoneos-arm64-rootless/1900"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_ROOT"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
# -liosexec: the Procursus SDK redirects sandbox-sensitive libc calls (getpwuid -> ie_getpwuid)
# into libiosexec, so anything using <pwd.h> must link it (the shared identity helper and the
# accounts stub do).
DEPFLAGS="$(pkg-config --cflags --libs gio-2.0 gio-unix-2.0) -L$SYSROOT/lib -liosexec -Wl,-rpath,/var/jb/usr/lib"
echo "   CC=$CC  SDK=$SDK  pkgconfig-libdir=$PKG_CONFIG_LIBDIR"

# All three stubs share xios-stub-dbus.c (register-object + own-name main loop). The login1
# + accounts stubs additionally share xios-session-identity.c, which resolves the real user
# once. It reads MobileGestalt for the device name via CoreFoundation, so those two stubs also
# link -framework CoreFoundation. polkit does not need the identity.
STUB_DBUS_SRC="$SRC/xios-stub-dbus.c"
IDENTITY_SRC="$SRC/xios-session-identity.c"

# install_name_tool: rewrite the linker's unversioned @rpath/libintl.dylib (a dev-only
# symlink not shipped at runtime) to the versioned libintl.8.dylib that the device actually
# has. Must run BEFORE ldid, since editing load commands invalidates a signature. The cctools
# in this image are triple-prefixed (aarch64-apple-darwin-*), so probe those names first.
TOOLBIN="$(dirname "$(command -v "$CC")")"
INT=""; OTOOL=""
for cand in "$TOOLBIN/aarch64-apple-darwin-install_name_tool" aarch64-apple-darwin-install_name_tool install_name_tool; do
  command -v "$cand" >/dev/null 2>&1 && { INT="$cand"; break; }
done
for cand in "$TOOLBIN/aarch64-apple-darwin-otool" aarch64-apple-darwin-otool otool; do
  command -v "$cand" >/dev/null 2>&1 && { OTOOL="$cand"; break; }
done

fix_libintl () {
  local bin="$1"
  [ -n "$INT" ] && [ -n "$OTOOL" ] || { echo "   (no otool/install_name_tool; skipping libintl fixup)"; return; }
  if "$OTOOL" -L "$bin" 2>/dev/null | grep -q '@rpath/libintl.dylib'; then
    "$INT" -change @rpath/libintl.dylib @rpath/libintl.8.dylib "$bin"
    echo "   libintl: @rpath/libintl.dylib -> @rpath/libintl.8.dylib"
  fi
}

for stub in login1 polkit accounts; do
  s="$SRC/xios-${stub}-stub.c"
  o="$OUT/xios-${stub}-stub"
  [ -f "$s" ] || { echo "   skip $stub (no source)"; continue; }
  echo "==> build xios-${stub}-stub"
  extra_src="$STUB_DBUS_SRC"; extra_ldflags=""
  if [ "$stub" = "login1" ] || [ "$stub" = "accounts" ]; then
    extra_src="$extra_src $IDENTITY_SRC"
    extra_ldflags="-framework CoreFoundation"
  fi
  # shellcheck disable=SC2086
  $CC $CFLAGS "$s" $extra_src $DEPFLAGS $extra_ldflags -o "$o"
  fix_libintl "$o"
  if [ -n "$LDID" ]; then
    "$LDID" -S "$o"           # ad-hoc: plain daemons, no special entitlements
  fi
  file "$o" | sed 's/^/   /'
done

echo "==> done -> $OUT/xios-{login1,polkit,accounts}-stub"
