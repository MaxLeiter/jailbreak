#!/usr/bin/env bash
# Build the ca-certificates deb from this package dir (rootless only). Not a template
# package: it ships symlinks, which build-template-package.sh does not stage.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11DIR="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$X11DIR/.." && pwd)"
. "$X11DIR/lib/xlib.sh"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ca-certificates.XXXXXX")/ca-certificates"
trap 'rm -rf "$(dirname "$STAGE")"' EXIT
mkdir -p "$STAGE"
cp -a "$HERE/DEBIAN" "$HERE/var" "$STAGE/"
find "$STAGE" -name .DS_Store -delete
chmod 0644 "$STAGE/DEBIAN/control" "$STAGE/DEBIAN/conffiles"

n="$(grep -c 'BEGIN CERTIFICATE' "$STAGE/var/jb/etc/ssl/certs/cacert.pem")"
[ "$n" -gt 100 ] || { echo "cacert.pem has only $n certificates" >&2; exit 2; }
for root in "emSign ECC Root CA - G3" "Comodo AAA Services root"; do
    if grep -qx "$root" "$STAGE/var/jb/etc/ssl/certs/cacert.pem"; then
        echo "cacert.pem still contains '$root'" >&2; exit 2
    fi
done

xdeb_refuse_published "$STAGE" || { echo "Bump Version in DEBIAN/control." >&2; exit 2; }
OUT="$X11DIR/linux-build/out"
built="$(xmkdeb "$STAGE" "$OUT")"
cp -c "$built" "$REPO/repo/debs/" 2>/dev/null || cp "$built" "$REPO/repo/debs/"
echo "==> built $built ($n certificates)"
