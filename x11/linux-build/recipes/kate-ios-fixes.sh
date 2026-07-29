#!/usr/bin/env bash
# kate source surgery for iOS. See kate.mk.
set -euo pipefail
src=${1:?usage: kate-ios-fixes.sh /path/to/kate-source}

# Kate builds without WITH_DBUS here, so main() takes the SingleApplication
# branch for single-instance handling. SingleApplication's own constructor
# returns EARLY on iOS -- it prints "SingleApplication is not supported on
# Android and iOS systems" and never creates its local server -- and
# isSecondary() is just `d->server == nullptr`, so it answers TRUE forever.
# Kate therefore believes it is a secondary instance on every launch, tries to
# hand its URLs to a primary that does not exist, and returns from main without
# ever creating a window. Symptom: the process starts, prints nothing, opens no
# Wayland surface at all, and exits.
#
# On iOS there can be no primary to talk to, so the process is always the
# primary. Skip the hand-off branch and let kate build its window.
python3 - "$src/apps/kate/main.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
MARKER = "// ios: SingleApplication cannot work here"
if MARKER not in text:
    old = "    if (!force_new && app.isSecondary()) {\n"
    new = (
        "#if defined(Q_OS_IOS)\n"
        "    " + MARKER + " (its ctor returns early and\n"
        "    // isSecondary() is then permanently true), so this process is always the\n"
        "    // primary. Taking the hand-off branch exits before any window is created.\n"
        "    if (false) {\n"
        "#else\n"
        "    if (!force_new && app.isSecondary()) {\n"
        "#endif\n"
    )
    if old not in text:
        raise SystemExit("kate-ios-fixes.sh: isSecondary hand-off branch not found")
    text = text.replace(old, new, 1)
    path.write_text(text)
PY
