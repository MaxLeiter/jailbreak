#!/usr/bin/env bash
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

# KF 6.30: RfkillThread::doSetSoftBlocked() writes to /dev/rfkill with linux/rfkill.h types outside any platform
# guard (the rest of rfkill.cpp is Q_OS_LINUX-guarded). iOS has no rfkill: make the write a no-op there.
python3 - "$src/src/rfkill.cpp" <<'PY'
import pathlib, sys, re
p = pathlib.Path(sys.argv[1])
s = p.read_text()
marker = "ios: no /dev/rfkill"
if marker not in s:
    m = re.search(r"(void RfkillThread::doSetSoftBlocked\(quint8 blocked\)\n\{\n)(.*?)(\n\};?\n)", s, re.S)
    if not m:
        raise SystemExit("bluezqt-ios-fixes.sh: RfkillThread::doSetSoftBlocked not found")
    s = s.replace(m.group(0), m.group(1) + "#ifdef Q_OS_LINUX\n" + m.group(2) + "\n#else\n    Q_UNUSED(blocked) // " + marker + "\n#endif" + m.group(3), 1)
    p.write_text(s)
PY
