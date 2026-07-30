#!/usr/bin/env bash
# Targeted Procursus cache invalidation for Xios build drivers.
#
# Source this from an in-container driver after `cd /work/Procursus`, then call:
#
#   xios_cache_prepare_target "$target"
#   make "$target" ...
#   xios_cache_record_target "$target"
#
# Procursus recipes short-circuit on build_work/.../<name>/.build_complete. This
# helper keeps that fast path, but invalidates the one package whose mounted
# recipe/helper inputs changed.

[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
xios_cache_target_name() {
  local target=$1
  target=${target%-package}
  target=${target%-stage}
  printf '%s\n' "$target"
}

xios_cache_work_dir() {
  local name=$1
  printf 'build_work/%s/%s/%s\n' \
    "${MEMO_TARGET:-$XIOS_MEMO_TARGET}" \
    "${MEMO_CFVER:-1900}" \
    "$name"
}

xios_cache_stage_dir() {
  local name=$1
  printf 'build_stage/%s/%s/%s\n' \
    "${MEMO_TARGET:-$XIOS_MEMO_TARGET}" \
    "${MEMO_CFVER:-1900}" \
    "$name"
}

xios_cache_inputs_for() {
  local name=$1
  local recipe="/work/recipes/${name}.mk"
  local input

  for input in ${XIOS_CACHE_COMMON_INPUTS:-}; do
    [ -f "$input" ] && printf '%s\n' "$input"
  done

  [ -f "$recipe" ] && printf '%s\n' "$recipe"

  for input in \
    /work/recipes/${name}-ios-fixes.sh \
    /work/recipes/${name}*.patch \
    /work/recipes/build_info/${name}*.c \
    /work/recipes/build_info/${name}*.h \
    /work/recipes/build_info/${name}*.patch \
    /work/recipes/build_info/${name}*.sh \
    /work/build_info/${name}*.c \
    /work/build_info/${name}*.h \
    /work/build_info/${name}*.patch \
    /work/build_info/${name}*.sh; do
    [ -f "$input" ] && printf '%s\n' "$input"
  done

  if [ -f "$recipe" ]; then
    grep -Eoh '/work/recipes/[A-Za-z0-9._+/=-]+' "$recipe" 2>/dev/null \
      | while IFS= read -r input; do
          case "$input" in
            *-ios-qml-stubs.sh|*-ios-qml-fixes.sh|*/relink-gtkintl.sh)
              continue
              ;;
          esac
          [ -f "$input" ] && printf '%s\n' "$input"
        done
  fi

  if [ -d "/work/ports/${name}/patches" ]; then
    find "/work/ports/${name}/patches" -type f -print
  fi
}

xios_cache_fingerprint_for() {
  local name=$1
  local inputs=()
  local input

  while IFS= read -r input; do
    [ -f "$input" ] || continue
    inputs+=("$input")
  done < <(xios_cache_inputs_for "$name" | sort -u)

  [ "${#inputs[@]}" -gt 0 ] || return 1

  {
    printf '%s\n' "xios-cache-fingerprint-v1"
    for input in "${inputs[@]}"; do
      printf '%s\n' "path:$input"
      sha256sum "$input"
    done
  } | sha256sum | awk '{print $1}'
}

xios_cache_inputs_newer_than() {
  local name=$1
  local marker=$2
  local input

  while IFS= read -r input; do
    [ -f "$input" ] || continue
    if [ "$input" -nt "$marker" ]; then
      return 0
    fi
  done < <(xios_cache_inputs_for "$name" | sort -u)

  return 1
}

xios_cache_prepare_target() {
  local target=$1
  local name work stage marker fpfile new_fp old_fp

  name=$(xios_cache_target_name "$target")
  [ -f "/work/recipes/${name}.mk" ] || return 0

  work=$(xios_cache_work_dir "$name")
  stage=$(xios_cache_stage_dir "$name")
  marker="${work}/.build_complete"
  fpfile="${work}/.xios-inputs.sha256"

  [ -f "$marker" ] || return 0

  new_fp=$(xios_cache_fingerprint_for "$name") || return 0
  old_fp=$(cat "$fpfile" 2>/dev/null || true)

  if [ -n "$old_fp" ] && [ "$old_fp" != "$new_fp" ]; then
    echo "==> invalidating ${name}: recipe/helper inputs changed"
    rm -rf "$work" "$stage"
    return 0
  fi

  if [ -z "$old_fp" ]; then
    if xios_cache_inputs_newer_than "$name" "$marker"; then
      echo "==> invalidating ${name}: recipe/helper inputs are newer than .build_complete"
      rm -rf "$work" "$stage"
      return 0
    fi
    printf '%s\n' "$new_fp" > "$fpfile"
    echo "==> seeded cache fingerprint for ${name}"
  fi
}

xios_cache_record_target() {
  local target=$1
  local name work fpfile new_fp

  name=$(xios_cache_target_name "$target")
  [ -f "/work/recipes/${name}.mk" ] || return 0

  work=$(xios_cache_work_dir "$name")
  [ -d "$work" ] || return 0

  new_fp=$(xios_cache_fingerprint_for "$name") || return 0
  fpfile="${work}/.xios-inputs.sha256"
  printf '%s\n' "$new_fp" > "$fpfile"
}
