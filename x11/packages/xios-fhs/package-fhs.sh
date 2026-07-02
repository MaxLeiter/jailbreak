#!/usr/bin/env bash
# Assemble the xios-fhs package from its staged payload.
#
# Build the daemons first:
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD:/work/xios-fhs" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/xios-fhs/build-hwbridge.sh
#
# This packer deliberately stages only DEBIAN/ and var/ so src/, out/ and helper
# scripts do not accidentally ship in the installed package.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

X11DIR="$(cd "$HERE/../.." && pwd)"
OUT="$X11DIR/linux-build/out"

for f in \
  "$HERE/var/jb/usr/libexec/xios-hwbridged" \
  "$HERE/var/jb/usr/libexec/xios-sensord"; do
  [ -x "$f" ] || {
    echo "ERROR: missing executable payload: $f" >&2
    echo "       run packages/xios-fhs/build-hwbridge.sh in the Procursus container first" >&2
    exit 1
  }
done

# Stage DEBIAN + var only (src/, out/ and helper scripts must not ship), set the
# perms host-side, then let xmkdeb chown root:root + build the zstd .deb (in the
# cross-build container on a macOS host).
STAGEROOT=/private/tmp/xios-fhs-stage
STAGE="$STAGEROOT/xios-fhs"
rm -rf "$STAGEROOT"
mkdir -p "$STAGE"
cp -a "$HERE/DEBIAN" "$STAGE/"
cp -a "$HERE/var" "$STAGE/"
find "$STAGE" -type d -exec chmod 0755 {} +
chmod 0755 "$STAGE/DEBIAN/postinst"
find "$STAGE/var" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/var/jb/usr/libexec/xios-hwbridged" \
           "$STAGE/var/jb/usr/libexec/xios-sensord"

built="$(xmkdeb "$STAGE" "$OUT")"
echo "==> built $built"
