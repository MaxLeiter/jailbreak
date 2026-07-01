#ifndef IOSC_HOST_NATIVECLIENT_H
#define IOSC_HOST_NATIVECLIENT_H

#include <IOSurface/IOSurfaceRef.h>

/*
 * Client half of the native per-window rendezvous (iosc-native.sock v2). One
 * connection per host process = one app_id; it carries every window that app
 * maps. See iosc_native_proto.h for the wire contract and x11/docs/
 * native-ipados-protocol.md for the full spec (iosc server half not built yet).
 *
 * Usage:
 *   c = iosc_native_connect(NULL, "org.gnome.Console", w, h, 2);
 *   loop on a background thread: iosc_native_next(c, 250, &ev) -> react
 *   iosc_native_resize/activate/closed(c, window, ...) as UIWindowScenes change
 *   iosc_native_close(c) on teardown
 *
 * The reader is a simple blocking-with-timeout pull, so a dedicated Swift Thread
 * can drive it and marshal each event to the main actor (NativeManager). No
 * C->Swift callback dance.
 */

typedef struct iosc_native_client iosc_native_client;

typedef enum {
    IOSC_NEV_NONE = 0,        /* timeout: nothing this interval             */
    IOSC_NEV_WINDOW_NEW,      /* window+surface+geometry+title valid        */
    IOSC_NEV_WINDOW_GEOM,     /* window+surface+geometry valid (resize)     */
    IOSC_NEV_DIRTY,           /* window valid; re-present                    */
    IOSC_NEV_TITLE,           /* window+title valid                         */
    IOSC_NEV_WINDOW_GONE,     /* window valid; tear the scene down          */
    IOSC_NEV_CURSOR,          /* window+cursor_id valid                     */
    IOSC_NEV_DISCONNECT,      /* the compositor went away                   */
} iosc_native_event_type;

typedef struct {
    iosc_native_event_type type;
    uint32_t     window;
    int          width, height;
    IOSurfaceRef surface;     /* +1 retained on WINDOW_NEW/GEOM; caller releases */
    uint32_t     cursor_id;
    uint32_t     flags;       /* IOSC_NWIN_* on WINDOW_NEW/GEOM               */
    char         title[256];  /* NUL-terminated on WINDOW_NEW/TITLE           */
} iosc_native_event;

/* Connect + BIND. `sock_path` NULL uses IOSC_NATIVE_SOCK. `app_id` is the
 * Wayland app_id this host presents (from the bundle's IOSCAppID). scale is the
 * backing scale (1 or 2). Returns NULL if the socket isn't up yet (caller
 * retries — iosc may launch after the host). */
iosc_native_client *iosc_native_connect(const char *sock_path, const char *app_id,
                                        int scene_w, int scene_h, int scale);

/* The socket fd, for callers that prefer to poll() instead of the blocking pull. */
int  iosc_native_fd(iosc_native_client *c);

/* Block up to timeout_ms for the next event. Returns 1 (ev filled), 0 (timeout,
 * ev.type == IOSC_NEV_NONE), or -1 (disconnected, ev.type == IOSC_NEV_DISCONNECT). */
int  iosc_native_next(iosc_native_client *c, int timeout_ms, iosc_native_event *ev);

/* host -> iosc control messages (best-effort; a dead socket is a silent no-op). */
void iosc_native_resize(iosc_native_client *c, uint32_t window, int w, int h);
void iosc_native_activate(iosc_native_client *c, uint32_t window, int active);
void iosc_native_closed(iosc_native_client *c, uint32_t window);

void iosc_native_close(iosc_native_client *c);

#endif /* IOSC_HOST_NATIVECLIENT_H */
