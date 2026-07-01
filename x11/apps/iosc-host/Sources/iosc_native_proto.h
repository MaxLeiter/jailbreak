/*
 * iosc_native_proto.h — wire contract for the NATIVE iPadOS flavor's per-window
 * rendezvous (iosc-native.sock v2). Shared by BOTH ends:
 *   - the per-app host app's client (apps/iosc-host/Sources/NativeClient.c), and
 *   - iosc's server half (to be implemented in wayland/iosc.c per x11/docs/
 *     native-ipados-protocol.md — NOT built yet).
 *
 * Native mode gives each xdg_toplevel its OWN presentation IOSurface ("canvas")
 * and its OWN UIWindowScene in the host, instead of compositing every window into
 * one shared output surface (the GNOME/KDE/X11 flavors). This socket is how the
 * host learns which canvas belongs to which window and follows its lifecycle.
 *
 * PROVISIONAL FRAMING — reconcile with iosc-protocols' typed app-socket header
 * (HELLO/DIRTY/CURSOR). The lead asked native to REUSE that header rather than
 * fork a parallel one; a request is out to iosc-protocols for its exact struct +
 * type-code enum. Until it lands, this defines a self-consistent 32-byte fixed
 * header with a reserved native type range (0x40-0x5f) that slots into their enum
 * without collision. Only the header struct + magic move if we adopt theirs; the
 * message set and semantics below stay.
 *
 * Both ends are arm64 little-endian, so the structs go on the wire verbatim.
 */
#ifndef IOSC_NATIVE_PROTO_H
#define IOSC_NATIVE_PROTO_H

#include <stdint.h>

#define IOSC_NATIVE_SOCK   "/var/jb/tmp/iosc-native.sock"
#define IOSC_NATIVE_MAGIC  0x584E4931u   /* 'XNI1' */

/* Fixed record header. `payload_len` bytes of UTF-8 follow the header (TITLE).
 * The four params carry per-message integers (geometry, flags, port names). */
struct iosc_native_hdr {
    uint32_t magic;        /* IOSC_NATIVE_MAGIC (sanity/resync) */
    uint32_t type;         /* one of IOSC_N_* below              */
    uint32_t window;       /* per-toplevel id (host<->iosc key)  */
    uint32_t payload_len;  /* trailing UTF-8 bytes (0 if none)   */
    uint32_t a, b, c, d;   /* per-message params (see each type) */
};

/* ---- host -> iosc -------------------------------------------------------- */
/* BIND: "I present windows for this app_id." payload = app_id (UTF-8).
 *   a = scene width px, b = scene height px, c = scale (1/2), d = mach
 *   receive-port name in the host's IPC space (iosc task_for_pid's the host and
 *   mach_msg's each canvas IOSurface send-right to this port, exactly like the
 *   single-surface ddx in xios_surface.c). window is 0 (connection-scoped). */
#define IOSC_N_BIND        0x40u
/* RESIZE: the scene's pixel size changed (Split View drag, rotation). a=w, b=h.
 * iosc reconfigures the toplevel; the client acks+commits; a WINDOW_GEOM with a
 * fresh canvas follows. */
#define IOSC_N_RESIZE      0x41u
/* ACTIVATE: this scene became key (a=1) or resigned key (a=0). Drives which
 * window holds wl_keyboard focus. */
#define IOSC_N_ACTIVATE    0x42u
/* CLOSED: the user dismissed this scene (swiped it away). iosc sends
 * xdg_toplevel.close to the client. */
#define IOSC_N_CLOSED      0x43u

/* ---- iosc -> host -------------------------------------------------------- */
/* WINDOW_NEW: a toplevel matching this host's app_id mapped. a=w, b=h, c=stride,
 * d=flags (bit0 maximized). payload = title. A mach_msg carrying the canvas
 * IOSurface send-right follows immediately on the BIND receive port. */
#define IOSC_N_WINDOW_NEW  0x50u
/* WINDOW_GEOM: the canvas was reallocated after a resize. a=w, b=h, c=stride. A
 * fresh canvas mach_msg follows (the old surface may be released after the swap). */
#define IOSC_N_WINDOW_GEOM 0x51u
/* DIRTY: the canvas changed; re-present. (Mirrors the single-surface DIRTY byte,
 * now per-window.) */
#define IOSC_N_DIRTY       0x52u
/* TITLE: the toplevel title changed. payload = UTF-8. */
#define IOSC_N_TITLE       0x53u
/* WINDOW_GONE: the toplevel unmapped / the client exited. Tear the scene down. */
#define IOSC_N_WINDOW_GONE 0x54u
/* CURSOR: the pointer over this window should show cursor-shape-v1 named cursor
 * `a` (see iosc's cursor-shape table). Lets the host set a per-scene
 * UIPointerStyle instead of iosc drawing the cursor into the canvas. Later. */
#define IOSC_N_CURSOR      0x55u

/* WINDOW_NEW/GEOM flag bits (hdr.d). */
#define IOSC_NWIN_MAXIMIZED  0x1u
#define IOSC_NWIN_FULLSCREEN 0x2u

#endif /* IOSC_NATIVE_PROTO_H */
