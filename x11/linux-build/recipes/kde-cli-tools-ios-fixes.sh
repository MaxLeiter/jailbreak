#!/usr/bin/env bash
# 1. DocTools: -DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE alone is a hard
#    configure error here (DocTools is in the REQUIRED component list), so
#    drop the component along with doc/, kdoctools_install(po), and
#    ki18n_install(po) (no Linguist target in this bring-up stack).
#
# 2. MACOSX_BUNDLE: the iOS cmake toolchain defaults CMAKE_MACOSX_BUNDLE=ON,
#    so unmarked executables become <name>.app/<name> and ECM routes them to
#    the BUNDLE destination, which KF6_COPY_RUNTIME never packages, so the
#    binary silently vanishes from the deb. Upstream already marks kdemv,
#    kdecp, kmimetypefinder, and ksvgtopng nongui; force the rest to plain
#    usr/bin binaries too.
set -euo pipefail

src=${1:?usage: kde-cli-tools-ios-fixes.sh <kde-cli-tools-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

old_components = "    Config\n    DocTools\n    IconThemes\n"
new_components = "    Config\n    IconThemes\n"
if old_components in text:
    text = text.replace(old_components, new_components, 1)
elif "    DocTools\n" in text:
    raise SystemExit("kde-cli-tools KF6 component block not in the expected shape")

for old, new in [
    ("add_subdirectory(doc)\n", "# ios-bringup-no-docs: add_subdirectory(doc)\n"),
    ("kdoctools_install(po)\n", "# ios-bringup-no-docs: kdoctools_install(po)\n"),
    ("ki18n_install(po)\n", "# ios-bringup-no-linguist: ki18n_install(po)\n"),
]:
    if old in text:
        text = text.replace(old, new, 1)

path.write_text(text)
PY

python3 - "$src" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])

# (relative CMakeLists, target expression, add_executable anchor)
targets = [
    ("kioclient/CMakeLists.txt", "${TARGET_NAME}", "add_executable(${TARGET_NAME} kioclient.cpp)"),
    ("kioclient/CMakeLists.txt", "kde-open", "add_executable(kde-open kioclient.cpp)"),
    ("keditfiletype/CMakeLists.txt", "keditfiletype", "add_executable(keditfiletype ${keditfiletype_SRCS})"),
    ("kstart/CMakeLists.txt", "kstart", "add_executable(kstart kstart.cpp)"),
    ("plasma-open-settings/CMakeLists.txt", "plasma-open-settings", "add_executable(plasma-open-settings main.cpp)"),
    ("kdeinhibit/CMakeLists.txt", "kde-inhibit", "add_executable(kde-inhibit main.cpp)"),
    ("kbroadcastnotification/CMakeLists.txt", "kbroadcastnotification", "add_executable(kbroadcastnotification main.cpp)"),
]

for rel, target, anchor in targets:
    path = src / rel
    text = path.read_text()
    fix = f"set_target_properties({target} PROPERTIES MACOSX_BUNDLE FALSE)"
    if fix in text:
        continue
    import re
    # exact anchor first; else any add_executable(<target> ...) line (6.7 appended header names to the lists).
    if anchor in text:
        found = anchor
    else:
        m = re.search(r"^[ \t]*add_executable\(" + re.escape(target) + r"(?=[\s)])[^\n]*\)[ \t]*$", text, re.M)
        if not m:
            raise SystemExit(f"{target}: add_executable line not found in {rel}")
        found = m.group(0).strip()
    text = text.replace(found, f"{found}\n{fix}", 1)
    path.write_text(text)
PY

# 6.7 relies on Qt6::DBus arriving transitively (Linux-only deps); give every target its headers.
python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "xios: Qt6::DBus for every target" not in text:
    new = re.sub(r"^(project\([^)]*\)\n)", r"\1link_libraries(Qt6::DBus) # xios: Qt6::DBus for every target\n", text, count=1, flags=re.M)
    if new == text:
        raise SystemExit("kde-cli-tools project() line not found")
    path.write_text(new)
PY
