#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out/tests"
mkdir -p "$OUT"

${CC:-clang} -std=c11 -D_DARWIN_C_SOURCE -Wall -Wextra -Werror \
  "$HERE/src/xios-desktop-entry.c" \
  "$HERE/tests/test-desktop-entry.c" \
  -o "$OUT/test-desktop-entry"
"$OUT/test-desktop-entry"
