#!/usr/bin/env bash
# Build a tweak's .deb. Usage: bin/build.sh [tweak-dir]
# Defaults to the current directory if it contains a Makefile.
set -euo pipefail

export THEOS="${THEOS:-$HOME/theos}"

# Prefer a modern GNU Make (4.x). macOS ships GNU Make 3.81 as `make`; Homebrew's
# is `gmake`. Under make 4.x Theos auto-enables `-j<ncores> -Otarget`, so the
# build uses every core (see $THEOS/makefiles/master/rules.mk). No -j needed here.
MAKE="$(command -v gmake || echo make)"

DIR="${1:-.}"
if [ ! -f "$DIR/Makefile" ]; then
  echo "error: no Makefile in '$DIR'. Pass a tweak directory, e.g. bin/build.sh tweaks/HelloWorld" >&2
  exit 1
fi

cd "$DIR"
echo "==> Building $(basename "$PWD") with THEOS=$THEOS ($("$MAKE" --version | head -1))"
"$MAKE" clean >/dev/null 2>&1 || true
"$MAKE" package FINALPACKAGE=1
echo "==> Done. Package(s):"
ls -1 packages/*.deb 2>/dev/null || echo "(no .deb found — check build output above)"
