#!/usr/bin/env bash
# Build and package a full OpenJDK 21 HotSpot JDK for arm64 iOS.
#
# This lane deliberately produces a headless JDK first: Java CLI, compiler,
# build tools, networking, crypto, images/fonts, JFR and HotSpot C1/C2 work,
# while native AWT windowing remains a separate XAWT/Wayland milestone.
#
# The iOS platform and writable-code-cache work is based on AngelAuraMC's
# shipping Java 21 patch set, pinned by commit and patch hashes. OpenJDK itself
# is pinned to the 21.0.12 GA source commit. The script uses the repo's iOS
# libX11/fontconfig development packages for the residual headless-AWT headers.
set -euo pipefail
umask 022
export LC_ALL=C
export TZ=UTC

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

source "$HERE/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"
source "$ROOT/lib/xlib.sh"

MODE="${1:-all}"
if [ "$MODE" = "--awt-x11-build-only" ]; then
  MODE="--build-only"
  OPENJDK_VARIANT="${OPENJDK_VARIANT:-awt-x11}"
fi
OPENJDK_VARIANT="${OPENJDK_VARIANT:-headless}"
case "$OPENJDK_VARIANT" in
  headless|awt-x11) ;;
  *)
    echo "unsupported OpenJDK variant: $OPENJDK_VARIANT (expected headless or awt-x11)" >&2
    exit 2
    ;;
esac
if [ "$XIOS_REPO_PROFILE" = rootless ]; then
  OUT="${OUT:-$HERE/out}"
else
  OUT="${OUT:-$HERE/out/targets/$XIOS_TARGET_ID}"
fi
if [ "$OPENJDK_VARIANT" = "awt-x11" ]; then
  WORK="${WORK:-$HERE/out/openjdk-awt-ios-work}"
  CONF="${OPENJDK_CONF:-ios-aarch64-server-awt-x11-release}"
  HEADLESS_ONLY=no
  PKG_JRE=openjdk-21-jre-awt
  PKG_JDK=openjdk-21-jdk-awt
else
  WORK="${WORK:-$HERE/out/openjdk-ios-work}"
  CONF="${OPENJDK_CONF:-ios-aarch64-server-release}"
  HEADLESS_ONLY=yes
  PKG_JRE=openjdk-21-jre-headless
  PKG_JDK=openjdk-21-jdk-headless
fi
IMAGE="$WORK/openjdk/build/$CONF/images/jdk"
JVM_HOME="$XIOS_INSTALL_PREFIX/lib/jvm/java-21-openjdk"
# Where the variant actually installs. The AWT lane gets its own JVM directory
# so it sits ALONGSIDE the proven headless runtime rather than replacing it,
# and it publishes no /usr/bin symlinks (those names belong to the headless
# packages); pick it with JAVA_HOME. JVM_HOME stays the configure --prefix for
# both variants -- the image derives java.home from the launcher at runtime, so
# the prefix is metadata only.
if [ "$OPENJDK_VARIANT" = "awt-x11" ]; then
  PKG_JVM_HOME="$XIOS_INSTALL_PREFIX/lib/jvm/java-21-openjdk-awt"
else
  PKG_JVM_HOME="$JVM_HOME"
fi
IOS_MIN="${IOS_MIN:-$XIOS_DEFAULT_MIN_IOS}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

if [ "$XIOS_REPO_PROFILE" != rootless ] && [ "$MODE" != "--package-only" ]; then
  echo "OpenJDK's arm64 iOS image is target-neutral, but source builds use the rootless" >&2
  echo "development sysroot. Build it once with rootless-1900, then repackage with:" >&2
  echo "  XIOS_TARGET=$XIOS_TARGET_ID $0 --package-only" >&2
  exit 2
fi


