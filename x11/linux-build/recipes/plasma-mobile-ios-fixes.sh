#!/usr/bin/env bash
# plasma-mobile-ios-fixes.sh — first-light trims for Plasma Mobile on iOS.
set -euo pipefail

src=${1:?usage: plasma-mobile-ios-fixes.sh <plasma-mobile-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

text = text.replace("    ModemManagerQt\n    NetworkManagerQt\n", "")
for old, new in [
    ("find_package(KF6Screen CONFIG REQUIRED)", "find_package(KF6Screen CONFIG)"),
    ("find_package(KF6KirigamiAddons 0.6 REQUIRED)", "find_package(KF6KirigamiAddons 0.6)"),
    ("find_package(XCB REQUIRED COMPONENTS XCB)", "find_package(XCB COMPONENTS XCB)"),
    ("find_package(Libudev REQUIRED)", "find_package(Libudev)"),
    ("    TYPE REQUIRED\n    PURPOSE \"Needed for virtual keyboard toggle button\"", "    TYPE OPTIONAL\n    PURPOSE \"Needed for virtual keyboard toggle button\""),
]:
    text = text.replace(old, new)

keep = {"bin", "components", "containments", "quicksettings"}

def subdir_repl(match: re.Match[str]) -> str:
    name = match.group(1)
    if name in keep:
        return match.group(0)
    return f"# ios-firstlight-skip: {match.group(0)}"

text = re.sub(r"^add_subdirectory\(([^)]+)\)", subdir_repl, text, flags=re.M)
text = re.sub(r"^ki18n_install\(po\)", "# ios-firstlight-skip: ki18n_install(po)", text, flags=re.M)
path.write_text(text)
PY

# Keep the QML plugin family needed by the mobile shell/homescreen, while
# skipping the modem and wallpaper service plugins that need later bridge work.
python3 - "$src/components/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
keep = {
    "hapticsplugin",
    "mobileshell",
    "mobileshellstate",
    "quicksettingsplugin",
    "windowplugin",
    "shellsettingsplugin",
}
text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) in keep else f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
path.write_text(text)
PY

# Keep mostly data/package installs in this first-light wave. The matching C++
# applet/plugin backends mostly need the next support-library wave or device
# services; the taskpanel applet plugin is small enough to keep.
python3 - "$src/containments/panel/CMakeLists.txt" "$src/containments/taskpanel/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

for arg in sys.argv[1:]:
    path = Path(arg)
    text = path.read_text()
    text = re.sub(r"(?ms)^set\(.*?^install\(TARGETS .*?\n", "# ios-firstlight-skip: C++ containment plugin\n", text)
    path.write_text(text)
PY

python3 - "$src/containments/homescreens/halcyon/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

for arg in sys.argv[1:]:
    path = Path(arg)
    text = path.read_text()
    text = re.sub(r"(?ms)^set\(.*?^install\(TARGETS .*?\n", "# ios-firstlight-skip: C++ homescreen plugin\n", text)
    text = re.sub(r"^add_subdirectory\(plugin\)", "# ios-firstlight-skip: add_subdirectory(plugin)", text, flags=re.M)
    path.write_text(text)
PY

for dir in flashlight nightcolor powermenu screenshot screenrotation; do
  cmake="$src/quicksettings/$dir/CMakeLists.txt"
  [ -f "$cmake" ] || continue
  python3 - "$cmake" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"(?ms)^.*?plasma_install_package\(", "plasma_install_package(", text, count=1)
path.write_text(text)
PY
done
