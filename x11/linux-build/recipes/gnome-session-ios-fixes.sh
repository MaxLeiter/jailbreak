#!/usr/bin/env bash
# gnome-session 46 iOS source-port fixes (idempotent). Applies one consolidated patch that
# makes the session manager build and run on a non-systemd, non-X11-display platform. The
# patch is the FreeBSD-ports non-systemd set (which itself reverts upstream commit
# 76534bcc "Drop consolekit backend and hard depend on systemd"), adapted to the 46.0 tree,
# plus two iOS-specific edits. See docs/gnome-session-plan.md for the full rationale.
#
# What the patch does:
#   1. Re-adds the `systemd` / `systemd_session` / `systemd_journal` / `consolekit` meson
#      options and their HAVE_SYSTEMD / ENABLE_SYSTEMD_SESSION / ENABLE_SYSTEMD_JOURNAL /
#      USE_SYSTEMD_SESSION config.h guards, so `-Dsystemd=false -Dsystemd_session=disable`
#      builds with libsystemd unresolved and no sd_* link edge. main() then falls straight
#      to the classic path: gsm_manager_new(..., FALSE) -> gsm_session_fill() reads
#      RequiredComponents from the .session file -> gsm_manager_start() spawns each
#      component as a child (the XSMP + autostart-.desktop way). A `--builtin` flag is added.
#   2. Retargets the `gnome-desktop-3.0` dependency to `gnome-desktop-4` (we ship only the
#      GTK4/base library; it exports the two symbols gnome-session uses -
#      gnome_idle_monitor_new + gnome_start_systemd_scope - verified in the built dylib).
#   3. Drops the three gnome-session-check-accelerated* helper binaries from tools/. They
#      need desktop GL (gl.pc), GLX and xcomposite - none present on the iOS ANGLE-Metal
#      stack - and are dead code in a Wayland session: main.c:check_gl() returns early when
#      DISPLAY is unset, so the helper is never spawned.
#
# Usage: gnome-session-ios-fixes.sh <gnome-session-source-dir> [<patch-file>]
set -euo pipefail
SRC="${1:?usage: $0 <gnome-session-src-dir> [patch-file]}"
PATCH="${2:-/work/patches/gnome-session/0001-ios-no-systemd.patch}"

if [ ! -f "$PATCH" ]; then
  echo "!! gnome-session-ios-fixes: patch not found: $PATCH" >&2
  exit 1
fi

# Idempotency: the patch adds the `consolekit` meson option; if it is already present the
# tree is patched, so skip (re-applying would --forward-fail on every hunk).
if grep -q "option('consolekit'" "$SRC/meson_options.txt" 2>/dev/null; then
  echo "gnome-session-ios-fixes: already applied (consolekit option present) - skipping"
else
  echo "gnome-session-ios-fixes: applying $PATCH"
  patch -p1 -d "$SRC" < "$PATCH"
fi

# --- verification --------------------------------------------------------------
fail=0
check()  { grep -q "$2" "$SRC/$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
absent() { grep -q "$2" "$SRC/$1" && { echo "!! VERIFY FAILED: $1: still has $2"; fail=1; } || true; }

# systemd made optional + code paths gated
check meson_options.txt "option('systemd'"
check meson.build       "HAVE_SYSTEMD"
check meson.build       "ENABLE_SYSTEMD_SESSION"
check gnome-session/main.c "\"builtin\""
check gnome-session/gsm-systemd.c "#ifdef HAVE_SYSTEMD"
# gnome-desktop retargeted to the GTK4 library we actually ship
check   meson.build "gnome-desktop-4"
absent  meson.build "gnome-desktop-3.0"
# GL accel-check helpers dropped (no desktop gl.pc on iOS)
absent tools/meson.build "gnome-session-check-accelerated-gl-helper"

[ "$fail" = 0 ] && echo "gnome-session-ios-fixes: all patches applied + verified" || exit 1
