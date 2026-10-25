#!/usr/bin/env bash
# Host (macOS) test for the libepoxy iOS GLX/desktop-GL loader patches.
#
# Builds libepoxy 1.5.7 natively with our ports/libepoxy patch series, in the
# same configuration recipes/libepoxy.mk uses (-Dx11=true -Degl=yes -Dglx=yes),
# so the __APPLE__ dispatch code is the code iOS runs. EPOXY_IOS_LIBGL points
# epoxy at stub-libgl.c instead of /var/jb/usr/lib/libGL.1.dylib, and
# glx-loader-probe.c checks every desktop GL call lands there.
#
#   bash x11/ports/libepoxy/tests/host-glx-loader-test.sh            # expect PASS
#   bash x11/ports/libepoxy/tests/host-glx-loader-test.sh --baseline # 0001 only: expect FAIL
#     (desktop GL still goes to OpenGL.framework; on macOS it exists, so the probe
#      reports the misroute instead of the abort iOS hits)
#
# Needs: clang, meson, ninja, pkg-config with Homebrew libx11 (brew install libx11),
# and the Khronos EGL/KHR headers (taken from the angle deb, or EGL_INCLUDE=<dir>).
# Work happens in $WORK (default: a mktemp dir); nothing in the repo is written.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$PORT/../../.." && pwd)"
VERSION=1.5.7
SHA256=9479cc0146ffb395fdecf9bd2a5930834fd0bce490cbcc4681ffd716bb3a0763
BASELINE=0
[ "${1:-}" = "--baseline" ] && BASELINE=1

WORK="${WORK:-$(mktemp -d "${TMPDIR:-/tmp}/epoxy-glx-test.XXXXXX")}"
mkdir -p "$WORK"
echo "==> work dir: $WORK"

tarball="$WORK/libepoxy-$VERSION.tar.xz"
if [ ! -f "$tarball" ]; then
  curl -fsSL -o "$tarball" "https://download.gnome.org/sources/libepoxy/1.5/libepoxy-$VERSION.tar.xz"
fi
echo "$SHA256  $tarball" | shasum -a 256 -c - >/dev/null

stub="$WORK/stub/libGL.1.dylib"
src="$WORK/src"
rm -rf "$src"
mkdir -p "$src"
tar -xf "$tarball" -C "$src" --strip-components=1

n=0
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  set -- $line
  [ "$#" -gt 0 ] || continue
  n=$((n + 1))
  if [ "$BASELINE" = 1 ] && [ "$n" -gt 1 ]; then
    echo "==> baseline: skipping $1"
    continue
  fi
  echo "==> patch $1"
  patch -s -p1 -d "$src" < "$PORT/patches/$1"
done < "$PORT/patches/series"
if [ "$BASELINE" = 1 ]; then
  # 0001 hardcodes GLX_LIB; aim it at the stub so the only difference left is
  # where desktop GL (OPENGL_LIB) comes from.
  sed -i '' "s|^#define GLX_LIB \"/var/jb/usr/lib/libGL.1.dylib\"|#define GLX_LIB \"$stub\"|" "$src/src/dispatch_common.c"
  grep -q "^#define GLX_LIB \"$stub\"" "$src/src/dispatch_common.c" || { echo "ERROR: baseline GLX_LIB rewrite missed" >&2; exit 1; }
fi

# epoxy's EGL dispatch needs the Khronos headers (build-gtk.sh stages them for the
# iOS build too). Default to the ones the angle deb ships.
if [ -z "${EGL_INCLUDE:-}" ]; then
  # repo/debs is untracked, so a worktree has none: fall back to the main checkout's.
  # (a worktree's .git is a file: "gitdir: <main>/.git/worktrees/<name>")
  main_repo="$REPO"
  if [ -f "$REPO/.git" ]; then
    gitdir="$(sed -n 's/^gitdir: //p' "$REPO/.git")"
    main_repo="${gitdir%/.git/worktrees/*}"
  fi
  angle_deb="${ANGLE_DEB:-$(ls -t "$REPO"/repo/debs/angle_*_iphoneos-arm64.deb "$main_repo"/repo/debs/angle_*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)}"
  [ -n "$angle_deb" ] || { echo "ERROR: no angle deb in repo/debs; set ANGLE_DEB=<deb> or EGL_INCLUDE=<dir with EGL/ KHR/>" >&2; exit 1; }
  mkdir -p "$WORK/angle"
  (cd "$WORK/angle" && bsdtar -xf "$angle_deb" && bsdtar -xf data.tar.*)
  EGL_INCLUDE="$WORK/angle/var/jb/include"
fi
[ -f "$EGL_INCLUDE/EGL/eglplatform.h" ] || { echo "ERROR: $EGL_INCLUDE/EGL/eglplatform.h missing" >&2; exit 1; }

mkdir -p "$WORK/stub"
clang -dynamiclib -O1 -Wall -install_name "$stub" -o "$stub" "$HERE/stub-libgl.c"

# gen_dispatch.py runs as `/usr/bin/env python3` and needs a working pyexpat, which a
# Homebrew python linked against a too-old system libexpat lacks. Pin one that works.
mkdir -p "$WORK/bin"
for py in "$(command -v python3 || true)" /usr/bin/python3; do
  [ -n "$py" ] && [ -x "$py" ] || continue
  if "$py" -c 'import xml.etree.ElementTree as E; E.XMLParser()' 2>/dev/null; then
    ln -sf "$py" "$WORK/bin/python3"
    break
  fi
done
[ -e "$WORK/bin/python3" ] || { echo "ERROR: no python3 with a working xml parser" >&2; exit 1; }
export PATH="$WORK/bin:$PATH"

build="$WORK/build"
rm -rf "$build"
# meson shlex-splits c_args, so the string-literal quotes need their own escape.
meson setup "$build" "$src" \
  -Dtests=false -Dx11=true -Degl=yes -Dglx=yes \
  -Dc_args="-I$EGL_INCLUDE $(pkg-config --cflags x11) -DEPOXY_IOS_LIBGL=\\\"$stub\\\"" > "$WORK/meson.log" 2>&1 \
  || { tail -30 "$WORK/meson.log" >&2; exit 1; }
ninja -C "$build" > "$WORK/ninja.log" 2>&1 || { tail -30 "$WORK/ninja.log" >&2; exit 1; }

lib="$(ls "$build"/src/libepoxy*.dylib | head -1)"
echo "==> built $lib"
echo "==> dlopen paths baked into it:"
strings "$lib" | grep -E '^/.*(dylib|OpenGL)$|\.so$' | sed 's/^/      /'

clang -O1 -Wall -o "$WORK/probe" "$HERE/glx-loader-probe.c" \
  -I"$src/include" -I"$build/include" -I"$EGL_INCLUDE" $(pkg-config --cflags x11) \
  -L"$build/src" -lepoxy -Wl,-rpath,"$build/src"
"$WORK/probe" "$stub"
