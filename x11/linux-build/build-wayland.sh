#!/usr/bin/env bash
# Build the Wayland W0 stack for rootless iOS via the Procursus/Docker pipeline:
#   epoll-shim, wayland (libwayland-client/server/cursor/egl), wayland-protocols, libxkbcommon.
# None of these exist in Procursus, so we drop ours (recipes/*.mk + recipes/build_info/*.control)
# into the clone (the main Makefile globs makefiles/*.mk) and build them. Deps that DO exist in
# Procursus (libffi, expat, xkeyboard-config, ...) cascade.
#
# Runs INSIDE the container, mirroring build-gtk.sh. Fire it host-side on its OWN volume
# (procursus-vol-wayland — clear of the DDX's procursus-vol and GTK's procursus-vol-gtk):
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-wayland:/work/Procursus \
#     -v "$PWD/build-wayland.sh:/work/build-wayland.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-wayland.sh
#
# Select targets via TARGETS env (default = the four W0 packages, epoll-shim first).
#
# PREP ONLY — nothing builds until this is invoked. On a *fresh* procursus-vol-wayland the
# first run also does Procursus `setup` (bootstrap + macOS-SDK header harvest) and builds the
# small cascade deps (libffi/expat) — one-time and unavoidable on a clean volume; seeding the
# volume from the DDX clone snapshot would skip it. The W0 packages themselves are tiny.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
umask 022
cd /work

echo "==> [1/5] ensure Procursus clone (fresh volume => clone)"
if [ ! -d Procursus/.git ]; then
  git clone --depth 1 https://github.com/ProcursusTeam/Procursus.git
fi
cd Procursus

# Host build tools the image may lack. bison/flex/cmake/ninja/meson/pkg-config/libxml2-dev are
# already in the Dockerfile; the native wayland-scanner pass (wayland.mk) additionally needs host
# expat headers. Install defensively (guarded) so this works before the image is rebuilt.
echo "==> [2/5] host build tools (libexpat1-dev for the native wayland-scanner)"
if ! dpkg -s libexpat1-dev >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends libexpat1-dev >/dev/null 2>&1 \
    || { echo "ERROR: could not install libexpat1-dev (needed by wayland.mk pass 1)"; exit 1; }
fi

echo "==> [3/5] apply toolchain fixes (idempotent; needed on a fresh volume)"
# (a) cc/cxx wrappers: neutralise meson's compile-only -Werror=unused-command-line-argument
#     probes (the Procursus clang wrapper injects -Wl,-adhoc_codesign, which those probes reject).
#     Same wrapper gtk-builder uses; harmless for the autotools/cmake deps.
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# (b) Makefile-global toolchain fixes — the subset of build.sh that is toolchain-level (not
#     tigervnc/mesa-specific), applied idempotently so a fresh volume's `setup` + C/C++ deps build.
python3 - <<'PY'
import re, pathlib
def edit(path, fn):
    p = pathlib.Path(path); s = p.read_text(); n = fn(s)
    if n != s: p.write_text(n); print(f"   patched {path}")
    else: print(f"   (already patched) {path}")

# setup harvests macOS-SDK framework headers; keep the copy non-fatal as a safety net.
edit("Makefile", lambda s: re.sub(r'(\n\t)@(cp -af\s+\$\(MACOSX_SYSROOT\))', r'\1-@\2', s))

