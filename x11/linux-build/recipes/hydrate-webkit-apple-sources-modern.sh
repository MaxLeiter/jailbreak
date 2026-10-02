#!/usr/bin/env bash
# WebKitGTK 2.54 release tarball hydration (sibling of hydrate-webkit-apple-sources.sh, which is
# pinned to the 2.44-era file layout and must not change). A real Darwin target of the GTK port
# still selects a few Apple-port files the tarball prunes; restore exactly those from the matching
# immutable WebKit commit. Probe 2026-10-01: 2.54 keeps most cocoa/cf/spi headers in the tarball;
# these are the ones it lacks. AbortWithReasonSPI.h became spi/darwin/ReasonSPI.h (kept in tarball).
set -euo pipefail

source_root="${1:?usage: $0 WEBKIT_SOURCE_ROOT WEBKIT_COMMIT}"
webkit_commit="${2:?usage: $0 WEBKIT_SOURCE_ROOT WEBKIT_COMMIT}"
raw="https://raw.githubusercontent.com/WebKit/WebKit/$webkit_commit/Source"

files=(
  WTF/wtf/spi/mac/MetadataSPI.h
  WTF/wtf/text/cf/StringConcatenateCF.h
  WTF/wtf/text/cf/TextBreakIteratorCF.h
  bmalloc/bmalloc/ProcessCheck.mm
)

echo "==> hydrating WebKit Apple-port sources from $webkit_commit"
for relative in "${files[@]}"; do
  destination="$source_root/Source/$relative"
  [ -f "$destination" ] && continue
  mkdir -p "$(dirname "$destination")"
  curl -LfsS "$raw/$relative" -o "$destination"
done
