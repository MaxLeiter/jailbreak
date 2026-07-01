#!/usr/bin/env bash
# gir-build-shell-closure-ondevice.sh — generate the REMAINING gnome-shell boot typelibs ON the
# iPad: the toolkit/framework namespaces dependencies.js hard-imports that no other batch script
# produces and the device does not have. Closure audit (patched dependencies.js diffed against
# the device typelib inventory + the other 4 gir scripts' outputs) found exactly these missing:
#
#   GDesktopEnums-3.0  (gsettings-desktop-schemas 46.1 — header-only gir, no library)
#   Atk-1.0            (atk 2.38.0 — standalone, NOT the merged at-spi2-core copy)
#   Atspi-2.0          (at-spi2-core 2.52.0)
#   Gck-2 + Gcr-4      (gcr 4.2.1; Gck-2 is not in dependencies.js but Gcr-4's gir includes it)
#   Polkit-1.0 + PolkitAgent-1.0  (polkit 124)
#   IBus-1.0           (ibus 1.5.29)
#   GnomeDesktop-4.0 + GnomeBG-4.0  (gnome-desktop 44.1; GnomeRR-4.0 exists but is NOT imported
#                                    by the shell and nothing here includes it — skipped)
#
# RUN THIS BEFORE gir-build-gnome-shell-ondevice.sh: Shell-14's own gir --includes Gcr-4 and
# PolkitAgent-1.0, so those .girs must exist at Shell scan time, not just at shell runtime.
#
# Route: standalone g-ir-scanner against the installed -dev debs (see
# gir-build-session-libs-ondevice.sh for the route rationale + annotation tradeoff). All params
# below were mined from each project's own generate_gir() block in the EXACT source trees the
# cross build used (tarballs on procursus-vol-shell:/vol/build_source). Notable per-lib facts:
#   - GDesktopEnums: upstream scans with --header-only against a noinst dummy lib; standalone we
#     just pass --header-only and no --library at all (pure-enum namespace, no dumper needed).
#   - Gck/Gcr headers hard-#error without GCK_/GCR_API_SUBJECT_TO_CHANGE (+ *_COMPILATION).
#   - polkit compiles everything with -D_POLKIT_COMPILATION; PolkitAgent's gir includes Polkit.
#   - ibus is autotools: params from src/Makefile.am (IBus_1_0_gir_*), -DIBUS_COMPILATION.
#   - gnome-desktop 4 headers need -DGNOME_DESKTOP_USE_UNSTABLE_API; GnomeBG's gir includes
#     GnomeDesktop-4.0 + Gdk-4.0 (Gdk/GdkPixbuf girs are already on device from the GTK4 pass).
#   - atk 2.38's single-include #error is gated on ATK_DISABLE_SINGLE_INCLUDES: no define needed.
#   - atspi headers self-include flat, so -I both at-spi-2.0/ and at-spi-2.0/atspi/.
#
# Scan ORDER within this script is dependency order: GDesktopEnums -> Atk -> Atspi -> Gck ->
# Gcr -> Polkit -> PolkitAgent -> IBus -> GnomeDesktop -> GnomeBG.
#
# PREREQUISITES on device: -dev debs for atk, at-spi2-core, gcr-4 (+p11-kit dev if gck-2.pc
# Requires it), polkit (gobject+agent), libibus-1.0, gnome-desktop-4 (incl. gnome-bg headers),
# gsettings-desktop-schemas (gdesktop-enums.h); the GI toolchain (gir-ondevice.sh bootstrap);
# the GTK4-era girs already in /var/jb/usr/share/gir-1.0 (Gdk-4.0, GdkPixbuf-2.0, DBus-1.0,
# GLib/GObject/Gio).
#
# Usage: DEVICE=root@MaxsiPad.local ./gir-build-shell-closure-ondevice.sh
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
mkdir -p /var/jb/tmp/shellclosure-gir && cd /var/jb/tmp/shellclosure-gir
OK=""; FAILED=""; SKIPPED=""

