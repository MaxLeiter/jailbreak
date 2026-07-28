/*
 * xios_paths.h — the single relocation seam for the compositor's on-disk prefix.
 *
 * The jailbroken build hardcodes "/var/jb" as its root; a future sandbox
 * (non-jailbroken) target instead points the prefix at its app container. Rather
 * than scatter that literal, every path is composed from xios_root(), which reads
 * the XIOS_ROOT env override and falls back to "/var/jb" when it is unset — so the
 * jailbroken build's resolved paths are byte-for-byte what they were before.
 *
 * Header-only static inline on purpose: no new .c means no build-system churn.
 */
#ifndef XIOS_PATHS_H
#define XIOS_PATHS_H

#include <stdlib.h>
#include <stdio.h>

/* Relocation root. Jailbroken build: "/var/jb". Overridable via XIOS_ROOT env
   (unset -> "/var/jb", so JB behavior is unchanged). */
static inline const char *xios_root(void)
{
    const char *r = getenv("XIOS_ROOT");
    return (r && *r) ? r : "/var/jb";
}

/* Writes "<root>/tmp/<name>" into buf, returns buf. */
static inline const char *xios_tmp(const char *name, char *buf, size_t n)
{
    snprintf(buf, n, "%s/tmp/%s", xios_root(), name);
    return buf;
}

/* Writes "<root>/<rel>" into buf (rel has NO leading slash), returns buf. */
static inline const char *xios_path(const char *rel, char *buf, size_t n)
{
    snprintf(buf, n, "%s/%s", xios_root(), rel);
    return buf;
}

#endif /* XIOS_PATHS_H */