OPENJDK_REPO="${OPENJDK_REPO:-https://github.com/openjdk/jdk21u.git}"
OPENJDK_COMMIT="${OPENJDK_COMMIT:-9de4f68c88a0a1510373f291d1a95b1f6b0db8c8}"
OPENJDK_SOURCE_DATE="${OPENJDK_SOURCE_DATE:-1783925755}"
PATCH_REPO="${PATCH_REPO:-https://github.com/AngelAuraMC/angelauramc-openjdk-build.git}"
PATCH_COMMIT="${PATCH_COMMIT:-4527b5a73dcf3f890b45eab4c6a91651ea28a5ea}"
PLATFORM_PATCH_SHA256="8c07d9f50afd8958e83ac4d868fe00a49b648393d7c679b4b29d3911ac20ee55"
MIRROR_PATCH_SHA256="25145c0a6134b5ff08491000827587be8df1051ef2657b0d88e8cc6e2f6cd756"
XIOS_PATCH_DIR="$ROOT/ports/openjdk21/patches"

CUPS_URL="https://github.com/apple/cups/releases/download/v2.2.4/cups-2.2.4-source.tar.gz"
CUPS_SHA256="596d4db72651c335469ae5f37b0da72ac9f97d73e30838d787065f559dea98cc"
XORGPROTO_URL="https://xorg.freedesktop.org/archive/individual/proto/xorgproto-2024.1.tar.xz"
XORGPROTO_SHA256="372225fd40815b8423547f5d890c5debc72e88b91088fbfb13158c20495ccb59"
XRENDER_URL="https://xorg.freedesktop.org/archive/individual/lib/libXrender-0.9.12.tar.xz"
XRENDER_SHA256="b832128da48b39c8d608224481743403ad1691bf4e554e4be9c174df171d1b97"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required host tool: $1" >&2
    exit 1
  }
}

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

download() {
  local url="$1" dest="$2" expected="$3"
  if [ ! -s "$dest" ]; then
    echo "==> download $(basename "$dest")"
    curl -fL --retry 3 -o "$dest" "$url"
  fi
  local actual
  actual="$(sha256 "$dest")"
  [ "$actual" = "$expected" ] || {
    echo "checksum mismatch for $dest" >&2
    echo " expected: $expected" >&2
    echo "   actual: $actual" >&2
    exit 1
  }
}

docker_extract_deb() {
  local deb="$1" sysroot="$2"
  local debdir base
  debdir="$(cd "$(dirname "$deb")" && pwd)"
  base="$(basename "$deb")"
  mkdir -p "$sysroot"
  if docker run --rm --platform linux/arm64 \
    -v "$debdir:/debs:ro" \
    -v "$sysroot:/sysroot" \
    "${XLIB_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}" \
    -c "dpkg-deb -x /debs/'$base' /sysroot"; then
    return 0
  fi

  # Some Docker hosts cannot execute the arm64 helper image even though the
  # host can unpack the zstd-compressed .deb itself. Keep extraction portable
  # so the AWT probe does not depend on a working cross-container emulator.
  local tmp data
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/xios-deb.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  (cd "$tmp" && ar -x "$deb")
  data="$(find "$tmp" -maxdepth 1 -type f -name 'data.tar.*' -print -quit)"
  [ -n "$data" ] || { echo "cannot find data archive in $deb" >&2; return 1; }
  tar -xf "$data" -C "$sysroot" --no-same-owner
}

make_deb_isolated() {
  local stage="$1"
  local control="$stage/DEBIAN/control"
  local package version arch parent base debname
  package="$(awk -F': ' '/^Package:/{print $2; exit}' "$control")"
  version="$(awk -F': ' '/^Version:/{print $2; exit}' "$control")"
  arch="$(awk -F': ' '/^Architecture:/{print $2; exit}' "$control")"
  parent="$(cd "$(dirname "$stage")" && pwd)"
  base="$(basename "$stage")"
  debname="${package}_${version}_${arch}.deb"

  # Docker Desktop cannot chown some of OpenJDK's read-only legal-file links
  # in place on the macOS bind mount. Normalize a copy on the container's
  # native filesystem, then write only the completed archive to the mount.
  docker run --rm --platform linux/arm64 \
    -v "$parent:/stage" \
    "${XLIB_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}" \
    -c "cp -a /stage/'$base' /tmp/pkg &&
        chown -R 0:0 /tmp/pkg &&
        dpkg-deb -Zzstd --build /tmp/pkg /stage/'$debname'" >&2
  cp "$parent/$debname" "$OUT/$debname"
  echo "$OUT/$debname"
}

