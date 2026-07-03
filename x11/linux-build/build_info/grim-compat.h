/* grim-compat.h — Darwin/iOS portability shim, force-included (-include) into every grim C TU.
 * grim's only iOS-unavailable libc use is wordexp()/wordfree() (declared __IPHONE_NA and would
 * fork a shell anyway). It calls them once, to expand the XDG_PICTURES_DIR line of
 * ~/.config/user-dirs.dirs. Suppress <wordexp.h> via its include guard and provide a minimal
 * replacement doing environment ($VAR/${VAR}) + leading-~ expansion and whitespace splitting
 * with basic quote stripping. (Lifted from imv-compat.h, sans the timer emulation grim doesn't
 * use.) */
#pragma once

#ifndef _WORDEXP_H
#define _WORDEXP_H
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef struct { size_t we_wordc; char **we_wordv; size_t we_offs; } wordexp_t;
#define WRDE_APPEND  0x01
#define WRDE_DOOFFS  0x02
#define WRDE_NOCMD   0x04
#define WRDE_REUSE   0x08
#define WRDE_SHOWERR 0x10
#define WRDE_UNDEF   0x20
enum { WRDE_BADCHAR = 1, WRDE_BADVAL, WRDE_CMDSUB, WRDE_NOSPACE, WRDE_SYNTAX, WRDE_NOSYS };

static inline int wordexp(const char *words, wordexp_t *we, int flags) {
    (void)flags;
    size_t cap = strlen(words) + 64, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) return WRDE_NOSPACE;
    for (const char *p = words; *p; ) {
        if (*p == '~' && p == words && (p[1] == '/' || p[1] == '\0')) {
            const char *home = getenv("HOME"); if (!home) home = "";
            size_t hl = strlen(home);
            while (len + hl + 2 > cap) { cap *= 2; buf = (char *)realloc(buf, cap); }
            memcpy(buf + len, home, hl); len += hl; p++;
        } else if (*p == '$') {
            p++;
            int braced = (*p == '{'); if (braced) p++;
            const char *s = p;
            while (*p && (isalnum((unsigned char)*p) || *p == '_')) p++;
            size_t nl = (size_t)(p - s);
            char name[256]; if (nl >= sizeof name) nl = sizeof name - 1;
            memcpy(name, s, nl); name[nl] = 0;
            if (braced && *p == '}') p++;
            const char *val = getenv(name); if (!val) val = "";
            size_t vl = strlen(val);
            while (len + vl + 2 > cap) { cap *= 2; buf = (char *)realloc(buf, cap); }
            memcpy(buf + len, val, vl); len += vl;
        } else {
            if (len + 2 > cap) { cap *= 2; buf = (char *)realloc(buf, cap); }
            buf[len++] = *p++;
        }
    }
    buf[len] = 0;

    char **wv = NULL; size_t wc = 0, wcap = 0;
    char *tok = (char *)malloc(len + 1); size_t tl = 0; int inword = 0; char quote = 0;
    for (size_t i = 0; ; i++) {
        char c = buf[i];
        if (quote) {
            if (c == quote) quote = 0;
            else if (c == 0) break;
            else { tok[tl++] = c; inword = 1; }
        } else if (c == '"' || c == '\'') { quote = c; inword = 1; }
        else if (c == ' ' || c == '\t' || c == '\n' || c == 0) {
            if (inword) {
                tok[tl] = 0;
                if (wc + 2 > wcap) { wcap = wcap ? wcap * 2 : 8; wv = (char **)realloc(wv, wcap * sizeof(char *)); }
                wv[wc++] = strdup(tok); tl = 0; inword = 0;
            }
            if (c == 0) break;
        } else { tok[tl++] = c; inword = 1; }
    }
    free(tok); free(buf);
    if (wc + 1 > wcap) { wcap = wc + 1; wv = (char **)realloc(wv, wcap * sizeof(char *)); }
    wv[wc] = NULL;
    we->we_wordc = wc; we->we_wordv = wv; we->we_offs = 0;
    return 0;
}
static inline void wordfree(wordexp_t *we) {
    if (!we || !we->we_wordv) return;
    for (size_t i = 0; i < we->we_wordc; i++) free(we->we_wordv[i]);
    free(we->we_wordv); we->we_wordv = NULL; we->we_wordc = 0;
}
#endif /* _WORDEXP_H */
