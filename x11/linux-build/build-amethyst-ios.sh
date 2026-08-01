#!/usr/bin/env bash
# Build AngelAuraMC Amethyst as a graphical Minecraft launcher for Xios.
#
# The application payload is identical for rootless and rootful devices. The
# selected target controls the package architecture, dependency version and
# install prefix:
#   XIOS_TARGET=rootless-1900 bash linux-build/build-amethyst-ios.sh
#   XIOS_TARGET=rootful-1900  bash linux-build/build-amethyst-ios.sh
set -euo pipefail
umask 022
export LC_ALL=C
export TZ=UTC

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

source "$HERE/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"
source "$ROOT/lib/xlib.sh"

BASE_OUT="$HERE/out"
if [ "$XIOS_REPO_PROFILE" = rootless ]; then
  OUT="${OUT:-$BASE_OUT}"
else
  OUT="${OUT:-$BASE_OUT/targets/$XIOS_TARGET_ID}"
fi
WORK="${WORK:-$BASE_OUT/amethyst-ios-work}"
SOURCE="$WORK/Amethyst-iOS"
CACHE="$WORK/cache"
STAGE="$WORK/stage-$XIOS_TARGET_ID"
TIPA_STAGE="$WORK/tipa-$XIOS_TARGET_ID"

AMETHYST_REPO="${AMETHYST_REPO:-https://github.com/AngelAuraMC/Amethyst-iOS.git}"
AMETHYST_COMMIT="${AMETHYST_COMMIT:-64c5c9c44148d9cc7c7c4430940b8dcbe9331a44}"
AMETHYST_DATE=20260711
AMETHYST_VERSION="1.0+git${AMETHYST_DATE}.${AMETHYST_COMMIT:0:7}${XIOS_VERSION_SUFFIX}"
BOOTJDK_URL="https://github.com/adoptium/temurin8-binaries/releases/download/jdk8u492-b09/OpenJDK8U-jdk_x64_mac_hotspot_8u492b09.tar.gz"
BOOTJDK_SHA256="dd2cc870118fe9fba136e48b2988cfa63d3bda46cc6f1646677cae27a1a02e99"
BOOTJDK_ARCHIVE="$CACHE/OpenJDK8U-jdk_x64_mac_hotspot_8u492b09.tar.gz"
BOOTJDK_ROOT="$CACHE/temurin8-x64"
BOOTJDK_HOME="$BOOTJDK_ROOT/Contents/Home"
LZMA_DEB="${LZMA_DEB:-$BASE_OUT/liblzma5_5.6.4+ios1_iphoneos-arm64.deb}"
LZMA_DEB_SHA256="d4b736515fb05dc9b7a21d0c6bf37f9c09c7d4b9f00793caf94b499b6d58ebc9"
APP_NAME=AngelAuraAmethyst.app
APP_ID=org.angelauramc.amethyst
APP_INSTALL="$XIOS_PREFIX/Applications/$APP_NAME"
JRE_VERSION="21.0.12$XIOS_VERSION_SUFFIX"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
MODE="${1:---all}"

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

prepare_bootjdk() {
  mkdir -p "$CACHE"
  download "$BOOTJDK_URL" "$BOOTJDK_ARCHIVE" "$BOOTJDK_SHA256"
  if [ ! -x "$BOOTJDK_HOME/bin/javac" ]; then
    mkdir -p "$BOOTJDK_ROOT"
    tar -xzf "$BOOTJDK_ARCHIVE" -C "$BOOTJDK_ROOT" --strip-components=1
  fi
  arch -x86_64 "$BOOTJDK_HOME/bin/javac" -version 2>&1 |
    grep -q '^javac 1\.8\.0_492$' || {
      echo "pinned Java 8 boot JDK failed validation" >&2
      exit 1
    }
}

