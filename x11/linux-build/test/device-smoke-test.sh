#!/usr/bin/env bash
# On-device GTK3 smoke test. Run from the host (macOS) once the iPad is reachable.
# Installs the GTK3 runtime stack, signs + runs hello-gtk on the X server, and
# reports whether a frame painted (HELLO_GTK_DREW). Optionally grabs a screenshot.
#
#   bash test/device-smoke-test.sh
set -uo pipefail

DEV=root@10.0.0.74
SSH="ssh -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=8 -i $HOME/.ssh/id_ed25519"
SCP="scp -o BatchMode=yes -o IdentitiesOnly=yes -i $HOME/.ssh/id_ed25519"
OUT="$(cd "$(dirname "$0")/../out" && pwd)"
DISPLAY_NUM="${DISPLAY_NUM:-:3}"

if ! $SSH "$DEV" true 2>/dev/null; then
  echo "FAIL: device $DEV unreachable (asleep?)."; exit 1
fi

# Runtime debs in rough dependency order. The X runtime libs (libx11-6, libxext6,
# libxrender1, libxi6, libxrandr2, libxfixes3, libxdamage1) are assumed already
# installed by the X stack; if not, dpkg will report them as unmet.
RUNTIME_DEBS=(
  libglib2.0-0_*.deb libglib2.0-bin_*.deb
  libgraphite2-3_*.deb libfribidi0_*.deb libharfbuzz0b_*.deb
  libfontconfig1_*.deb fontconfig-config_*.deb
  libpango-1.0-0_*.deb libatk1.0-0_*.deb libgdk-pixbuf-2.0-0_*.deb
  libcairo2_*.deb libcairo-gobject2_*.deb libepoxy0_*.deb
  libxcursor1_*.deb libxinerama1_*.deb
  libgtk-3-0_*.deb gtk-3-bin_*.deb
)

echo "== shipping debs + hello-gtk to device =="
$SSH "$DEV" 'mkdir -p /var/jb/tmp/gtktest'
for pat in "${RUNTIME_DEBS[@]}"; do
  for f in "$OUT"/$pat; do [ -e "$f" ] && $SCP "$f" "$DEV:/var/jb/tmp/gtktest/"; done
done
$SCP "$OUT/hello-gtk" "$DEV:/var/jb/tmp/gtktest/"

echo "== installing on device =="
$SSH "$DEV" 'cd /var/jb/tmp/gtktest && dpkg -i *.deb 2>&1 | tail -20'

echo "== signing hello-gtk (ad-hoc) =="
$SSH "$DEV" 'ldid -S /var/jb/tmp/gtktest/hello-gtk 2>/dev/null || codesign -f -s - /var/jb/tmp/gtktest/hello-gtk 2>/dev/null; chmod +x /var/jb/tmp/gtktest/hello-gtk'

echo "== running hello-gtk on DISPLAY=$DISPLAY_NUM =="
$SSH "$DEV" "DISPLAY=$DISPLAY_NUM /var/jb/tmp/gtktest/hello-gtk; echo EXIT=\$?" 2>&1

echo "== (optional) screenshot via xwd if available =="
$SSH "$DEV" "command -v xwd >/dev/null && DISPLAY=$DISPLAY_NUM xwd -root -silent > /var/jb/tmp/gtktest/screen.xwd 2>/dev/null && echo 'screenshot at /var/jb/tmp/gtktest/screen.xwd' || echo 'xwd not available (skip)'"

echo "== DONE: look for HELLO_GTK_DREW / HELLO_GTK_DONE above (EXIT=0 = render OK) =="
