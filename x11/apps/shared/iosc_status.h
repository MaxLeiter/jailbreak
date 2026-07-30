/*
 * iosc_status.h — the shared runtime-visibility channel (docs/ios-platform-features.md §0).
 *
 * Three tracks (process confinement, display pacing, thermal/jetsam reaction)
 * change behaviour at runtime in ways a user would otherwise experience as
 * unexplained slowness or a mysteriously blurry desktop. They all announce
 * themselves here rather than each inventing its own mechanism.
 *
 * Two kinds of announcement:
 *   iosc_status_set()   latched state — "this is true now" (pacing, upscale,
 *                       thermal, memory, sandbox). Overwrites the previous value
 *                       for that key and is what a status reader dumps.
 *   iosc_status_event() transient — "this just happened". Log only.
 *
 * Both ALWAYS write one `[status] key=value` line to stderr, so a headless SSH
 * session tailing iosc.log sees every change with no extra tooling.
 *
 * Consumers, in the order §0 ranks them:
 *   1. stderr, free, always on.
 *   2. `xios-status` / `printf 'STATUS\n' | nc -U /var/jb/tmp/ioscd.sock` — dumps
 *      the latched table. Backed by the sidecar files this module writes (see
 *      below); ioscd is a different process from every producer, so a file is the
 *      cheapest thing that works across all of them.
 *   3. an iosc-shell panel indicator (not built yet).
 *
 * Storage: one sidecar per producer, $XIOS_STATUS_DIR (default <runtime tmp>/
 * xios-status.d)/<producer>.status, holding `key<TAB>value` lines. Rewritten
 * whole under a temp+rename so a reader never sees a half-written table. One file
 * PER PRODUCER because the producers are separate processes running as different
 * users (iosc as root, Xios.app as mobile) — a single shared file would need
 * cross-user locking to avoid lost updates.
 *
 * Deliberately not an IPC subsystem: no daemon, no sockets, no reader callbacks.
 * A status write is a stderr line plus a small rewrite of a file that only
 * changes when behaviour changes.
 */
#ifndef IOSC_STATUS_H
#define IOSC_STATUS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Name this process reports under; becomes <producer>.status. Defaults to the
 * program name. Call once at startup, before the first set/event. */
void iosc_status_set_producer(const char *name);

/* Latch `key` = `value`. `key` should be one of the stable slugs from §0 —
 * sandbox, thermal, memory, pacing, upscale — so a reader can rely on it.
 * Writes the stderr line and rewrites this producer's sidecar. A repeated set
 * with an unchanged value is dropped (no log spam from a per-frame caller).
 *
 * These two take a ready-made string rather than a format because Swift cannot
 * call C variadics: XScreen.swift interpolates and calls straight in. C callers
 * usually want the printf forms below, which funnel through these. */
void iosc_status_set_value(const char *key, const char *value);

/* One-shot event: stderr only, never latched (nothing for a reader to show
 * "now"). Use for things that happened rather than things that are true. */
void iosc_status_event_value(const char *key, const char *value);

void iosc_status_set(const char *key, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
void iosc_status_event(const char *key, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

/* Drop this producer's sidecar (clean exit: a stale table outlives the process
 * that wrote it and reads as live state). Safe to call more than once. */
void iosc_status_clear(void);

#ifdef __cplusplus
}
#endif

#endif /* IOSC_STATUS_H */
