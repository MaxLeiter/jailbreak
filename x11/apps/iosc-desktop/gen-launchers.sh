#!/usr/bin/env bash
# Turns freedesktop .desktop entries into iOS Home Screen apps that launch
# their Linux app inside the iosc Wayland desktop.
#
# Each bundle shares one prebuilt IOSCLaunch binary and identifies its installed
# desktop entry by app id, so the same signed Mach-O drives every app.
#
# HOST-SIDE ONLY. No device contact unless you pass --deploy (off by default).
# See x11/docs/iosc-desktop-env.md for the full design + the device test plan.
#
# Usage:
#   gen-launchers.sh --icons-root <share-dir> [--out <dir>] [--deploy] <app.desktop>...
#   gen-launchers.sh --icons-root <share-dir> --apps-root <applications-dir>   # scan all
#
#   --icons-root  a host-readable mirror of /var/jb/usr/share (for icons/ + pixmaps/).
#                 Get it by rsync from the device, or by extracting the app's deb:
#                   dpkg-deb -x gnome-console_*.deb stage && \
#                     gen-launchers.sh --icons-root stage/var/jb/usr/share ...
#                 Multiple roots may be colon-separated.
#   --apps-root   scan this dir for *.desktop instead of listing them (skips NoDisplay).
#   --out         where bundles are written (default: out/bundles).
#   --deploy      scp each bundle to the device + uicache (needs device.env; LEAD only).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
OUT="$HERE/out/bundles"
ICONS_ROOT=""
APPS_ROOT=""
DEPLOY=0
NATIVE=0
DESKTOPS=()
HOST_DIR="$REPO_ROOT/x11/apps/iosc-host"

while [ $# -gt 0 ]; do
  case "$1" in
    --icons-root) ICONS_ROOT="$2"; shift 2 ;;
    --apps-root)  APPS_ROOT="$2";  shift 2 ;;
    --out)        OUT="$2";        shift 2 ;;
    --deploy)     DEPLOY=1;        shift ;;
    --native)     NATIVE=1;        shift ;;   # per-app windows (iosc-host), not one Xios window
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    *)            DESKTOPS+=("$1"); shift ;;
  esac
done

PY="$REPO_ROOT/.repo-venv/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
PB=/usr/libexec/PlistBuddy

# Build the shared prebuilt binaries if they aren't here yet.
if [ "$NATIVE" = "1" ]; then
  # Native flavor: each bundle IS the per-app host, Metal-presenting its own
  # windows in its own UIWindowScene (built by build-host.sh).
  if [ ! -x "$HOST_DIR/out/IOSCHost" ] || [ ! -f "$HOST_DIR/out/default.metallib" ]; then
    echo "==> iosc-host prebuilt missing; building it first"
    bash "$HOST_DIR/build-host.sh"
  fi
elif [ ! -x "$HERE/out/IOSCLaunch" ]; then
  echo "==> IOSCLaunch missing; building stubs first"
  bash "$HERE/build-stub.sh"
fi

