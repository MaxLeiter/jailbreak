# Shared helpers for the x11-on-iOS build/sign/package scripts.
# NOT executable: source it. The one-line idiom that works from any depth is:
#
#   _x="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
#   . "$_x/lib/xlib.sh"
#
# After sourcing, $XLIB_ROOT is the x11 dir (the one containing lib/ + tools/).
# Everything here fails loud (returns non-zero) so callers under `set -e` abort
# on a signing/packaging error instead of shipping something broken.
#
# Provides:
#   xsign   <bin> [ents] [required-marker...]   ldid-sign + verify entitlements
#   xmkdeb  <staging_dir> <out_dir> [--no-minos]  build a .deb (+ minos stamp)
#   xdeb_find    <stem> <dir>...                  newest matching iphoneos deb path
#   xdeb_extract <sysroot> <deb-dir-list> <pkg>... extract dev debs into a sysroot

# Resolve the x11 root from this file's own location (works when sourced).
XLIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- signing --------------------------------------------------------------
# xsign <binary> [entitlements] [required-marker...]
#   ldid-signs <binary>. With an entitlements plist, uses it (DER-encoded by the
#   Mac/Homebrew ldid, which iOS 15+/16 AMFI requires for IOKit/IOSurface/
#   task_for_pid); without one, ad-hoc signs. Every required-marker must then show
#   up in `ldid -e`, else it fails — the check the 28 inline `ldid -S` sites lacked.
xsign() {
    local bin="$1"; shift || true
    local ents=""
    if [ $# -gt 0 ] && [ -f "$1" ]; then ents="$1"; shift; fi

    command -v ldid >/dev/null 2>&1 || {
        echo "xsign: ERROR ldid not found (brew install ldid)" >&2; return 1; }
    [ -n "$bin" ] && [ -f "$bin" ] || {
        echo "xsign: ERROR missing binary: $bin" >&2; return 1; }
    if [ -n "$ents" ]; then
        ldid -S"$ents" "$bin" || { echo "xsign: ERROR ldid failed on $bin" >&2; return 1; }
    else
        ldid -S "$bin" || { echo "xsign: ERROR ldid failed on $bin" >&2; return 1; }
    fi

    if [ $# -gt 0 ]; then
        local have need
        have="$(ldid -e "$bin" 2>/dev/null || true)"
        for need in "$@"; do
            grep -q "$need" <<<"$have" || {
                echo "xsign: ERROR $bin is missing entitlement marker: $need" >&2
                return 1; }
        done
    fi
    echo "xsign: signed $bin${ents:+ ($ents)}" >&2
}

# ---- packaging ------------------------------------------------------------
# xmkdeb <staging_dir> <out_dir> [--minos]
#   Assembles <staging_dir> (must hold DEBIAN/control) into a root-owned, zstd .deb
#   named <Package>_<Version>_<Architecture>.deb (read from control) in <out_dir>.
#   Echoes the resulting .deb path.
#
#   The catalog needs root:root ownership. If dpkg-deb is present AND we are root
#   (running inside the cross-build container), build directly. Otherwise (a macOS
#   host, which has no dpkg-deb) shell out to the container to chown + dpkg-deb,
#   exactly as the hand-rolled packagers did. Override the image with
#   XLIB_XBUILD_IMAGE.
#
#   MinimumOSVersion stamping is a deliberate SEPARATE final sweep in this repo
#   (tools/stamp-minos.py over out/, done last because concurrent builds churn
#   out/), so xmkdeb does NOT stamp unless you pass --minos.
xmkdeb() {
    local stage="$1" out="$2" minos=0
    [ "${3:-}" = "--minos" ] && minos=1
    local ctrl="$stage/DEBIAN/control"
    [ -f "$ctrl" ] || { echo "xmkdeb: ERROR no DEBIAN/control in $stage" >&2; return 1; }

    local pkg ver arch
    pkg="$(awk -F': ' '/^Package:/{print $2; exit}'      "$ctrl")"
    ver="$(awk -F': ' '/^Version:/{print $2; exit}'      "$ctrl")"
    arch="$(awk -F': ' '/^Architecture:/{print $2; exit}' "$ctrl")"
    [ -n "$pkg" ] && [ -n "$ver" ] && [ -n "$arch" ] || {
        echo "xmkdeb: ERROR control missing Package/Version/Architecture" >&2; return 1; }

    mkdir -p "$out"
    local debname="${pkg}_${ver}_${arch}.deb"
    local deb="$out/$debname"

    if command -v dpkg-deb >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
        chown -R 0:0 "$stage" 2>/dev/null || true
        dpkg-deb -Zzstd --build "$stage" "$deb" >/dev/null || {
            echo "xmkdeb: ERROR dpkg-deb failed for $pkg" >&2; return 1; }
    elif command -v docker >/dev/null 2>&1; then
        local img="${XLIB_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}"
        local parent base
        parent="$(cd "$(dirname "$stage")" && pwd)"
        base="$(basename "$stage")"
        # stdout MUST stay clean: xmkdeb echoes only the deb path (callers capture
        # it via $(...)), so send dpkg-deb's build chatter to stderr.
        docker run --rm --platform linux/arm64 -v "$parent:/stage" "$img" \
          -c "chown -R 0:0 /stage/'$base' && dpkg-deb -Zzstd --build /stage/'$base' /stage/'$debname'" 1>&2 \
          || { echo "xmkdeb: ERROR container dpkg-deb failed for $pkg" >&2; return 1; }
        cp "$parent/$debname" "$deb" || { echo "xmkdeb: ERROR copying $debname to $out" >&2; return 1; }
    else
        echo "xmkdeb: ERROR need either dpkg-deb (as root) or docker to build $pkg" >&2
        return 1
    fi

    if [ "$minos" = 1 ] && [ -f "$XLIB_ROOT/tools/stamp-minos.py" ]; then
        python3 "$XLIB_ROOT/tools/stamp-minos.py" "$deb" >/dev/null 2>&1 ||
          echo "xmkdeb: WARNING minos stamp failed for $deb (continuing)" >&2
    fi
    echo "$deb"
}

# ---- deb extraction into a cross sysroot ----------------------------------
# xdeb_find <stem> <dir>...  -> newest matching <stem>_*_iphoneos-arm64.deb, or 1.
xdeb_find() {
    local stem="$1"; shift
    local d f
    for d in "$@"; do
        [ -d "$d" ] || continue
        f="$(ls -t "$d/${stem}_"*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)"
        [ -n "$f" ] && { echo "$f"; return 0; }
    done
    return 1
}

# xdeb_extract <sysroot> "<space-separated deb dirs>" <pkg-stem>...
#   dpkg-deb -x each pkg (first dir that has it wins) into <sysroot>. Fails loud on
#   the first missing package, naming where it looked.
xdeb_extract() {
    local sys="$1" dirs="$2"; shift 2
    local pat f
    for pat in "$@"; do
        f="$(xdeb_find "$pat" $dirs || true)"
        [ -n "$f" ] || { echo "xdeb_extract: ERROR missing deb: $pat (searched: $dirs)" >&2; return 1; }
        dpkg-deb -x "$f" "$sys" || { echo "xdeb_extract: ERROR failed to extract $f" >&2; return 1; }
        echo "   + $(basename "$f")"
    done
}
