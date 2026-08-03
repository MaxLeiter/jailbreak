#!/usr/bin/env bash
# Collect device evidence for the App Intents + share-sheet integration
# (see docs/handoff/xios-app.md, "2026-08-03 iPadOS system integration").
#
#   x11/apps/Xios/verify-integration.sh [tag]
#
# Everything this collects is READ-ONLY except the optional --install, which
# dpkg -i's the locally built com.max.xios. It never publishes.
#
# The parts a script CANNOT do are listed at the end: invoking Siri, tapping a
# Shortcut, and doing a real share from Safari are physical acts. Run those, then
# re-run this to capture the resulting log lines.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
. "$REPO_ROOT/x11/apps/iosc-desktop/deploy-env.sh"

TAG="${1:-xios-integration}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO_ROOT/x11/artifacts/device-runs/${TAG}-${STAMP}"
mkdir -p "$OUT"

echo "==> evidence -> $OUT"

if ! ssh_ true 2>/dev/null; then
    echo "error: device unreachable at $IP:$PORT." >&2
    echo "       Wake the screen, confirm Wi-Fi, or plug in USB. device.env sets the host." >&2
    exit 1
fi

say() { echo; echo "== $1"; }

# --- what is installed -------------------------------------------------------
say "installed packages"
ssh_ 'dpkg-query -W -f="\${Package} \${Version}\n" com.max.xios iosc xios-session 2>&1' \
    | tee "$OUT/packages.txt"

# --- does the app bundle actually contain the extension ----------------------
say "app bundle layout"
ssh_ 'APP=/var/jb/Applications/Xios.app; ls -la "$APP/PlugIns/" 2>&1;
      echo "--- appex binary ---";
      ls -la "$APP/PlugIns/XiosShare.appex/XiosShare" 2>&1;
      echo "--- appintents metadata ---";
      ls -la "$APP/Metadata.appintents/" 2>&1' | tee "$OUT/bundle-layout.txt"

# An .appex that is 0644, or missing, is the silent-failure mode the packaging
# fix exists to prevent — call it out rather than burying it in the log.
if grep -q "PlugIns.*No such file" "$OUT/bundle-layout.txt" 2>/dev/null; then
    echo "!! WARNING: no PlugIns dir on device — the installed build predates the extension"
fi

# --- the gating question: appex sandbox --------------------------------------
say "share-extension sandbox probe result"
# XiosSandboxProbe writes this on every share attempt. Absent = the extension has
# not run yet (do a real share from Safari first).
ssh_ 'cat /var/jb/tmp/xios-share-probe.txt 2>&1' | tee "$OUT/appex-sandbox-probe.txt"

# --- control-path state ------------------------------------------------------
say "session status"
ssh_ 'cat /var/jb/tmp/xios-session-status.json 2>&1' | tee "$OUT/session-status.json"

say "runtime status table"
ssh_ '/var/jb/usr/local/bin/xios-status 2>&1' | tee "$OUT/xios-status.txt"

say "ioscd socket"
ssh_ 'ls -la /var/jb/tmp/ioscd.sock 2>&1' | tee "$OUT/ioscd-sock.txt"

# --- is there an xdg-open for OPEN_URL to use --------------------------------
say "xdg-open availability (OPEN_URL depends on it)"
ssh_ 'ls -la /var/jb/usr/bin/xdg-open 2>&1;
      echo "--- must be root-owned and not group/other writable ---"' \
    | tee "$OUT/xdg-open.txt"

# --- exercise OPEN_URL from root (proves the verb, not the appex) ------------
# Deliberately separate from the share test: this shows the DAEMON side works
# even if the extension turns out to be sandboxed away from the socket.
say "OPEN_URL round-trip from the device shell"
ssh_ 'printf "OPEN_URL\thttps://example.com\n" | nc -U /var/jb/tmp/ioscd.sock 2>&1' \
    | tee "$OUT/open-url-reply.txt"

say "OPEN_URL rejects a disallowed scheme (invariant check)"
ssh_ 'printf "OPEN_URL\tjavascript:alert(1)\n" | nc -U /var/jb/tmp/ioscd.sock 2>&1' \
    | tee "$OUT/open-url-rejected.txt"

# --- ioscd log, which records the peer path per request ----------------------
say "ioscd log tail (peer attribution for SESSION / OPEN_URL)"
ssh_ 'tail -120 /var/jb/tmp/ioscd.log 2>&1' | tee "$OUT/ioscd.log"

echo
echo "==> collected to $OUT"
cat <<'MANUAL'

STILL MANUAL — these need a human at the device:
  1. Shortcuts app -> does "Open Desktop" / "Open App on Desktop" /
     "Desktop Status" appear under Xios? Screenshot it.
  2. Say "Hey Siri, <phrase>". Phrase matching is the unverified bit: the build
     ships no nlu/ training payload.
  3. Safari -> Share -> "Open on Desktop". Read the verdict line in the sheet;
     that is the appex sandbox answer. Screenshot it.
  4. With a DIFFERENT healthy desktop up (e.g. KDE), run the "Open Desktop"
     shortcut with flavor=gnome. It must actually switch, not answer
     "active session is healthy" — that is the in-process-intent design holding.

Then re-run this script to capture the log lines those produced, and drop the
screenshots into the same directory.
MANUAL
