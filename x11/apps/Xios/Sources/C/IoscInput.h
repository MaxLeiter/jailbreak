#ifndef XIOS_IOSCINPUT_H
#define XIOS_IOSCINPUT_H
#include <stdbool.h>

/*
 * IoscInput: handle-based client for a compositor's input socket. One handle
 * per desktop connection (Xios v2 holds an input link only for the presented
 * session). Same source as apps/iosc-host/Sources/IoscInput.{c,h}; the one
 * difference is that window 0 means "unbound" and sends no XIOS_IN_BIND, which
 * is exactly what the pre-v2 app put on the wire.
 *
 * The wire is the 32-byte xios_msg of apps/shared/XiosProtocol.h, opened by an
 * exact-version HELLO each way. Coordinates are absolute framebuffer (output)
 * pixels, the same space as the IOSurface the app maps. Every call tolerates a
 * NULL or dropped handle by doing nothing.
 */

typedef struct iosc_input iosc_input_t;

/* Connect to `sock_path`; BIND to `window` when it is non-zero. NULL on failure.
 * Blocks in connect(): call it off the main thread. */
iosc_input_t *iosc_input_open(const char *sock_path, unsigned window);
void iosc_input_close(iosc_input_t *h);
bool iosc_input_is_open(iosc_input_t *h);

void iosc_input_motion(iosc_input_t *h, int x, int y);
void iosc_input_button(iosc_input_t *h, int button, bool down, int x, int y);
void iosc_input_key(iosc_input_t *h, unsigned keysym, bool down, unsigned mods);
void iosc_input_text(iosc_input_t *h, const char *utf8);
void iosc_input_touch(iosc_input_t *h, int slot, int phase, int x, int y);
void iosc_input_tablet(iosc_input_t *h, int phase, int x, int y, unsigned pressure16,
                       int tilt_x_deg, int tilt_y_deg);
/* Two-finger / wheel scroll (XIOS_IN_AXIS in apps/shared/XiosProtocol.h).
 * dx256/dy256 = deltas in 1/256 canvas-pixel fixed point, wl_pointer sign
 * (positive = content scrolls down/right). source: 0 finger, 1 wheel. mods:
 * 1 shift, 2 ctrl, 4 alt. stop ends the gesture (dx=dy=0) so clients can fling
 * kinetically. Mirrors apps/Xios/Sources/IoscInput.{c,h} iosc_input_axis(),
 * made handle-based like the rest of this file. */
void iosc_input_axis(iosc_input_t *h, int dx256, int dy256, unsigned source,
                     unsigned mods, bool stop);
/* Trackpad pinch/rotate (XIOS_IN_GESTURE in apps/shared/XiosProtocol.h) ->
 * zwp_pointer_gestures_v1. kind: 1 swipe, 2 pinch, 3 hold. phase: 0 begin, 1 update,
 * 2 end, 3 cancel. scale256 = scale since begin in 1/256 (256 = 1.0), rot256 = rotation
 * since begin in 1/256 DEGREES clockwise; both ABSOLUTE since begin, as wl_pointer wants
 * them, not per-frame deltas. dx256/dy256 = gesture-centre movement in 1/256 canvas px.
 * Mirrors apps/Xios/Sources/IoscInput.{c,h} iosc_input_gesture(), handle-based. */
void iosc_input_gesture(iosc_input_t *h, unsigned kind, unsigned phase, unsigned fingers,
                        int dx256, int dy256, unsigned scale256, int rot256);
/* Drain the server->app stream. Returns 1 with ONE TRAITS record's fields filled
 * (call again for more; every enable/disable transition is delivered, nothing
 * coalesces), 0 when no complete record is pending, -1 on disconnect. Also
 * flushes input queued while the compositor was not reading, so call it every
 * tick. */
int  iosc_input_poll_traits(iosc_input_t *h, unsigned *hint, unsigned *purpose, unsigned *enabled);

#endif