prepare_sources() {
  mkdir -p "$WORK"

  if [ ! -d "$WORK/openjdk/.git" ]; then
    git clone --filter=blob:none --no-checkout "$OPENJDK_REPO" "$WORK/openjdk"
  fi
  git -C "$WORK/openjdk" fetch --quiet --depth 1 origin "$OPENJDK_COMMIT"
  git -C "$WORK/openjdk" checkout --quiet --detach "$OPENJDK_COMMIT"
  git -C "$WORK/openjdk" reset --quiet --hard "$OPENJDK_COMMIT"
  git -C "$WORK/openjdk" clean -fd --quiet

  if [ ! -d "$WORK/angelauramc/.git" ]; then
    git clone --filter=blob:none --no-checkout "$PATCH_REPO" "$WORK/angelauramc"
  fi
  git -C "$WORK/angelauramc" fetch --quiet --depth 1 origin "$PATCH_COMMIT"
  git -C "$WORK/angelauramc" checkout --quiet --detach "$PATCH_COMMIT"

  local p1="$WORK/angelauramc/patches/jre_21/ios/1_jdk21u_ios.diff"
  local p2="$WORK/angelauramc/patches/jre_21/ios/2_mirror_mapping.diff"
  [ "$(sha256 "$p1")" = "$PLATFORM_PATCH_SHA256" ] || {
    echo "AngelAura platform patch hash drifted" >&2; exit 1; }
  [ "$(sha256 "$p2")" = "$MIRROR_PATCH_SHA256" ] || {
    echo "AngelAura mirror patch hash drifted" >&2; exit 1; }

  echo "==> apply pinned iOS platform and code-cache patches"
  (
    cd "$WORK/openjdk"
    # BSD patch's fuzz handling cleanly rebases the two context-only 21.0.8 ->
    # 21.0.12 shifts that git-apply rejects.
    patch --batch --forward -p1 --fuzz=3 < "$p1"
    git apply "$p2"
    while IFS= read -r patch_name; do
      case "$patch_name" in
        ""|\#*) continue ;;
      esac
      git apply "$XIOS_PATCH_DIR/$patch_name"
    done < "$XIOS_PATCH_DIR/series"
    git diff --check
  )

  # grep, not rg: these are fixed-string post-patch assertions, and requiring
  # ripgrep made the script fail before doing any work on a host that only has
  # `rg` as an interactive shell function rather than a real binary.
  grep -q 'MirrorMappedCodeCache' "$WORK/openjdk/src/hotspot/share/runtime/globals.hpp"
  grep -q 'IOS_USE_COMPRESSED_CLASS_POINTERS_DEFAULT' \
    "$WORK/openjdk/src/hotspot/share/runtime/globals.hpp"
  grep -q 'aarch64-apple-ios' "$WORK/openjdk/make/autoconf/platform.m4" || \
    grep -qE '\\*ios\\*' "$WORK/openjdk/make/autoconf/platform.m4"

  local desktop="$WORK/openjdk/src/java.desktop/macosx"
  mv "$desktop" "${desktop}_NOTIOS"
  mkdir -p "$desktop/native"
  mv "${desktop}_NOTIOS/native/libjsound" "$desktop/native/"
}