prepare_source() {
  mkdir -p "$WORK"
  if [ ! -d "$SOURCE/.git" ]; then
    git clone --filter=blob:none --no-checkout "$AMETHYST_REPO" "$SOURCE"
  fi
  git -C "$SOURCE" fetch --quiet --depth 1 origin "$AMETHYST_COMMIT"
  git -C "$SOURCE" checkout --quiet --detach "$AMETHYST_COMMIT"
  git -C "$SOURCE" reset --quiet --hard "$AMETHYST_COMMIT"
  git -C "$SOURCE" clean -fd --quiet
  git -C "$SOURCE" submodule sync --recursive
  git -C "$SOURCE" submodule update --init --recursive
  git -C "$SOURCE" submodule foreach --quiet --recursive \
    'git reset --hard -q && git clean -fdq'

  while IFS= read -r patch_name; do
    case "$patch_name" in
      ""|\#*) continue ;;
    esac
    git -C "$SOURCE" apply "$ROOT/ports/amethyst-ios/patches/$patch_name"
  done < "$ROOT/ports/amethyst-ios/patches/series"
  git -C "$SOURCE" diff --check
  rg -q 'xios-system' "$SOURCE/Natives/LauncherPreferences.m"
  rg -q '/var/jb/usr/lib/jvm/java-21-openjdk' \
    "$SOURCE/Natives/LauncherPreferences.m"
  rg -q '/usr/lib/jvm/java-21-openjdk' \
    "$SOURCE/Natives/LauncherPreferences.m"
}

build_app() {
  echo "==> build pinned Amethyst GUI launcher"
  (
    cd "$SOURCE"
    gmake clean
    gmake -j"$JOBS" package \
      RELEASE=1 \
      SLIMMED_ONLY=1 \
      XIOS_SYSTEM_JRE=1 \
      TROLLSTORE_JIT_ENT=1 \
      BOOTJDK="$BOOTJDK_HOME/bin" \
      PLATFORM=2
  )
  [ -x "$SOURCE/artifacts/Payload/$APP_NAME/AngelAuraAmethyst" ] || {
    echo "Amethyst application build did not produce an executable app" >&2
    exit 1
  }
}

extract_lzma() {
  [ -f "$LZMA_DEB" ] || {
    echo "missing iOS liblzma package: $LZMA_DEB" >&2
    exit 1
  }
  [ "$(sha256 "$LZMA_DEB")" = "$LZMA_DEB_SHA256" ] || {
    echo "liblzma package checksum drifted: $LZMA_DEB" >&2
    exit 1
  }
  local extract="$WORK/liblzma-extract"
  mkdir -p "$extract"
  find "$extract" -mindepth 1 -delete
  docker run --rm --platform linux/arm64 \
    -v "$(dirname "$LZMA_DEB"):/debs:ro" \
    -v "$extract:/extract" \
    "${XLIB_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}" \
    -c "dpkg-deb -x /debs/'$(basename "$LZMA_DEB")' /extract"
  find "$extract" -type f -name 'liblzma.*.dylib' -print -quit
}

stage_app() {
  local app="$STAGE$APP_INSTALL"
  mkdir -p "$STAGE"
  find "$STAGE" -mindepth 1 -delete
  mkdir -p "$(dirname "$app")" "$app/Frameworks" "$STAGE/DEBIAN"
  rsync -a "$SOURCE/artifacts/Payload/$APP_NAME/" "$app/"

  local lzma
  lzma="$(extract_lzma)"
  [ -n "$lzma" ] || {
    echo "liblzma package did not contain a versioned dylib" >&2
    exit 1
  }
  install -m 0755 "$lzma" "$app/Frameworks/liblzma.5.dylib"
  install_name_tool -id '@rpath/liblzma.5.dylib' \
    "$app/Frameworks/liblzma.5.dylib"
  install_name_tool -change /usr/lib/liblzma.5.dylib \
    '@rpath/liblzma.5.dylib' "$app/AngelAuraAmethyst"
  /usr/libexec/PlistBuddy -c 'Set :MinimumOSVersion 17.0' "$app/Info.plist"

  # Refresh the bundle resource seal after changing Info.plist and adding the
  # bundled dependency, then restore the executable's privileged entitlements.
  ldid -S "$app"
  xsign "$app/Frameworks/liblzma.5.dylib"
  xsign "$app/AngelAuraAmethyst" "$SOURCE/entitlements.trollstore.xml" \
    com.apple.private.security.no-sandbox \
    AGXDeviceUserClient \
    platform-application

  cat > "$STAGE/DEBIAN/control" <<EOF
Package: amethyst-ios
Name: Amethyst Minecraft Launcher
Version: $AMETHYST_VERSION
Architecture: $XIOS_DEB_ARCH
Depends: openjdk-21-jre-headless (= $JRE_VERSION)
Description: Graphical Minecraft Java Edition launcher for Xios.
 Uses a native UIKit launcher, patched LWJGL/GLFW input, OpenAL audio and
 iOS-native OpenGL translation. Game ownership or demo access is still required.
Maintainer: max
Author: AngelAuraMC contributors and Xios
Section: Games
Priority: optional
MinimumOSVersion: 17.0
EOF

  cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ -x "$XIOS_INSTALL_PREFIX/bin/uicache" ]; then
  "$XIOS_INSTALL_PREFIX/bin/uicache" -p "$APP_INSTALL" || true
