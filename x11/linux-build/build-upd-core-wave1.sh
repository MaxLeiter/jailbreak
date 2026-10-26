#!/usr/bin/env bash
# Wave 1 of the Procursus takeover (x11/docs/handoff/procursus-dependency-audit-2026-10-25.md):
# security rebuilds of runtime libraries our stack loads from Procursus, plus the libtiff5
# retirement. Container-side; run through the standard wrapper, one target set at a time:
#
#   PROCURSUS_VOL=procursus-vol-wave1 JOBS=4 TARGETS="libtasn1 nettle" \
#     bash x11/linux-build/run-target-script.sh build-upd-core-wave1.sh
#
# procursus-vol-wave1 is a light clone of procursus-vol-gtk (every tree but build_work, whose
# per-package dirs keep only their .build_complete markers), so dependencies stay "previously
# built" while this lane owns its own volume.
#
# TARGETS (order is fixed below, whatever order they are given in):
#   libtasn1 nettle libidn2 p11-kit gnutls   the GnuTLS stack (gnutls must come after the rest)
#   xz flac libsndfile sudo fribidi libarchive libx11
#   libtiff-stage   swap Procursus libtiff 4.2.0 in build_base for our libtiff6 4.7.2 headers +
#                   dylib (from the gimp-stack stage in /out/gimp-stage/libtiff) and clear the
#                   gdk-pixbuf/gtk4 markers; build-gtk.sh then rebuilds those two against it
#   lcms2           liblcms2-utils relink onto libtiff6 (needs libtiff-stage first)
#
# Like build-upd-core-ladybird.sh, every target wipes its build_work/build_stage trees and the
# build_base files it shadows first: the recipes no-op on an existing .build_complete, and a stale
# older dylib left in build_base would be linked instead of the new one.
#
# Debs built by this run land in /out/wave1-20261025/raw.
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus
TARGETS="${TARGETS:-}"
want() { [[ " $TARGETS " == *" $1 "* ]]; }
[ -n "$TARGETS" ] || { echo "ERROR: set TARGETS" >&2; exit 2; }

if [ -r /work/procursus-common-edits.py ]; then
  echo "==> common Procursus toolchain edits"
  python3 /work/procursus-common-edits.py
fi

echo "==> wave 1 recipes and control templates"
for m in libtasn1 nettle libidn2 p11-kit gnutls xz flac libsndfile sudo fribidi libarchive libx11 lcms2; do
  cp -v "/work/recipes/$m.mk" makefiles/
done
for c in libgnutls30 libgnutlsxx30 gnutls-bin p11-kit p11-kit-modules nettle-bin liblcms2-utils \
         sudo xzdec; do
  cp -v "/work/build_info/$c.control" build_info/
done
for p in nettle flac libsndfile p11-kit; do
  want "$p" && bash /work/recipes/stage-port-patches.sh "$p" /work/ports build_patch
done

# p11-kit's recipe runs autoreconf; the image may lack the gettext m4 macros it needs.
if want p11-kit && ! command -v autopoint >/dev/null 2>&1; then
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq --no-install-recommends autopoint gettext >/dev/null 2>&1 || true
fi

# Same PATH-level compiler shim build-gtk.sh installs (see the long note there): it keeps the
# compiler's own name, so configure and make agree and CC_FOR_BUILD assignments (libx11's
# makekeys) are not clobbered the way a CC= command-line override clobbers them.
CCSHIM=/work/Procursus/build_tools/ccshim
mkdir -p "$CCSHIM"
for n in clang clang++; do
  cat > "$CCSHIM/aarch64-apple-darwin-$n" <<EOF
#!/usr/bin/env bash
exec /root/cctools/bin/aarch64-apple-darwin-$n "\$@" -Wno-unused-command-line-argument
EOF
  chmod +x "$CCSHIM/aarch64-apple-darwin-$n"
done
export PATH="$CCSHIM:$PATH"

