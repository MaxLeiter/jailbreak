#!/usr/bin/env bash
# Build the shared SDL foundations and the Xios game ports.
#
# Host invocation (the repo payload mount supplies already-built Wayland/ANGLE
# dependencies without rebuilding the desktop stack):
#   PROCURSUS_VOL=procursus-vol-wayland \
#     bash linux-build/run-target-script.sh build-games.sh -- \
#       -v "$PWD/../repo/debs:/repo-debs:ro"
#
# Select a lane with TARGETS, for example:
#   TARGETS="sdl3-package" PROCURSUS_VOL=procursus-vol-wayland ...
set -euo pipefail

[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || {
  echo "ERROR: $XIOS_TARGET_ENV missing" >&2
  exit 1
}
. "$XIOS_TARGET_ENV"
cd /work/Procursus

# The Procursus tree and sysroot are mutable shared state. Two game-wave
# containers can otherwise race while extracting sources or staging headers.
exec 9>.xios-build-games.lock
if ! flock -n 9; then
  echo "ERROR: another build-games.sh process owns /work/Procursus" >&2
  exit 75
fi

TARGETS="${TARGETS:-sdl2-package sdl3-package openttd-package}"

if [ "$TARGETS" = "openttd-package" ]; then
  echo "==> using image host tools (OpenTTD needs no Wayland scanner or zip)"
else
  echo "==> installing supplemental host tools"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends \
    libwayland-bin zip >/dev/null 2>&1
fi

# Debian's scanner writes --version to stdout while SDL 2/3's CMake check reads
# stderr. Keep protocol generation on the native scanner and mirror only the
# version response to the stream SDL expects.
cat > /usr/local/bin/wayland-scanner <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  /usr/bin/wayland-scanner --version >&2
  exit $?
fi
exec /usr/bin/wayland-scanner "$@"
EOF
chmod +x /usr/local/bin/wayland-scanner

echo "==> installing game recipes, controls, and patches"
for recipe in sdl2.mk sdl3.mk sdl2-image.mk sdl2-mixer.mk openal-soft.mk physfs.mk boost-games.mk enet.mk fribidi.mk libsodium.mk openttd.mk warzone2100.mk wesnoth.mk zero-ad.mk xios-sdl-smoke.mk; do
  cp -v "/work/recipes/$recipe" makefiles/
done
# These are stock Procursus recipes whose source is already portable. Mark the
# Xios-built package revision at the deb-version seam without changing the
# upstream source version (which also owns the download URL).
sed -E -i 's|^(DEB_LIBOGG_V[[:space:]]+\?=[[:space:]]+\$\(LIBOGG_VERSION\))$|\1+ios1|' makefiles/libogg.mk
sed -E -i 's|^(DEB_LIBVORBIS_V[[:space:]]+\?=[[:space:]]+\$\(LIBVORBIS_VERSION\))$|\1+ios1|' makefiles/libvorbis.mk
sed -E -i 's|^(DEB_LIBOPUS_V[[:space:]]+\?=[[:space:]]+\$\(LIBOPUS_VERSION\))$|\1+ios1|' makefiles/libopus.mk
sed -E -i 's|^(DEB_LIBTHEORA_V[[:space:]]+\?=[[:space:]]+\$\(LIBTHEORA_VERSION\))$|\1+ios1|' makefiles/libtheora.mk
sed -E -i 's|^(DEB_LIBSODIUM_V[[:space:]]+\?=[[:space:]]+\$\(LIBSODIUM_VERSION\))$|\1+ios1|' makefiles/libsodium.mk
sed -E -i 's|^(DEB_LIBZIP_V[[:space:]]+\?=[[:space:]]+\$\(LIBZIP_VERSION\))$|\1+ios1|' makefiles/libzip.mk
sed -E -i 's|^(DEB_OPENSSL_V[[:space:]]+\?=[[:space:]]+\$\(OPENSSL_VERSION\))$|\1+ios1|' makefiles/openssl.mk
# The original libzip host is not reliably reachable from the arm64 build
# container, and OpenSSL's old source URL now redirects through its GitHub
# release assets. Use the projects' official GitHub release payloads directly.
sed -E -i \
  's|https://libzip\.org/download/libzip-\$\(LIBZIP_VERSION\)\.tar\.gz|https://github.com/nih-at/libzip/releases/download/v$(LIBZIP_VERSION)/libzip-$(LIBZIP_VERSION).tar.gz|' \
  makefiles/libzip.mk
sed -E -i \
  's|https://www\.openssl\.org/source/openssl-\$\(OPENSSL_VERSION\)\.tar\.gz|https://github.com/openssl/openssl/releases/download/openssl-$(OPENSSL_VERSION)/openssl-$(OPENSSL_VERSION).tar.gz|' \
  makefiles/openssl.mk
for recipe in libogg libvorbis libopus libtheora libsodium libzip openssl; do
  grep -Eq '^DEB_[A-Z0-9_]+_V[[:space:]]+\?=.*\+ios1$' "makefiles/$recipe.mk"
done
cp -v /work/recipes/build_info/libsdl*.control \
  /work/recipes/build_info/xios-sdl2*.control build_info/
cp -v /work/recipes/build_info/libopenal*.control \
  /work/recipes/build_info/libphysfs*.control \
  /work/recipes/build_info/libboost-game*.control \
  /work/recipes/build_info/libenet*.control \
  build_info/
cp -v /work/build_info/openttd.control build_info/
cp -v /work/recipes/build_info/xios-sdl-smoke.control \
  /work/recipes/build_info/xios-sdl2-smoke.desktop \
  /work/recipes/build_info/xios-sdl3-smoke.desktop \
  /work/recipes/build_info/warzone2100.control \
  /work/recipes/build_info/warzone2100.desktop \
  /work/recipes/build_info/wesnoth.control \
  /work/recipes/build_info/wesnoth.desktop \
  /work/recipes/build_info/0ad.control \
  /work/recipes/build_info/0ad.desktop \
  build_info/
for package in sdl2 sdl3 physfs openttd warzone2100 wesnoth 0ad; do
  bash /work/recipes/stage-port-patches.sh "$package" /work/ports build_patch
done

# Procursus' DOWNLOAD_FILES neither verifies a download nor re-fetches, and it
# skips any file that already exists. A connection that drops mid-transfer
# therefore leaves a truncated archive that tar unpacks *partially*, and every
# later run happily reuses it -- which reads as a source or configuration bug
# rather than a bad download. Both boost and wesnoth lost a build cycle to this
# on 2026-08-02. Test every cached archive up front and delete the bad ones so
# their recipes refetch instead of building on half a tree.
echo "==> verifying cached source archives"
for archive in build_source/*.tar.gz build_source/*.tgz build_source/*.tar.xz \
               build_source/*.tar.bz2 build_source/*.zip; do
  [ -e "$archive" ] || continue
  case "$archive" in
    *.tar.gz|*.tgz)  tester=(gzip -t) ;;
    *.tar.xz)        tester=(xz -t) ;;
    *.tar.bz2)       tester=(bzip2 -t) ;;
    *.zip)           tester=(unzip -tq) ;;
    *)               continue ;;
  esac
  if ! "${tester[@]}" "$archive" >/dev/null 2>&1; then
    echo "    corrupt or truncated, removing for refetch: $archive"
    rm -f "$archive"
  fi
done

stage_rootless_deb() {
  local package="$1"
  if [ "${SKIP_GAME_DEP_STAGING:-0}" = "1" ]; then
    return 0
  fi
  local deb=""
  local directory
  for directory in /out /repo-debs "build_dist/$XIOS_TRIPLE"; do
    [ -d "$directory" ] || continue
    deb="$(find "$directory" -maxdepth 2 -type f -name "${package}_*_${XIOS_DEB_ARCH}.deb" \
      -print | sort -V | tail -1)"
    [ -n "$deb" ] && break
  done
  if [ -z "$deb" ]; then
    echo "ERROR: no ${package} deb in /out or /repo-debs" >&2
    return 1
  fi

  echo "    staging $deb"
  dpkg-deb -x "$deb" "$XIOS_BUILD_BASE"

  # xios-sdl2 ships its dylibs in a private directory so it shadows nothing at
  # runtime. Link them into the ordinary sysroot libdir for BUILD time only, so
  # -lSDL2 and the pkg-config/CMake metadata resolve exactly as before. The
  # packaged games still load it via DYLD_LIBRARY_PATH, not from here.
  if [ "$package" = "xios-sdl2" ]; then
    mkdir -p "$XIOS_BUILD_BASE/var/jb/usr/lib"
    for dylib in "$XIOS_BUILD_BASE/var/jb/usr/lib/xios-sdl2/"libSDL2*.dylib; do
      [ -e "$dylib" ] || continue
      ln -sf "xios-sdl2/$(basename "$dylib")" \
        "$XIOS_BUILD_BASE/var/jb/usr/lib/$(basename "$dylib")"
    done
  fi
}

echo "==> staging Xios Wayland, input, graphics, and audio development roots"
if [ "${SKIP_GAME_DEP_STAGING:-0}" = "1" ]; then
  echo "    preserving the already-staged sysroot for an incremental resume"
fi
if [ "${FORCE_GAME_DEPS_STAGE:-0}" = "1" ] || \
   [ ! -f "$XIOS_BUILD_BASE/.xios-game-base-deps-staged" ]; then
  for package in \
    libwayland0 libwayland-dev \
    libxkbcommon0 libxkbcommon-dev \
    angle libpulse0 libpulse-dev; do
    stage_rootless_deb "$package"
  done
  touch "$XIOS_BUILD_BASE/.xios-game-base-deps-staged"
else
  echo "    using staged base dependencies"
fi

# Procursus' cross-pkg-config only scans build_base/usr. Rootless package
# metadata correctly advertises /var/jb paths, so expose just the .pc files in
# the scanner directory while leaving headers and dylibs at their real sysroot
# locations under build_base/var/jb.
mkdir -p "$XIOS_BUILD_BASE/usr/lib/pkgconfig"
find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
  cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;

cat > "$XIOS_BUILD_BASE/usr/lib/pkgconfig/egl.pc" <<'EOF'
prefix=/var/jb
includedir=${prefix}/include
libdir=${prefix}/lib/angle

Name: EGL
Description: Xios ANGLE EGL
Version: 1.5
Libs: -L${libdir} -lEGL
Cflags: -I${includedir}
EOF

cat > "$XIOS_BUILD_BASE/usr/lib/pkgconfig/glesv2.pc" <<'EOF'
prefix=/var/jb
includedir=${prefix}/include
libdir=${prefix}/lib/angle

Name: GLESv2
Description: Xios ANGLE OpenGL ES
Version: 3.2
Libs: -L${libdir} -lGLESv2
Cflags: -I${includedir}
EOF

# The Procursus compiler wrapper adds a link-only option to compile probes.
# Keep CMake's try_compile checks from promoting that harmless warning.
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# --- iOS SDK os/object.h fix (unblocks Apple ObjC framework probes) ----------
# Same backport build-wayland-apps.sh already carries, needed here because
# SDL2_image compiles IMG_ImageIO.m: any Foundation -> NSXPCConnection include
# pulls the newer xpc/session.h, whose OS_OBJECT_DECL_SENDABLE_* macros this
# 16.5 SDK's os/object.h predates. Without them xpc_session_t is never declared
# and every ObjC translation unit fails with "unknown type name". Alias to the
# non-sendable forms (identical expansion on the C/ObjC, non-Swift path). Only
# the ephemeral container's SDK copy is touched; --rm discards it. Idempotent.
OSOBJ=/root/cctools/SDK/iPhoneOS16.5.sdk/usr/include/os/object.h
if [ -f "$OSOBJ" ] && ! grep -q OS_OBJECT_DECL_SENDABLE_CLASS "$OSOBJ"; then
  echo "==> backporting OS_OBJECT_DECL_SENDABLE_* into $OSOBJ"
  cat >> "$OSOBJ" <<'EOF'

/* XIOS: backport OS_OBJECT_DECL_SENDABLE_* (this 16.5 SDK os/object.h predates
 * them, but its newer xpc/session.h requires them; alias to the non-sendable
 * forms -- identical C/ObjC path). */
#ifndef OS_OBJECT_DECL_SENDABLE_CLASS
#define OS_OBJECT_DECL_SENDABLE_CLASS(name) OS_OBJECT_DECL_CLASS(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SWIFT(name) OS_OBJECT_DECL_SWIFT(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT(name, super) OS_OBJECT_DECL_SUBCLASS_SWIFT(name, super)
#endif
EOF
fi

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused \
  CXX=/work/Procursus/build_tools/cxx-nounused"

if [ "${FORCE_SDL_REBUILD:-0}" = "1" ]; then
  rm -f \
    "$XIOS_BUILD_WORK/sdl2/.build_complete" \
    "$XIOS_BUILD_WORK/sdl3/.build_complete"
fi
if [ "${FORCE_SDL_SMOKE_REBUILD:-0}" = "1" ]; then
  rm -f "$XIOS_BUILD_WORK/xios-sdl-smoke/.build_complete"
fi
if [ "${FORCE_GAME_DEPS_REBUILD:-0}" = "1" ]; then
  rm -f \
    "$XIOS_BUILD_WORK/openal-soft/.build_complete" \
    "$XIOS_BUILD_WORK/physfs/.build_complete" \
    "$XIOS_BUILD_WORK/enet/.build_complete" \
    "$XIOS_BUILD_WORK/boost-games/.build_complete"
fi
# Surgical resume: rebuild only the named subprojects after a recipe fix,
# without discarding the rest of an expensive dependency wave.
for subproject in ${FORCE_REBUILD:-}; do
  echo "==> forcing rebuild of $subproject"
  rm -f "$XIOS_BUILD_WORK/$subproject/.build_complete"
done

for target in $TARGETS; do
  if [ "$target" = "sdl2-image-package" ]; then
    echo "==> staging SDL2_image development roots"
    for package in \
      xios-sdl2 xios-sdl2-dev \
      libpng16-16 libpng16-dev \
      libjpeg62-turbo libjpeg62-turbo-dev; do
      stage_rootless_deb "$package"
    done
    find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
      cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;
  fi
  if [ "$target" = "sdl2-mixer-package" ]; then
    echo "==> staging SDL2_mixer development roots"
    for package in \
      xios-sdl2 xios-sdl2-dev \
      libogg0 libogg-dev \
      libvorbis0a libvorbisfile3 libvorbis-dev; do
      stage_rootless_deb "$package"
    done
    find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
      cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;
  fi
  if [ "$target" = "openttd-package" ]; then
    echo "==> staging OpenTTD development roots"
    if [ "${FORCE_GAME_DEPS_STAGE:-0}" = "1" ] || \
       [ ! -f "$XIOS_BUILD_BASE/.xios-openttd-deps-staged" ]; then
      for package in \
        xios-sdl2 xios-sdl2-dev \
        libcurl4 libcurl4-openssl-dev \
        libpng16-16 libpng16-dev \
        liblzma5 liblzma-dev \
        libz1 zlib-dev \
        libfreetype6 libfreetype-dev \
        libfontconfig1 libfontconfig-dev \
        libharfbuzz0b libharfbuzz-dev \
        libicu78 libicu-dev; do
        stage_rootless_deb "$package"
      done
      find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
        cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;
      touch "$XIOS_BUILD_BASE/.xios-openttd-deps-staged"
    else
      echo "    using staged OpenTTD dependencies"
    fi
  fi
  if [ "$target" = "warzone2100-package" ]; then
    echo "==> staging Warzone 2100 development roots"
    for package in \
      libsdl3-0 libsdl3-dev \
      libopenal1 libopenal-dev \
      libphysfs1 libphysfs-dev \
      libogg0 libogg-dev \
      libvorbis0a libvorbisfile3 libvorbis-dev \
      libopus0 libopus-dev \
      libtheora0 libtheora-dev \
      libsodium23 libsodium-dev \
      libzip5 libzip-dev \
      libsqlite3-1 libsqlite3-dev \
      libcurl4 libcurl4-openssl-dev \
      libssl3 libssl-dev \
      libpng16-16 libpng16-dev \
      libjpeg62-turbo libjpeg62-turbo-dev \
      libfreetype6 libfreetype-dev \
      libharfbuzz0b libharfbuzz-dev \
      libfribidi0 libfribidi-dev \
      libpulse0 libpulse-dev; do
      stage_rootless_deb "$package"
    done
    find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
      cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;
  fi
  if [ "$target" = "wesnoth-package" ]; then
    echo "==> staging Battle for Wesnoth development roots"
    for package in \
      xios-sdl2 xios-sdl2-dev \
      libsdl2-image-2.0-0 libsdl2-image-dev \
      libsdl2-mixer-2.0-0 libsdl2-mixer-dev \
      libboost-game1.90 libboost-game-dev \
      libicu78 libicu-dev \
      libcurl4 libcurl4-openssl-dev \
      libssl3 libssl-dev \
      libogg0 libogg-dev \
      libvorbis0a libvorbisfile3 libvorbis-dev \
      libfontconfig1 libfontconfig-dev \
      libcairo2 libcairo2-dev \
      libpango-1.0-0 libpango1.0-dev; do
      stage_rootless_deb "$package"
    done
    find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
      cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;
  fi
  if [ "$target" = "zero-ad-package" ]; then
    echo "==> staging 0 A.D. development roots"
    for package in \
      xios-sdl2 xios-sdl2-dev \
      libboost-game1.90 libboost-game-dev \
      libenet7 libenet-dev \
      libmozjs-115-0 libmozjs-115-dev \
      libopenal1 libopenal-dev \
      libogg0 libogg-dev \
      libvorbis0a libvorbisfile3 libvorbis-dev \
      libsodium23 libsodium-dev \
      libfmt12 libfmt-dev \
      libxml2 libxml2-dev \
      libicu78 libicu-dev \
      libcurl4 libcurl4-openssl-dev \
      libpng16-16 libpng16-dev \
      libfreetype6 libfreetype-dev \
      libz1 zlib-dev; do
      stage_rootless_deb "$package"
    done
    # 0 A.D. discovers SpiderMonkey with `pkg-config mozjs-115`, but the
    # libmozjs-115-dev deb ships no .pc file at all, so every mozjs header came
    # back not-found (js/TypeDecls.h, jspubtd.h) even though the headers and
    # dylib are both staged. Synthesise one, the way egl.pc and glesv2.pc above
    # stand in for ANGLE.
    mkdir -p "$XIOS_BUILD_BASE/var/jb/usr/lib/pkgconfig"
    cat > "$XIOS_BUILD_BASE/var/jb/usr/lib/pkgconfig/mozjs-115.pc" <<'PCEOF'
prefix=/var/jb
includedir=${prefix}/usr/include/mozjs-115
libdir=${prefix}/usr/lib

Name: mozjs-115
Description: Xios SpiderMonkey 115
Version: 115.12.0
Libs: -L${libdir} -lmozjs-115
Cflags: -I${includedir}
PCEOF
    find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
      cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;
  fi
  echo "==> make $target"
  make "$target" $COMMON -j"${JOBS:-4}"
done

echo "==> collecting game-wave debs"
mkdir -p /out
for package in \
  xios-sdl2 xios-sdl2-dev libsdl3-0 libsdl3-dev \
  libsdl2-image-2.0-0 libsdl2-image-dev \
  libsdl2-mixer-2.0-0 libsdl2-mixer-dev \
  libopenal1 libopenal-dev libphysfs1 libphysfs-dev \
  libboost-game1.90 libboost-game-dev \
  libenet7 libenet-dev \
  libogg0 libogg-dev libvorbis0a libvorbisenc2 libvorbisfile3 libvorbis-dev \
  libopus0 libopus-dev libtheora0 libtheora-dev \
  libsodium23 libsodium-dev libzip5 libzip-dev \
  libssl3 libssl-dev \
  openttd warzone2100 wesnoth 0ad xios-sdl-smoke; do
  find "build_dist/$XIOS_TRIPLE" -maxdepth 2 -type f \
    -name "${package}_*_${XIOS_DEB_ARCH}.deb" -exec cp -v {} /out/ \;
done
