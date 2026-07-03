#!/usr/bin/env bash
# dunst-ios-fixes.sh — apply the two Darwin/iOS porting patches to a freshly extracted dunst
# source tree. Called from recipes/dunst.mk's setup rule as:
#     bash /work/recipes/dunst-ios-fixes.sh $(BUILD_WORK)/dunst
#
# Patch 1 (st_mtim): GNU/Linux's `struct stat` has st_mtim (POSIX 2008), but Darwin/BSD spells the
#   nanosecond mtime field st_mtimespec. src/utils.c:modification_time() reads statbuf.st_mtim, so
#   alias it on Apple platforms (the .tv_sec/.tv_nsec members are identical).
# Patch 2 (wordexp): iOS marks wordexp()/wordfree() explicitly unavailable (__IPHONE_NA), so
#   src/utils.c:string_to_path() won't compile. Replace it with a portable GLib expansion that
#   covers what dunst actually needs in config paths: a leading '~' -> $HOME plus $VAR / ${VAR}
#   environment substitution. Command substitution (which wordexp gated off with WRDE_NOCMD anyway)
#   stays unsupported.
set -euo pipefail

SRC="${1:?usage: dunst-ios-fixes.sh <dunst-src-dir>}"
U="$SRC/src/utils.c"
[ -f "$U" ] || { echo "ERROR: $U not found"; exit 1; }

echo "==> dunst patch 1/2: aliasing st_mtim -> st_mtimespec on Apple"
if ! grep -q 'st_mtim st_mtimespec' "$U"; then
  sed -i 's|#include "settings_data.h"|#include "settings_data.h"\n#if defined(__APPLE__)\n#define st_mtim st_mtimespec\n#endif|' "$U"
fi
grep -q 'st_mtim st_mtimespec' "$U" || { echo "ERROR: st_mtim alias not applied"; exit 1; }

echo "==> dunst patch 2/2: replacing wordexp-based string_to_path() with a GLib expansion"
NEWFN=/tmp/dunst_string_to_path.c
cat > "$NEWFN" <<'CEOF'
char *string_to_path(char *string)
{
        ASSERT_OR_RET(string, string);

        /* iOS/Darwin marks the shell word-expansion API unavailable, so re-implement the
         * expansion dunst needs directly on GLib: a leading '~' expands to $HOME and
         * $VAR / ${VAR} are substituted from the environment. Command substitution is
         * intentionally unsupported (the original was invoked with WRDE_NOCMD anyway). */
        GString *out = g_string_new(NULL);
        const char *p = string;

        if (p[0] == '~' && (p[1] == '/' || p[1] == '\0')) {
                const char *home = g_get_home_dir();
                if (home)
                        g_string_append(out, home);
                p++;
        }

        while (*p) {
                if (*p == '$' && p[1] == '{') {
                        const char *start = p + 2;
                        const char *end = start;
                        while (*end && *end != '}')
                                end++;
                        if (*end != '}') {
                                g_string_append_c(out, *p++);
                                continue;
                        }
                        char *name = g_strndup(start, end - start);
                        const char *val = g_getenv(name);
                        if (val)
                                g_string_append(out, val);
                        g_free(name);
                        p = end + 1;
                } else if (*p == '$' && (g_ascii_isalpha(p[1]) || p[1] == '_')) {
                        const char *start = p + 1;
                        const char *end = start;
                        while (*end && (g_ascii_isalnum(*end) || *end == '_'))
                                end++;
                        char *name = g_strndup(start, end - start);
                        const char *val = g_getenv(name);
                        if (val)
                                g_string_append(out, val);
                        g_free(name);
                        p = end;
                } else {
                        g_string_append_c(out, *p++);
                }
        }

        g_free(string);
        return g_string_free(out, FALSE);
}
CEOF

# Splice: from the function signature line up to its column-0 closing brace, swap in NEWFN verbatim
# (getline from a file, so no awk -v escape mangling of the C body).
awk -v fn="$NEWFN" '
  /^char \*string_to_path\(char \*string\)/ {
    while ((getline line < fn) > 0) print line
    close(fn)
    skip = 1
    next
  }
  skip && /^}/ { skip = 0; next }
  skip { next }
  { print }
' "$U" > "$U.tmp" && mv "$U.tmp" "$U"

# Sanity: the actual wordexp/wordfree call sites must be gone and the new marker present.
if grep -qE 'wordexp\(string|wordfree\(&we\)' "$U"; then
  echo "ERROR: wordexp/wordfree call sites still present after patch"; exit 1
fi
grep -q 'g_get_home_dir' "$U" || { echo "ERROR: replacement string_to_path not spliced in"; exit 1; }

echo "==> dunst iOS fixes applied."
