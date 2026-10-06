#!/usr/bin/env bash
# Host checks that ioscd's children inherit none of its descriptors: not the
# listening control socket, not the SIGCHLD pipe, and (for a launched app,
# which drops to mobile) nothing else either (tests/test-ioscd-fds.c).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out/tests"
mkdir -p "$OUT"

${CC:-clang} -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror \
  "$HERE/tests/test-ioscd-fds.c" "$HERE/src/xios-desktop-entry.c" \
  -Wl,-U,_ie_execl -Wl,-U,_ie_execv -Wl,-U,_ie_execvp \
  -o "$OUT/test-ioscd-fds"
"$OUT/test-ioscd-fds"
