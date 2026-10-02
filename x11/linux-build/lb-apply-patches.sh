#!/usr/bin/env bash
# Apply the Ladybird iOS patch series (m0 + app) to the rebase source tree without building.
set -euo pipefail
LB_SUFFIX="${LB_SUFFIX--r2}"
LB_APP_BUILD=1 bash /work/recipes-ladybird/ladybird-m0-patches.sh "/work/Procursus/ladybird-src$LB_SUFFIX"
