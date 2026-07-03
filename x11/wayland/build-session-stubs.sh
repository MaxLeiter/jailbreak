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

MEMO_TARGET="${XIOS_MEMO_TARGET:-${MEMO_TARGET:-iphoneos-arm64-rootless}}"
MEMO_CFVER="${XIOS_MEMO_CFVER:-${MEMO_CFVER:-1900}}"
if [ "${XIOS_PREFIX+x}" = x ]; then
  TARGET_PREFIX="$XIOS_PREFIX"
elif [ "$MEMO_TARGET" = "iphoneos-arm64-rootless" ]; then
  TARGET_PREFIX="/var/jb"
else
  TARGET_PREFIX=""
fi
TARGET_SUBPREFIX="${XIOS_SUBPREFIX:-/usr}"
TARGET_MIN_IOS="${XIOS_DEFAULT_MIN_IOS:-16.0}"
TARGET_RUNTIME_TMP="${XIOS_RUNTIME_TMP:-}"
if [ -z "$TARGET_RUNTIME_TMP" ]; then
  if [ -n "$TARGET_PREFIX" ]; then TARGET_RUNTIME_TMP="$TARGET_PREFIX/tmp"; else TARGET_RUNTIME_TMP="/var/tmp"; fi
fi
TARGET_INSTALL_PREFIX="$TARGET_PREFIX$TARGET_SUBPREFIX"
[ -n "$TARGET_PREFIX" ] || TARGET_INSTALL_PREFIX="$TARGET_SUBPREFIX"

SYSROOT_ROOT="$PROC/build_base/$MEMO_TARGET/$MEMO_CFVER"
SYSROOT="$SYSROOT_ROOT$TARGET_INSTALL_PREFIX"
[ -d "$SYSROOT/include/glib-2.0" ] || { echo "!! glib not in sysroot: $SYSROOT"; exit 1; }

echo "==> locate cross clang + tools"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cross clang not found"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
LDID="$(command -v ldid || true)"

# Point plain pkg-config at the cross sysroot. The sysroot root is the
# build_base tree and PKG_CONFIG_SYSROOT_DIR prepends it to -I/-L.
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_ROOT"

CFLAGS=(
  -arch arm64
  -isysroot "$SDK"
  -miphoneos-version-min="$TARGET_MIN_IOS"
  -O2
  -Wall
  -Wextra
  -Wno-unused-parameter
  "-DXIOS_LOGIN1_RUNTIME_DIR=\"$TARGET_RUNTIME_TMP/xios-run\""
)
# -liosexec: the Procursus SDK redirects sandbox-sensitive libc calls (getpwuid -> ie_getpwuid)
# into libiosexec, so anything using <pwd.h> must link it (the shared identity helper and the
# accounts stub do).
DEPFLAGS="$(pkg-config --cflags --libs gio-2.0 gio-unix-2.0) -L$SYSROOT/lib -liosexec -Wl,-rpath,$TARGET_INSTALL_PREFIX/lib"
echo "   target=$MEMO_TARGET/$MEMO_CFVER prefix=${TARGET_PREFIX:-/} runtime=$TARGET_RUNTIME_TMP"
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
  $CC "${CFLAGS[@]}" "$s" $extra_src $DEPFLAGS $extra_ldflags -o "$o"
  fix_libintl "$o"
  if [ -n "$LDID" ]; then
    "$LDID" -S "$o"           # ad-hoc: plain daemons, no special entitlements
  fi
  file "$o" | sed 's/^/   /'
done

# --- xios-bluez-stub (ObjC): org.bluez bridge backed by BluetoothManager.framework ----------
# Unlike the three C stubs this is Objective-C (Foundation/CoreFoundation) and reaches the
# private BluetoothManager.framework at RUNTIME via dlopen()+ObjC-runtime, so it needs no
# link-time framework stub in the cross SDK — only -framework Foundation/CoreFoundation + libobjc.
# It shares xios-stub-dbus.c (own-name loop + register_object) with the C stubs.
BLUEZ_SRC="$SRC/xios-bluez-stub.m"
if [ -f "$BLUEZ_SRC" ]; then
  # os/object.h backport: this cross SDK's os/object.h predates the OS_OBJECT_DECL_SENDABLE_*
  # macros, but its newer xpc/session.h (pulled transitively by importing <Foundation/Foundation.h>)
  # requires them -> "a parameter list without types is only allowed in a function definition".
  # Alias the three sendable forms to their non-sendable equivalents (identical C/ObjC path).
  # Same fix as linux-build/build-wayland-apps.sh. Idempotent (guarded).
  OSOBJ="$SDK/usr/include/os/object.h"
  if [ -f "$OSOBJ" ] && ! grep -q OS_OBJECT_DECL_SENDABLE_CLASS "$OSOBJ"; then
    echo "==> backporting OS_OBJECT_DECL_SENDABLE_* into $OSOBJ"
    cat >> "$OSOBJ" <<'EOF'

/* XIOS: backport OS_OBJECT_DECL_SENDABLE_* (this SDK's os/object.h predates them, but its
 * newer xpc/session.h requires them; alias to the non-sendable forms — identical C/ObjC path). */
#ifndef OS_OBJECT_DECL_SENDABLE_CLASS
#define OS_OBJECT_DECL_SENDABLE_CLASS(name) OS_OBJECT_DECL_CLASS(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SWIFT(name) OS_OBJECT_DECL_SWIFT(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT(name, super) OS_OBJECT_DECL_SUBCLASS_SWIFT(name, super)
#endif
EOF
  fi
  echo "==> build xios-bluez-stub (ObjC)"
  o="$OUT/xios-bluez-stub"
  # shellcheck disable=SC2086
  $CC "${CFLAGS[@]}" -fobjc-arc "$BLUEZ_SRC" "$STUB_DBUS_SRC" $DEPFLAGS \
      -framework Foundation -framework CoreFoundation -lobjc -o "$o"
  fix_libintl "$o"
  # Sign with the com.apple.bluetooth.system entitlement (verified on device: the minimal
  # unlock for bluetoothd's XPC peer-check — without it BluetoothManager returns no data).
  BT_ENT="$SRC/xios-bluez-ent.xml"
  if [ -n "$LDID" ]; then
    if [ -f "$BT_ENT" ]; then "$LDID" -S"$BT_ENT" "$o"; echo "   signed with $BT_ENT";
    else "$LDID" -S "$o"; fi
  fi
  file "$o" | sed 's/^/   /'
else
  echo "   skip bluez (no $BLUEZ_SRC)"
fi

echo "==> done -> $OUT/xios-{login1,polkit,accounts,bluez}-stub"
