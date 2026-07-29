#!/usr/bin/env bash
# gir-build-session-libs-ondevice.sh — generate the standalone client-lib boot typelibs ON the
# iPad in one pass: UPowerGlib-1.0, Geoclue-2.0, GWeather-4.0, Gdm-1.0 (+ GeocodeGlib-2.0,
# optional). All but GeocodeGlib are gnome-shell BOOT-BLOCKERS: js/misc/dependencies.js
# version-pins each gi:// namespace and the imports are static from the panel boot chain
# (see boot-typelib audit), so every typelib must resolve or the shell throws at module load.
#
# Route: STANDALONE g-ir-scanner against the installed -dev debs (headers + .pc + dylib already
# on device). These are simple GObject/Gio client libs, so a direct header scan is clean; the
# scanner still compiles+runs its dumper against the real dylib, so the typelib matches the
# installed ABI. (Ownership annotations that live in the .c files are lost — acceptable, boot
# only needs the namespaces to resolve; rescan via each lib's meson route later if it matters.)
# If any scan fails, fall back to that lib's MESON route (build its tree on-device with
# introspection ON, like gir-build-accountsservice-ondevice.sh).
#
# Scan params verified against each lib's own generate_gir() block in the EXACT source trees
# gnome-session built (upower 1.90.2, geoclue 2.7.1, geocode-glib 3.26.4, libgweather 4.4.2):
#   UPowerGlib  — headers guard on UP_COMPILATION, umbrella upower.h includes
#                 <libupower-glib/...> so -I both include/ and include/libupower-glib.
#   Geoclue     — api 2.0, library('geoclue-2'), flat headers in include/libgeoclue-2.0.
#   GWeather    — gir includes ONLY Gio-2.0 (4.4.2 does NOT reference GeocodeGlib, so there is
#                 no scan-order constraint and the GeocodeGlib typelib is NOT needed for the
#                 shell); headers guard on GWEATHER_COMPILATION and self-include as
#                 <libgweather/...> so -I include/libgweather-4.0 (the parent).
#   GeocodeGlib — recipes build -Dsoup2=false, so the api version is 2.0 NOT 1.0: namespace
#                 GeocodeGlib-2.0, library geocode-glib-2, pc geocode-glib-2.0, and the gir
#                 --includes Json-1.0 + Soup-3.0 (those girs must be on device; row is gated
#                 and skipped if they aren't — it is not boot-critical, scan for completeness).
#   Gdm         — libgdm CLIENT-only deb built by gnome-session (built rather than patching the
#                 shell). Params CONFIRMED against the shipped deb: gdm.pc,
#                 headers include/gdm/{gdm-client,gdm-sessions,gdm-user-switching,
#                 gdm-client-glue}.h, libgdm.1.dylib (NOUNDEFS) + unversioned libgdm.dylib
#                 symlink in -dev, gir includes GLib-2.0/GObject-2.0/Gio-2.0. Only the CLIENT
#                 glue is installed (no gdm-manager-glue.h), matching upstream — the Gdm API
#                 the shell imports lives in the client glue. Meson-fallback caveat: the recipe
#                 REMOVED the cross generate_gir block and drops the daemon, so a meson-route
#                 rescan must use the client-only top-level meson.build the fixes script
#                 writes (configures only common/ + libgdm/).
#
# PREREQUISITES on device: the -dev debs installed (libupower-glib-dev, libgeoclue-dev,
# libgweather-4-dev, libgeocode-glib-2-dev, libgdm-dev), the GI toolchain
# bootstrapped (gir-ondevice.sh bootstrap: g-ir-scanner/g-ir-compiler, sljit_shim.dylib,
# clang-ios), and GObject-2.0 + Gio-2.0 girs present (gir1.2-glib-2.0).
#
# Usage: DEVICE=root@MaxsiPad.local ./gir-build-session-libs-ondevice.sh
set -euo pipefail
DEVICE="${DEVICE:-root@MaxsiPad.local}"
SSHKEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY" "$DEVICE")

"${SSH[@]}" bash -s <<'EOSH'
set -e
PREFIX=/var/jb/usr
GISPIKE=/var/jb/tmp/gi-spike
export DYLD_LIBRARY_PATH=$PREFIX/lib
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib   # pcre2 flat-namespace shim for giscanner
export CC=$GISPIKE/clang-ios
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0
export XDG_DATA_DIRS=$PREFIX/share
export PATH=$PREFIX/bin:/var/jb/bin:/usr/bin:/bin
mkdir -p /var/jb/tmp/sessionlib-gir && cd /var/jb/tmp/sessionlib-gir
OK=""; FAILED=""; SKIPPED=""

