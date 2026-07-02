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
X11DIR="$(cd "$HERE/../.." && pwd)"
OUT="$X11DIR/linux-build/out"
IMG="debian:bookworm-slim"
ARCH="iphoneos-arm64"

VER="$(awk -F': ' '/^Version:/{print $2}' "$HERE/DEBIAN/control")"
DEB="xios-fhs_${VER}_${ARCH}.deb"

for f in \
  "$HERE/var/jb/usr/libexec/xios-hwbridged" \
  "$HERE/var/jb/usr/libexec/xios-sensord"; do
  [ -x "$f" ] || {
    echo "ERROR: missing executable payload: $f" >&2
    echo "       run packages/xios-fhs/build-hwbridge.sh in the Procursus container first" >&2
    exit 1
  }
done

mkdir -p "$OUT"
docker run --rm \
  -v "$HERE":/work:ro \
  -v "$OUT":/out \
  "$IMG" bash -euo pipefail -c '
    stage=/tmp/xios-fhs
    rm -rf "$stage"
    mkdir -p "$stage"
    cp -a /work/DEBIAN "$stage/"
    cp -a /work/var "$stage/"
    chown -R root:root "$stage"
    find "$stage" -type d -exec chmod 0755 {} +
    chmod 0755 "$stage/DEBIAN/postinst"
    find "$stage/var" -type f -exec chmod 0644 {} +
    chmod 0755 "$stage/var/jb/usr/libexec/xios-hwbridged" \
               "$stage/var/jb/usr/libexec/xios-sensord"
    dpkg-deb -Zzstd -b "$stage" "/out/'"$DEB"'"
  '

echo "==> built $OUT/$DEB"