# The GTK volumes' sysroot libintl is not gettext's. build-gtk.sh points libintl.dylib at
# libgtkintl, and include/libintl.h is GLib's proxy-libintl header, which renames gettext()
# to g_libintl_gettext(). Linked against that, the first p11-kit and libidn2 builds here
# recorded @rpath/libgtkintl.dylib (a package nothing here depends on; libidn2 sits under apt
# via gnutls), and with the symlink fixed, configure found no usable gettext and built
# libidn2 without NLS. These libraries replace Procursus packages, so link them against the
# exact libintl the device has: Procursus libintl8 + libintl-dev 0.22 (debs in
# /out/wave1-20261025/procursus-base, sha256 checked against the 1900 index). The sysroot's
# own files are backed up and put back on exit, so later GTK builds see what they expect.
INTL_BAK="$XIOS_BUILD_WORK/.wave1-intl-backup"
PBASE=/out/wave1-20261025/procursus-base
restore_intl() {
  [ -d "$INTL_BAK" ] || return 0
  echo "==> restoring the sysroot's own libintl files"
  rm -f "$XIOS_USR/include/libintl.h" "$XIOS_USR/lib/libintl.8.dylib" "$XIOS_USR/lib/libintl.dylib" "$XIOS_USR/lib/libintl.a"
  cp -a "$INTL_BAK/." "$XIOS_USR/"
  rm -rf "$INTL_BAK"
}
if ! want libtiff-stage || [ "$(echo $TARGETS)" != libtiff-stage ]; then
  for d in libintl8_0.22 libintl-dev_0.22; do
    [ -f "$PBASE/${d}_$XIOS_DEB_ARCH.deb" ] || { echo "ERROR: missing $PBASE/${d}_$XIOS_DEB_ARCH.deb" >&2; exit 1; }
  done
  [ -d "$INTL_BAK" ] || {
    mkdir -p "$INTL_BAK/include" "$INTL_BAK/lib"
    cp -a "$XIOS_USR/include/libintl.h" "$INTL_BAK/include/" 2>/dev/null || true
    cp -a "$XIOS_USR"/lib/libintl.8.dylib "$XIOS_USR"/lib/libintl.dylib "$XIOS_USR"/lib/libintl.a "$INTL_BAK/lib/" 2>/dev/null || true
  }
  trap restore_intl EXIT
  rm -f "$XIOS_USR/include/libintl.h" "$XIOS_USR/lib/libintl.8.dylib" "$XIOS_USR/lib/libintl.dylib" "$XIOS_USR/lib/libintl.a"
  dpkg-deb -x "$PBASE/libintl8_0.22_$XIOS_DEB_ARCH.deb" "$XIOS_BUILD_BASE"
  dpkg-deb -x "$PBASE/libintl-dev_0.22_$XIOS_DEB_ARCH.deb" "$XIOS_BUILD_BASE"
  rm -rf "$XIOS_USR/share/doc/libintl-dev"
  echo "==> sysroot libintl = Procursus libintl8/libintl-dev 0.22 for this run"
  # Same idea for zlib: the sysroot carries our libz1 (libz.1.dylib), so -lz binds
  # @rpath/libz.1.dylib, a package Procursus does not have. Procursus links the system
  # /usr/lib/libz.1.dylib (the SDK's libz.tbd). Hide ours for the run (header and API are
  # the same) so gnutls & co. keep linking the system zlib, as the packages they replace do.
  for f in libz.dylib libz.1.dylib pkgconfig/zlib.pc; do
    if [ -e "$XIOS_USR/lib/$f" ] || [ -L "$XIOS_USR/lib/$f" ]; then
      mkdir -p "$INTL_BAK/lib/$(dirname "$f")"
      mv "$XIOS_USR/lib/$f" "$INTL_BAK/lib/$f"
    fi
  done
  ls "$XIOS_USR"/lib/libz.*.dylib >/dev/null 2>&1 && echo "   NOTE: other libz dylibs remain: $(ls "$XIOS_USR"/lib/libz.*.dylib)"
fi

# A light-cloned volume recreates every build_work/<pkg> dir, even for packages the source
# volume never finished (no .build_complete). An empty dir makes EXTRACT_TAR skip the
# extract, so that dependency's setup then fails on missing sources (libvorbis, under
# libsndfile). Empty dirs carry nothing; drop them so those dependencies build normally.
find "$XIOS_BUILD_WORK" -mindepth 1 -maxdepth 1 -type d -empty -print -delete | sed 's/^/   dropped empty build_work dir: /'

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 CORE_COUNT=${JOBS:-4}"
BW=$XIOS_BUILD_WORK; BS=$XIOS_BUILD_STAGE; BB=$XIOS_SYSROOT
RAW=/out/wave1-20261025/raw
mkdir -p "$RAW"
declare -A RESULT
START=$(date +%s)

run() { # pkg, build_base globs (relative to the sysroot) it shadows...
  local pkg="$1"; shift
  want "$pkg" || return 0
  echo; echo "########## $pkg ##########"
  rm -rf "$BW/$pkg" "$BS/$pkg"
  local g
  for g in "$@"; do rm -rf $BB/$g; done
  if make "${pkg}-package" $COMMON -j"${JOBS:-4}"; then RESULT[$pkg]=OK; else RESULT[$pkg]=FAILED; fi
}

run libtasn1 'usr/lib/libtasn1.*' 'usr/lib/pkgconfig/libtasn1.pc' 'usr/include/libtasn1.h'
run nettle 'usr/lib/libnettle.*' 'usr/lib/libhogweed.*' 'usr/lib/pkgconfig/nettle.pc' \
  'usr/lib/pkgconfig/hogweed.pc' 'usr/include/nettle'
