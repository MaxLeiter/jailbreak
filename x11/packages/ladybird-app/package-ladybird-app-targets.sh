#!/usr/bin/env bash
# Produce the two architecture variants that expose one ladybird-app package id:
#   rootless-1900 -> iphoneos-arm64, /var/jb/Applications
#   rootful-1900  -> iphoneos-arm,   /Applications
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IN="${1:-}"
OUT_ROOT="${2:-}"

[ -n "$IN" ] && [ -f "$IN" ] || {
    echo "usage: $0 <container-built-ladybird-app.deb> [out-root]" >&2
    exit 2
}
OUT_ROOT="${OUT_ROOT:-$(dirname "$IN")}"

for target in rootless-1900 rootful-1900; do
    if [ "$target" = rootless-1900 ]; then
        target_out="$OUT_ROOT"
    else
        target_out="$OUT_ROOT/targets/$target"
    fi
    echo "==> Ladybird package target: $target"
    XIOS_TARGET="$target" "$HERE/resign-ladybird-app-deb.sh" "$IN" "$target_out"
done
