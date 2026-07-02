#!/usr/bin/env bash
# relink-gtkintl.sh — shared post-package pass that makes every GTK/GNOME .deb immune to
# the bundled proxy-libintl (g_libintl_*) dyld-abort, so no recipe has to reinvent it.
#
# For each .deb in the given dir(s):
#   * relink any mach-o that IMPORTS g_libintl_* (the renamed proxy-libintl symbols) onto
#     @rpath/libgtkintl.dylib — the shim shipped by the libgtkintl package, which reexports
#     libintl.8 and re-adds the g_libintl_* names dyld needs;
#   * re-sign it (ldid -S, since the relink invalidates the signature). GTK/Qt/EGL
#     app executables are signed with the GPU-client entitlement so the post-pass
#     does not strip AGX/IOGPU access after the package recipe added it;
#   * declare `Depends: libgtkintl` so apt installs the shim;
#   * regenerate DEBIAN/md5sums and repack (zstd).
#
# Idempotent by construction: a deb already fixed (by this pass, by gtk+3.0.mk/gtk4.mk, or
# by hand) still imports g_libintl_* but no longer links @rpath/libintl{,.8}.dylib, so it is
# left untouched — no needless repack. libgtkintl itself EXPORTS (not imports) the symbols,
# so it is naturally skipped and never gets a self-dependency.
#
# Runs inside the Procursus build container (needs dpkg-deb + the cross cctools + ldid).
# Usage: relink-gtkintl.sh DIR [DIR ...]
set -euo pipefail

pick() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done; echo "$1"; }
INT="$(pick aarch64-apple-darwin-install_name_tool install_name_tool llvm-install-name-tool llvm-install-name-tool-14)"
NM="$(pick aarch64-apple-darwin-nm llvm-nm llvm-nm-14 nm)"
OTOOL="$(pick aarch64-apple-darwin-otool llvm-otool llvm-otool-14 otool)"
LDID="$(pick ldid)"
DEB="$(pick dpkg-deb)"
SHIM=libgtkintl
GPU_ENT="$(dirname "$0")/../build_info/iosc-gpu-client-ent.xml"
[ -f "$GPU_ENT" ] || GPU_ENT="/work/build_info/iosc-gpu-client-ent.xml"
[ -f "$GPU_ENT" ] || GPU_ENT="/work/Procursus/build_misc/entitlements/iosc-gpu-client-ent.xml"
GL_ENT="$(dirname "$0")/../build_info/iosc-gl-ent.xml"
[ -f "$GL_ENT" ] || GL_ENT="/work/build_info/iosc-gl-ent.xml"
[ -f "$GL_ENT" ] || GL_ENT="/work/Procursus/build_misc/entitlements/iosc-gl-ent.xml"

is_process_macho() {
  case "${1##*.}" in
    a|dylib|bundle|so) return 1 ;;
    *) return 0 ;;
  esac
}

needs_gpu_entitlement() {
  local f="$1"
  is_process_macho "$f" || return 1
  "$OTOOL" -L "$f" 2>/dev/null \
    | grep -qE 'libgtk-4|libadwaita|libEGL|libGLESv2|QtGui|QtWayland|libmutter|libepoxy|libGL\.1'
}

needs_compositor_entitlement() {
  local f="$1"
  is_process_macho "$f" || return 1
  "$OTOOL" -L "$f" 2>/dev/null | grep -q 'libmutter'
}

has_gpu_entitlement() {
  "$LDID" -e "$1" 2>/dev/null | grep -qE 'AGXDeviceUserClient|IOGPUDeviceUserClient'
}

sign_macho() {
  local f="$1"
  if needs_compositor_entitlement "$f" && [ -f "$GL_ENT" ]; then
    "$LDID" -S"$GL_ENT" "$f"
  elif needs_gpu_entitlement "$f" && [ -f "$GPU_ENT" ]; then
    "$LDID" -S"$GPU_ENT" "$f"
  else
    "$LDID" -S "$f"
  fi
}

fix_deb() {
  local deb="$1" work pkg changed=0 needdep=0 f
  work="$(mktemp -d)"
  "$DEB" -R "$deb" "$work" >/dev/null
  pkg="$(awk '/^Package:/{print $2; exit}' "$work/DEBIAN/control")"

  while IFS= read -r f; do
    file "$f" 2>/dev/null | grep -q 'Mach-O' || continue
    "$NM" -u "$f" 2>/dev/null | grep -q '_g_libintl_' || continue
    needdep=1
    # Only relink if it still points at the unshippable proxy (keeps re-runs no-op).
    if "$OTOOL" -L "$f" 2>/dev/null | grep -qE '@rpath/libintl(\.8)?\.dylib'; then
      "$INT" -change @rpath/libintl.dylib   "@rpath/$SHIM.dylib" "$f" 2>/dev/null || true
      "$INT" -change @rpath/libintl.8.dylib "@rpath/$SHIM.dylib" "$f" 2>/dev/null || true
      sign_macho "$f"
      changed=1
    elif needs_gpu_entitlement "$f" && ! has_gpu_entitlement "$f"; then
      sign_macho "$f"
      changed=1
    fi
  done < <(find "$work" -path "$work/DEBIAN" -prune -o -type f -print)

  if [ "$needdep" = 1 ] && [ "$pkg" != "$SHIM" ] \
     && ! { grep '^Depends:' "$work/DEBIAN/control" 2>/dev/null | grep -qw "$SHIM"; }; then
    if grep -q '^Depends:' "$work/DEBIAN/control"; then
      sed -i "s/^Depends:[[:space:]]*/Depends: $SHIM, /" "$work/DEBIAN/control"
    else
      sed -i "/^Architecture:/a Depends: $SHIM" "$work/DEBIAN/control"
    fi
    changed=1
  fi

  if [ "$changed" = 1 ]; then
    ( cd "$work" && find . -path ./DEBIAN -prune -o -type f -print0 \
        | xargs -0 md5sum | sed 's|  \./|  |' > DEBIAN/md5sums )
    "$DEB" -Zzstd --root-owner-group -b "$work" "$deb" >/dev/null
    printf '  FIXED   %-46s [%s]\n' "$(basename "$deb")" "$pkg"
  elif [ "$needdep" = 1 ]; then
    printf '  ok      %-46s [%s] (already shimmed)\n' "$(basename "$deb")" "$pkg"
  else
    printf '  skip    %-46s [%s] (no g_libintl_)\n' "$(basename "$deb")" "$pkg"
  fi
  rm -rf "$work"
}

n=0
for dir in "$@"; do
  for deb in "$dir"/*.deb; do
    [ -e "$deb" ] || continue
    fix_deb "$deb"; n=$((n + 1))
  done
done
echo "==> relink-gtkintl: processed $n deb(s)"
