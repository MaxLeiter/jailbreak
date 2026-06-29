#!/usr/bin/env bash
# Live device console over USB (no SSH required) via libimobiledevice.
# Usage:
#   bin/logs.sh            # stream everything
#   bin/logs.sh HelloWorld # only lines containing "HelloWorld"
set -euo pipefail

if ! command -v idevicesyslog >/dev/null 2>&1; then
  echo "error: idevicesyslog not found. Install with: brew install libimobiledevice" >&2
  exit 1
fi

FILTER="${1:-}"
if [ -n "$FILTER" ]; then
  echo "==> Streaming device syslog, filtering for: $FILTER  (Ctrl-C to stop)"
  idevicesyslog | grep --line-buffered -i "$FILTER"
else
  echo "==> Streaming full device syslog  (Ctrl-C to stop)"
  idevicesyslog
fi
