#!/usr/bin/env bash
# Print the normalized values for a target descriptor.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/target-lib.sh"

xios_load_target "${1:-${XIOS_TARGET:-rootless-1900}}"
xios_print_target
