#!/usr/bin/env bash
# kpty source surgery for iOS. See kpty.mk.
set -euo pipefail
src=${1:?usage: kpty-ios-fixes.sh /path/to/kpty-source}

# ConfigureChecks probes only whether a header EXISTS, and iOS has BOTH
# libutil.h and util.h. kpty.cpp checks HAVE_LIBUTIL_H first, so it includes
# libutil.h -- which on Darwin does NOT declare openpty/forkpty (they live in
# util.h; libutil.h only carries the mount/pidfile helpers). Result:
# "no member named 'openpty' in the global namespace" despite HAVE_OPENPTY=1.
# Prefer util.h on Apple and leave every other platform on the upstream order.
python3 - "$src/src/kpty.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
MARKER = "// ios: libutil.h exists on Darwin but"
if MARKER not in text:
    old = "#if HAVE_LIBUTIL_H\n#include <libutil.h>\n#elif HAVE_UTIL_H\n#include <util.h>\n"
    new = (
        MARKER + " does not declare openpty/forkpty;\n"
        "// those are in util.h. Check it first so the Darwin build sees them.\n"
        "#if defined(__APPLE__) && HAVE_UTIL_H\n"
        "#include <util.h>\n"
        "#elif HAVE_LIBUTIL_H\n"
        "#include <libutil.h>\n"
        "#elif HAVE_UTIL_H\n"
        "#include <util.h>\n"
    )
    if old not in text:
        raise SystemExit("kpty-ios-fixes.sh: libutil.h include block not found")
    text = text.replace(old, new, 1)
    path.write_text(text)
PY
