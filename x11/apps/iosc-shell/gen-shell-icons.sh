#!/usr/bin/env bash
#
# gen-shell-icons.sh — pre-rasterize app icons for the iosc panel.
#
# There is no librsvg on device, so the shell clients can't render the SVG icons that
# GNOME apps ship (hicolor/scalable/apps/*.svg). This script rasterises each
# installed app's icon to a PNG the panel loads with cairo's built-in PNG reader
# (panel-icons.h resolves Icon= -> <IconName>.png in the shipped set).
#
# It reads the app .deb files in linux-build/out, resolves each .desktop's Icon=
# to its best source image (largest raster, or scalable SVG), and writes
#   out/icons/<IconName>.png   at MASTER px (downscaled crisply at draw time).
#
# Host tools: ar, tar, zstd, rsvg-convert (brew install librsvg).
# Deploy rootless: scp -r out/icons/* root@ipad:/var/jb/usr/share/iosc-shell/icons/
# Deploy rootful:  scp -r out/icons/* root@ipad:/usr/share/iosc-shell/icons/
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DEBS="${DEBS:-$REPO/linux-build/out}"
OUT="${1:-$HERE/out/icons}"
MASTER="${MASTER:-256}"       # master raster size (px); draw-time downscale is crisp

command -v rsvg-convert >/dev/null || { echo "need rsvg-convert (brew install librsvg)" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MERGE="$TMP/merge"; mkdir -p "$MERGE"

# --- unpack every app deb's icon + desktop dirs into one merged tree ---------
extract_deb() {
  local deb="$1" d; d="$TMP/x"; rm -rf "$d"; mkdir -p "$d"; ( cd "$d" && ar x "$deb" ) 2>/dev/null || return 0
  local data; data="$(ls "$d"/data.tar.* 2>/dev/null | head -1)"; [ -n "$data" ] || return 0
  case "$data" in
    *.zst) ( cd "$MERGE" && zstd -dc "$data" | tar x ) 2>/dev/null || ( cd "$MERGE" && tar --zstd -xf "$data" ) 2>/dev/null ;;
    *.xz)  ( cd "$MERGE" && tar xJf "$data" ) 2>/dev/null ;;
    *.gz)  ( cd "$MERGE" && tar xzf "$data" ) 2>/dev/null ;;
    *)     ( cd "$MERGE" && tar xf  "$data" ) 2>/dev/null ;;
  esac
}
echo "unpacking app debs from $DEBS ..."
for deb in "$DEBS"/*.deb; do
  [ -f "$deb" ] || continue
  extract_deb "$deb"
done

SHARE="${IOSC_SHARE_ROOT:-}"
if [ -z "$SHARE" ]; then
  if [ -d "$MERGE/var/jb/usr/share" ]; then
    SHARE="$MERGE/var/jb/usr/share"
  elif [ -d "$MERGE/usr/share" ]; then
    SHARE="$MERGE/usr/share"
  fi
fi
APPS="$SHARE/applications"
[ -n "$SHARE" ] && [ -d "$APPS" ] || { echo "no applications/ found in debs" >&2; exit 1; }

HICOLOR_SIZES="512x512 256x256 192x192 128x128 96x96 64x64 48x48"

# resolve an Icon= name to a source file within the merged tree
resolve() {
  local name="${1:-}"; local base="$name"; local p ext theme size
  [ -n "$name" ] || return 0
  case "$name" in /*) [ -f "$name" ] && { echo "$name"; return; } ;; esac
  base="${base%.png}"; base="${base%.svg}"; base="${base%.xpm}"
  for theme in hicolor Adwaita gnome default; do
    for size in $HICOLOR_SIZES; do
      for ext in png svg; do
        p="$SHARE/icons/$theme/$size/apps/$base.$ext"; [ -f "$p" ] && { echo "$p"; return; }
      done
    done
    p="$SHARE/icons/$theme/scalable/apps/$base.svg"; [ -f "$p" ] && { echo "$p"; return; }
  done
  for ext in png svg xpm; do p="$SHARE/pixmaps/$base.$ext"; [ -f "$p" ] && { echo "$p"; return; } ; done
  return 0
}

mkdir -p "$OUT"
n=0
for desktop in "$APPS"/*.desktop; do
  [ -f "$desktop" ] || continue
  icon="$(awk -F= '/^\[/{e=($0=="[Desktop Entry]")} e&&/^Icon=/{print substr($0,6); exit}' "$desktop")"
  [ -n "$icon" ] || continue
  src="$(resolve "$icon")" || true
  [ -n "${src:-}" ] || { echo "  -- $icon: no source"; continue; }
  dst="$OUT/${icon}.png"
  case "$src" in
    *.svg) rsvg-convert -w "$MASTER" -h "$MASTER" -o "$dst" "$src" 2>/dev/null && { echo "  OK $icon (svg)"; n=$((n+1)); } ;;
    *.png) sips -Z "$MASTER" "$src" --out "$dst" >/dev/null 2>&1 && { echo "  OK $icon (png)"; n=$((n+1)); } \
             || { cp "$src" "$dst"; echo "  OK $icon (png copy)"; n=$((n+1)); } ;;
    *)     echo "  -- $icon: unsupported $src" ;;
  esac
done
echo "wrote $n icon(s) -> $OUT"
