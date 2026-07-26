#!/usr/bin/env bash
# The WebKitGTK release tarball intentionally omits Apple-port files. Cross-configuring the
# GTK port for a real Darwin/iOS target still selects a small set of shared WTF Apple sources
# and public headers, so hydrate those exact files from the matching immutable WebKit commit.
set -euo pipefail

source_root="${1:?usage: hydrate-webkit-apple-sources.sh WEBKIT_SOURCE_ROOT WEBKIT_COMMIT}"
webkit_commit="${2:?usage: hydrate-webkit-apple-sources.sh WEBKIT_SOURCE_ROOT WEBKIT_COMMIT}"
raw_base="https://raw.githubusercontent.com/WebKit/WebKit/$webkit_commit/Source/WTF/wtf"

files=(
  darwin/OSLogPrintStream.mm
  cf/CFURLExtras.h
  cf/TypeCastsCF.h
  cf/VectorCF.h
  cocoa/CrashReporter.h
  cocoa/Entitlements.h
  cocoa/NSURLExtras.h
  cocoa/RuntimeApplicationChecksCocoa.h
  cocoa/SoftLinking.h
  cocoa/TollFreeBridging.h
  cocoa/TypeCastsCocoa.h
  cocoa/VectorCocoa.h
  spi/cf/CFBundleSPI.h
  spi/cf/CFStringSPI.h
  spi/cocoa/CFXPCBridgeSPI.h
  spi/cocoa/CrashReporterClientSPI.h
  spi/cocoa/IOSurfaceSPI.h
  spi/cocoa/MachVMSPI.h
  spi/cocoa/NSLocaleSPI.h
  spi/cocoa/NSObjCRuntimeSPI.h
  spi/cocoa/SecuritySPI.h
  spi/cocoa/objcSPI.h
  spi/darwin/AbortWithReasonSPI.h
  spi/mac/MetadataSPI.h
  text/cf/StringConcatenateCF.h
  text/cf/TextBreakIteratorCF.h
)

echo "==> hydrating WebKit WTF Apple sources from $webkit_commit"
for relative in "${files[@]}"; do
  destination="$source_root/Source/WTF/wtf/$relative"
  [ -f "$destination" ] && continue
  mkdir -p "$(dirname "$destination")"
  curl -LfsS "$raw_base/$relative" -o "$destination"
done

bmalloc_process_check="$source_root/Source/bmalloc/bmalloc/ProcessCheck.mm"
if [ ! -f "$bmalloc_process_check" ]; then
  mkdir -p "$(dirname "$bmalloc_process_check")"
  curl -LfsS \
    "https://raw.githubusercontent.com/WebKit/WebKit/$webkit_commit/Source/bmalloc/bmalloc/ProcessCheck.mm" \
    -o "$bmalloc_process_check"
fi
