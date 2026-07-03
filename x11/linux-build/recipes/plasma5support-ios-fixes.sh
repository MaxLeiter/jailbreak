#!/usr/bin/env bash
# plasma5support-ios-fixes.sh — first-light Plasma5Support cuts for iOS.
set -euo pipefail

src=${1:?usage: plasma5support-ios-fixes.sh <plasma5support-source-dir>}

python3 - "$src/CMakeLists.txt" "$src/src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

top = Path(sys.argv[1])
text = top.read_text()
text = text.replace("find_package(KSysGuard CONFIG REQUIRED) # devicenotifications",
                    "find_package(KSysGuard CONFIG) # devicenotifications")
if "ios-firstlight-no-linguist" not in text:
    text = text.replace(
        "if (IS_DIRECTORY \"${CMAKE_CURRENT_SOURCE_DIR}/po\")\n    ki18n_install(po)\nendif()\n",
        "# ios-firstlight-no-linguist: skip translation install during cross bring-up.\n",
    )
top.write_text(text)

src_cmake = Path(sys.argv[2])
text = src_cmake.read_text()
text = text.replace("add_subdirectory(dataengines)", "# ios-firstlight-skip: add_subdirectory(dataengines)")
src_cmake.write_text(text)
PY
