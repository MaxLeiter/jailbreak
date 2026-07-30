/*
 * iosc_native_proto.h — wire contract for the NATIVE iPadOS flavor's per-window
 * rendezvous (iosc-native.sock). Shared by BOTH ends:
 *   - the per-app host app's client (apps/iosc-host/Sources/NativeClient.c), and
 *   - iosc's server half (to be implemented in wayland/iosc.c per x11/docs/
 *     native-ipados-protocol.md).
 *
 * Native mode gives each xdg_toplevel its OWN presentation IOSurface ("canvas")
 * and its OWN UIWindowScene in the host, instead of compositing every window into
 * one shared output surface (the GNOME/KDE/X11 flavors). This socket is how the
 * host learns which canvas belongs to which window and follows its lifecycle.
 *
 * FRAMING: the shared typed app-socket record designed by the iosc maintainer for
 * the cursor-overlay work (agreed 2026-07-01). ONE 32-byte header both directions;
 * core type codes 0x01-0x0f are flavor-agnostic and owned by iosc (HELLO/DIRTY/
 * CURSOR); the native lifecycle codes live in 0x40-0x5f, the range reserved for
 * this flavor. Native protocol v1 uses NATIVE_FRAME rather than core DIRTY so
 * every production frame carries a broker fence token/value; CURSOR remains
 * window_id-targeted. Both ends are arm64 little-endian; structs go on the wire
 * verbatim.
 */
#ifndef IOSC_NATIVE_PROTO_H
#define IOSC_NATIVE_PROTO_H

#include <stdint.h>

#define IOSC_NATIVE_SOCK "/var/jb/tmp/iosc-native.sock"
#define IOSC_NATIVE_PROTOCOL_VERSION 1u
#define IOSC_NATIVE_FENCE_TOKEN_SIZE 32u

/* ---- shared typed record (authoritative shape: the iosc maintainer) ------- */

#define XIOS_MSG_MAGIC 0x584D5331u   /* 'XMS1' — frame sync/sanity */

typedef struct {
    uint32_t magic;      /* XIOS_MSG_MAGIC                                   */
    uint32_t type;       /* XIOS_MSG_* below                                 */
    uint32_t window_id;  /* per-window; 0 = the single/default surface       */
    uint32_t length;     /* payload bytes after the header (0 if none)       */
    int32_t  a, b, c, d; /* type-specific scalar args                        */
} xios_msg;              /* 32 bytes; optional `length`-byte payload follows */

/* ---- core codes 0x01-0x0f (iosc-owned, flavor-agnostic) ------------------- */
/* HELLO   compositor->app: a=width b=height c=stride d=format; payload =
 *         compositor id UTF-8 ("iosc"). Informational on the native socket
 *         (per-window geometry rides on WINDOW_NEW); hosts may ignore it. */
#define XIOS_MSG_HELLO   0x01u
/* DIRTY   compositor->app: a,b,c,d = damage x,y,w,h (all 0 = whole surface);
 *         window_id = which canvas changed. Native hosts re-present that scene. */
#define XIOS_MSG_DIRTY   0x02u
/* CURSOR  compositor->app: a=x b=y (pointer pos, px) c=shape_id (cursor-shape-v1
 *         enum; 0=none/hidden) d=flags (bit0=visible). length>0 carries an
 *         xios_cursor_bitmap payload (client-supplied cursor image); a host that
 *         only maps shape_id -> UIPointerStyle just drains the payload. */
#define XIOS_MSG_CURSOR  0x03u
/* CLIPBOARD both directions, on the DEDICATED clipboard socket only (never this
 *           one): a=XIOS_CLIP_KIND_* b=generation, payload = item data. Full
 *           contract in linux-build/patches/xios/xios_surface.h. Listed here so
 *           nobody re-allocates 0x04. */
#define XIOS_MSG_CLIPBOARD 0x04u

/* CURSOR bitmap payload (when length > 0): header then w*h*4 premultiplied BGRA. */
typedef struct { uint32_t w, h; int32_t hot_x, hot_y; } xios_cursor_bitmap;

/* ---- native lifecycle codes 0x40-0x5f (this flavor's reserved range) ------ */

/* host -> compositor. window_id is COMPOSITOR-assigned; the host echoes it back
 * on RESIZE/ACTIVATE/CLOSED. */
/* BIND: "I present windows for this app_id." payload = app_id UTF-8.
 *   a = scene width px, b = scene height px, c = backing scale (1/2),
 *   d = mach receive-port name in the host's IPC space (iosc task_for_pid's the
 *   host and mach_msg's each canvas IOSurface send-right to this port, exactly
 *   like the single-surface ddx in xios_surface.c). Protocol v1 requires
 *   window_id = IOSC_NATIVE_PROTOCOL_VERSION. The server
 *   replies with a HELLO whose a field carries the same version before any
 *   WINDOW_* records; either side closes on a mismatch.
 *   If toplevels matching app_id are already live (host relaunch after a jetsam
 *   kill), the compositor immediately replays WINDOW_NEW + canvas for each. */
#define XIOS_MSG_BIND         0x40u
/* RESIZE: the scene's pixel size changed (Split View drag, rotation). a=w, b=h.
 * Compositor reconfigures the toplevel; client acks + commits; a WINDOW_GEOM
 * with a fresh canvas follows. */
#define XIOS_MSG_RESIZE       0x41u
/* ACTIVATE: this scene became key (a=1) or resigned (a=0). Drives wl_keyboard
 * focus. */
#define XIOS_MSG_ACTIVATE     0x42u
/* CLOSED: the user dismissed the scene (swiped it away in the app switcher).
 * Compositor sends xdg_toplevel.close. */
#define XIOS_MSG_CLOSED       0x43u

/* compositor -> host */
/* WINDOW_NEW: a toplevel matching the bind mapped. a=w, b=h, c=stride, d=flags
 * (XIOS_NWIN_*). payload = title UTF-8. A mach_msg carrying the canvas IOSurface
 * send-right follows immediately on the BIND receive port. */
#define XIOS_MSG_WINDOW_NEW   0x50u
/* WINDOW_GEOM: canvas reallocated after a RESIZE. a=w, b=h, c=stride. A fresh
 * canvas mach_msg follows (release the old surface after the swap). */
#define XIOS_MSG_WINDOW_GEOM  0x51u
/* WINDOW_TITLE: the toplevel title changed. payload = UTF-8. */
#define XIOS_MSG_WINDOW_TITLE 0x52u
/* WINDOW_GONE: toplevel unmapped / client exited. Tear the scene down. */
#define XIOS_MSG_WINDOW_GONE  0x53u
/* NATIVE_FRAME: one complete per-window GPU frame. window_id selects the
 * canvas; length=32 carries the broker capability token; a/b are the low/high
 * halves of the non-zero MTLSharedEvent value the host must wait for before
 * sampling. c/d are reserved and must be zero. Damage is whole-canvas. */
#define XIOS_MSG_NATIVE_FRAME 0x54u

/* WINDOW_NEW/GEOM flag bits (msg.d). */
#define XIOS_NWIN_MAXIMIZED  0x1
#define XIOS_NWIN_FULLSCREEN 0x2

#endif /* IOSC_NATIVE_PROTO_H */
