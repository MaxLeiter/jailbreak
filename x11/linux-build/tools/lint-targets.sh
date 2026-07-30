#!/usr/bin/env bash
# Lint every target descriptor: it must load, expose the full variable set, and
# satisfy the invariants the build and packaging scripts rely on.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LB="$(cd "$HERE/.." && pwd)"
. "$LB/target-lib.sh"

fail=0
note() { echo "  !! $1"; fail=1; }

for env_file in "$LB"/targets/*.env; do
  id="$(basename "$env_file" .env)"
  echo "== $id"

  if ! ( xios_load_target "$id" ) >/dev/null 2>&1; then
    note "does not load"
    xios_load_target "$id" || true
    continue
  fi
  # shellcheck disable=SC1090
  ( set -e
    xios_load_target "$id"

    for key in XIOS_TARGET_ID XIOS_MEMO_TARGET XIOS_MEMO_CFVER XIOS_SUBPREFIX \
               XIOS_DEB_ARCH XIOS_REPO_PROFILE XIOS_RUNTIME_TMP XIOS_RUNTIME_VAR \
               XIOS_DEFAULT_MIN_IOS XIOS_TRIPLE XIOS_SYSROOT XIOS_MEMO_ARGS \
               XIOS_SHELL_PATH XIOS_PATH_DIRS; do
      [ -n "${!key:-}" ] || { echo "  !! $key is empty"; exit 1; }
    done

    # The descriptor id has to encode the bootstrap profile and the CFVER, since
    # that pair is what selects the Procursus dependency universe.
    case "$id" in
      "$XIOS_REPO_PROFILE-$XIOS_MEMO_CFVER") ;;
      *) echo "  !! id does not match <repo_profile>-<memo_cfver> ($XIOS_REPO_PROFILE-$XIOS_MEMO_CFVER)"; exit 1 ;;
    esac

    # Rootless installs under a prefix; rootful owns the filesystem root.
    if [ -n "$XIOS_PREFIX" ]; then
      case "$XIOS_MEMO_TARGET" in
        *-rootless) ;;
        *) echo "  !! prefix $XIOS_PREFIX with non-rootless MEMO_TARGET $XIOS_MEMO_TARGET"; exit 1 ;;
      esac
      case "$XIOS_RUNTIME_TMP" in
        "$XIOS_PREFIX"/*) ;;
        *) echo "  !! runtime_tmp $XIOS_RUNTIME_TMP is outside the prefix"; exit 1 ;;
      esac
    else
      case "$XIOS_MEMO_TARGET" in
        *-rootless) echo "  !! empty prefix with rootless MEMO_TARGET $XIOS_MEMO_TARGET"; exit 1 ;;
      esac
      case "$XIOS_RUNTIME_TMP" in
        /var/jb/*) echo "  !! rootful runtime_tmp points into a rootless prefix"; exit 1 ;;
      esac
    fi

    [ "$XIOS_PACKAGE_PATH_PREFIX" = "$XIOS_PREFIX" ] ||
      { echo "  !! package_path_prefix ($XIOS_PACKAGE_PATH_PREFIX) != prefix ($XIOS_PREFIX)"; exit 1; }

    echo "   prefix=${XIOS_PREFIX:-/}  arch=$XIOS_DEB_ARCH  profile=$XIOS_REPO_PROFILE  tmp=$XIOS_RUNTIME_TMP  sh=$XIOS_SHELL_PATH"
  ) || fail=1
done

if [ "$fail" = 0 ]; then
  echo "all target descriptors OK"
else
  echo "target descriptor lint FAILED" >&2
fi
exit "$fail"
