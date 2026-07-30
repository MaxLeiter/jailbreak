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

TARGETS="${TARGETS:-sdl2-package sdl3-package openttd-package}"

echo "==> installing host tools"
apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  cmake libwayland-bin ninja-build pkg-config python3 wget zip >/dev/null 2>&1

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
for recipe in sdl2.mk sdl3.mk sdl2-image.mk sdl2-mixer.mk openal-soft.mk physfs.mk boost-games.mk enet.mk fribidi.mk openttd.mk warzone2100.mk wesnoth.mk zero-ad.mk xios-sdl-smoke.mk; do
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
for recipe in libogg libvorbis libopus libtheora libsodium libzip openssl; do
  grep -Eq '^DEB_[A-Z0-9_]+_V[[:space:]]+\?=.*\+ios1$' "makefiles/$recipe.mk"
done
cp -v /work/recipes/build_info/libsdl*.control build_info/
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
for package in sdl2 sdl3 openttd warzone2100 wesnoth 0ad; do
  bash /work/recipes/stage-port-patches.sh "$package" /work/ports build_patch
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
    "$XIOS_BUILD_WORK/physfs/.build_complete"
fi

for target in $TARGETS; do
  if [ "$target" = "sdl2-image-package" ]; then
    echo "==> staging SDL2_image development roots"
    for package in \
      libsdl2-2.0-0 libsdl2-dev \
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
      libsdl2-2.0-0 libsdl2-dev \
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
        libsdl2-2.0-0 libsdl2-dev \
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
      libsdl2-2.0-0 libsdl2-dev \
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
      libsdl2-2.0-0 libsdl2-dev \
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
    find "$XIOS_BUILD_BASE/var/jb" -type f -name '*.pc' -exec \
      cp -f {} "$XIOS_BUILD_BASE/usr/lib/pkgconfig/" \;
  fi
  echo "==> make $target"
  make "$target" $COMMON -j"${JOBS:-4}"
done

echo "==> collecting game-wave debs"
mkdir -p /out
for package in \
  libsdl2-2.0-0 libsdl2-dev libsdl3-0 libsdl3-dev \
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
