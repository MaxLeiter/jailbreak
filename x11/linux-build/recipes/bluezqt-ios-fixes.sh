#!/usr/bin/env bash
# bluezqt-ios-fixes.sh — first-light KF6 BluezQt cuts for Xios.
set -euo pipefail

src=${1:?usage: bluezqt-ios-fixes.sh <bluezqt-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace("add_subdirectory(tools/bluezapi2qt)\n", "# ios: skip source generator tool\n")
p.write_text(s)
PY

python3 - "$src/src/a2dp-codecs.h" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
s = s.replace(
    "#include <endian.h>\n",
    """#if defined(__APPLE__)
#include <machine/endian.h>
#ifndef __BYTE_ORDER
#define __BYTE_ORDER BYTE_ORDER
#endif
#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN LITTLE_ENDIAN
#endif
#ifndef __BIG_ENDIAN
#define __BIG_ENDIAN BIG_ENDIAN
#endif
#else
#include <endian.h>
#endif
""",
)
p.write_text(s)
PY
