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

# Kate (and only Kate) forks itself into the background before it creates the
# QApplication: apps/kate/main.cpp sets detach=true unless one of
# -b/--block/-i/--stdin/-v/--version/-h/--help is on the command line, and then
# KateApp::initPreApplicationCreation(detach) calls daemon(1, 0).
#
# On Darwin that is fatal. daemon() forks and the PARENT _exit(0)s at once, so
# the kate we launched returns 0 immediately, and the child gets stdin, stdout
# and stderr replaced by /dev/null -- which is why the process prints literally
# nothing, not even SingleApplication's unconditional "SingleApplication is not
# supported on Android and iOS systems" qWarning, and why WAYLAND_DEBUG=1 shows
# no protocol lines at all. The orphaned fork-without-exec child then cannot
# bring a window up on Darwin, so nothing ever appears. Upstream already
# excludes macOS from this block for exactly that reason ("fork without exec not
# supported on macOS, will just crash"); iOS is the same kernel and needs the
# same exclusion.
#
# The tell that isolates this to detach: kate --version and kate --help are the
# invocations that set detach=false, and they are the only ones that work, while
# kwrite -- same tarball, same recipe -- passes false /* never detach */ in
# apps/kwrite/main.cpp and works. --new does not suppress detach, which is why
# it changed nothing.
python3 - "$src/apps/lib/kateapp.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
MARKER = "// ios: never daemonize"
if MARKER not in text:
    old = "#if !defined(Q_OS_MACOS) && defined(HAVE_DAEMON)\n"
    new = (
        "    " + MARKER + " -- daemon() forks without exec, the parent exits 0\n"
        "    // instantly, and the child loses stdout/stderr to /dev/null and cannot open a\n"
        "    // window on Darwin. Upstream skips this on macOS for the same reason.\n"
        "#if !defined(Q_OS_MACOS) && !defined(Q_OS_IOS) && defined(HAVE_DAEMON)\n"
    )
    if old not in text:
        raise SystemExit("kate-ios-fixes.sh: daemon() detach guard not found")
    text = text.replace(old, new, 1)
    path.write_text(text)
PY
