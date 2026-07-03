#!/usr/bin/env bash
# Shared build + pseudo-sign for the SwiftUI apps under apps/<Name>.
# Sourced by bin/install-app.sh (which then scp-installs) and bin/package-app.sh
# (which then stages the result into a .deb) so both use one build path.
#
#   build_app <app-dir>   # prints the absolute path to the built, ldid-signed .app
#
# All build chatter goes to stderr; stdout is ONLY the .app path so callers can
# capture it with $(...).

build_app() {
  local app_dir app_name app
  app_dir="$(cd "$1" 2>/dev/null && pwd)" || { echo "build_app: app dir not found: $1" >&2; return 1; }
  app_name="$(basename "$app_dir")"

  (
    cd "$app_dir"
    echo "==> Generating Xcode project (xcodegen): $app_name" >&2
    xcodegen generate >&2
    echo "==> Building $app_name (Release, iphoneos, unsigned)" >&2
    xcodebuild \
      -project "${app_name}.xcodeproj" \
      -scheme "${app_name}" \
      -configuration Release \
      -sdk iphoneos \
      -derivedDataPath build \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
      -quiet build >&2
  ) || { echo "build_app: xcodebuild failed for $app_name" >&2; return 1; }

  app="$app_dir/build/Build/Products/Release-iphoneos/${app_name}.app"
  [ -d "$app" ] || { echo "build_app: build did not produce $app" >&2; return 1; }

  echo "==> Pseudo-signing with ldid" >&2
  if [ -f "$app_dir/entitlements.plist" ]; then
    ldid -S"$app_dir/entitlements.plist" "$app/${app_name}" >&2
  else
    ldid -S "$app/${app_name}" >&2
  fi

  echo "$app"
}