# cctools-port clang++ defaults to GNU libstdc++ (absent); force Apple libc++.
def cxxflags(s):
    if "-stdlib=libc++" in s: return s
    s = s.replace("CXXFLAGS            := $(CFLAGS)",
                  "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
    s = s.replace("-Wl,-not_for_dyld_shared_cache",
                  "-Wl,-not_for_dyld_shared_cache -stdlib=libc++", 1)
    return s
edit("Makefile", cxxflags)

# Expose dlfcn/Darwin POSIX symbols via _DARWIN_C_SOURCE (NOT a global -include dlfcn.h — that
# regresses C deps like libffi/ncurses).
def darwinsrc(s):
    s = s.replace("-D_DARWIN_C_SOURCE -include dlfcn.h", "-D_DARWIN_C_SOURCE")
    if "-D_DARWIN_C_SOURCE" in s: return s
    return s.replace("CXXFLAGS            := $(CFLAGS) -stdlib=libc++",
                     "CFLAGS              += -D_DARWIN_C_SOURCE\n"
                     "CXXFLAGS            := $(CFLAGS) -stdlib=libc++", 1)
edit("Makefile", darwinsrc)

# Xcode-26 macOS headers #include <_bounds.h>; copy it too so setup's harvested headers resolve.
edit("Makefile", lambda s: s.replace(
    "/usr/include/{arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}",
    "/usr/include/{_bounds.h,arpa,bsm,hfs,net,xpc,protocols,netinet,netinet6,servers,timeconv.h,launch.h}"))
PY

echo "==> [4/5] install our recipes + control templates into the clone"
cp -v /work/recipes/*.mk makefiles/
# Our control templates live in recipes/build_info/ (the top-level linux-build/build_info/ is the
# GTK track's and is not mounted here). Copy into the *clone's* build_info/.
cp -v /work/recipes/build_info/*.control build_info/

echo "==> [5/5] build the W0 stack (epoll-shim first; wayland depends on it)"
COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
TARGETS="${TARGETS:-epoll-shim-package wayland-package wayland-protocols-package libxkbcommon-package}"

target_requests() {
  local requested
  for requested in $TARGETS; do
    [ "$requested" = "$1" ] && return 0
  done
  return 1
}

stage_required_patch_stack() {
  local pkg="$1"
  if [ ! -d "/work/ports/$pkg/patches" ]; then
    echo "ERROR: missing /work/ports/$pkg/patches; mount ports with -v \\$PWD/../ports:/work/ports:ro" >&2
    exit 1
  fi
  echo "==> staging $pkg source patches"
  bash /work/recipes/stage-port-patches.sh "$pkg" /work/ports build_patch
}

target_requests wayland && stage_required_patch_stack wayland

WAYLAND_W=build_work/$XIOS_TRIPLE/wayland
WAYLAND_S=build_stage/$XIOS_TRIPLE/wayland
WAYLAND_F="$WAYLAND_W/.xios_patch_series.sha256"
if target_requests wayland; then
  WAYLAND_FP="$(sha256sum \
    /work/ports/wayland/patches/series \
    /work/ports/wayland/patches/*.patch | sha256sum | awk '{print $1}')"
  WAYLAND_OLD_FP="$(cat "$WAYLAND_F" 2>/dev/null || true)"
  if [ -d "$WAYLAND_W" ] && [ "$WAYLAND_FP" != "$WAYLAND_OLD_FP" ]; then
    echo "==> wiping stale wayland build after patch changes"
    rm -rf "$WAYLAND_W" "$WAYLAND_S"
  fi
fi

# Procursus's EXTRACT_TAR and .build_complete cache are keyed by package name,
# not version. Without an explicit fingerprint, changing FOO_VERSION can
# silently package the old source tree. Invalidate only requested W0 packages
# when their recipe (or staged patch series) changes.
for pkg in epoll-shim wayland wayland-protocols libxkbcommon; do
  target_requests "$pkg" || target_requests "$pkg-package" || continue
  work="build_work/$XIOS_TRIPLE/$pkg"
  stage="build_stage/$XIOS_TRIPLE/$pkg"
  stamp="$work/.xios_recipe.sha256"
  inputs=("/work/recipes/$pkg.mk")
  if [ -f "/work/ports/$pkg/patches/series" ]; then
    inputs+=("/work/ports/$pkg/patches/series" /work/ports/"$pkg"/patches/*.patch)
  fi
  fingerprint="$(sha256sum "${inputs[@]}" | sha256sum | awk '{print $1}')"
  old_fingerprint="$(cat "$stamp" 2>/dev/null || true)"
  if [ -d "$work" ] && [ "$fingerprint" != "$old_fingerprint" ]; then
    echo "==> wiping stale $pkg build after recipe/version changes"
    rm -rf "$work" "$stage"
  fi
  RECIPE_FINGERPRINTS="${RECIPE_FINGERPRINTS:-}$pkg=$fingerprint "
done

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done
if [ -d "$WAYLAND_W" ] && [ -n "${WAYLAND_FP:-}" ]; then
  printf '%s\n' "$WAYLAND_FP" > "$WAYLAND_F"
fi
for pair in ${RECIPE_FINGERPRINTS:-}; do
  pkg="${pair%%=*}"
  fingerprint="${pair#*=}"
  work="build_work/$XIOS_TRIPLE/$pkg"
  if [ -d "$work" ]; then
    printf '%s\n' "$fingerprint" > "$work/.xios_recipe.sha256"
  fi
done

echo "==> collect debs -> /out"
mkdir -p /out
found=0
for pat in libepoll-shim libwayland wayland-protocols libxkbcommon; do
  for d in $(find . -name "${pat}*_*_$XIOS_DEB_ARCH.deb" 2>/dev/null); do
    cp -v "$d" /out/; found=1
  done
done
[ "$found" = 1 ] || { echo "!! no wayland-stack debs produced"; exit 1; }
echo "==> done. W0 debs in /out:"
ls -1 /out/*.deb 2>/dev/null || true
