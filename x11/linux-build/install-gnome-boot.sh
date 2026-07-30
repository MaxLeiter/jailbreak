#!/bin/sh
# install-gnome-boot.sh — install the gnome-shell boot set on iPad via dpkg -i in dependency
# order, not apt: apt-get -f install's dep-resolver can REMOVE libmutter on this device.
# Run on-device: scp x11/linux-build/out/*.deb to the box first, then sh install-gnome-boot.sh.
set -e
DEBS="\
  hicolor-icon-theme_0.17_$XIOS_DEB_ARCH.deb \
  adwaita-icon-theme_46.0_$XIOS_DEB_ARCH.deb \
  angle_2.1.0+git20260630.a32d31d_$XIOS_DEB_ARCH.deb \
  dbus_1.14.10_$XIOS_DEB_ARCH.deb \
  libglib2.0-0_2.78.0_$XIOS_DEB_ARCH.deb \
  dconf_0.40.0_$XIOS_DEB_ARCH.deb \
  libgirepository-1.0-1_1.78.0_$XIOS_DEB_ARCH.deb \
  gir1.2-freedesktop_1.78.0_$XIOS_DEB_ARCH.deb \
  gir1.2-glib-2.0_1.78.0_$XIOS_DEB_ARCH.deb \
  libgtkintl_1.0_$XIOS_DEB_ARCH.deb \
  libmozjs-115-0_115.12.0_$XIOS_DEB_ARCH.deb \
  libfontconfig1_2.14.0_$XIOS_DEB_ARCH.deb \
  libpixman-1-0_0.42.2_$XIOS_DEB_ARCH.deb \
  libxcb-render0_1.14_$XIOS_DEB_ARCH.deb \
  libcairo2_1.16.0-3_$XIOS_DEB_ARCH.deb \
  libcairo-gobject2_1.16.0-3_$XIOS_DEB_ARCH.deb \
  libgjs0_1.78.0_$XIOS_DEB_ARCH.deb \
  gjs_1.78.0_$XIOS_DEB_ARCH.deb \
  libglib2.0-bin_2.78.0_$XIOS_DEB_ARCH.deb \
  libgdk-pixbuf-2.0-0_2.42.12_$XIOS_DEB_ARCH.deb \
  libgraphite2-3_1.3.14_$XIOS_DEB_ARCH.deb \
  libharfbuzz0b_2.8.1_$XIOS_DEB_ARCH.deb \
  libfribidi0_1.0.13_$XIOS_DEB_ARCH.deb \
  libpango-1.0-0_1.50.14_$XIOS_DEB_ARCH.deb \
  libatk1.0-0_2.38.0_$XIOS_DEB_ARCH.deb \
  libepoxy0_1.5.7_$XIOS_DEB_ARCH.deb \
  libxfixes3_6.0.1_$XIOS_DEB_ARCH.deb \
  libxcursor1_1.2.0_$XIOS_DEB_ARCH.deb \
  libxinerama1_1.1.4_$XIOS_DEB_ARCH.deb \
  libgtk-3-0_3.24.38_$XIOS_DEB_ARCH.deb \
  libgraphene-1.0-0_1.10.8_$XIOS_DEB_ARCH.deb \
  libxml2_2.9.12_$XIOS_DEB_ARCH.deb \
  libxkbcommon0_1.7.0_$XIOS_DEB_ARCH.deb \
  libepoll-shim0_0.0.20240608_$XIOS_DEB_ARCH.deb \
  libwayland0_1.23.1_$XIOS_DEB_ARCH.deb \
  libcairo-script-interpreter2_1.16.0-3_$XIOS_DEB_ARCH.deb \
  libgtk-4-1_4.14.5_$XIOS_DEB_ARCH.deb \
  gsettings-desktop-schemas_46.1_$XIOS_DEB_ARCH.deb \
  iso-codes_4.15.0_$XIOS_DEB_ARCH.deb \
  libgnome-desktop-4-2_44.1_$XIOS_DEB_ARCH.deb \
  libjson-glib-1.0-0_1.8.0_$XIOS_DEB_ARCH.deb \
  gnome-session_46.0_$XIOS_DEB_ARCH.deb \
  libnotify4_0.8.3_$XIOS_DEB_ARCH.deb \
  libpolkit-gobject-1-0_124_$XIOS_DEB_ARCH.deb \
  libpulse0_17.0-1_$XIOS_DEB_ARCH.deb \
  gnome-settings-daemon_46.0_$XIOS_DEB_ARCH.deb \
  liblcms2-2_2.12_$XIOS_DEB_ARCH.deb \
  libcolord2_1.4.7_$XIOS_DEB_ARCH.deb \
  libei1_1.2.1_$XIOS_DEB_ARCH.deb \
  libmutter-14-0_46.0_$XIOS_DEB_ARCH.deb \
  libatspi2.0-0_2.52.0_$XIOS_DEB_ARCH.deb \
  libatk-bridge2.0-0_2.52.0_$XIOS_DEB_ARCH.deb \
  libgcr-4-4_4.2.1_$XIOS_DEB_ARCH.deb \
  libpolkit-agent-1-0_124_$XIOS_DEB_ARCH.deb \
  libibus-1.0-5_1.5.29_$XIOS_DEB_ARCH.deb \
  libxcb-util1_*_$XIOS_DEB_ARCH.deb \
  libstartup-notification0_0.12_$XIOS_DEB_ARCH.deb \
  gnome-shell_46.0_$XIOS_DEB_ARCH.deb \
  libaccountsservice0_23.13.9_$XIOS_DEB_ARCH.deb \
  libgdm1_46.0_$XIOS_DEB_ARCH.deb \
  libgeoclue-2-0_2.7.1_$XIOS_DEB_ARCH.deb \
  libpsl5_0.21.5_$XIOS_DEB_ARCH.deb \
  libsoup-3.0-0_3.4.4_$XIOS_DEB_ARCH.deb \
  libgeocode-glib-2-0_3.26.4_$XIOS_DEB_ARCH.deb \
  libgweather-4-0_4.4.2_$XIOS_DEB_ARCH.deb \
  libupower-glib3_1.90.2_$XIOS_DEB_ARCH.deb \
  xios-session-stubs_0.1.2_$XIOS_DEB_ARCH.deb \
"

