#!/usr/bin/env bash
# Host-side checks that ioscd execs through Procursus libiosexec
# (src/xios-iosexec.h). Without it, a desktop entry whose Exec target is a
# "#!/bin/sh" script dies with 127 on rootless, where /bin/sh does not exist.
#
#   test-iosexec.sh                 source check + host routing/fallback tests
#   test-iosexec.sh --binary FILE   also check the built iOS ioscd's link shape
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out/tests"
mkdir -p "$OUT"

BIN=""
if [ "${1:-}" = "--binary" ]; then BIN="${2:?--binary needs a path}"; fi

# 1. ioscd.c makes no raw exec-family call: every one goes through xios_exec*.
raw="$(grep -nE '(^|[^_[:alnum:]])(execl|execle|execlp|execv|execve|execvp|execvpe|posix_spawn|posix_spawnp|system|popen)\(' \
        "$HERE/src/ioscd.c" || true)"
if [ -n "$raw" ]; then
  echo "test-iosexec: raw exec call in ioscd.c (use xios_exec* from xios-iosexec.h):" >&2
  echo "$raw" >&2
  exit 1
fi

# 2. Host routing (stubbed libiosexec) and fallback (libiosexec absent).
CFLAGS=(-std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror)
${CC:-clang} "${CFLAGS[@]}" -DWITH_STUBS \
  "$HERE/tests/test-iosexec.c" "$HERE/tests/test-iosexec-stubs.c" \
  -o "$OUT/test-iosexec-routing"
"$OUT/test-iosexec-routing"
${CC:-clang} "${CFLAGS[@]}" "$HERE/tests/test-iosexec.c" \
  -Wl,-U,_ie_execl -Wl,-U,_ie_execv -Wl,-U,_ie_execvp \
  -o "$OUT/test-iosexec-fallback"
"$OUT/test-iosexec-fallback"

# 3. The device binary weak-loads libiosexec, can find it, and imports the
#    entry points. ioscd linking only libSystem is exactly the bug.
if [ -n "$BIN" ]; then
  OTOOL="$(xcrun -f otool 2>/dev/null || command -v otool)"
  NM="$(xcrun -f nm 2>/dev/null || command -v nm)"
  rpath="${XIOS_PREFIX-/var/jb}/usr/lib"
  loads="$("$OTOOL" -l "$BIN")"
  grep -A2 'cmd LC_LOAD_WEAK_DYLIB' <<<"$loads" | grep -q 'name @rpath/libiosexec.1.dylib ' || {
    echo "test-iosexec: $BIN does not weak-load @rpath/libiosexec.1.dylib" >&2; exit 1; }
  grep -A2 'cmd LC_RPATH' <<<"$loads" | grep -q "path $rpath " || {
    echo "test-iosexec: $BIN has no LC_RPATH $rpath" >&2; exit 1; }
  imports="$("$NM" -u "$BIN")"
  for sym in _ie_execl _ie_execv _ie_execvp; do
    grep -qx "$sym" <<<"$imports" || {
      echo "test-iosexec: $BIN does not import $sym" >&2; exit 1; }
  done
  echo "iosexec link check: ok ($(basename "$BIN") weak-loads libiosexec, rpath $rpath)"
fi