prepare_headers() {
  mkdir -p "$WORK"
  download "$CUPS_URL" "$WORK/cups-2.2.4-source.tar.gz" "$CUPS_SHA256"
  download "$XORGPROTO_URL" "$WORK/xorgproto-2024.1.tar.xz" "$XORGPROTO_SHA256"
  download "$XRENDER_URL" "$WORK/libXrender-0.9.12.tar.xz" "$XRENDER_SHA256"

  [ -d "$WORK/cups-2.2.4" ] ||
    tar -C "$WORK" -xf "$WORK/cups-2.2.4-source.tar.gz"
  [ -d "$WORK/xorgproto-2024.1" ] ||
    tar -C "$WORK" -xf "$WORK/xorgproto-2024.1.tar.xz"
  [ -d "$WORK/libXrender-0.9.12" ] ||
    tar -C "$WORK" -xf "$WORK/libXrender-0.9.12.tar.xz"

  local repo_debs="$ROOT/../repo/debs"
  local target_out="$HERE/out/targets/$XIOS_TARGET_ID"
  local libx11_deb fontconfig_deb
  libx11_deb="$(xdeb_find libx11-dev "$OUT" "$target_out" "$repo_debs")" || {
    echo "libx11-dev iOS package is required in linux-build/out or repo/debs" >&2
    exit 1
  }
  fontconfig_deb="$(xdeb_find libfontconfig-dev "$OUT" "$target_out" "$repo_debs")" || {
    echo "libfontconfig-dev iOS package is required in linux-build/out or repo/debs" >&2
    exit 1
  }

  local depsys="$WORK/header-sysroot"
  docker_extract_deb "$libx11_deb" "$depsys"
  docker_extract_deb "$fontconfig_deb" "$depsys"

  if [ "$OPENJDK_VARIANT" = awt-x11 ]; then
    local xdep xdep_deb
    for xdep in libx11-6 libxext-dev libxext6 libxrender-dev libxrender1 \
      libxi-dev libxi6 libxtst-dev libxtst6 libxrandr-dev libxrandr2; do
      xdep_deb="$(xdeb_find "$xdep" "$OUT" "$target_out" "$repo_debs")" || {
        echo "AWT/X11 probe requires $xdep in linux-build/out or repo/debs" >&2
        echo "build the missing Procursus X11 dependency before rerunning" >&2
        exit 1
      }
      docker_extract_deb "$xdep_deb" "$depsys"
    done
  fi

  local headers="$WORK/ios-build-include"
  mkdir -p "$headers/X11/extensions"
  rsync -a "$WORK/angelauramc/ios-missing-include/" "$headers/"
  rsync -a "$depsys$XIOS_PREFIX/usr/include/X11/" "$headers/X11/"
  # xorgproto supplies the protocol headers intentionally split out of
  # libx11-dev; libXrender supplies the one client API header used here.
  rsync -a "$WORK/xorgproto-2024.1/include/X11/" "$headers/X11/"
  install -m 0644 \
    "$WORK/libXrender-0.9.12/include/X11/extensions/Xrender.h" \
    "$headers/X11/extensions/Xrender.h"
  rsync -a "$depsys$XIOS_PREFIX/usr/include/fontconfig/" "$headers/fontconfig/"

  local macsdk
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  ln -sfn "$macsdk/System/Library/Frameworks/CoreAudio.framework/Headers" \
    "$headers/CoreAudio"
  ln -sfn "$macsdk/System/Library/Frameworks/IOKit.framework/Headers" \
    "$headers/IOKit"
  ln -sfn "$WORK/cups-2.2.4/cups" "$headers/cups"
}

