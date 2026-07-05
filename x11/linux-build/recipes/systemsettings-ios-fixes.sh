#!/usr/bin/env bash
# systemsettings-ios-fixes.sh - source trims for System Settings on Xios.
set -euo pipefail

src=${1:?usage: systemsettings-ios-fixes.sh <systemsettings-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("ki18n_install(po)", "# ios-bringup-no-linguist: ki18n_install(po)")
text = text.replace("    add_subdirectory(doc)", "    # ios-bringup-no-docs: add_subdirectory(doc)")
text = text.replace("    kdoctools_install(po)", "    # ios-bringup-no-docs: kdoctools_install(po)")
path.write_text(text)
PY
