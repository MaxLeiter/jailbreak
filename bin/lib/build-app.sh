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
      -derivedDataPath "$app_dir/build" \
      CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
      -quiet build >&2
  ) || { echo "build_app: xcodebuild failed for $app_name" >&2; return 1; }

  app="$app_dir/build/Build/Products/Release-iphoneos/${app_name}.app"
  [ -d "$app" ] || { echo "build_app: build did not produce $app" >&2; return 1; }

  # Nested bundles first, outer app last. An app extension is a SEPARATE Mach-O
  # that AMFI validates on its own: an unsigned .appex does not fail the build and
  # does not fail the install — it silently never loads (no share sheet entry, no
  # crash log), which is a miserable thing to debug. Each .appex gets its own
  # entitlements, because it is its own sandboxed process and does not inherit the
  # host app's.
  #
  # Entitlements for PlugIns/<Ext>.appex are looked up as, in order:
  #   <app_dir>/<Ext>/entitlements.plist   (per-extension source dir — preferred)
  #   <app_dir>/<Ext>.entitlements
  # An extension with neither is signed bare (ldid -S) rather than inheriting the
  # app's: the app's entitlements name app-only things (camera/mic TCC, GPU IOKit
  # user clients) that an extension has no business carrying.
  if [ -d "$app/PlugIns" ]; then
    for appex in "$app"/PlugIns/*.appex; do
      [ -d "$appex" ] || continue
      local ext_name ext_bin ext_ent cand
      ext_name="$(basename "$appex" .appex)"
      ext_bin="$appex/$ext_name"
      [ -f "$ext_bin" ] || { echo "build_app: $appex has no $ext_name binary" >&2; return 1; }

      ext_ent=""
      for cand in "$app_dir/$ext_name/entitlements.plist" "$app_dir/$ext_name.entitlements"; do
        [ -f "$cand" ] && { ext_ent="$cand"; break; }
      done

      if [ -n "$ext_ent" ]; then
        echo "==> Pseudo-signing extension $ext_name (${ext_ent##*/})" >&2
        ldid -S"$ext_ent" "$ext_bin" >&2
      else
        echo "==> Pseudo-signing extension $ext_name (no entitlements)" >&2
        ldid -S "$ext_bin" >&2
      fi
    done
  fi

  echo "==> Pseudo-signing with ldid" >&2
  if [ -f "$app_dir/entitlements.plist" ]; then
    ldid -S"$app_dir/entitlements.plist" "$app/${app_name}" >&2
  else
    ldid -S "$app/${app_name}" >&2
  fi

  echo "$app"
}