run libidn2 'usr/lib/libidn2.*' 'usr/lib/pkgconfig/libidn2.pc' 'usr/include/idn2.h'
run p11-kit 'usr/lib/libp11-kit.*' 'usr/lib/p11-kit-proxy.dylib' 'usr/lib/pkcs11' \
  'usr/lib/pkgconfig/p11-kit-1.pc' 'usr/include/p11-kit-1'
run gnutls 'usr/lib/libgnutls.*' 'usr/lib/libgnutlsxx.*' 'usr/lib/pkgconfig/gnutls.pc' 'usr/include/gnutls'
run xz 'usr/lib/liblzma.*' 'usr/lib/pkgconfig/liblzma.pc' 'usr/include/lzma.h' 'usr/include/lzma'
run flac 'usr/lib/libFLAC.*' 'usr/lib/libFLAC++.*' 'usr/lib/pkgconfig/flac.pc' 'usr/lib/pkgconfig/flac++.pc' \
  'usr/include/FLAC' 'usr/include/FLAC++'
run libsndfile 'usr/lib/libsndfile.*' 'usr/lib/pkgconfig/sndfile.pc' 'usr/include/sndfile.h' 'usr/include/sndfile.hh'
run sudo
run fribidi 'usr/lib/libfribidi.*' 'usr/lib/pkgconfig/fribidi.pc' 'usr/include/fribidi'
run libarchive 'usr/lib/libarchive.*' 'usr/lib/pkgconfig/libarchive.pc' 'usr/include/archive.h' \
  'usr/include/archive_entry.h'
# libX11's headers share include/X11 with every other X library; the install overwrites its own.
run libx11 'usr/lib/libX11.*' 'usr/lib/libX11-xcb.*' 'usr/lib/pkgconfig/x11.pc' 'usr/lib/pkgconfig/x11-xcb.pc'

if want libtiff-stage; then
  echo; echo "########## libtiff-stage ##########"
  TS=/out/gimp-stage/libtiff$XIOS_PREFIX$XIOS_SUBPREFIX
  if [ -f "$TS/include/tiffio.h" ] && ls "$TS"/lib/libtiff.6.*.dylib >/dev/null 2>&1; then
    rm -f "$XIOS_USR"/lib/libtiff.* "$XIOS_USR"/lib/libtiffxx.* "$XIOS_USR"/lib/pkgconfig/libtiff-4.pc \
      "$XIOS_USR"/include/tiff.h "$XIOS_USR"/include/tiffconf.h "$XIOS_USR"/include/tiffio.h \
      "$XIOS_USR"/include/tiffio.hxx "$XIOS_USR"/include/tiffvers.h
    cp -a "$TS/include/." "$XIOS_USR/include/"
    cp -a "$TS/lib/pkgconfig/libtiff-4.pc" "$XIOS_USR/lib/pkgconfig/"
    cp -a "$TS"/lib/libtiff.6.*.dylib "$TS/lib/libtiff.6.dylib" "$TS/lib/libtiff.dylib" "$XIOS_USR/lib/"
    # Procursus convention: consumers record @rpath/<soname>, resolved by their /var/jb/usr/lib rpath.
    aarch64-apple-darwin-install_name_tool -id @rpath/libtiff.6.dylib "$XIOS_USR"/lib/libtiff.6.*.dylib
    sed -n 's/^Version: /   staged libtiff-4.pc /p' "$XIOS_USR/lib/pkgconfig/libtiff-4.pc"
    rm -rf "$BW/gdk-pixbuf" "$BS/gdk-pixbuf" "$BW/gtk4" "$BS/gtk4"
    RESULT[libtiff-stage]=OK
  else
    echo "ERROR: no libtiff 4.7 stage at $TS; build it with build-gimp-stack.sh first" >&2
    RESULT[libtiff-stage]=FAILED
  fi
fi

run lcms2 'usr/lib/liblcms2.*' 'usr/lib/pkgconfig/lcms2.pc' 'usr/include/lcms2.h' 'usr/include/lcms2_plugin.h'

echo; echo "==> collect debs built by this run -> $RAW"
find ./build_dist -name "*_$XIOS_DEB_ARCH.deb" -newermt "@$START" -exec cp -v {} "$RAW/" \;
echo "==================== SUMMARY ===================="
for p in libtasn1 nettle libidn2 p11-kit gnutls xz flac libsndfile sudo fribidi libarchive libx11 libtiff-stage lcms2; do
  want $p && printf '  %-14s %s\n' $p "${RESULT[$p]:-SKIPPED}"
done
for p in "${!RESULT[@]}"; do [ "${RESULT[$p]}" = OK ] || exit 1; done
