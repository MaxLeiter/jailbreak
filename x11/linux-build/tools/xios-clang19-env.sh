#!/usr/bin/env bash
# Opt-in clang-19 + modern libc++ headers ("libc++ mode B") for the Procursus cross env.
#
# SOURCE this inside the toolchain container (procursus-xbuild:*), then call
#
#   xios_clang19_setup            # idempotent; writes wrappers, installs headers once
#
# It exports:
#   XIOS_CC19 XIOS_CXX19      compiler wrappers (use as CMake/meson C and C++ compilers)
#   XIOS_AR19 XIOS_RANLIB19   Mach-O-correct ar/ranlib (llvm-ar-19 --format=darwin / cctools)
#   XIOS_LD19_DIR             dir holding the cctools ld64 + friends (for -B / -fuse-ld)
#   XIOS_LIBCXX19_INC         the libc++-19 header dir
#
# Nothing here changes the default toolchain: the Procursus `aarch64-apple-darwin-clang`
# (Debian clang 14) stays what every other recipe gets. A recipe opts in by passing
# -DCMAKE_C_COMPILER=$XIOS_CC19 -DCMAKE_CXX_COMPILER=$XIOS_CXX19 (after DEFAULT_CMAKE_FLAGS).
#
# Why mode B (probe, 2026-10-01, docs/webkitgtk-toolchain-plan.md section 12):
#   * the SDK libc++ is 15.0.6 and lacks <expected>, <source_location>, <format>, newer ranges;
#     WebKitGTK 2.54's StdLibExtras.h includes <expected> unconditionally.
#   * clang-19 + the LLVM-19 libc++ HEADERS (vendor availability annotations left ON) compile
#     that code; we still link the SYSTEM /usr/lib/libc++.1.dylib from the SDK .tbd, so no libc++
#     is shipped, nothing shadows a base package, and there is no ABI skew inside the stack.
#     Anything needing a newer runtime than the deployment target is a COMPILE error.
#
# Knobs (environment):
#   XIOS_CLANG19_DIR   where wrappers/headers live   (default /work/Procursus/build_tools/clang19,
#                      i.e. on the Procursus volume so they persist between containers)
#   XIOS_SDK           sysroot                       (default /root/cctools/SDK/iPhoneOS16.5.sdk)
#   XIOS_IOS_MIN       deployment target             (default 16.0; also on every link line,
#                      so ld64 stamps minos=16.0 instead of the SDK version)
#   XIOS_LIBCXX_MODE   B (default) = LLVM-19 headers, system dylib
#                      A            = SDK libc++ 15 headers (the Ladybird setup; will NOT build
#                                     WebKitGTK >= 2.54)
#
# The wrappers strip what Procursus's CFLAGS inject that is wrong for clang-19: `-arch X`,
# `-miphoneos-version-min=*` (re-added canonically) and every `-isystem*/c++/v1` (the SDK's old
# libc++ headers, which would otherwise win include order over the modern ones).

# Write stdin to $1 only if the content changed. Rewriting a wrapper bumps its mtime, and ninja then
# treats every object compiled through it as dirty (measured: every re-run was a full rebuild).
_xios_write_if_changed() {
  local dest="$1" tmp
  tmp="$(mktemp)"; cat > "$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; else mv -f "$tmp" "$dest"; fi
  chmod +x "$dest" 2>/dev/null || true
}

xios_clang19_setup() {
  local dir="${XIOS_CLANG19_DIR:-/work/Procursus/build_tools/clang19}"
  local sdk="${XIOS_SDK:-/root/cctools/SDK/iPhoneOS16.5.sdk}"
  local min="${XIOS_IOS_MIN:-16.0}"
  local mode="${XIOS_LIBCXX_MODE:-B}"
  local cct="${XIOS_CCTOOLS:-/root/cctools/bin}"

  command -v clang-19 >/dev/null 2>&1 || {
    echo "xios-clang19: clang-19 missing; rebuild the toolchain image (x11/linux-build/Dockerfile)" >&2
    return 1
  }
  mkdir -p "$dir/bin" "$dir/ld"

  # cctools Mach-O tools, unprefixed, for -B / -fuse-ld. (Same set the Ladybird scripts use.)
  local t
  for t in ld ranlib libtool install_name_tool otool nm strip lipo dsymutil codesign_allocate \
           segedit size nmedit; do
    [ -e "$cct/aarch64-apple-darwin-$t" ] && [ "$(readlink "$dir/ld/$t" 2>/dev/null)" != "$cct/aarch64-apple-darwin-$t" ] && ln -sf "$cct/aarch64-apple-darwin-$t" "$dir/ld/$t"
  done
  # The image's aarch64-apple-darwin-ar can be clobbered into a self-exec loop: use llvm-ar in
  # Darwin archive format (cctools ld64/ranlib accept it), expanding @response files first.
  _xios_write_if_changed "$dir/ld/ar" <<'EOF'
#!/bin/sh
n=$#; i=0
while [ "$i" -lt "$n" ]; do
  a=$1; shift
  case "$a" in
    @*) f="${a#@}"; for o in $(cat "$f"); do set -- "$@" "$o"; done ;;
    *)  set -- "$@" "$a" ;;
  esac
  i=$((i+1))