# The -dev debs below are needed ONLY for gtk4-gpu's on-device gir/typelib scan (headers +
# pkg-config), not for boot. Install them before running the gir batch. The second group covers
# the shell's remaining boot-import closure (gtk4-gpu's 2026-07-01 audit): Atk-1.0, Atspi-2.0,
# Gcr-4 + Gck-2 (one deb), Polkit-1.0 + PolkitAgent-1.0 (one deb), IBus-1.0, GnomeDesktop-4.0 +
# GnomeBG-4.0 (one deb). NOT here: GDesktopEnums-3.0 (gsettings-desktop-schemas ships no header/
# gir → gtk4-gpu meson-routes it) and p11-kit-1-dev (gck-2.pc/gcr-4.pc Require it for cflags →
# apt-get download'd below, like libxcb-util1).
GIR_DEV_DEBS="\
  libmutter-14-dev_46.0_$XIOS_DEB_ARCH.deb \
  libgjs-dev_1.78.0_$XIOS_DEB_ARCH.deb \
  libaccountsservice-dev_23.13.9_$XIOS_DEB_ARCH.deb \
  libgdm-dev_46.0_$XIOS_DEB_ARCH.deb \
  libupower-glib-dev_1.90.2_$XIOS_DEB_ARCH.deb \
  libgeocode-glib-2-dev_3.26.4_$XIOS_DEB_ARCH.deb \
  libgweather-4-dev_4.4.2_$XIOS_DEB_ARCH.deb \
  libgeoclue-dev_2.7.1_$XIOS_DEB_ARCH.deb \
  libatk1.0-dev_2.38.0_$XIOS_DEB_ARCH.deb \
  at-spi2-core-dev_2.52.0_$XIOS_DEB_ARCH.deb \
  gcr4-dev_4.2.1_$XIOS_DEB_ARCH.deb \
  polkit-dev_124_$XIOS_DEB_ARCH.deb \
  libibus-dev_1.5.29_$XIOS_DEB_ARCH.deb \
  libgnome-desktop-dev_44.1_$XIOS_DEB_ARCH.deb \
  p11-kit-1-dev_*_$XIOS_DEB_ARCH.deb \
"