# scan_one NS VER ID-PREFIX SYMBOL-PREFIX LIBRARY PKG HEADER-GLOB [extra scanner args...]
scan_one() {
  local NS=$1 VER=$2 IDP=$3 SYMP=$4 LIB=$5 PKG=$6 HGLOB=$7; shift 7
  echo "=== $NS-$VER (lib=$LIB pkg=$PKG) ==="
  local HDRS; HDRS=$(ls $HGLOB 2>/dev/null || true)
  if [ -z "$HDRS" ]; then
    echo "-- SKIP $NS: no headers at $HGLOB (dev deb not installed yet?)"
    SKIPPED="$SKIPPED $NS"; return 0
  fi
  if g-ir-scanner \
       --namespace="$NS" --nsversion="$VER" \
       --identifier-prefix="$IDP" --symbol-prefix="$SYMP" \
       --library="$LIB" --library-path=$PREFIX/lib \
       --pkg="$PKG" --pkg=gobject-2.0 --pkg=gio-2.0 \
       "$@" \
       --warn-all --quiet --output="$NS-$VER.gir" $HDRS >"$NS.scan.log" 2>&1 \
     && [ -s "$NS-$VER.gir" ] \
     && g-ir-compiler "$NS-$VER.gir" -o "$NS-$VER.typelib" >>"$NS.scan.log" 2>&1; then
    cp "$NS-$VER.gir" $PREFIX/share/gir-1.0/
    cp "$NS-$VER.typelib" $PREFIX/lib/girepository-1.0/
    echo "-- OK $NS-$VER installed"; OK="$OK $NS"
  else
    echo "-- FAIL $NS (log tail):"; tail -12 "$NS.scan.log"; FAILED="$FAILED $NS"
  fi
}

scan_one UPowerGlib 1.0 Up up_ upower-glib upower-glib \
  "$PREFIX/include/libupower-glib/*.h" \
  --include=GObject-2.0 --include=Gio-2.0 --c-include=upower.h \
  --cflags-begin -DUP_COMPILATION -I$PREFIX/include -I$PREFIX/include/libupower-glib --cflags-end

scan_one Geoclue 2.0 GClue gclue geoclue-2 libgeoclue-2.0 \
  "$PREFIX/include/libgeoclue-2.0/*.h" \
  --include=GObject-2.0 --include=Gio-2.0 --c-include=geoclue.h \
  --cflags-begin -I$PREFIX/include/libgeoclue-2.0 --cflags-end

scan_one GWeather 4.0 GWeather gweather gweather-4 gweather4 \
  "$PREFIX/include/libgweather-4.0/libgweather/*.h" \
  --include=Gio-2.0 --c-include=libgweather/gweather.h \
  --cflags-begin -DGWEATHER_COMPILATION -I$PREFIX/include/libgweather-4.0 --cflags-end

scan_one Gdm 1.0 Gdm gdm gdm gdm \
  "$PREFIX/include/gdm/*.h" \
  --include=GLib-2.0 --include=GObject-2.0 --include=Gio-2.0 \
  --cflags-begin -I$PREFIX/include -I$PREFIX/include/gdm --cflags-end

if [ -f $PREFIX/share/gir-1.0/Json-1.0.gir ] && [ -f $PREFIX/share/gir-1.0/Soup-3.0.gir ]; then
  scan_one GeocodeGlib 2.0 Geocode geocode geocode-glib-2 geocode-glib-2.0 \
    "$PREFIX/include/geocode-glib-2.0/geocode-glib/*.h" \
    --include=GObject-2.0 --include=Gio-2.0 --include=Json-1.0 --include=Soup-3.0 \
    --c-include=geocode-glib/geocode-glib.h \
    --cflags-begin -I$PREFIX/include/geocode-glib-2.0 --cflags-end
else
  echo "-- SKIP GeocodeGlib-2.0: Json-1.0.gir / Soup-3.0.gir not in $PREFIX/share/gir-1.0 (not boot-critical)"
  SKIPPED="$SKIPPED GeocodeGlib"
fi

echo "--- gjs import smoke (version-pinned like dependencies.js) ---"
for nsver in UPowerGlib:1.0 Geoclue:2.0 GWeather:4.0 Gdm:1.0 GeocodeGlib:2.0; do
  NS=${nsver%%:*}; V=${nsver##*:}
  case " $OK " in *" $NS "*) ;; *) continue ;; esac
  gjs -c "imports.gi.versions['$NS'] = '$V'; const M = imports.gi['$NS']; print('$NS $V OK');" 2>&1 | tail -1
done

echo "=== summary ==="
echo "ok:     ${OK:-none}"
echo "skipped:${SKIPPED:-none}"
echo "failed: ${FAILED:-none}"
[ -z "$FAILED" ] || exit 3
EOSH
echo "==> done (any FAIL row: fall back to that lib's on-device meson route)"
