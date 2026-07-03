#!/usr/bin/env bash
# Shared device-deploy environment for the lead-run scripts in this directory
# (install-ioscd.sh, install-xios-session.sh, gen-launchers.sh --deploy).
#
# device.env (repo root, gitignored) provides THEOS_DEVICE_IP / THEOS_DEVICE_PORT.
# Sets IP/PORT/KEY/SSH_OPTS and the ssh_/scp_ helpers. BatchMode=yes: these are
# non-interactive scripts, so fail fast instead of hanging on a password prompt.

_DE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DE_REPO_ROOT="$(cd "$_DE_HERE/../../.." && pwd)"
[ -f "$_DE_REPO_ROOT/device.env" ] && { set -a; . "$_DE_REPO_ROOT/device.env"; set +a; }
IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"; PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_CONNECT_TIMEOUT="${SSH_CONNECT_TIMEOUT:-8}"
SSH_SERVER_ALIVE_INTERVAL="${SSH_SERVER_ALIVE_INTERVAL:-5}"
SSH_SERVER_ALIVE_COUNT_MAX="${SSH_SERVER_ALIVE_COUNT_MAX:-2}"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout="$SSH_CONNECT_TIMEOUT"
  -o ServerAliveInterval="$SSH_SERVER_ALIVE_INTERVAL"
  -o ServerAliveCountMax="$SSH_SERVER_ALIVE_COUNT_MAX"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -i "$KEY"
)
ssh_() { ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" "$@"; }
scp_() { scp -P "$PORT" "${SSH_OPTS[@]}" "$@"; }
