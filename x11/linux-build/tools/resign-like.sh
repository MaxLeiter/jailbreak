#!/usr/bin/env bash
# resign-like.sh MODE ROOT
#
# Re-sign edited Mach-Os with exactly the signer that produced the shipped file.
#
# Each ROOT/<id>/ holds orig/<name> (the shipped, signed Mach-O) and mod/<name> (the same
# file after an install_name_tool edit, so its signature is now invalid). For every <id>
# without a ROOT/<id>/variant yet, this tries each signer invocation on a copy of orig and
# keeps the first one that turns orig back into itself byte for byte. That proves which
# tool, flags and entitlements made the shipped signature. It then signs mod the same way
# into signed/<name> and records the invocation in ROOT/<id>/variant.
#
# The file keeps its basename throughout because ldid and codesign derive the signing
# identifier from it.
#
# MODE container: the in-container ldid (no DER entitlements), plain and with the Procursus
#                 SIGN flags (-Hsha256 -Cadhoc). Run it inside procursus-xbuild.
# MODE host:      the host (Homebrew) ldid, which emits DER, and codesign.
#
# An <id> no variant reproduces is left without a variant file; the caller treats that as
# a failure, so nothing is ever signed by a guess.
set -euo pipefail
mode="$1"
root="$2"

sign() { # variant file ent
  local v="$1" f="$2" ent="$3"
  case "$v" in
    ldid)
      if [ -s "$ent" ]; then ldid -S"$ent" "$f"; else ldid -S "$f"; fi ;;
    ldid-sha256-adhoc)
      if [ -s "$ent" ]; then ldid -Hsha256 -Cadhoc -S"$ent" "$f"; else ldid -Hsha256 -Cadhoc -S "$f"; fi ;;
    codesign)
      if [ -s "$ent" ]; then codesign -s - --force --entitlements "$ent" "$f"
      else codesign -s - --force "$f"; fi ;;
    *) return 1 ;;
  esac
}

case "$mode" in
  container) variants="ldid ldid-sha256-adhoc" ;;
  host)      variants="ldid codesign" ;;
  *) echo "usage: $0 container|host ROOT" >&2; exit 2 ;;
esac

for d in "$root"/*/; do
  d="${d%/}"
  [ -s "$d/variant" ] && continue
  name="$(ls "$d/orig")"
  ent="$d/ent.$mode.xml"
  ldid -e "$d/orig/$name" > "$ent" 2>/dev/null || : > "$ent"
  for v in $variants; do
    rm -rf "$d/try"; mkdir -p "$d/try"
    cp "$d/orig/$name" "$d/try/$name"
    sign "$v" "$d/try/$name" "$ent" >/dev/null 2>&1 || continue
    if cmp -s "$d/try/$name" "$d/orig/$name"; then
      rm -rf "$d/signed"; mkdir -p "$d/signed"
      cp "$d/mod/$name" "$d/signed/$name"
      sign "$v" "$d/signed/$name" "$ent" >/dev/null 2>&1
      echo "$mode:$v" > "$d/variant"
      break
    fi
  done
  rm -rf "$d/try"
done
