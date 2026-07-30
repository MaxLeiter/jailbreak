#!/usr/bin/env bash
# Stage the GNU gettext Darwin ABI needed by C/C++ cross-builds into a private
# rootless iOS SDK. Runtime ownership remains with libintl8 + libgtkintl.
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 TARGET_PREFIX IOS_CC APPLE_SDK [MIN_IOS]" >&2
  exit 2
fi

TARGET_PREFIX="$1"
CC="$2"
APPLE_SDK="$3"
MIN_IOS="${4:-16.0}"
WORK="${TMPDIR:-/tmp}/xios-gettext-sdk"

[ -f "$TARGET_PREFIX/lib/libgtkintl.dylib" ] || {
  echo "missing libgtkintl.dylib in $TARGET_PREFIX/lib" >&2
  exit 2
}

mkdir -p "$TARGET_PREFIX/include" "$TARGET_PREFIX/lib" "$WORK"

# Debian's gettext header includes glibc-only headers. This compact public
# surface matches GNU gettext's Darwin-prefixed ABI without importing glibc.
cat > "$TARGET_PREFIX/include/libintl.h" <<'EOF'
#ifndef XIOS_LIBINTL_H
#define XIOS_LIBINTL_H 1
#ifdef __cplusplus
extern "C" {
#endif
extern char *libintl_gettext (const char *);
extern char *libintl_dgettext (const char *, const char *);
extern char *libintl_dcgettext (const char *, const char *, int);
extern char *libintl_ngettext (const char *, const char *, unsigned long);
extern char *libintl_dngettext (const char *, const char *, const char *,
                               unsigned long);
extern char *libintl_dcngettext (const char *, const char *, const char *,
                                unsigned long, int);
extern char *libintl_textdomain (const char *);
extern char *libintl_bindtextdomain (const char *, const char *);
extern char *libintl_bind_textdomain_codeset (const char *, const char *);
#ifdef __cplusplus
}
#endif
#define gettext libintl_gettext
#define dgettext libintl_dgettext
#define dcgettext libintl_dcgettext
#define ngettext libintl_ngettext
#define dngettext libintl_dngettext
#define dcngettext libintl_dcngettext
#define textdomain libintl_textdomain
#define bindtextdomain libintl_bindtextdomain
#define bind_textdomain_codeset libintl_bind_textdomain_codeset
#endif
EOF

# GLib-only targets receive this include directory but sometimes not the SDK's
# general include root.
if [ -d "$TARGET_PREFIX/include/glib-2.0" ]; then
  cp "$TARGET_PREFIX/include/libintl.h" \
    "$TARGET_PREFIX/include/glib-2.0/libintl.h"
fi

# The stub supplies link-time exports only. Device binaries resolve the same
# symbols from the real libintl8 runtime re-exported by libgtkintl.
cat > "$WORK/libintl-stub.c" <<'EOF'
char *libintl_gettext (const char *s) { return (char *) s; }
char *libintl_dgettext (const char *d, const char *s) { (void) d; return (char *) s; }
char *libintl_dcgettext (const char *d, const char *s, int c) { (void) d; (void) c; return (char *) s; }
char *libintl_ngettext (const char *s, const char *p, unsigned long n) { return (char *) (n == 1 ? s : p); }
char *libintl_dngettext (const char *d, const char *s, const char *p, unsigned long n) { (void) d; return (char *) (n == 1 ? s : p); }
char *libintl_dcngettext (const char *d, const char *s, const char *p, unsigned long n, int c) { (void) d; (void) c; return (char *) (n == 1 ? s : p); }
char *libintl_textdomain (const char *d) { return (char *) d; }
char *libintl_bindtextdomain (const char *d, const char *dir) { (void) d; return (char *) dir; }
char *libintl_bind_textdomain_codeset (const char *d, const char *c) { (void) d; return (char *) c; }
EOF

"$CC" "-miphoneos-version-min=$MIN_IOS" -isysroot "$APPLE_SDK" \
  -dynamiclib -Wl,-install_name,@rpath/libintl.8.dylib \
  -Wl,-compatibility_version,12 -Wl,-current_version,12 \
  "$WORK/libintl-stub.c" -o "$TARGET_PREFIX/lib/libintl.8.dylib"
ln -sf libgtkintl.dylib "$TARGET_PREFIX/lib/libintl.dylib"
