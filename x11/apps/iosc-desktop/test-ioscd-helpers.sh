#!/usr/bin/env bash
# Host checks for ioscd's per-bus helper guard (one xios-hwbridged/-sensord/
# -sysintd per session bus, recorded in <busdir>/<name>.pid like
# xios-session-lib.sh) and for the SESSION reply when xios-session is not
# installed, for the PRESETS verb (stand-in scripts, then the real xios-session
# and lib on a scratch prefix) and for the accessibility helper's identity
# (tests/test-ioscd-helpers.c).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out/tests"
mkdir -p "$OUT"

${CC:-clang} -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror \
  -DSESSION_SRC_DIR="\"$HERE\"" \
  "$HERE/tests/test-ioscd-helpers.c" "$HERE/src/xios-desktop-entry.c" \
  -Wl,-U,_ie_execl -Wl,-U,_ie_execv -Wl,-U,_ie_execvp \
  -o "$OUT/test-ioscd-helpers"
"$OUT/test-ioscd-helpers"
