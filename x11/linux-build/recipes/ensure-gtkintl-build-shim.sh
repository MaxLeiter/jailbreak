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
gettext_runtime="$gettext_stage$prefix/lib/libintl.8.dylib"
cc="${CC:-$procursus_root/build_tools/cc-nounused}"

[ -f "$source_file" ] || {
  echo "ensure-gtkintl-build-shim: missing $source_file" >&2
  exit 1
}
[ -f "$gettext_runtime" ] || {
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

# ld64 resolves a re-export while linking the consumer, before its runtime
# @rpath is meaningful. Give this build-only bridge an absolute re-export path;
# shipped libgtkintl is built separately with the correct @rpath dependency.
int_tool="$(command -v aarch64-apple-darwin-install_name_tool \
  || command -v install_name_tool \
  || command -v llvm-install-name-tool)"
"$int_tool" -change @rpath/libintl.8.dylib "$gettext_runtime" "$output_file"

# Keep the real gettext runtime beside the bridge and aim the unversioned
# development name at the bridge. Callers then see both ordinary libintl_*
# exports and GTK's g_libintl_* proxy exports.
cp -f "$gettext_runtime" "$output_dir/libintl.8.dylib"
ln -sf libgtkintl.dylib "$output_dir/libintl.dylib"
echo "==> prepared build-sysroot libgtkintl bridge and gettext runtime"
