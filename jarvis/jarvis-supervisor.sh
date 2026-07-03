#!/bin/sh
# launchd keeps this small supervisor alive. It starts the Bun daemon only when
# Jarvis is enabled and outside quiet hours.
JDIR=/var/jb/var/root/jarvis
BUN=/var/jb/usr/bin/bun
PREF=/var/mobile/Library/Preferences/com.max.jarvis.plist
CONSOLE="$JDIR/public/console.html"
LOG="$JDIR/jarvis.log"

pids() { ps ax | awk '/[b]un server[.]js/ { print $1 }'; }

stop_server() {
  for p in $(pids); do kill -9 "$p" 2>/dev/null; done
}

start_server() {
  if [ "$(pids | wc -l | tr -d ' ')" != "0" ]; then return; fi
  cd "$JDIR" || exit 1
  JARVIS_CONSOLE="$CONSOLE" "$BUN" server.js >>"$LOG" 2>&1 &
}

load_prefs() {
  eval "$(/var/jb/usr/bin/python3 - "$PREF" <<'PY'
import os, plistlib, shlex, sys

path = sys.argv[1]
data = {}
if os.path.exists(path):
    try:
        with open(path, "rb") as f:
            data = plistlib.load(f)
    except Exception:
        data = {}

def b(key, default):
    value = data.get(key, default)
    if isinstance(value, str):
        value = value.lower() not in ("0", "false", "no", "off")
    return "1" if bool(value) else "0"

def s(key, default):
    value = data.get(key, default)
    return shlex.quote(str(value))

print("ENABLED=" + b("enabled", True))
print("QUIET_ENABLED=" + b("quietEnabled", False))
print("QUIET_START=" + s("quietStart", "23:00"))
print("QUIET_END=" + s("quietEnd", "07:00"))
PY
)"
}

minutes() {
  echo "$1" | awk -F: '
    /^[0-9][0-9]?:[0-9][0-9]$/ {
      h=$1 + 0; m=$2 + 0;
      if (h >= 0 && h < 24 && m >= 0 && m < 60) { print h * 60 + m; exit 0; }
    }
    { print -1 }
  '
}

in_quiet_hours() {
  [ "${QUIET_ENABLED:-0}" = "1" ] || return 1
  now="$(date +%H:%M | awk -F: '{ print ($1 + 0) * 60 + ($2 + 0) }')"
  start="$(minutes "${QUIET_START:-23:00}")"
  end="$(minutes "${QUIET_END:-07:00}")"
  [ "$start" -ge 0 ] && [ "$end" -ge 0 ] || return 1
  [ "$start" = "$end" ] && return 1
  if [ "$start" -lt "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
  else
    [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
  fi
}

prefs_mtime() {
  [ -e "$PREF" ] && stat -f %m "$PREF" 2>/dev/null || echo 0
}

trap 'stop_server; exit 0' INT TERM

last_mtime="$(prefs_mtime)"

while true; do
  load_prefs
  current_mtime="$(prefs_mtime)"
  prefs_changed=0
  if [ "$current_mtime" != "$last_mtime" ]; then
    prefs_changed=1
    last_mtime="$current_mtime"
  fi

  if [ "${ENABLED:-1}" = "1" ] && ! in_quiet_hours; then
    if [ "$prefs_changed" = "1" ] && [ "$(pids | wc -l | tr -d ' ')" != "0" ]; then
      stop_server
    fi
    start_server
  else
    stop_server
  fi
  sleep "${JARVIS_SUPERVISOR_INTERVAL:-60}"
done
