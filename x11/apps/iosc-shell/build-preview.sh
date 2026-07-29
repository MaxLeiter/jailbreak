#!/usr/bin/env bash
#
# Renders the REAL shell draw code to PNGs, off-device.
#
# This is the fast visual-iteration loop for the shell-polish work: it compiles
# preview-host.c (which calls the same panel-layout.h / overview-layout.h /
# shell-blur.h code the device clients use) natively in the Procursus xbuild
# container, which has cairo + pangocairo. For font fidelity it drops in the
# host's San Francisco (SFNS.ttf) and aliases generic "Sans" -> SF, mirroring
# the on-device x11-fonts-sf fontconfig rule — so the preview's typography
# matches the iPad.
#
# Output: design/preview-desktop.png, design/preview-quicksettings.png,
#         design/preview-overview.png
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE=procursus-xbuild:bookworm-arm64

# Stage SF under the (already-mounted) work dir so Docker can see it without a
# separate system-path mount. Gitignored; preview-only, never shipped.
SF_SRC=/System/Library/Fonts/SFNS.ttf
SF_LOCAL="$HERE/design/.sf/SFNS.ttf"
if [[ ! -f "$SF_LOCAL" && -f "$SF_SRC" ]]; then
  mkdir -p "$HERE/design/.sf"; cp "$SF_SRC" "$SF_LOCAL"
fi

docker run --rm --entrypoint /bin/bash \
  -v "$HERE":/work \
  "$IMAGE" -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    if ! pkg-config --exists cairo pangocairo gdk-pixbuf-2.0; then
      apt-get update -qq
      apt-get install -y -qq libcairo2-dev libpango1.0-dev libgdk-pixbuf-2.0-dev fontconfig >/dev/null
    fi
    # Font fidelity: install SF and alias the generic families to it (== device).
    if [ -f /work/design/.sf/SFNS.ttf ]; then
      mkdir -p /usr/share/fonts/truetype/sf
      cp /work/design/.sf/SFNS.ttf /usr/share/fonts/truetype/sf/
      cat >/etc/fonts/conf.d/09-sf.conf <<EOF
<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="pattern"><test name="family"><string>sans-serif</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>SF Pro</string></edit></match>
</fontconfig>
EOF
      fc-cache -f >/dev/null 2>&1 || true
    fi
    cd /work
    cc preview-host.c $(pkg-config --cflags --libs cairo pangocairo gdk-pixbuf-2.0) -lm -o /tmp/preview-host
    IOSC_SHELL_ICONS=/work/design/preview-icons /tmp/preview-host /work/design
  '
echo "wrote $HERE/design/preview-{desktop,quicksettings,overview}.png"
