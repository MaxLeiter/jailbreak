#!/usr/bin/env bash
# kscreen-ios-fixes.sh - KScreen source trims and Apple guards for Xios.
set -euo pipefail

src=${1:?usage: kscreen-ios-fixes.sh <kscreen-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Test Sensors)",
    "find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Sensors)",
)
import re
# Qt6Test is not staged (FEATURE_testlib=OFF): drop it from any Qt6 find_package component list.
text = re.sub(r"(find_package\(Qt6 [^)]*?)\bTest\s+", r"\1", text)
text = text.replace("add_subdirectory(tests)", "# ios: tests are disabled in the cross build\n# add_subdirectory(tests)")
text = text.replace("include(KDEGitCommitHooks)", "# ios: source tarball build, no git hooks\n#include(KDEGitCommitHooks)")
text = text.replace("kde_configure_git_pre_commit_hook(CHECKS CLANG_FORMAT)", "# ios: no git hook in cross build")
text = text.replace("ki18n_install(po)", "# ios-bringup-no-linguist: ki18n_install(po)")
path.write_text(text)
PY

python3 - "$src/osd/osd.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n" not in text:
    text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
import re
# Wrap the X11-only else-branch (KX11Extras) in HAVE_X11. Regex so the 6.1 and 6.7 bodies (which differ in
# setVisible/setGeometry ordering) both match; a missing anchor is a hard failure.
if "#if defined(HAVE_X11) && HAVE_X11\n    else {" not in text:
    m = re.search(r"    \} else \{\n(        auto newGeometry.*?requestActivate\(\);\n)    \}\n", text, re.S)
    if not m:
        raise SystemExit("KScreen OSD platform block not found")
    text = text.replace(m.group(0), "    }\n#if defined(HAVE_X11) && HAVE_X11\n    else {\n" + m.group(1) + "    }\n#endif\n", 1)
path.write_text(text)
PY
