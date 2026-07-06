#!/usr/bin/env bash
# Single source of truth for the xios-session ship manifest.
#
# Both consumers source this file so the deb and the scp fast path can never
# diverge:
#   package-session.sh        stage_session_files "$PAYLOAD_ROOT"
#   install-xios-session.sh   session_manifest drives mkdir/scp/chmod
#
# To ship a new file (or move one), edit ONLY the table in session_manifest.

_SF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SF_REPO_ROOT="$(cd "$_SF_HERE/../../.." && pwd)"
_SF_WAYLAND="$_SF_REPO_ROOT/x11/wayland"
_SF_SHELLDIR="$_SF_REPO_ROOT/x11/apps/iosc-shell"

# Prints one line per shipped file:  <abs source>\t<dest relative to target payload root>\t<mode>
# The script entries are reused copies of the REAL bring-up scripts (see
# xios-session-lib.sh): they live in our libexec so the presets resolve even if
# iosc-shell / the dev tree aren't the ones that installed them. GNOME is
# launched by launch-gnome-session.sh from xios-session-stubs, not by this
# package.
session_manifest() {
  printf '%s\t%s\t%s\n' \
    "$_SF_HERE/xios-session"                usr/local/bin/xios-session                        0755 \
    "$_SF_HERE/xios-start-a11y"             usr/local/bin/xios-start-a11y                     0755 \
    "$_SF_HERE/xios-session-lib.sh"         libexec/xios-session/xios-session-lib.sh          0644 \
    "$_SF_HERE/xios-capability-profiles.sh" libexec/xios-session/xios-capability-profiles.sh 0755 \
    "$_SF_SHELLDIR/run-shell.sh"            libexec/xios-session/run-shell.sh                 0755 \
    "$_SF_WAYLAND/run-mutter.sh"            libexec/xios-session/run-mutter.sh                0755 \
    "$_SF_WAYLAND/run-kde-plasma.sh"        libexec/xios-session/run-kde-plasma.sh            0755
}

# stage_session_files <root> — populate <root> (the target payload root)
# with the manifest at the right relative paths + modes.
stage_session_files() {
  local root="$1" src dst mode
  while IFS=$'\t' read -r src dst mode; do
    mkdir -p "$root/$(dirname "$dst")"
    cp "$src" "$root/$dst"
    chmod "$mode" "$root/$dst"
  done < <(session_manifest)
}
