#!/bin/sh
# Device-side control for the Jarvis daemon. iOS/rootless has no pkill/pgrep, so
# we find PIDs with ps+awk and kill by number. Run on the iPad.
#   sh jarvisctl.sh {start|stop|restart|status}
JDIR=/var/jb/var/root/jarvis
BUN=/var/jb/usr/bin/bun
CONSOLE="$JDIR/public/console.html"
LOG="$JDIR/jarvis.log"
LABEL=com.max.jarvis

pids() { ps ax | awk '/[b]un server[.]js/ { print $1 }'; }
supervisor_pids() { ps ax | awk '/jarvis-supervisor[.]sh/ && $0 !~ /jarvisctl[.]sh/ && $0 !~ /awk/ { print $1 }'; }
service() {
  launchctl print "user/501/$LABEL" >/dev/null 2>&1 && { echo "user/501/$LABEL"; return; }
  launchctl print "system/$LABEL" >/dev/null 2>&1 && echo "system/$LABEL"
}
stop() { for p in $(pids); do kill -9 "$p" 2>/dev/null; done; }

case "${1:-restart}" in
  launch)
    exec /var/jb/usr/bin/sh "$JDIR/jarvis-supervisor.sh"
    ;;
  stop) stop; echo "stopped" ;;
  status)
    echo "supervisors=$(supervisor_pids | wc -l | tr -d ' ')"
    supervisor_pids
    echo "instances=$(pids | wc -l | tr -d ' ')"
    pids
    ;;
  start)
    svc="$(service)"
    if [ -n "$svc" ]; then
      launchctl kickstart -k "$svc" 2>/dev/null || true
      sleep 2
      echo "instances=$(pids | wc -l | tr -d ' ')"
      grep -E 'Jarvis console|EADDRINUSE' "$LOG" | head -2
      exit 0
    fi
    sleep 1
    cd "$JDIR" || exit 1
    JARVIS_CONSOLE="$CONSOLE" nohup "$BUN" server.js </dev/null >jarvis.log 2>&1 &
    sleep 2
    echo "instances=$(pids | wc -l | tr -d ' ')"
    grep -E 'Jarvis console|EADDRINUSE' "$LOG" | head -2
    ;;
  restart|*)
    svc="$(service)"
    if [ -n "$svc" ]; then
      launchctl kickstart -k "$svc" 2>/dev/null || true
      sleep 2
      echo "instances=$(pids | wc -l | tr -d ' ')"
      grep -E 'Jarvis console|EADDRINUSE' "$LOG" | head -2
      exit 0
    fi
    stop
    sleep 1
    cd "$JDIR" || exit 1
    JARVIS_CONSOLE="$CONSOLE" nohup "$BUN" server.js </dev/null >jarvis.log 2>&1 &
    sleep 2
    echo "instances=$(pids | wc -l | tr -d ' ')"
    grep -E 'Jarvis console|EADDRINUSE' "$LOG" | head -2
    ;;
esac
