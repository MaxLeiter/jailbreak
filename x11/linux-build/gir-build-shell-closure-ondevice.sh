#!/usr/bin/env bash
# gir-build-shell-closure-ondevice.sh — generate the REMAINING gnome-shell boot typelibs ON the
# iPad: the toolkit/framework namespaces dependencies.js hard-imports that no other batch script
# produces and the device does not have. Closure audit (patched dependencies.js diffed against
# the device typelib inventory + the other 4 gir scripts' outputs) found exactly these missing:
#
#   GDesktopEnums-3.0  (gsettings-desktop-schemas 46.1 — header-only gir, no library; the deb
#                       ships NO header either, so this one is MESON-ROUTED from the tarball)
#   Atk-1.0            (atk 2.38.0 — standalone, NOT the merged at-spi2-core copy)
#   Atspi-2.0          (at-spi2-core 2.52.0)
#   Gck-2 + Gcr-4      (gcr 4.2.1; Gck-2 is not in dependencies.js but Gcr-4's gir includes it)
#   Polkit-1.0 + PolkitAgent-1.0  (polkit 124)
#   IBus-1.0           (ibus 1.5.29)
#   GnomeDesktop-4.0 + GnomeBG-4.0  (gnome-desktop 44.1; GnomeRR-4.0 exists but is NOT imported
#                                    by the shell and nothing here includes it — skipped)
#
# RUN THIS FIRST — before BOTH gir-build-mutter-ondevice.sh and gir-build-gnome-shell-ondevice.sh:
#   - the mutter scans --include Atk-1.0 and GDesktopEnums-3.0 (see that script's prereq #3),
#     both produced HERE — they were never on the device (not part of the GTK4 pass);
#   - Shell-14's gir --includes Gcr-4 and PolkitAgent-1.0, also produced here.
# Nothing in this script depends on mutter/shell girs, so closure-first is safe.
#
# Route: standalone g-ir-scanner against the installed -dev debs (see
# gir-build-session-libs-ondevice.sh for the route rationale + annotation tradeoff). All params
# below were mined from each project's own generate_gir() block in the EXACT source trees the
# cross build used (tarballs on procursus-vol-shell:/vol/build_source). Notable per-lib facts:
#   - GDesktopEnums: upstream scans with --header-only against a noinst dummy lib (pure-enum
#     namespace, no dumper). Our deb carries only the schemas + .pc — no gdesktop-enums.h — so
#     there is nothing to scan against: meson-route the 46.1 tarball (pass as $1; boolean
#     -Dintrospection=true; only build dep is glib-mkenums). If a header IS present on device
#     (future -dev deb), the standalone --header-only scan runs instead.
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
# PREREQUISITES on device — exact deb names per gnome-session (9 of the 10 namespaces come
# from 6 -dev debs; two pairs share a deb), all in install-gnome-boot.sh's GIR_DEV_DEBS:
#   libatk1.0-dev_2.38.0 (Atk) · at-spi2-core-dev_2.52.0 (Atspi) · gcr4-dev_4.2.1 (Gck AND Gcr)
#   polkit-dev_124 (Polkit AND PolkitAgent) · libibus-dev_1.5.29 (IBus)
#   libgnome-desktop-dev_44.1 (GnomeDesktop AND GnomeBG)
#   + p11-kit-1-dev: gck-2.pc/gcr-4.pc `Requires: p11-kit-1`, so without its .pc the Gck/Gcr
#     scans die in pkg-config (install-gnome-boot.sh apt-get downloads it best-effort).
# Plus the GI toolchain (gir-ondevice.sh bootstrap) and the GTK4-era girs already in
# /var/jb/usr/share/gir-1.0 (Gdk-4.0, GdkPixbuf-2.0, DBus-1.0, GLib/GObject/Gio).
#
# Usage: DEVICE=root@MaxsiPad.local ./gir-build-shell-closure-ondevice.sh \
#            /path/to/gsettings-desktop-schemas-46.1.tar
# (tar = the GDesktopEnums meson route; optional, but without it GDesktopEnums is skipped
#  unless a header is already on device. Decompress the .tar.xz locally — device has no xz.)
set -euo pipefail
DEVICE="${DEVICE:-root@MaxsiPad.local}"
SSHKEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY" "$DEVICE")
SCP=(scp -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY")

GDS_TAR="${1:-}"
if [ -n "$GDS_TAR" ]; then
  [ -f "$GDS_TAR" ] || { echo "!! no such tar: $GDS_TAR" >&2; exit 2; }
  echo "==> pushing $(basename "$GDS_TAR") for the GDesktopEnums meson route"
  "${SSH[@]}" "mkdir -p /var/jb/tmp/shellclosure-gir"
  "${SCP[@]}" "$GDS_TAR" "$DEVICE:/var/jb/tmp/shellclosure-gir/" >/dev/null
fi

"${SSH[@]}" "GDS_TAR='$(basename "${GDS_TAR:-none}")' bash -s" <<'EOSH'
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
     && case "$NS" in
          Gck)
            # g-ir-scanner sees the GckPassword property accessors but marks the
            # methods non-introspectable, which makes g-ir-compiler reject the
            # getter references. The property metadata is enough for shell boot.
            python3 - "$NS-$VER.gir" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r'\s+getter="get_(?:key|module|token)"', '', text)
