/*
 * iosc_status.c — implementation of the shared visibility channel. See
 * iosc_status.h for the contract and docs/ios-platform-features.md §0 for why it
 * exists.
 *
 * Shared verbatim by iosc (root, cross-compiled in the Procursus image) and
 * Xios.app (mobile, built by Xcode), so this stays plain C with nothing but libc:
 * no CoreFoundation, no Wayland, no Foundation.
 */
#include "iosc_status.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

#define IOSC_STATUS_MAX_KEYS  16
#define IOSC_STATUS_KEY_MAX   32
#define IOSC_STATUS_VALUE_MAX 160

struct status_entry {
    char key[IOSC_STATUS_KEY_MAX];
    char value[IOSC_STATUS_VALUE_MAX];
};

static struct status_entry s_entries[IOSC_STATUS_MAX_KEYS];
static int s_nentries;
static char s_producer[32];
static char s_dir[PATH_MAX];
static char s_file[PATH_MAX];
/* One failed sidecar write is expected on a system with no writable runtime tmp
 * (or a sandboxed producer, per §1's capability matrix); we log it once and keep
 * the stderr channel working rather than retrying every frame. */
static int s_file_broken;

/* Same resolution order as ioscd's init_paths() and XiosRuntimePaths.runtimeTmp,
 * so all three agree on where the table lives without a shared config. */
static const char *runtime_tmp(void)
{
    const char *e = getenv("XIOS_RUNTIME_TMP");
    if (e && *e) return e;
    e = getenv("XIOS_PREFIX");
    if (e && *e && strcmp(e, "/") != 0) {
        static char buf[PATH_MAX];
        snprintf(buf, sizeof(buf), "%s/tmp", e);
        return buf;
    }
    if (access("/var/jb/usr", X_OK) == 0) return "/var/jb/tmp";
    return "/var/tmp";
}

static void init_paths(void)
{
    if (s_file[0]) return;

    if (!s_producer[0]) {
        const char *p = getprogname();
        snprintf(s_producer, sizeof(s_producer), "%s", (p && *p) ? p : "unknown");
    }
    /* Keep the producer name a single safe path component. */
    for (char *p = s_producer; *p; p++)
        if (*p == '/' || *p == '.' || (unsigned char)*p < 32) *p = '_';

    const char *dir = getenv("XIOS_STATUS_DIR");
    if (dir && *dir)
        snprintf(s_dir, sizeof(s_dir), "%s", dir);
    else
        snprintf(s_dir, sizeof(s_dir), "%s/xios-status.d", runtime_tmp());
    snprintf(s_file, sizeof(s_file), "%s/%s.status", s_dir, s_producer);

    /* 01777: root-owned iosc and mobile-owned Xios.app both write here, and the
     * sticky bit keeps either from replacing the other's sidecar. mkdir failing
     * because it already exists is the normal case. */
    if (mkdir(s_dir, 01777) == 0)
        chmod(s_dir, 01777);
}

void iosc_status_set_producer(const char *name)
{
    if (!name || !*name) return;
    snprintf(s_producer, sizeof(s_producer), "%s", name);
    s_file[0] = 0;          /* re-resolve on the next write */
    s_file_broken = 0;
}

static struct status_entry *entry_for(const char *key)
{
    for (int i = 0; i < s_nentries; i++)
        if (strcmp(s_entries[i].key, key) == 0) return &s_entries[i];
    if (s_nentries >= IOSC_STATUS_MAX_KEYS) return NULL;
    struct status_entry *e = &s_entries[s_nentries++];
    snprintf(e->key, sizeof(e->key), "%s", key);
    e->value[0] = 0;
    return e;
}

/* Rewrite the whole sidecar. temp+rename so `xios-status` run concurrently with
 * a set() reads either the old table or the new one, never a truncated file. */
static void write_sidecar(void)
{
    char tmp[PATH_MAX + 32];
    init_paths();
    if (s_file_broken) return;

    snprintf(tmp, sizeof(tmp), "%s.tmp.%d", s_file, (int)getpid());
    FILE *f = fopen(tmp, "w");
    if (!f) {
        s_file_broken = 1;
        fprintf(stderr, "iosc-status: cannot write %s (%s); stderr only from here\n",
                s_file, strerror(errno));
        return;
    }
    for (int i = 0; i < s_nentries; i++)
        fprintf(f, "%s\t%s\n", s_entries[i].key, s_entries[i].value);
    fclose(f);
    if (rename(tmp, s_file) != 0) {
        unlink(tmp);
        s_file_broken = 1;
        fprintf(stderr, "iosc-status: cannot publish %s (%s); stderr only from here\n",
                s_file, strerror(errno));
        return;
    }
    /* ioscd runs as root and Xios.app as mobile; either may need to read the
     * other's table, so the sidecars are world-readable. */
    chmod(s_file, 0644);
}

/* Newlines and tabs would break the sidecar's line/field framing. */
static void sanitize(char *s)
{
    for (char *p = s; *p; p++)
        if (*p == '\n' || *p == '\r' || *p == '\t') *p = ' ';
}

void iosc_status_set_value(const char *key, const char *value)
{
    char clean[IOSC_STATUS_VALUE_MAX];

    if (!key || !*key || !value) return;
    snprintf(clean, sizeof(clean), "%s", value);
    sanitize(clean);

    struct status_entry *e = entry_for(key);
    if (e && strcmp(e->value, clean) == 0)
        return;             /* unchanged: no log line, no rewrite */

    fprintf(stderr, "[status] %s=%s\n", key, clean);
    fflush(stderr);
    if (!e) return;         /* table full: the stderr line is still the record */
    snprintf(e->value, sizeof(e->value), "%s", clean);
    write_sidecar();
}

void iosc_status_event_value(const char *key, const char *value)
{
    char clean[IOSC_STATUS_VALUE_MAX];

    if (!key || !*key || !value) return;
    snprintf(clean, sizeof(clean), "%s", value);
    sanitize(clean);
    fprintf(stderr, "[status] %s=%s\n", key, clean);
    fflush(stderr);
}

void iosc_status_set(const char *key, const char *fmt, ...)
{
    char value[IOSC_STATUS_VALUE_MAX];
    va_list ap;

    if (!fmt) return;
    va_start(ap, fmt);
    vsnprintf(value, sizeof(value), fmt, ap);
    va_end(ap);
    iosc_status_set_value(key, value);
}

void iosc_status_event(const char *key, const char *fmt, ...)
{
    char value[IOSC_STATUS_VALUE_MAX];
    va_list ap;

    if (!fmt) return;
    va_start(ap, fmt);
    vsnprintf(value, sizeof(value), fmt, ap);
    va_end(ap);
    iosc_status_event_value(key, value);
}

void iosc_status_clear(void)
{
    if (!s_file[0]) return;
    unlink(s_file);
    s_nentries = 0;
}