# Collect .desktop files from --apps-root if none were listed explicitly.
if [ ${#DESKTOPS[@]} -eq 0 ] && [ -n "$APPS_ROOT" ]; then
  while IFS= read -r f; do DESKTOPS+=("$f"); done \
    < <(find "$APPS_ROOT" -maxdepth 1 -name '*.desktop' | sort)
fi
[ ${#DESKTOPS[@]} -gt 0 ] || { echo "error: no .desktop files given (list them or use --apps-root)"; exit 1; }

mkdir -p "$OUT"

# Read the first value of `key=` inside the [Desktop Entry] group (exact key, so
# localized Name[xx] keys are ignored). Prints nothing if absent.
desktop_field() {  # $1=file  $2=key
  awk -F= -v k="$2" '
    /^\[/ { inentry = ($0 == "[Desktop Entry]") }
    inentry && index($0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit }
  ' "$1"
}

# Lowercase + keep only [a-z0-9.-]; collapse the rest to "-" (bundle-id safe).
sanitize() { echo "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9.-]+/-/g; s/^-+//; s/-+$//'; }

BUILT=()
for DESKTOP in "${DESKTOPS[@]}"; do
  [ -f "$DESKTOP" ] || { echo "skip (not found): $DESKTOP"; continue; }
  TYPE="$(desktop_field "$DESKTOP" Type)"
  [ -z "$TYPE" ] || [ "$TYPE" = "Application" ] || { echo "skip (Type=$TYPE): $DESKTOP"; continue; }
  [ "$(desktop_field "$DESKTOP" NoDisplay)" = "true" ] && { echo "skip (NoDisplay): $DESKTOP"; continue; }

  NAME="$(desktop_field "$DESKTOP" Name)"
  ICON="$(desktop_field "$DESKTOP" Icon)"
  EXEC_RAW="$(desktop_field "$DESKTOP" Exec)"
  WMCLASS="$(desktop_field "$DESKTOP" StartupWMClass)"
  [ -n "$EXEC_RAW" ] || { echo "skip (no Exec): $DESKTOP"; continue; }
  [ -n "$NAME" ] || NAME="$(basename "$DESKTOP" .desktop)"

  # app_id: prefer StartupWMClass (what GTK reports as the Wayland app_id), else
  # the .desktop basename (which for GNOME apps IS the app-id, e.g. org.gnome.Console).
  APPID="$WMCLASS"; [ -n "$APPID" ] || APPID="$(basename "$DESKTOP" .desktop)"

  SAN="$(sanitize "$APPID")"
  BUNDLE_ID="com.max.iosc.$SAN"
  BDIR="$OUT/$SAN.app"

  echo "==> $NAME  (app_id=$APPID)"
  rm -rf "$BDIR"; mkdir -p "$BDIR"

  if [ "$NATIVE" = "1" ]; then
    # Native: the bundle binary IS the per-app host + its compiled shader.
    EXE=IOSCHost
    cp "$HOST_DIR/out/IOSCHost"        "$BDIR/IOSCHost"
    cp "$HOST_DIR/out/default.metallib" "$BDIR/default.metallib"
    chmod 0755 "$BDIR/IOSCHost"
  else
    EXE=IOSCLaunch
    cp "$HERE/out/IOSCLaunch" "$BDIR/IOSCLaunch"
    chmod 0755 "$BDIR/IOSCLaunch"
  fi

  # Placeholder values below get set via PlistBuddy so &, quotes, etc. in
  # Names are escaped correctly. Classic bundle = one fullscreen landscape
  # Xios window; native bundle = multi-scene host that follows device rotation.
  if [ "$NATIVE" = "1" ]; then
    cat > "$BDIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>IOSCHost</string>
  <key>CFBundleIdentifier</key><string>PLACEHOLDER_ID</string>
  <key>CFBundleName</key><string>PLACEHOLDER_NAME</string>
  <key>CFBundleDisplayName</key><string>PLACEHOLDER_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>UIDeviceFamily</key><array><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIStatusBarHidden</key><true/>
  <key>UIApplicationSupportsIndirectInputEvents</key><true/>
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key><true/>
    <key>UISceneConfigurations</key>
    <dict>
      <key>UIWindowSceneSessionRoleApplication</key>
      <array>
        <dict>
          <key>UISceneConfigurationName</key><string>Default</string>
          <key>UISceneDelegateClassName</key><string>IOSCHost.HostSceneDelegate</string>
        </dict>
      </array>
    </dict>
  </dict>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>IOSCAppID</key><string></string>
  <key>IOSCName</key><string></string>
  <key>CFBundleIcons</key>
  <dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key>
    <array><string>AppIcon60x60</string><string>AppIcon76x76</string></array></dict></dict>
  <key>CFBundleIcons~ipad</key>
  <dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key>
    <array><string>AppIcon60x60</string><string>AppIcon76x76</string><string>AppIcon83.5x83.5</string></array></dict></dict>
</dict>
</plist>
PLIST
  else
    cat > "$BDIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>IOSCLaunch</string>
  <key>CFBundleIdentifier</key><string>PLACEHOLDER_ID</string>
  <key>CFBundleName</key><string>PLACEHOLDER_NAME</string>
  <key>CFBundleDisplayName</key><string>PLACEHOLDER_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>16.0</string>
  <key>UIDeviceFamily</key><array><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIRequiresFullScreen</key><true/>
  <key>UIStatusBarHidden</key><true/>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>IOSCAppID</key><string></string>
  <key>IOSCName</key><string></string>
  <key>CFBundleIcons</key>
  <dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key>
    <array><string>AppIcon60x60</string><string>AppIcon76x76</string></array></dict></dict>
  <key>CFBundleIcons~ipad</key>
  <dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleIconFiles</key>
    <array><string>AppIcon60x60</string><string>AppIcon76x76</string><string>AppIcon83.5x83.5</string></array></dict></dict>
</dict>
</plist>
PLIST
  fi

  "$PB" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$BDIR/Info.plist"
  "$PB" -c "Set :CFBundleName $NAME"            "$BDIR/Info.plist"
  "$PB" -c "Set :CFBundleDisplayName $NAME"     "$BDIR/Info.plist"
  "$PB" -c "Set :IOSCAppID $APPID"              "$BDIR/Info.plist"
  "$PB" -c "Set :IOSCName $NAME"                "$BDIR/Info.plist"

  # Icons
  "$PY" "$HERE/gen-icons.py" --icon "$ICON" --name "$NAME" \
        --icons-root "$ICONS_ROOT" --out "$BDIR"

  # Native hosts need GPU/IOSurface entitlements (Metal present + task_for_pid
  # canvas rendezvous); the classic stub needs only the minimal launcher set.
  if [ "$NATIVE" = "1" ]; then
    xsign "$BDIR/IOSCHost" "$HOST_DIR/entitlements.plist" \
      AGXDeviceUserClient IOGPUDeviceUserClient IOSurfaceRootUserClient
  else
    xsign "$BDIR/IOSCLaunch" "$HERE/launcher-ent.xml"
  fi

  BUILT+=("$BDIR")
done

echo
echo "==> built ${#BUILT[@]} launcher bundle(s) in $OUT"
for b in "${BUILT[@]}"; do echo "    $b"; done

if [ "$DEPLOY" = "1" ]; then
  echo
  echo "==> --deploy: installing to the device (needs $REPO_ROOT/device.env)"
  . "$HERE/deploy-env.sh"   # IP/PORT/SSH_OPTS + ssh_/scp_ (loads device.env)

  # Which executable + entitlements each bundle carries (native host vs classic stub).
  if [ "$NATIVE" = "1" ]; then
    EXE_NAME=IOSCHost;   ENT_SRC="$HOST_DIR/entitlements.plist"
  else
    EXE_NAME=IOSCLaunch; ENT_SRC="$HERE/launcher-ent.xml"
  fi
  # Signing host-side isn't enough: SpringBoard launches a tapped bundle through
  # AMFI, which rejects a bundle whose on-disk cdhash it doesn't trust. Re-sign
  # in place with ldid + register the cdhash to make the first tap work.
  DEV_ENT="/var/jb/tmp/iosc-deploy-ent.plist"
  scp_ "$ENT_SRC" "root@$IP:$DEV_ENT"

  for b in "${BUILT[@]}"; do
    dest="/var/jb/Applications/$(basename "$b")"
    exe="$dest/$EXE_NAME"
    echo "   -> $IP:$dest"
    ssh_ "rm -rf '$dest'"
    scp_ -r "$b" "root@$IP:/var/jb/Applications/"
    # Trust-cache add is best-effort: palera1n/ellekit accept the ldid ad-hoc
    # signature directly even without it.
    ssh_ "set -e
      chmod -R 0755 '$dest'
      if command -v ldid >/dev/null 2>&1; then ldid -S'$DEV_ENT' '$exe'; fi
      if command -v jbctl >/dev/null 2>&1; then jbctl trust add '$exe' 2>/dev/null || jbctl trustcache add '$exe' 2>/dev/null || true
      elif command -v trustcache >/dev/null 2>&1; then trustcache add '$exe' 2>/dev/null || true
      elif command -v ellekitc >/dev/null 2>&1; then ellekitc trustcache '$exe' 2>/dev/null || true
      else echo 'note: no trust-cache CLI found; relying on the ldid ad-hoc signature (fine on palera1n/ellekit)'; fi
      /var/jb/usr/bin/uicache -p '$dest'"
  done
  ssh_ "rm -f '$DEV_ENT'"
  echo "==> deployed. Tap the new icons on the Home Screen."
  echo "    If a tap fails with launch error 3/9, the JB needs an explicit"
  echo "    trust-cache add for /var/jb/Applications/*/$EXE_NAME (see above)."
fi
