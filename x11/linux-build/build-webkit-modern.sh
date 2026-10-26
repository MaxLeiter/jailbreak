#!/usr/bin/env bash
# Host side: build WebKitGTK 2.54 (recipe webkitgtk-modern) and optionally epiphany/geary against it
# in procursus-vol-gtk, with the opt-in clang-19 toolchain.
#
#   bash x11/linux-build/build-webkit-modern.sh <make-target>...
#   e.g. webkitgtk-modern-configure | webkitgtk-modern-wtf | webkitgtk-modern-jsc |
#        webkitgtk-modern-webcore | webkitgtk-modern-package | epiphany-package geary-package
#
# Output debs land in x11/linux-build/out-webkit-modern/ of THIS checkout (never the main checkout).
# Dependency debs are read-only: /Users/max/Documents/jailbreak/{x11/linux-build/out,repo/debs}
# are hardlinked into a scratch farm that is mounted at /repo-debs.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11DIR="$(cd "$HERE/.." && pwd)"
MAIN="${XIOS_MAIN_CHECKOUT:-/Users/max/Documents/jailbreak}"
VOL="${PROCURSUS_VOL:-procursus-vol-gtk}"
IMAGE="${XIOS_PROC_IMAGE:-procursus-xbuild:bookworm-arm64}"
OUT="$HERE/out-webkit-modern"
FARM="${XIOS_DEP_FARM:-/private/tmp/xios-webkit-modern-depdebs}"
CPUS="${XIOS_CPUS:-6}"
[ "$#" -gt 0 ] || { echo "usage: $0 <make-target>..." >&2; exit 2; }
mkdir -p "$OUT" "$FARM"
# Hardlink farm: newest-wins is decided in-container by version sort, so just link everything.
for d in "$MAIN/x11/linux-build/out" "$MAIN/repo/debs"; do
  for f in "$d"/*.deb; do [ -e "$f" ] && ln -f "$f" "$FARM/$(basename "$f")" 2>/dev/null || true; done
done
echo "df: $(df -h / | tail -1)"
exec docker run --rm --platform linux/arm64 --cpus="$CPUS" \
  -v "$VOL":/work/Procursus \
  -v "$HERE/target-env.sh:/work/target-env.sh:ro" \
  -v "$HERE/build-gnome.sh:/work/build-gnome.sh:ro" \
  -v "$HERE/build-webkit-modern-inner.sh:/work/build-webkit-modern-inner.sh:ro" \
  -v "$HERE/tools:/work/tools:ro" \
  -v "$HERE/recipes:/work/recipes:ro" \
  -v "$X11DIR/ports:/work/ports:ro" \
  -v "$HERE/build_info:/work/build_info:ro" \
  -v "$HERE/vapi:/work/vapi:ro" \
  -v "$OUT":/out \
  -v "$FARM":/repo-debs:ro \
  -e TARGETS="$*" \
  ${DEB_EPIPHANY_V:+-e DEB_EPIPHANY_V="$DEB_EPIPHANY_V"} ${DEB_GEARY_V:+-e DEB_GEARY_V="$DEB_GEARY_V"} \
  --entrypoint /bin/bash "$IMAGE" /work/build-webkit-modern-inner.sh