fi
exit 0
EOF
  cat > "$STAGE/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
if [ -x "$XIOS_INSTALL_PREFIX/bin/uicache" ]; then
  "$XIOS_INSTALL_PREFIX/bin/uicache" -u "$APP_ID" || true
fi
exit 0
EOF
  chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"
}

audit_app() {
  local app="$STAGE$APP_INSTALL"
  local count=0 binary macho_loads dylib_loads archs
  while IFS= read -r binary; do
    file "$binary" | grep -q 'Mach-O' || continue
    archs="$(lipo -archs "$binary")"
    grep -qw arm64 <<<"$archs" || {
      echo "non-arm64 application binary: $binary" >&2
      exit 1
    }
    macho_loads="$(otool -l "$binary")"
    if ! grep -A4 LC_BUILD_VERSION <<<"$macho_loads" |
      grep 'platform 2' >/dev/null; then
      grep -q LC_VERSION_MIN_IPHONEOS <<<"$macho_loads" || {
        echo "non-iOS application binary: $binary" >&2
        exit 1
      }
    fi
    dylib_loads="$(otool -L "$binary")"
    if grep -q '/usr/lib/liblzma' <<<"$dylib_loads"; then
      echo "unbundled liblzma dependency remains: $binary" >&2
      exit 1
    fi
    count=$((count + 1))
  done < <(find "$app" -type f -print | sort)
  [ "$count" -ge 20 ] || {
    echo "unexpectedly few Mach-O files in Amethyst app: $count" >&2
    exit 1
  }

  local string_audit="$WORK/amethyst-launcher.strings"
  strings "$app/AngelAuraAmethyst" > "$string_audit"
  grep -q '/var/jb/usr/lib/jvm/java-21-openjdk' "$string_audit"
  grep -q '/usr/lib/jvm/java-21-openjdk' "$string_audit"
  [ "$(plutil -extract CFBundleIdentifier raw "$app/Info.plist")" = "$APP_ID" ]
  [ "$(plutil -extract MinimumOSVersion raw "$app/Info.plist")" = 17.0 ]
  echo "==> audited $count arm64 iOS Mach-O files"
}

package_app() {
  mkdir -p "$OUT"
  local deb
  deb="$(xmkdeb "$STAGE" "$OUT")"

  mkdir -p "$TIPA_STAGE/Payload"
  find "$TIPA_STAGE/Payload" -mindepth 1 -delete
  rsync -a "$STAGE$APP_INSTALL" "$TIPA_STAGE/Payload/"
  local tipa="$OUT/amethyst-ios_${AMETHYST_VERSION}_${XIOS_TARGET_ID}.tipa"
  rm -f "$tipa"
  (cd "$TIPA_STAGE" && zip --symlinks -qry "$tipa" Payload)

  echo "==> packages"
  echo "    $deb"
  echo "    $tipa"
}

for tool in arch curl docker file git gmake install_name_tool ldid lipo \
  otool plutil rg rsync shasum strings tar xcrun zip; do
  need "$tool"
done

case "$MODE" in
  --all)
    prepare_bootjdk
    prepare_source
    build_app
    ;;
  --package-only)
    [ -x "$SOURCE/artifacts/Payload/$APP_NAME/AngelAuraAmethyst" ] || {
      echo "existing Amethyst build missing under $SOURCE/artifacts" >&2
      exit 1
    }
    ;;
  *)
    echo "usage: $0 [--all|--package-only]" >&2
    exit 2
    ;;
esac
stage_app
audit_app
package_app
