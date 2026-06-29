#!/usr/bin/env bash
# Fast dev loop: build a tweak for the iOS Simulator and load it via simject.
# Usage: bin/sim.sh [tweak-dir]   (defaults to current dir)
#
# This is the device-free front half of the loop. It builds your tweak for the
# Simulator target, drops the .dylib + filter .plist into /opt/simject, and
# runs `resim` to reload. Your %hooks then run against the iOS frameworks inside
# the running Simulator.
#
# NOT a substitute for the device: there's no real jailbreak/SpringBoard here,
# and some frameworks are missing in the sim. Use this to iterate on logic, then
# `bin/install.sh` to confirm on MaxsiPad. See README "iOS Simulator loop".
#
# One-time setup required (see README): install simject + simulator Substrate.
#
# This machine is Apple Silicon, so the Simulator is arm64 (ignore old x86_64
# guides). We override the tweak's device build settings on the command line:
#   TARGET=simulator:clang::12.0  ARCHS=arm64  THEOS_PACKAGE_SCHEME=(empty)
set -euo pipefail

export THEOS="${THEOS:-$HOME/theos}"
# Prefer Homebrew's GNU Make 4.x (`gmake`) over macOS's 3.81 (`make`) so Theos
# parallelizes the build across all cores. Falls back to `make` if absent.
MAKE="$(command -v gmake || echo make)"
SIMJECT_DIR="/opt/simject"

command -v resim >/dev/null 2>&1 || {
  echo "error: 'resim' not found — simject isn't installed yet." >&2
  echo "       Install it once (see README 'iOS Simulator loop'):" >&2
  echo "         git clone https://github.com/akemin-dayo/simject.git" >&2
  echo "         cd simject && make setup && ./installsubstrate.sh subst" >&2
  exit 1
}
[ -d "$SIMJECT_DIR" ] || {
  echo "error: $SIMJECT_DIR missing — run simject's 'make setup' first." >&2
  exit 1
}

DIR="${1:-.}"
[ -f "$DIR/Makefile" ] || { echo "error: no Makefile in '$DIR'" >&2; exit 1; }
cd "$DIR"

echo "==> Building $(basename "$PWD") for the Simulator (arm64)"
# Switching between the iphone and simulator targets reuses .theos/obj, so a
# clean is required or you'll link stale device objects into the sim dylib.
"$MAKE" clean >/dev/null 2>&1 || true
"$MAKE" TARGET='simulator:clang::12.0' ARCHS='arm64' THEOS_PACKAGE_SCHEME=

# Theos drops the built dylib somewhere under .theos/obj (path varies by version,
# e.g. .theos/obj/simulator/ or .theos/obj/iphone_simulator/). Find it — but skip
# the identically-named copy inside the .dSYM debug bundle.
DYLIB="$(find .theos/obj -name '*.dylib' -type f -not -path '*.dSYM/*' 2>/dev/null | head -1)"
[ -n "$DYLIB" ] || { echo "error: no .dylib produced — check build output above" >&2; exit 1; }
NAME="$(basename "$DYLIB" .dylib)"
PLIST="$NAME.plist"
[ -f "$PLIST" ] || { echo "error: filter plist '$PLIST' not found next to Makefile" >&2; exit 1; }

echo "==> Loading '$NAME' into simject ($SIMJECT_DIR)"
# simject silently skips a tweak whose .plist is missing, so copy both.
cp -f "$DYLIB" "$SIMJECT_DIR/$NAME.dylib"
cp -f "$PLIST" "$SIMJECT_DIR/$NAME.plist"

# CRITICAL: re-sign the dylib LAST, on the final on-disk bytes. Theos signs
# during the build, but its post-link fixups leave that signature stale. The
# Simulator enforces real code signing on Apple Silicon, so a stale signature =
# kernel kills the host (SpringBoard) with an "Invalid Page" / Code Signature
# Invalid SIGKILL → respring loop. An ad-hoc re-sign here matches the real bytes.
codesign --force --sign - --timestamp=none "$SIMJECT_DIR/$NAME.dylib"

echo "==> Reloading the Simulator (resim)"
# No args = respring whichever single Simulator is booted. With more than one
# booted, target a specific one:  resim -i <UUID>   (or:  resim -d "iPad ..." -v 18.2)
resim
echo "==> Done. (Re-run 'resim' after a Simulator reboot or SpringBoard crash.)"
