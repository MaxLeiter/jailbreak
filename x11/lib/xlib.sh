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
#   xstage_lagom_fonts <fonts_dir> [cache_dir]    stage Ladybird's text fonts
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
    # Entitlement files are committed with rootless path exceptions. A binary
    # signed for another target needs its OWN prefix excepted -- the exception is
    # what lets it read its libraries and sockets at all, so a stale /var/jb here
    # is a sandbox denial on device, not a cosmetic mismatch. Render a copy for
    # the selected target rather than making every caller remember to.
    # XIOS_PREFIX comes from linux-build/target-lib.sh; unset means rootless, so
    # this is a no-op for every existing caller.
    if [ -n "$ents" ] && [ "${XIOS_PREFIX-/var/jb}" != "/var/jb" ]; then
        local rendered
        rendered="$(mktemp -t xios-ents)" || return 1
        # An empty prefix must NOT become "/": that grants the whole filesystem
        # where rootless granted one directory. Rootful installs under the
        # subprefix, so that is what gets excepted.
        local ent_prefix="${XIOS_PREFIX:-${XIOS_SUBPREFIX:-/usr}}"
        sed -e "s|/var/jb/tmp|${XIOS_RUNTIME_TMP:-/var/tmp}|g" \
            -e "s|<string>/var/jb/</string>|<string>$ent_prefix/</string>|g" \
            -e "s|<string>/private/var/jb/</string>|<string>$ent_prefix/</string>|g" \
            -e "s|/var/jb/|$ent_prefix/|g" "$ents" > "$rendered"
        echo "xsign: rendered $ents for prefix ${XIOS_PREFIX:-/}" >&2
        ents="$rendered"
    fi
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

# ---- Ladybird resource fonts ----------------------------------------------
# xstage_lagom_fonts <share/Lagom/fonts dir> [cache dir]
#   Stages the Liberation text family (Sans/Serif/Mono x Regular/Bold/Italic/
#   BoldItalic) into a Ladybird resource font directory, then fails if the result
#   still has no monospace face.
#
#   WebContent loads fonts ONLY from resource://fonts -- that is, exactly this
#   directory. It never walks Gfx::FontDatabase::font_directories(), and the iOS
#   build has no fontconfig (USE_FONTCONFIG is gated `if (NOT APPLE)`), so nothing
#   under $XIOS_PREFIX/usr/share/fonts is visible to it. Upstream Base/res/fonts --
#   all that `cmake --install --component ladybird_Runtime` ships -- is NotoEmoji +
#   SerenitySans-Regular, neither of them monospace, so
#   Web::Platform::FontPlugin's VERIFY(m_default_fixed_width_font) aborts
#   WebContent on every launch. Liberation is the fix because its family names
#   ("Liberation Sans/Serif/Mono") are already in the engine's generic-family
#   fallback lists, so no engine patch is needed.
#
#   Same font set, URL and cache filename as the "bundle text fonts (Liberation)"
#   step in linux-build/build-ladybird-app-bundle.sh, which does this for the .app
#   flavor (that one runs inside the build container and caches in the Procursus
#   volume; this one runs on the host).
#
#   Set LADYBIRD_LIBERATION_TTF_DIR=<dir containing Liberation*.ttf> to stage from
#   a local copy instead of downloading.
xstage_lagom_fonts() {
    local fonts_dir="$1"; shift || true
    local cache="${1:-${LADYBIRD_FONT_CACHE:-$XLIB_ROOT/linux-build/out/.font-cache}}"

    [ -n "$fonts_dir" ] || {
        echo "xstage_lagom_fonts: ERROR missing fonts directory argument" >&2; return 1; }
    mkdir -p "$fonts_dir" || return 1

    if [ -n "${LADYBIRD_LIBERATION_TTF_DIR:-}" ]; then
        [ -d "$LADYBIRD_LIBERATION_TTF_DIR" ] || {
            echo "xstage_lagom_fonts: ERROR LADYBIRD_LIBERATION_TTF_DIR is not a directory: $LADYBIRD_LIBERATION_TTF_DIR" >&2
            return 1; }
        find "$LADYBIRD_LIBERATION_TTF_DIR" -name 'Liberation*.ttf' -exec cp -f {} "$fonts_dir/" \; || return 1
    else
        local url="https://github.com/liberationfonts/liberation-fonts/files/7261482/liberation-fonts-ttf-2.1.5.tar.gz"
        local sha256="7191c669bf38899f73a2094ed00f7b800553364f90e2637010a69c0e268f25d0"
        local tarball="$cache/liberation-fonts-ttf-2.1.5.tar.gz"
        mkdir -p "$cache" || return 1
        if [ ! -s "$tarball" ]; then
            echo "xstage_lagom_fonts: downloading Liberation fonts -> $tarball" >&2
            curl -sL --connect-timeout 20 --retry 3 -o "$tarball" "$url" || {
                rm -f "$tarball"
                echo "xstage_lagom_fonts: ERROR download failed: $url" >&2
                echo "xstage_lagom_fonts:   set LADYBIRD_LIBERATION_TTF_DIR to stage offline" >&2
                return 1; }
        fi
        # Pin the archive: this is fetched over the network into a shipped deb, and a
        # silently-changed upstream file would be baked into every build from then on.
        local have_sha
        have_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')" || return 1
        [ "$have_sha" = "$sha256" ] || {
            echo "xstage_lagom_fonts: ERROR checksum mismatch for $tarball" >&2
            echo "xstage_lagom_fonts:   want $sha256" >&2
            echo "xstage_lagom_fonts:   got  $have_sha  (delete the file to re-fetch)" >&2
            return 1; }
        local tmp
        tmp="$(mktemp -d)" || return 1
        tar xzf "$tarball" -C "$tmp" || {
            rm -rf "$tmp"
            echo "xstage_lagom_fonts: ERROR could not unpack $tarball (delete it and retry)" >&2
            return 1; }
        find "$tmp" -name 'Liberation*.ttf' -exec cp -f {} "$fonts_dir/" \;
        rm -rf "$tmp"
    fi

    # Gate on the monospace face specifically: that is the one FontPlugin VERIFYs,
    # so "some fonts were copied" is not the property worth asserting here.
    ls "$fonts_dir"/*Mono*.ttf >/dev/null 2>&1 || {
        echo "xstage_lagom_fonts: ERROR no monospace font in $fonts_dir -- WebContent would abort" >&2
        return 1; }
    chmod 0644 "$fonts_dir"/*.ttf || return 1
    echo "xstage_lagom_fonts: staged $(ls "$fonts_dir" | wc -l | tr -d ' ') fonts in $fonts_dir" >&2
}

# ---- deb extraction into a cross sysroot ----------------------------------
# xdeb_find <stem> <dir>...  -> newest matching <stem>_*_iphoneos-arm64.deb, or 1.
xdeb_find() {
    local stem="$1"; shift
    local d f
    for d in "$@"; do
        [ -d "$d" ] || continue
        f="$(ls -t "$d/${stem}_"*_$XIOS_DEB_ARCH.deb 2>/dev/null | head -1 || true)"
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
