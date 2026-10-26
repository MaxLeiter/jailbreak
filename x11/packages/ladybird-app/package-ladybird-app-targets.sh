#!/usr/bin/env bash
# Re-target and re-sign the container-built ladybird-app deb for each supported
# target. There is only one now (rootful-1900 was dropped on 2026-10-25):
#   rootless-1900 -> iphoneos-arm64, /var/jb/Applications
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IN="${1:-}"
OUT_ROOT="${2:-}"

[ -n "$IN" ] && [ -f "$IN" ] || {
    echo "usage: $0 <container-built-ladybird-app.deb> [out-root]" >&2
    exit 2
}
OUT_ROOT="${OUT_ROOT:-$(dirname "$IN")}"

for target in rootless-1900; do
    echo "==> Ladybird package target: $target"
    XIOS_TARGET="$target" "$HERE/resign-ladybird-app-deb.sh" "$IN" "$OUT_ROOT"
done