open(path, "w").write(text)
PY
            ;;
        esac \
     && g-ir-compiler "$NS-$VER.gir" -o "$NS-$VER.typelib" >>"$NS.scan.log" 2>&1; then
    cp "$NS-$VER.gir" $PREFIX/share/gir-1.0/
    cp "$NS-$VER.typelib" $PREFIX/lib/girepository-1.0/
    echo "-- OK $NS-$VER installed"; OK="$OK $NS"
  else
    echo "-- FAIL $NS (log tail):"; tail -12 "$NS.scan.log"; FAILED="$FAILED $NS"
  fi
}

# GDesktopEnums-3.0: no header on device (the deb ships none) -> meson route from the pushed
# tarball; the standalone --header-only scan only fires if a future deb lands the header.
GDS_HDR=$(ls $PREFIX/include/gsettings-desktop-schemas*/gdesktop-enums.h 2>/dev/null || true)
if [ -n "$GDS_HDR" ]; then
  scan_one GDesktopEnums 3.0 GDesktop gdesktop - gsettings-desktop-schemas \
    "$PREFIX/include/gsettings-desktop-schemas*/gdesktop-enums.h" \
    --include=GObject-2.0
elif [ -f "$GDS_TAR" ]; then
  echo "=== GDesktopEnums-3.0 (meson route: $GDS_TAR) ==="
  BASE="${GDS_TAR%.tar}"
  [ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh
  rm -rf "$BASE" && tar xf "$GDS_TAR"
  if (cd "$BASE" \
      && meson setup _build --prefix=$PREFIX -Dintrospection=true >meson.log 2>&1 \
      && TL=$($GISPIKE/ninja2 -C _build -t targets all 2>/dev/null | sed -n 's/:.*//p' | grep -E '\.typelib$') \
      && $GISPIKE/ninja2 -C _build $TL >>meson.log 2>&1) \
     && GIR=$(find "$BASE/_build" -name 'GDesktopEnums-3.0.gir' | head -1) && [ -n "$GIR" ] \
     && TLB=$(find "$BASE/_build" -name 'GDesktopEnums-3.0.typelib' | head -1) && [ -n "$TLB" ]; then
    cp "$GIR" $PREFIX/share/gir-1.0/ && cp "$TLB" $PREFIX/lib/girepository-1.0/
    HDR=$(find "$BASE" -name 'gdesktop-enums.h' | head -1)
    if [ -n "$HDR" ]; then
      mkdir -p $PREFIX/include/gsettings-desktop-schemas
      cp "$HDR" $PREFIX/include/gsettings-desktop-schemas/
    fi
    echo "-- OK GDesktopEnums-3.0 installed (meson route)"; OK="$OK GDesktopEnums"
  else
    echo "-- FAIL GDesktopEnums (log tail):"; tail -12 "$BASE/meson.log" 2>/dev/null
    FAILED="$FAILED GDesktopEnums"
  fi
else
  echo "-- SKIP GDesktopEnums: no header on device and no tarball passed (GnomeDesktop/GnomeBG scans will also fail — their girs include it)"
  SKIPPED="$SKIPPED GDesktopEnums"
fi

# Gck/Gcr pre-flight: their .pc files Require p11-kit-1; fail fast with a useful hint.
pkg-config --exists p11-kit-1 2>/dev/null \
  || echo "!! WARNING: p11-kit-1.pc missing -> Gck-2/Gcr-4 scans will fail in pkg-config (install p11-kit-1-dev)"

scan_one Atk 1.0 Atk atk atk-1.0 atk \
  "$PREFIX/include/atk-1.0/atk/atk.h" \
  --include=GObject-2.0 --c-include=atk/atk.h \
  --cflags-begin -I$PREFIX/include/atk-1.0 --cflags-end

scan_one Atspi 2.0 Atspi atspi atspi atspi-2 \
  "$PREFIX/include/at-spi-2.0/atspi/atspi.h" \
  --include=DBus-1.0 --include=GLib-2.0 --include=GObject-2.0 --c-include=atspi/atspi.h --pkg=dbus-1 \
  --cflags-begin -I$PREFIX/include/at-spi-2.0 -I$PREFIX/include/at-spi-2.0/atspi -I$PREFIX/include/dbus-1.0 -I$PREFIX/lib/dbus-1.0/include --cflags-end

scan_one Gck 2 Gck gck gck-2 gck-2 \
  "$PREFIX/include/gck-2/gck/gck.h" \
  --include=GObject-2.0 --include=Gio-2.0 --c-include=gck/gck.h --pkg=p11-kit-1 \
  --cflags-begin -DGCK_COMPILATION -DGCK_API_SUBJECT_TO_CHANGE -I$PREFIX/include/gck-2 -I$PREFIX/include/p11-kit-1 --cflags-end

scan_one Gcr 4 Gcr gcr gcr-4 gcr-4 \
  "$PREFIX/include/gcr-4/gcr/gcr.h" \
  --include=GObject-2.0 --include=Gio-2.0 --include=Gck-2 --c-include=gcr/gcr.h --pkg=p11-kit-1 \
  --cflags-begin -DGCR_COMPILATION -DGCR_API_SUBJECT_TO_CHANGE -I$PREFIX/include/gcr-4 -I$PREFIX/include/p11-kit-1 --cflags-end

scan_one Polkit 1.0 Polkit polkit polkit-gobject-1 polkit-gobject-1 \
  "$PREFIX/include/polkit-1/polkit/*.h" \
  --include=Gio-2.0 --c-include=polkit/polkit.h \
  --cflags-begin -D_POLKIT_COMPILATION -I$PREFIX/include/polkit-1 --cflags-end

scan_one PolkitAgent 1.0 PolkitAgent polkit_agent polkit-agent-1 polkit-agent-1 \
  "$PREFIX/include/polkit-1/polkitagent/polkitagent.h" \
  --include=Gio-2.0 --include=Polkit-1.0 --c-include=polkitagent/polkitagent.h \
  --cflags-begin -D_POLKIT_COMPILATION -DPOLKIT_AGENT_I_KNOW_API_IS_SUBJECT_TO_CHANGE -I$PREFIX/include/polkit-1 --cflags-end

scan_one IBus 1.0 IBus ibus ibus-1.0 ibus-1.0 \
  "$PREFIX/include/ibus-1.0/*.h" \
  --include=GLib-2.0 --include=GObject-2.0 --include=Gio-2.0 --c-include=ibus.h \
  --cflags-begin -DIBUS_COMPILATION -I$PREFIX/include/ibus-1.0 --cflags-end

scan_one GnomeDesktop 4.0 Gnome gnome gnome-desktop-4 gnome-desktop-4 \
  "$PREFIX/include/gnome-desktop-4.0/libgnome-desktop/*.h" \
  --include=GObject-2.0 --include=Gio-2.0 --include=GDesktopEnums-3.0 --include=GdkPixbuf-2.0 \
  --cflags-begin -DGNOME_DESKTOP_USE_UNSTABLE_API -I$PREFIX/include/gsettings-desktop-schemas -I$PREFIX/include/gnome-desktop-4.0 -I$PREFIX/include/gnome-desktop-4.0/libgnome-desktop --cflags-end

scan_one GnomeBG 4.0 Gnome gnome gnome-bg-4 gnome-bg-4 \
  "$PREFIX/include/gnome-desktop-4.0/gnome-bg/*.h" \
  --include=GnomeDesktop-4.0 --include=GdkPixbuf-2.0 --include=Gdk-4.0 \
  --cflags-begin -DGNOME_DESKTOP_USE_UNSTABLE_API -I$PREFIX/include/gsettings-desktop-schemas -I$PREFIX/include/gnome-desktop-4.0 -I$PREFIX/include/gnome-desktop-4.0/gnome-bg --cflags-end

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