# ---- fetch the ENTIRE external dependency closure from Procursus in ONE pass ----------------
# Our set Depends a frontier of standard Procursus libs we do not build. Some (libsndfile1) pull
# their own codec subtree (libFLAC/vorbis/ogg/opus...). Rather than discover them one re-run at a
# time, ask apt to resolve the RECURSIVE closure of the whole frontier, then download only what is
# (a) not already installed and (b) not in our local set. apt has the Procursus metadata; we just
# harvest the names. dpkg -i later configures everything in topological order regardless of order.
echo "==> resolving + fetching the external dependency closure from Procursus (one pass)"
apt-get update >/dev/null 2>&1 || true
# The direct external frontier of the boot set (from the deb-metadata closure). The p11-kit-1-dev
# gir-scan dep rides along. Base libs already on device drop out of the download below.
EXT_FRONTIER="libsndfile1 libxcb-util1 libxcb-util0 libFLAC12 libFLAC8 libvorbis0a libvorbisenc2 \
  libogg0 libopus0 libmpg123-0 libmp3lame0 libgcrypt20 libgpg-error0 libp11-kit0 p11-kit-1-dev \
  libfreetype6 fontconfig-config libjpeg62-turbo libtiff5 libpng16-16 libgcc-s1 libstdc++6 \
  liblzma5 liblzo2-2 libnghttp2-14 libpcre2-8-0 libsqlite3-1 libuuid16 libintl8"
# Expand each frontier package to its recursive dependency names, uniq, then download the missing.
CLOSURE=$(for p in $EXT_FRONTIER; do
            apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
              --no-breaks --no-replaces --no-enhances "$p" 2>/dev/null | awk '/^\w/{print $1}'
          done | sort -u)
for p in $EXT_FRONTIER $CLOSURE; do
  case "$p" in ""|"<"*) continue;; esac
  dpkg -s "$p" >/dev/null 2>&1 && continue           # already installed on device
  ls "${p}_"*_$XIOS_DEB_ARCH.deb >/dev/null 2>&1 && continue   # already in our local set / fetched
  apt-get download "$p" 2>/dev/null && echo "   + fetched $p" || true
done
# Hard gate: libsndfile1 (libpulse0's new blocker) MUST be present now.
if ! ls libsndfile1_*_$XIOS_DEB_ARCH.deb >/dev/null 2>&1 && ! dpkg -s libsndfile1 >/dev/null 2>&1; then
  echo "!! libsndfile1 still missing after the closure fetch — 'apt-get download libsndfile1' by hand, then re-run"; exit 1
fi

# CONFLICT 1 (PulseAudio): the device may carry audio-desktop's libpulse-simple-xios0 (the
# CoreAudio-server client shim), which package-Conflicts the full libpulse0. gnome-shell + gsd
# need the FULL libpulse0 (gvc volume control), not the simple shim — and libpulse0 is declared
# to supersede it (Provides: libpulse-simple0, Conflicts+Replaces libpulse-simple-xios0). So
# remove the shim first; anything that linked libpulse-simple0 still resolves via libpulse0.
if dpkg -s libpulse-simple-xios0 >/dev/null 2>&1; then
  echo "==> removing libpulse-simple-xios0 (superseded by the full libpulse0 for gvc/gnome-shell)"
  dpkg -r libpulse-simple-xios0 || echo "   (blocked — a package Depends it; coordinate with audio-desktop before proceeding)"
fi

# CONFLICT 2 (icon themes): hicolor-icon-theme + adwaita-icon-theme (hard deps of libgtk-3-0)
# ship index.theme files that xios-desktop-defaults 1.1.1 also carries. The icon-theme packages
# are the canonical owners of those files, and xios's theming is applied via gsettings overrides
# (not by owning index.theme), so --force-overwrite is safe here. FOLLOW-UP: xios-desktop-defaults
# should Replaces: hicolor-icon-theme, adwaita-icon-theme (or stop shipping those files) to make
# this clean without the flag; tracked separately.
# Collect the external closure debs we just fetched (frontier + recursive names present in this
# dir), to install ALONGSIDE our set. dpkg -i given everything at once configures in topological
# order regardless of argument order, so we do not need to interleave them by hand. The GIR_DEV
# debs are deliberately NOT included here — they are the Phase-2 pass.
EXT_DEBS=""
for p in $EXT_FRONTIER $CLOSURE; do
  for f in ${p}_*_$XIOS_DEB_ARCH.deb; do [ -f "$f" ] && EXT_DEBS="$EXT_DEBS $f"; done
done

echo "==> installing the boot set + fetched external closure (--force-overwrite for the icon-theme"
echo "    conflict with xios-desktop-defaults; dpkg -i is idempotent — safe to re-run)"
dpkg -i --force-overwrite $EXT_DEBS $DEBS
echo "==> boot set installed."
echo "==> Phase 2 (gir scan prereq): dpkg -i \$GIR_DEV_DEBS  — the 14 -dev debs + p11-kit-1-dev;"
echo "    then gtk4-gpu runs the closure scan (GDesktopEnums-3.0 is meson-routed, not a deb)."
echo "==> verify: apt-get check   (must be clean; do NOT run apt --fix-broken on this device)"