configure_and_build() {
  local src="$WORK/openjdk"
  local headers="$WORK/ios-build-include"
  local boot_jdk="${BOOT_JDK:-/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home}"
  [ -x "$boot_jdk/bin/java" ] || {
    echo "Java 21 boot JDK not found at $boot_jdk (set BOOT_JDK)" >&2
    exit 1
  }

  export IOS_SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
  export IOS_CLANG="$(xcrun -find -sdk iphoneos clang)"
  export IOS_CLANGXX="$(xcrun -find -sdk iphoneos clang++)"
  export IOS_MIN
  export CC="$HERE/tools/openjdk-ios-clang"
  export CXX="$HERE/tools/openjdk-ios-clang++"
  export CXXCPP="$CXX -E"
  export LD="$(xcrun -find -sdk iphoneos ld)"
  export HOTSPOT_DISABLE_DTRACE_PROBES=1
  export BUILD_SYSROOT_CFLAGS="-isysroot $(xcrun --sdk macosx --show-sdk-path)"
  export themacsysroot="$(xcrun --sdk macosx --show-sdk-path)"
  # Never export IPHONEOS_DEPLOYMENT_TARGET globally: OpenJDK's build-time
  # helpers must remain runnable macOS binaries. The wrappers carry IOS_MIN.
  unset IPHONEOS_DEPLOYMENT_TARGET

  local extra_cflags="-O3 -arch arm64 -I$headers -Wno-implicit-function-declaration"
  local extra_ldflags="-arch arm64"
  if [ "$OPENJDK_VARIANT" = awt-x11 ]; then
    # The Procursus X11 dylibs carry @rpath install names (e.g.
    # @rpath/libX11.6.dylib), and OpenJDK only gives its own libraries
    # LC_RPATH @loader_path/. That resolves the JDK's own lib dir and nothing
    # else, so libawt_xawt/libsplashscreen would miss libX11 at dlopen time on
    # device. Record the on-device library dir the same way every other
    # Procursus consumer does.
    extra_ldflags+=" -L$WORK/header-sysroot$XIOS_PREFIX/usr/lib"
    extra_ldflags+=" -Wl,-rpath,$XIOS_PREFIX/usr/lib"
  fi

  echo "==> configure OpenJDK 21.0.12 for arm64 iOS"
  (
    cd "$src"
    bash ./configure \
      --openjdk-target=aarch64-apple-ios \
      --with-sysroot="$IOS_SDKROOT" \
      --with-extra-cflags="$extra_cflags" \
      --with-extra-cxxflags="$extra_cflags" \
      --with-extra-ldflags="$extra_ldflags" \
      --disable-precompiled-headers \
      --disable-warnings-as-errors \
      --enable-option-checking=fatal \
      --enable-headless-only="$HEADLESS_ONLY" \
      --with-jvm-variants=server \
      --with-jvm-features=-dtrace,-zero,-vm-structs,-epsilongc \
      --with-cups-include="$WORK/cups-2.2.4" \
      --with-boot-jdk="$boot_jdk" \
      --with-freetype=bundled \
      --with-native-debug-symbols=none \
      --with-debug-level=release \
      --with-conf-name="$CONF" \
      --with-source-date="$OPENJDK_SOURCE_DATE" \
      --with-version-pre= \
      --with-version-build=7 \
      --with-version-opt=xios1 \
      --prefix="$JVM_HOME" \
      --with-vendor-name=Xios \
      --with-vendor-version-string=ios1

    gmake -C "build/$CONF" JOBS="$JOBS" images
  )
}

