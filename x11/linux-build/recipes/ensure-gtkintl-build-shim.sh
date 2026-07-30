#!/usr/bin/env bash
# Put the shared libgtkintl bridge in the active Procursus build sysroot.
#
# GTK is intentionally relinked from its bundled proxy-libintl to
# @rpath/libgtkintl.dylib. Downstream links therefore need the same bridge in
# BUILD_BASE, not only in the final libgtkintl package. Keep that setup here so
# every GTK package wave can reuse it instead of creating package-local hacks.
set -euo pipefail

: "${XIOS_MEMO_TARGET:?source target-env.sh before calling this helper}"
: "${XIOS_MEMO_CFVER:?source target-env.sh before calling this helper}"

procursus_root="${PROCURSUS_ROOT:-/work/Procursus}"
prefix="${XIOS_PREFIX:-/var/jb}${XIOS_SUBPREFIX:-/usr}"
build_base="$procursus_root/build_base/$XIOS_MEMO_TARGET/$XIOS_MEMO_CFVER"
gettext_stage="$procursus_root/build_stage/$XIOS_MEMO_TARGET/$XIOS_MEMO_CFVER/gettext"
source_file="$procursus_root/build_tools/gtkintl_shim.c"
output_dir="$build_base$prefix/lib"
output_file="$output_dir/libgtkintl.dylib"
cc="${CC:-$procursus_root/build_tools/cc-nounused}"

[ -f "$source_file" ] || {
  echo "ensure-gtkintl-build-shim: missing $source_file" >&2
  exit 1
}
[ -f "$gettext_stage$prefix/lib/libintl.dylib" ] || {
  echo "ensure-gtkintl-build-shim: gettext stage is missing for $XIOS_MEMO_TARGET" >&2
  exit 1
}

mkdir -p "$output_dir"
"$cc" -dynamiclib -fno-common -install_name @rpath/libgtkintl.dylib \
  "$source_file" \
  -L"$gettext_stage$prefix/lib" \
  -L"$output_dir" \
  -Wl,-reexport-lintl \
  -o "$output_file.tmp"
mv -f "$output_file.tmp" "$output_file"
echo "==> prepared build-sysroot libgtkintl bridge"
