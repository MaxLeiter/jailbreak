#!/usr/bin/env bash
# WebKitGTK 2.54 release tarball hydration (sibling of hydrate-webkit-apple-sources.sh, which is
# pinned to the 2.44-era file layout and must not change). A real Darwin target of the GTK port
# still selects a few Apple-port files the tarball prunes; restore exactly those from the matching
# immutable WebKit commit. The list is exactly what WTF/bmalloc/ANGLE CMake asked for in the first
# 2.54 configure on 2026-10-01 (extend it when a later configure names more). AbortWithReasonSPI.h
# became spi/darwin/ReasonSPI.h and is kept in the tarball.
set -euo pipefail

source_root="${1:?usage: $0 WEBKIT_SOURCE_ROOT WEBKIT_COMMIT}"
webkit_commit="${2:?usage: $0 WEBKIT_SOURCE_ROOT WEBKIT_COMMIT}"
raw="https://raw.githubusercontent.com/WebKit/WebKit/$webkit_commit/Source"

files=(
  WTF/wtf/darwin/OSLogPrintStream.mm
  WTF/wtf/cf/CFURLExtras.h
  WTF/wtf/cf/NotificationCenterCF.h
  WTF/wtf/cf/TypeCastsCF.h
  WTF/wtf/cf/VectorCF.h
  WTF/wtf/cocoa/AuditToken.h
  WTF/wtf/cocoa/CrashReporter.h
  WTF/wtf/cocoa/Entitlements.h
  WTF/wtf/cocoa/NSStringExtras.h
  WTF/wtf/cocoa/NSURLExtras.h
  WTF/wtf/cocoa/RuntimeApplicationChecksCocoa.h
  WTF/wtf/cocoa/SoftLinking.h
  WTF/wtf/cocoa/SpanCocoa.h
  WTF/wtf/cocoa/TollFreeBridging.h
  WTF/wtf/cocoa/TypeCastsCocoa.h
  WTF/wtf/cocoa/VectorCocoa.h
  WTF/wtf/spi/cf/CFBundleSPI.h
  WTF/wtf/spi/cf/CFPrivSPI.h
  WTF/wtf/spi/cf/CFRunLoopSPI.h
  WTF/wtf/spi/cf/CFStringSPI.h
  WTF/wtf/spi/cocoa/BOMSPI.h
  WTF/wtf/spi/cocoa/CFXPCBridgeSPI.h
  WTF/wtf/spi/cocoa/CrashReporterClientSPI.h
  WTF/wtf/spi/cocoa/IOReturnSPI.h
  WTF/wtf/spi/cocoa/IOSurfaceSPI.h
  WTF/wtf/spi/cocoa/IOTypesSPI.h
  WTF/wtf/spi/cocoa/MachVMSPI.h
  WTF/wtf/spi/cocoa/NSLocaleSPI.h
  WTF/wtf/spi/cocoa/NSObjCRuntimeSPI.h
  WTF/wtf/spi/cocoa/OSLogSPI.h
  WTF/wtf/spi/cocoa/SecuritySPI.h
  WTF/wtf/spi/cocoa/XTSPI.h
  WTF/wtf/spi/cocoa/objcSPI.h
  WTF/wtf/spi/mac/MetadataSPI.h
  WTF/wtf/text/cf/StringConcatenateCF.h
  WTF/wtf/text/cf/TextBreakIteratorCF.h
  WTF/wtf/text/cf/TextBreakIteratorCFCharacterCluster.h
  WTF/wtf/text/cf/TextBreakIteratorCFStringTokenizer.h
  WTF/wtf/text/cocoa/ContextualizedCFString.h
  WTF/wtf/text/cocoa/ContextualizedNSString.h
  bmalloc/bmalloc/ProcessCheck.mm
  ThirdParty/ANGLE/src/common/apple_platform_utils.mm
)

echo "==> hydrating WebKit Apple-port sources from $webkit_commit"
for relative in "${files[@]}"; do
  destination="$source_root/Source/$relative"
  [ -f "$destination" ] && continue
  mkdir -p "$(dirname "$destination")"
  curl -LfsS "$raw/$relative" -o "$destination"
done
