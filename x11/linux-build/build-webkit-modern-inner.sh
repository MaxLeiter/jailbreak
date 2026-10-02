#!/usr/bin/env bash
# Container side of build-webkit-modern.sh. Sources the opt-in clang-19 env, stages the 2.54 patch
# stack, then hands the requested TARGETS to the shared build-gnome.sh driver.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
. /work/tools/xios-clang19-env.sh
xios_clang19_setup
cd /work/Procursus
mkdir -p makefiles build_patch build_tools
cp -v /work/recipes/*.mk makefiles/
bash /work/recipes/stage-port-patches.sh webkitgtk-modern /work/ports build_patch
export JOBS="${JOBS:-6}" WEBKIT_NINJA_JOBS="${WEBKIT_NINJA_JOBS:-6}"
exec bash /work/build-gnome.sh
