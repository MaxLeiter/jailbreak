#!/usr/bin/env bash
# Shared target-matrix loader for Xios build and packaging scripts.
#
# Source this file, then call:
#   xios_load_target [target-id]
#
# If target-id is omitted, XIOS_TARGET is used, then rootless-1900.

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  _xios_target_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _xios_target_lib_dir="$(pwd)"
fi

XIOS_TARGETS_DIR="${XIOS_TARGETS_DIR:-$_xios_target_lib_dir/targets}"

xios_load_target() {
  local id="${1:-${XIOS_TARGET:-rootless-1900}}"
  case "$id" in
    ""|*/*|*..*|*" "*|*$'\t'*|*$'\n'*)
      echo "xios_load_target: invalid target id: $id" >&2
      return 2
      ;;
  esac

  local file="$XIOS_TARGETS_DIR/$id.env"
  if [ ! -f "$file" ]; then
    echo "xios_load_target: target not found: $id ($file)" >&2
    return 2
  fi

  local target_id memo_target memo_cfver prefix subprefix deb_arch repo_profile
  local version_suffix package_path_prefix runtime_tmp runtime_var default_min_ios

  # shellcheck disable=SC1090
  . "$file"

  local required=(
    target_id memo_target memo_cfver prefix subprefix deb_arch repo_profile
    version_suffix package_path_prefix runtime_tmp runtime_var default_min_ios
  )
  local key
  for key in "${required[@]}"; do
    if ! eval '[ "${'"$key"'+x}" = x ]'; then
      echo "xios_load_target: $file missing required key: $key" >&2
      return 2
    fi
  done

  if [ "$target_id" != "$id" ]; then
    echo "xios_load_target: $file declares target_id=$target_id, expected $id" >&2
    return 2
  fi
  if [ -z "$memo_target" ] || [ -z "$memo_cfver" ] || [ -z "$subprefix" ] ||
     [ -z "$deb_arch" ] || [ -z "$repo_profile" ] || [ -z "$runtime_tmp" ] ||
     [ -z "$runtime_var" ] || [ -z "$default_min_ios" ]; then
    echo "xios_load_target: $file has an empty non-optional value" >&2
    return 2
  fi
  case "$subprefix" in
    /*) ;;
    *) echo "xios_load_target: subprefix must be absolute: $subprefix" >&2; return 2 ;;
  esac
  case "$runtime_tmp" in
    /*) ;;
    *) echo "xios_load_target: runtime_tmp must be absolute: $runtime_tmp" >&2; return 2 ;;
  esac
  case "$runtime_var" in
    /*) ;;
    *) echo "xios_load_target: runtime_var must be absolute: $runtime_var" >&2; return 2 ;;
  esac

  export XIOS_TARGET_ID="$target_id"
  export XIOS_MEMO_TARGET="$memo_target"
  export XIOS_MEMO_CFVER="$memo_cfver"
  export XIOS_PREFIX="$prefix"
  export XIOS_SUBPREFIX="$subprefix"
  export XIOS_DEB_ARCH="$deb_arch"
  export XIOS_REPO_PROFILE="$repo_profile"
  export XIOS_VERSION_SUFFIX="$version_suffix"
  export XIOS_PACKAGE_PATH_PREFIX="$package_path_prefix"
  export XIOS_RUNTIME_TMP="$runtime_tmp"
  export XIOS_RUNTIME_VAR="$runtime_var"
  export XIOS_DEFAULT_MIN_IOS="$default_min_ios"

  if [ -n "$prefix" ]; then
    export XIOS_INSTALL_PREFIX="$prefix$subprefix"
    export XIOS_PATH_DIRS="$prefix$subprefix/bin:$prefix$subprefix/sbin:$prefix/bin:$prefix/sbin"
    export XIOS_SHELL_PATH="$prefix/bin/sh"
  else
    export XIOS_INSTALL_PREFIX="$subprefix"
    export XIOS_PATH_DIRS="$subprefix/bin:$subprefix/sbin:/bin:/sbin"
    export XIOS_SHELL_PATH="/bin/sh"
  fi

  # Derived build-tree paths and the shared helpers, so host-side packaging
  # scripts and container-side build scripts speak the same vocabulary. The
  # values it computes for /work/Procursus are simply unused host-side.
  # shellcheck disable=SC1091
  [ -r "$_xios_target_lib_dir/target-env.sh" ] && . "$_xios_target_lib_dir/target-env.sh"
}

xios_print_target() {
  local keys=(
    XIOS_TARGET_ID XIOS_MEMO_TARGET XIOS_MEMO_CFVER XIOS_PREFIX
    XIOS_SUBPREFIX XIOS_INSTALL_PREFIX XIOS_DEB_ARCH XIOS_REPO_PROFILE
    XIOS_VERSION_SUFFIX XIOS_PACKAGE_PATH_PREFIX XIOS_RUNTIME_TMP
    XIOS_RUNTIME_VAR XIOS_DEFAULT_MIN_IOS XIOS_PATH_DIRS XIOS_SHELL_PATH
  )
  local key
  for key in "${keys[@]}"; do
    printf '%s=%s\n' "$key" "${!key}"
  done
}