sign_and_verify_image() {
  [ -x "$IMAGE/bin/java" ] || {
    echo "JDK image missing: $IMAGE" >&2
    exit 1
  }

  local ent="$ROOT/ports/mozjs/tools/ent-jit.xml"
  local count=0
  while IFS= read -r f; do
    file "$f" | grep -q 'Mach-O' || continue
    otool -l "$f" | grep -A4 LC_BUILD_VERSION | grep -q 'platform 2' || {
      echo "non-iOS Mach-O in JDK image: $f" >&2
      exit 1
    }
    otool -l "$f" | grep -A4 LC_BUILD_VERSION | grep -q "minos $IOS_MIN" || {
      echo "wrong deployment floor in JDK image: $f" >&2
      exit 1
    }
    case "$f" in
      "$IMAGE"/bin/*|"$IMAGE"/lib/jspawnhelper)
        xsign "$f" "$ent" dynamic-codesigning platform-application
        ;;
      *)
        xsign "$f"
        ;;
    esac
    count=$((count + 1))
  done < <(find "$IMAGE" -type f -print | sort)

  [ "$count" -ge 60 ] || {
    echo "unexpectedly few Mach-O files in JDK image: $count" >&2
    exit 1
  }
  echo "==> verified and signed $count iOS Mach-O files"
}

package_image() {
  [ -x "$IMAGE/bin/java" ] || {
    echo "JDK image missing: $IMAGE" >&2
    exit 1
  }

  local pkgwork="$WORK/package"
  mkdir -p "$pkgwork"
  find "$pkgwork" -mindepth 1 -delete

  local jre="$pkgwork/$PKG_JRE"
  local jdk="$pkgwork/$PKG_JDK"
  local jre_home="$jre$PKG_JVM_HOME"
  local jdk_home="$jdk$PKG_JVM_HOME"
  mkdir -p "$jre/DEBIAN" "$jdk/DEBIAN" \
    "$jre_home/bin" "$jre$XIOS_PREFIX/usr/bin" \
    "$jdk_home/bin" "$jdk$XIOS_PREFIX/usr/bin"
  cp "$ROOT/packages/$PKG_JRE/DEBIAN/control" "$jre/DEBIAN/control"
  cp "$ROOT/packages/$PKG_JDK/DEBIAN/control" "$jdk/DEBIAN/control"
  # OPENJDK_PKG_VERSION lets a variant cut a new package revision without
  # disturbing the target-wide suffix the headless packages are published
  # under. The AWT lane needs it: its first cut shipped the RECT_T clip bug,
  # so the fixed build must not carry the same version string.
  local runtime_version="${OPENJDK_PKG_VERSION:-21.0.12$XIOS_VERSION_SUFFIX}"
  sed -i.bak \
    -e "s/^Version: .*/Version: $runtime_version/" \
    -e "s/^Architecture: .*/Architecture: $XIOS_DEB_ARCH/" \
    -e "s/^MinimumOSVersion: .*/MinimumOSVersion: $IOS_MIN/" \
    -e 's/ for rootless iOS\\./ for iOS./' \
    "$jre/DEBIAN/control"
  sed -i.bak \
    -e "s/^Version: .*/Version: $runtime_version/" \
    -e "s/^Architecture: .*/Architecture: $XIOS_DEB_ARCH/" \
    -e "s/^Depends: $PKG_JRE .*/Depends: $PKG_JRE (= $runtime_version)/" \
    -e "s/^MinimumOSVersion: .*/MinimumOSVersion: $IOS_MIN/" \
    -e 's/ for rootless iOS\\./ for iOS./' \
    "$jdk/DEBIAN/control"
  rm -f "$jre/DEBIAN/control.bak" "$jdk/DEBIAN/control.bak"

  for d in conf legal; do
    cp -R "$IMAGE/$d" "$jre_home/$d"
  done
  cp "$IMAGE/release" "$jre_home/release"
  mkdir -p "$jre_home/lib"
  rsync -a --exclude=/src.zip "$IMAGE/lib/" "$jre_home/lib/"

  # Only the headless packages own the unsuffixed /usr/bin names. The AWT lane
  # ships its tools inside its own JVM directory and links nothing into
  # /usr/bin, so installing it can never shadow or conflict with the runtime
  # everything else on the device already depends on.
  local link_into_usr_bin=yes
  [ "$OPENJDK_VARIANT" = awt-x11 ] && link_into_usr_bin=no

  local runtime_bins=(java jfr keytool rmiregistry)
  local tool
  for tool in "${runtime_bins[@]}"; do
    cp "$IMAGE/bin/$tool" "$jre_home/bin/$tool"
    if [ "$link_into_usr_bin" = yes ]; then
      ln -s "$PKG_JVM_HOME/bin/$tool" "$jre$XIOS_PREFIX/usr/bin/$tool"
    fi
  done

  for tool_path in "$IMAGE"/bin/*; do
    tool="$(basename "$tool_path")"
    case " ${runtime_bins[*]} " in
      *" $tool "*) continue ;;
    esac
    cp "$tool_path" "$jdk_home/bin/$tool"
    if [ "$link_into_usr_bin" = yes ]; then
      ln -s "$PKG_JVM_HOME/bin/$tool" "$jdk$XIOS_PREFIX/usr/bin/$tool"
    fi
  done
  for d in include jmods man; do
    cp -R "$IMAGE/$d" "$jdk_home/$d"
  done
  mkdir -p "$jdk_home/lib"
  cp "$IMAGE/lib/src.zip" "$jdk_home/lib/src.zip"

  chmod 0755 "$jre_home/bin/"* "$jdk_home/bin/"*
  local jre_deb jdk_deb
  mkdir -p "$OUT"
  jre_deb="$(make_deb_isolated "$jre")"
  jdk_deb="$(make_deb_isolated "$jdk")"
  echo "==> packages"
  echo "    $jre_deb"
  echo "    $jdk_deb"
}

for tool in git curl shasum patch rsync xcrun gmake file otool ldid docker ar tar; do
  need "$tool"
done

case "$MODE" in
  all)
    prepare_sources
    prepare_headers
    configure_and_build
    sign_and_verify_image
    package_image
    ;;
  --build-only)
    prepare_sources
    prepare_headers
    configure_and_build
    sign_and_verify_image
    ;;
  --package-only)
    sign_and_verify_image
    package_image
    ;;
  *)
    echo "usage: $0 [all|--build-only|--package-only]" >&2
    exit 2
    ;;
esac
