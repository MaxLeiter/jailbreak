/* imv-compat.h — Darwin/iOS portability shim, force-included (-include) into every imv C TU.
 *  - wordexp()/wordfree() are declared __IPHONE_NA (unavailable, and would fork a shell anyway),
 *    so we suppress <wordexp.h> via its include guard and provide a minimal replacement that does
 *    environment ($VAR/${VAR}) + leading-~ expansion and whitespace splitting with basic quote
 *    stripping. imv only uses it for config-path / command / title-format expansion.
 *  - POSIX per-process timers (timer_create/settime/delete + timer_t + struct itimerspec) don't
 *    exist on iOS. imv uses exactly one, SIGEV_THREAD + CLOCK_MONOTONIC, for keyboard key-repeat;
 *    we emulate that case with a pthread that fires the notify function. (struct sigevent and
 *    union sigval DO exist in Darwin's <signal.h>.)
 *  - (navigator.c's st_mtim.tv_sec is rewritten to the portable st_mtime scalar in -setup.) */
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

/* --- POSIX per-process timer emulation (SIGEV_THREAD only) over pthreads --- */
#include <pthread.h>
#include <time.h>
#include <signal.h>
#include <errno.h>

#ifndef __itimerspec_defined
#define __itimerspec_defined 1
struct itimerspec { struct timespec it_interval; struct timespec it_value; };
#endif

struct _imv_timer {
    pthread_t thread; pthread_mutex_t mtx; pthread_cond_t cond;
    struct timespec next, interval;
    int armed, stop;
    void (*fn)(union sigval);
    union sigval val;
};
typedef struct _imv_timer *timer_t;

static inline void *_imv_timer_thread(void *arg) {
    struct _imv_timer *t = (struct _imv_timer *)arg;
    pthread_mutex_lock(&t->mtx);
    for (;;) {
        while (!t->armed && !t->stop) pthread_cond_wait(&t->cond, &t->mtx);
        if (t->stop) break;
        int rc = pthread_cond_timedwait(&t->cond, &t->mtx, &t->next);
        if (t->stop) break;
        if (rc == ETIMEDOUT && t->armed) {
            void (*fn)(union sigval) = t->fn;
            union sigval v = t->val;
            if (t->interval.tv_sec || t->interval.tv_nsec) {
                t->next.tv_sec += t->interval.tv_sec;
                t->next.tv_nsec += t->interval.tv_nsec;
                if (t->next.tv_nsec >= 1000000000L) { t->next.tv_sec++; t->next.tv_nsec -= 1000000000L; }
            } else {
                t->armed = 0;
            }
            pthread_mutex_unlock(&t->mtx);
            if (fn) fn(v);
            pthread_mutex_lock(&t->mtx);
        }
    }
    pthread_mutex_unlock(&t->mtx);
    return NULL;
}

static inline int timer_create(clockid_t clockid, struct sigevent *ev, timer_t *out) {
    (void)clockid;
    struct _imv_timer *t = (struct _imv_timer *)calloc(1, sizeof *t);
    if (!t) return -1;
    pthread_mutex_init(&t->mtx, NULL);
    pthread_cond_init(&t->cond, NULL);   /* Darwin cond deadlines are CLOCK_REALTIME */
    if (ev) { t->fn = ev->sigev_notify_function; t->val = ev->sigev_value; }
    if (pthread_create(&t->thread, NULL, _imv_timer_thread, t) != 0) {
        pthread_mutex_destroy(&t->mtx); pthread_cond_destroy(&t->cond); free(t); return -1;
    }
    *out = t;
    return 0;
}

static inline int timer_settime(timer_t t, int flags, const struct itimerspec *nv, struct itimerspec *ov) {
    (void)flags; (void)ov;
    if (!t) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&t->mtx);
    if (nv->it_value.tv_sec == 0 && nv->it_value.tv_nsec == 0) {
        t->armed = 0;
    } else {
        struct timespec now; clock_gettime(CLOCK_REALTIME, &now);
        t->next.tv_sec = now.tv_sec + nv->it_value.tv_sec;
        t->next.tv_nsec = now.tv_nsec + nv->it_value.tv_nsec;
        if (t->next.tv_nsec >= 1000000000L) { t->next.tv_sec++; t->next.tv_nsec -= 1000000000L; }
        t->interval = nv->it_interval;
        t->armed = 1;
    }
    pthread_cond_signal(&t->cond);
    pthread_mutex_unlock(&t->mtx);
    return 0;
}

static inline int timer_delete(timer_t t) {
    if (!t) return 0;
    pthread_mutex_lock(&t->mtx);
    t->stop = 1;
    pthread_cond_signal(&t->cond);
    pthread_mutex_unlock(&t->mtx);
    pthread_join(t->thread, NULL);
    pthread_mutex_destroy(&t->mtx);
    pthread_cond_destroy(&t->cond);
    free(t);
    return 0;
}
