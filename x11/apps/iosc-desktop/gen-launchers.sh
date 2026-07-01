#!/usr/bin/env bash
# gen-launchers.sh — turn freedesktop .desktop entries into iOS Home Screen apps
# that launch their Linux app inside the iosc Wayland desktop.
#
# For each .desktop it emits a thin per-app .app bundle: a unique bundle id, the
# .desktop's Name as the Home Screen label, its Icon rendered to the iOS sizes,
# and the SHARED prebuilt IOSCLaunch binary (the launch target is carried in the
# bundle's own Info.plist, so the same signed Mach-O drives every app). Tapping the
# icon asks the ioscd daemon to run the app as an iosc client + show the display.
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
  # Native flavor: each bundle IS the per-app host (Metal-presents the app's own
  # windows in its own UIWindowScene). The shared payload is the host binary + its
  # compiled shader (see x11/apps/iosc-host/build-host.sh).
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

  # Strip freedesktop field codes (%f %F %u %U %i %c %k %d %v %m) from Exec.
  EXEC="$(echo "$EXEC_RAW" | sed -E 's/ ?%[fFuUickdvm]//g; s/[[:space:]]+$//')"

  # app_id: prefer StartupWMClass (what GTK reports as the Wayland app_id), else
  # the .desktop basename (which for GNOME apps IS the app-id, e.g. org.gnome.Console).
  APPID="$WMCLASS"; [ -n "$APPID" ] || APPID="$(basename "$DESKTOP" .desktop)"

  SAN="$(sanitize "$APPID")"
  BUNDLE_ID="com.max.iosc.$SAN"
  BDIR="$OUT/$SAN.app"

  echo "==> $NAME  (app_id=$APPID  exec=$EXEC)"
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

  # Static Info.plist (dynamic string values get set via PlistBuddy below so any
  # &, quotes, etc. in Name/Exec are escaped correctly). The classic bundle runs
  # ONE fullscreen landscape Xios window; the native bundle is a multi-scene host
  # that follows device rotation.
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
  <key>IOSCExec</key><string></string>
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
  <key>IOSCExec</key><string></string>
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
  "$PB" -c "Set :IOSCExec $EXEC"                "$BDIR/Info.plist"
  "$PB" -c "Set :IOSCAppID $APPID"              "$BDIR/Info.plist"
  "$PB" -c "Set :IOSCName $NAME"                "$BDIR/Info.plist"

  # Icons
  "$PY" "$HERE/gen-icons.py" --icon "$ICON" --name "$NAME" \
        --icons-root "$ICONS_ROOT" --out "$BDIR"

  # Pseudo-sign the bundle's copy of the binary. Native hosts need the GPU/IOSurface
  # entitlements (Metal present + task_for_pid canvas rendezvous); the classic stub
  # needs only the minimal launcher set.
  if [ "$NATIVE" = "1" ]; then
    ldid -S"$HOST_DIR/entitlements.plist" "$BDIR/IOSCHost"
  else
    ldid -S"$HERE/launcher-ent.xml" "$BDIR/IOSCLaunch"
  fi

  BUILT+=("$BDIR")
done

echo
echo "==> built ${#BUILT[@]} launcher bundle(s) in $OUT"
for b in "${BUILT[@]}"; do echo "    $b"; done

if [ "$DEPLOY" = "1" ]; then
  echo
  echo "==> --deploy: installing to the device (needs $REPO_ROOT/device.env)"
  [ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }
  IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"; PORT="${THEOS_DEVICE_PORT:-22}"
  KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
  SSH_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")
  for b in "${BUILT[@]}"; do
    dest="/var/jb/Applications/$(basename "$b")"
    echo "   -> $IP:$dest"
    ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" "rm -rf '$dest'"
    scp -P "$PORT" "${SSH_OPTS[@]}" -r "$b" "root@$IP:/var/jb/Applications/"
    ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" \
      "chmod -R 0755 '$dest'; /var/jb/usr/bin/uicache -p '$dest'"
  done
  echo "==> deployed. Tap the new icons on the Home Screen."
fi
