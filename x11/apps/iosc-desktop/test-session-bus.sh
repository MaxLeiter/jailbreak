#!/usr/bin/env bash
# Host checks that ioscd adopts its session-bus dir and socket without
# following names planted in the world-writable tmp dir
# (tests/test-session-bus.c). Uses dbus-daemon from PATH, or $DBUS_DAEMON,
# when there is one; the daemon cases are skipped otherwise.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out/tests"
mkdir -p "$OUT"

${CC:-clang} -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror \
  "$HERE/tests/test-session-bus.c" "$HERE/src/xios-desktop-entry.c" \
  -Wl,-U,_ie_execl -Wl,-U,_ie_execv -Wl,-U,_ie_execvp \
  -o "$OUT/test-session-bus"
DBUS_DAEMON="${DBUS_DAEMON:-$(command -v dbus-daemon || true)}" "$OUT/test-session-bus"