done
exec llvm-ar-19 --format=darwin "$@"
EOF

  local cxxinc=""
  if [ "$mode" = B ]; then
    cxxinc="$dir/libcxx/v1"
    if [ ! -f "$cxxinc/__config_site" ] || [ ! -f "$cxxinc/expected" ]; then
      echo "xios-clang19: installing libc++-19 headers (mode B, headers only)"
      if [ ! -f /usr/lib/llvm-19/include/c++/v1/expected ]; then
        apt-get update >/dev/null 2>&1 || true
        apt-get install -y --no-install-recommends libc++-19-dev >/dev/null 2>&1 || {
          echo "xios-clang19: could not apt-get install libc++-19-dev" >&2; return 1; }
      fi
      rm -rf "$dir/libcxx"; mkdir -p "$dir/libcxx"
      cp -a /usr/lib/llvm-19/include/c++/v1 "$dir/libcxx/v1"
      # Debian's __config_site is Linux-flavoured. Ours: ABI v1 / __1 (same namespace as the system
      # dylib), pthread threads, vendor availability annotations ON (undefine nothing), hardening off.
      _xios_write_if_changed "$cxxinc/__config_site" <<'EOF'
#ifndef _LIBCPP___CONFIG_SITE
#define _LIBCPP___CONFIG_SITE
#define _LIBCPP_ABI_VERSION 1
#define _LIBCPP_ABI_NAMESPACE __1
#define _LIBCPP_HAS_THREAD_API_PTHREAD
#define _LIBCPP_HARDENING_MODE_DEFAULT 2
#define _LIBCPP_PSTL_BACKEND_SERIAL
#endif
EOF
    fi
  fi

  local common="--target=arm64-apple-ios$min -miphoneos-version-min=$min -isysroot $sdk -B$dir/ld -fuse-ld=$dir/ld/ld -Wno-unused-command-line-argument"
  local filter='
args=(); skip=0
for a in "$@"; do
  if [ "$skip" = 1 ]; then skip=0; continue; fi
  case "$a" in
    -arch) skip=1 ;;
    -miphoneos-version-min=*) ;;
    -isystem*/c++/v1) ;;
    *) args+=("$a") ;;
  esac
done'
  _xios_write_if_changed "$dir/bin/cc19" <<EOF
#!/usr/bin/env bash
$filter
exec clang-19 $common "\${args[@]}"
EOF
  if [ "$mode" = B ]; then
    _xios_write_if_changed "$dir/bin/cxx19" <<EOF
#!/usr/bin/env bash
$filter
exec clang++-19 $common -stdlib=libc++ -nostdinc++ -isystem $cxxinc "\${args[@]}"
EOF
  else
    _xios_write_if_changed "$dir/bin/cxx19" <<EOF
#!/usr/bin/env bash
$filter
exec clang++-19 $common -stdlib=libc++ "\${args[@]}"
EOF
  fi

  export XIOS_CC19="$dir/bin/cc19" XIOS_CXX19="$dir/bin/cxx19"
  export XIOS_AR19="$dir/ld/ar" XIOS_RANLIB19="$dir/ld/ranlib"
  export XIOS_LD19_DIR="$dir/ld" XIOS_LIBCXX19_INC="$cxxinc"
  echo "xios-clang19: mode $mode, $(clang-19 --version | head -1), min iOS $min, wrappers in $dir/bin"
}