# scan_one NS VER ID-PREFIX SYMBOL-PREFIX LIBRARY|- PKG HEADER-GLOB [extra scanner args...]
# LIBRARY "-" = --header-only (no dumper, no library link).
scan_one() {
  local NS=$1 VER=$2 IDP=$3 SYMP=$4 LIB=$5 PKG=$6 HGLOB=$7; shift 7
  echo "=== $NS-$VER (lib=$LIB pkg=$PKG) ==="
  local HDRS; HDRS=$(ls $HGLOB 2>/dev/null || true)
  if [ -z "$HDRS" ]; then
    echo "-- SKIP $NS: no headers at $HGLOB (dev deb not installed yet?)"
    SKIPPED="$SKIPPED $NS"; return 0
  fi
  local LIBARGS
  if [ "$LIB" = "-" ]; then LIBARGS="--header-only"
  else LIBARGS="--library=$LIB --library-path=$PREFIX/lib"; fi
  if g-ir-scanner \
       --namespace="$NS" --nsversion="$VER" \
       --identifier-prefix="$IDP" --symbol-prefix="$SYMP" \
       $LIBARGS \
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

scan_one GDesktopEnums 3.0 GDesktop gdesktop - gsettings-desktop-schemas \
  "$PREFIX/include/gsettings-desktop-schemas*/gdesktop-enums.h" \
  --include=GObject-2.0

scan_one Atk 1.0 Atk atk atk-1.0 atk \
  "$PREFIX/include/atk-1.0/atk/*.h" \
  --include=GObject-2.0 --c-include=atk/atk.h \
  --cflags-begin -I$PREFIX/include/atk-1.0 --cflags-end

scan_one Atspi 2.0 Atspi atspi atspi atspi-2 \
  "$PREFIX/include/at-spi-2.0/atspi/*.h" \
  --include=DBus-1.0 --include=GLib-2.0 --include=GObject-2.0 --c-include=atspi/atspi.h \
  --cflags-begin -I$PREFIX/include/at-spi-2.0 -I$PREFIX/include/at-spi-2.0/atspi --cflags-end

scan_one Gck 2 Gck gck gck-2 gck-2 \
  "$PREFIX/include/gck-2/gck/*.h" \
  --include=GObject-2.0 --include=Gio-2.0 --c-include=gck/gck.h \
  --cflags-begin -DGCK_COMPILATION -DGCK_API_SUBJECT_TO_CHANGE -I$PREFIX/include/gck-2 --cflags-end

scan_one Gcr 4 Gcr gcr gcr-4 gcr-4 \
  "$PREFIX/include/gcr-4/gcr/*.h" \
  --include=GObject-2.0 --include=Gio-2.0 --include=Gck-2 --c-include=gcr/gcr.h \
  --cflags-begin -DGCR_COMPILATION -DGCR_API_SUBJECT_TO_CHANGE -I$PREFIX/include/gcr-4 --cflags-end

scan_one Polkit 1.0 Polkit polkit polkit-gobject-1 polkit-gobject-1 \
  "$PREFIX/include/polkit-1/polkit/*.h" \
  --include=Gio-2.0 --c-include=polkit/polkit.h \
  --cflags-begin -D_POLKIT_COMPILATION -I$PREFIX/include/polkit-1 --cflags-end

scan_one PolkitAgent 1.0 PolkitAgent polkit_agent polkit-agent-1 polkit-agent-1 \
  "$PREFIX/include/polkit-1/polkitagent/*.h" \
  --include=Gio-2.0 --include=Polkit-1.0 --c-include=polkitagent/polkitagent.h \
  --cflags-begin -D_POLKIT_COMPILATION -I$PREFIX/include/polkit-1 --cflags-end

scan_one IBus 1.0 IBus ibus ibus-1.0 ibus-1.0 \
  "$PREFIX/include/ibus-1.0/*.h" \
  --include=GLib-2.0 --include=GObject-2.0 --include=Gio-2.0 --c-include=ibus.h \
  --cflags-begin -DIBUS_COMPILATION -I$PREFIX/include/ibus-1.0 --cflags-end

scan_one GnomeDesktop 4.0 Gnome gnome gnome-desktop-4 gnome-desktop-4 \
  "$PREFIX/include/gnome-desktop-4.0/libgnome-desktop/*.h" \
  --include=GObject-2.0 --include=Gio-2.0 --include=GDesktopEnums-3.0 --include=GdkPixbuf-2.0 \
  --cflags-begin -DGNOME_DESKTOP_USE_UNSTABLE_API -I$PREFIX/include/gnome-desktop-4.0 -I$PREFIX/include/gnome-desktop-4.0/libgnome-desktop --cflags-end

scan_one GnomeBG 4.0 Gnome gnome gnome-bg-4 gnome-bg-4 \
  "$PREFIX/include/gnome-desktop-4.0/gnome-bg/*.h" \
  --include=GnomeDesktop-4.0 --include=GdkPixbuf-2.0 --include=Gdk-4.0 \
  --cflags-begin -DGNOME_DESKTOP_USE_UNSTABLE_API -I$PREFIX/include/gnome-desktop-4.0 -I$PREFIX/include/gnome-desktop-4.0/gnome-bg --cflags-end

echo "--- gjs import smoke (version-pinned like dependencies.js; note Gck=2, Gcr=4) ---"
for nsver in GDesktopEnums:3.0 Atk:1.0 Atspi:2.0 Gck:2 Gcr:4 Polkit:1.0 PolkitAgent:1.0 IBus:1.0 GnomeDesktop:4.0 GnomeBG:4.0; do
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
echo "==> done (any FAIL row: meson-route fallback — tarballs on procursus-vol-shell:/vol/build_source)"
