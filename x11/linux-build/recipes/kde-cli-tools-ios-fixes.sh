#!/usr/bin/env bash
# kde-cli-tools-ios-fixes.sh — source trims for kde-cli-tools on Xios/iOS.
#
# Two classes of fix, nothing else:
#
#   1. DocTools. kde-cli-tools lists KF6DocTools in its REQUIRED find_package
#      component list, so -DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE alone
#      turns into a hard configure error instead of a graceful skip. Drop the
#      component, the doc/ subdirectory, and kdoctools_install(po). ki18n_install(po)
#      goes with them: no target Linguist in this bring-up stack (milou.mk:16,
#      plasma-desktop-ios-fixes.sh:472 precedent).
#
#   2. MACOSX_BUNDLE. The iOS cmake toolchain defaults CMAKE_MACOSX_BUNDLE=ON, so
#      every un-marked executable becomes <name>.app/<name> and ECM routes it to the
#      BUNDLE DESTINATION (/Applications/KDE), which KF6_COPY_RUNTIME never packages
#      — the binary silently vanishes from the deb. Same landmine as kiod6 (kio.mk:21)
#      and kscreen-doctor (libkscreen-ios-fixes.sh:214-238). Upstream already calls
#      ecm_mark_nongui_executable() on kdemv, kdecp, kmimetypefinder and ksvgtopng
#      (that helper sets MACOSX_BUNDLE FALSE); the GUI-capable ones are not marked,
#      because on a real desktop a bundle is the right answer. Here it is not, and
#      install_compat_symlink() would also point its <name>5 symlink at a path that
#      no longer holds a binary. Force them all to plain binaries in usr/bin.
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
    if anchor not in text:
        raise SystemExit(f"{target}: add_executable line not found in {rel}")
    text = text.replace(anchor, f"{anchor}\n{fix}", 1)
    path.write_text(text)
PY
