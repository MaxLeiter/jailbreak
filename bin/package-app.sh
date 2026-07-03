#!/usr/bin/env bash
# Build an apps/<Name> SwiftUI app and stage it into an installable .deb in
# repo/debs/ — the Sileo/apt counterpart to bin/install-app.sh (which scp-installs
# the same built+signed .app straight to the device).
#
#   bin/package-app.sh apps/TaskManager
#
# The app dir must contain packaging/control (Package/Name/Section/Description;
# Version may be @VERSION@, filled from project.yml's MARKETING_VERSION). The .deb
# ships the ldid-signed .app at /var/jb/Applications/<Name>.app and its postinst
# runs uicache — exactly what install-app.sh does on the device, but packaged.
#
# Mac needs: Xcode, xcodegen, ldid, and Docker (xmkdeb builds the .deb in the
# procursus-xbuild container since macOS has no dpkg-deb).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$(cd "${1:?usage: bin/package-app.sh <app-dir>}" 2>/dev/null && pwd)" \
  || { echo "error: app dir not found: ${1:-}" >&2; exit 1; }
APP_NAME="$(basename "$APP_DIR")"

CTRL_SRC="$APP_DIR/packaging/control"
[ -f "$CTRL_SRC" ] || { echo "error: missing $CTRL_SRC (needed to build the .deb)" >&2; exit 1; }

PKG="$(awk -F': ' '/^Package:/{print $2; exit}' "$CTRL_SRC")"
[ -n "$PKG" ] || { echo "error: no Package: in $CTRL_SRC" >&2; exit 1; }

# Version is single-sourced from project.yml so the .deb can't drift from the app.
VERSION="$(grep -E 'MARKETING_VERSION' "$APP_DIR/project.yml" | head -1 | sed 's/.*: *//' | tr -d '"' || true)"
[ -n "$VERSION" ] || { echo "error: no MARKETING_VERSION in $APP_DIR/project.yml" >&2; exit 1; }

# Build + pseudo-sign (shared with install-app.sh).
. "$REPO_ROOT/bin/lib/build-app.sh"
APP="$(build_app "$APP_DIR")"

echo "==> Staging $PKG $VERSION"
STAGE="/private/tmp/xios-app-pkg/$PKG"
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/Applications"
cp -a "$APP" "$STAGE/var/jb/Applications/${APP_NAME}.app"

# control (fill @VERSION@).
sed "s/@VERSION@/${VERSION}/g" "$CTRL_SRC" > "$STAGE/DEBIAN/control"

# postinst / postrm — same register/unregister as install-app.sh's final step.
DEST="/var/jb/Applications/${APP_NAME}.app"
cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
case "\$1" in
  configure|install|"")
    chmod -R 0755 "$DEST"
    [ -x /var/jb/usr/bin/uicache ] && /var/jb/usr/bin/uicache -p "$DEST" || true
    ;;
esac
exit 0
EOF
cat > "$STAGE/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
case "\$1" in
  remove|purge)
    [ -x /var/jb/usr/bin/uicache ] && /var/jb/usr/bin/uicache -u "$DEST" 2>/dev/null || true
    ;;
esac
exit 0
EOF

# Perms: dirs 0755, maintainer scripts 0755, payload files 0644 except the Mach-O
# (xmkdeb chowns root:root inside the container before building).
find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE/var" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/var/jb/Applications/${APP_NAME}.app/${APP_NAME}"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

# Build the .deb into repo/debs/ (xmkdeb picks dpkg-deb-as-root or the container).
. "$REPO_ROOT/x11/lib/xlib.sh"
built="$(xmkdeb "$STAGE" "$REPO_ROOT/repo/debs")"
echo "==> built $built"
