#!/usr/bin/env bash
# Build and package a full OpenJDK 21 HotSpot JDK for rootless arm64 iOS.
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
[ "$XIOS_PREFIX" = /var/jb ] || {
  echo "OpenJDK packaging currently supports the rootless /var/jb target only" >&2
  exit 1
}
source "$ROOT/lib/xlib.sh"

OUT="${OUT:-$HERE/out}"
WORK="${WORK:-$OUT/openjdk-ios-work}"
CONF="${OPENJDK_CONF:-ios-aarch64-server-release}"
IMAGE="$WORK/openjdk/build/$CONF/images/jdk"
JVM_HOME="$XIOS_PREFIX/usr/lib/jvm/java-21-openjdk"
IOS_MIN="${IOS_MIN:-16.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MODE="${1:-all}"

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
  docker run --rm --platform linux/arm64 \
    -v "$debdir:/debs:ro" \
    -v "$sysroot:/sysroot" \
    "${XLIB_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}" \
    -c "dpkg-deb -x /debs/'$base' /sysroot"
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

  rg -q 'MirrorMappedCodeCache' "$WORK/openjdk/src/hotspot/share/runtime/globals.hpp"
  rg -q 'IOS_USE_COMPRESSED_CLASS_POINTERS_DEFAULT' \
    "$WORK/openjdk/src/hotspot/share/runtime/globals.hpp"
  rg -q 'aarch64-apple-ios' "$WORK/openjdk/make/autoconf/platform.m4" || \
    rg -q '\\*ios\\*' "$WORK/openjdk/make/autoconf/platform.m4"

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
  local libx11_deb fontconfig_deb
  libx11_deb="$(xdeb_find libx11-dev "$OUT" "$repo_debs")" || {
    echo "libx11-dev iOS package is required in linux-build/out or repo/debs" >&2
    exit 1
  }
  fontconfig_deb="$(xdeb_find libfontconfig-dev "$OUT" "$repo_debs")" || {
    echo "libfontconfig-dev iOS package is required in linux-build/out or repo/debs" >&2
    exit 1
  }

  local depsys="$WORK/header-sysroot"
  docker_extract_deb "$libx11_deb" "$depsys"
  docker_extract_deb "$fontconfig_deb" "$depsys"

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

  echo "==> configure OpenJDK 21.0.12 for arm64 iOS"
  (
    cd "$src"
    bash ./configure \
      --openjdk-target=aarch64-apple-ios \
      --with-sysroot="$IOS_SDKROOT" \
      --with-extra-cflags="$extra_cflags" \
      --with-extra-cxxflags="$extra_cflags" \
      --with-extra-ldflags="-arch arm64" \
      --disable-precompiled-headers \
      --disable-warnings-as-errors \
      --enable-option-checking=fatal \
      --enable-headless-only=yes \
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

  local jre="$pkgwork/openjdk-21-jre-headless"
  local jdk="$pkgwork/openjdk-21-jdk-headless"
  local jre_home="$jre$JVM_HOME"
  local jdk_home="$jdk$JVM_HOME"
  mkdir -p "$jre/DEBIAN" "$jdk/DEBIAN" \
    "$jre_home/bin" "$jre$XIOS_PREFIX/usr/bin" \
    "$jdk_home/bin" "$jdk$XIOS_PREFIX/usr/bin"
  cp "$ROOT/packages/openjdk-21-jre-headless/DEBIAN/control" "$jre/DEBIAN/control"
  cp "$ROOT/packages/openjdk-21-jdk-headless/DEBIAN/control" "$jdk/DEBIAN/control"

  for d in conf legal; do
    cp -R "$IMAGE/$d" "$jre_home/$d"
  done
  cp "$IMAGE/release" "$jre_home/release"
  mkdir -p "$jre_home/lib"
  rsync -a --exclude=/src.zip "$IMAGE/lib/" "$jre_home/lib/"

  local runtime_bins=(java jfr keytool rmiregistry)
  local tool
  for tool in "${runtime_bins[@]}"; do
    cp "$IMAGE/bin/$tool" "$jre_home/bin/$tool"
    ln -s "$JVM_HOME/bin/$tool" "$jre$XIOS_PREFIX/usr/bin/$tool"
  done

  for tool_path in "$IMAGE"/bin/*; do
    tool="$(basename "$tool_path")"
    case " ${runtime_bins[*]} " in
      *" $tool "*) continue ;;
    esac
    cp "$tool_path" "$jdk_home/bin/$tool"
    ln -s "$JVM_HOME/bin/$tool" "$jdk$XIOS_PREFIX/usr/bin/$tool"
  done
  for d in include jmods man; do
    cp -R "$IMAGE/$d" "$jdk_home/$d"
  done
  mkdir -p "$jdk_home/lib"
  cp "$IMAGE/lib/src.zip" "$jdk_home/lib/src.zip"

  chmod 0755 "$jre_home/bin/"* "$jdk_home/bin/"*
  local jre_deb jdk_deb
  jre_deb="$(make_deb_isolated "$jre")"
  jdk_deb="$(make_deb_isolated "$jdk")"
  echo "==> packages"
  echo "    $jre_deb"
  echo "    $jdk_deb"
}

for tool in git curl shasum patch rg rsync xcrun gmake file otool ldid docker; do
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
