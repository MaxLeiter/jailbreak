#!/usr/bin/env bash
# gnome-text-editor iOS port fixes (idempotent).
#
# src/editor-path.c uses wordexp()/wordfree() (POSIX shell word-expansion) under
# `#ifdef G_OS_UNIX` to expand a leading ~ / $VAR in a path. iOS marks both
# __attribute__((unavailable)) (sandbox), so the cross-compile fails. The only
# behaviour the editor needs is leading "~/" / "~" -> home dir, which GLib does
# natively. Replace the wordexp block with a GLib expansion.
#
# Usage: gnome-text-editor-ios-fixes.sh <gnome-text-editor-source-dir>
set -euo pipefail
SRC="${1:?usage: $0 <gnome-text-editor-src-dir>}"

python3 - "$SRC/src/editor-path.c" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
old = """  escaped = g_shell_quote (path);
  r = wordexp (escaped, &state, WRDE_NOCMD);
  if (r == 0 && state.we_wordc > 0)
    ret = g_strdup (state.we_wordv [0]);
  wordfree (&state);"""
new = """  /* iOS port: wordexp()/wordfree() are __attribute__((unavailable)) (sandbox).
   * The editor only needs a leading "~/" or "~" expanded to the home dir, which
   * GLib does without a shell. */
  (void) state; (void) r;
  escaped = NULL;
  if (path[0] == '~' && (path[1] == '/' || path[1] == '\\0'))
    ret = g_build_filename (g_get_home_dir (), &path[1], NULL);
  else
    ret = g_strdup (path);"""
if old in s:
    open(f, "w").write(s.replace(old, new))
    print("editor-path.c: wordexp -> GLib expansion applied")
elif "wordexp()/wordfree() are __attribute__((unavailable))" in s:
    print("editor-path.c: already patched")
else:
    sys.exit("ERROR: editor-path.c wordexp block not found (source changed?)")
PY
