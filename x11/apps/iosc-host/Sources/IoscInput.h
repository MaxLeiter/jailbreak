#ifndef IOSC_HOST_IOSCINPUT_H
#define IOSC_HOST_IOSCINPUT_H
#include <stdbool.h>

/*
 * IoscInput — host copy of apps/Xios/Sources/IoscInput.c, made HANDLE-BASED.
 *
 * The Xios app has ONE input connection (it shows the whole shared desktop). A
 * native-mode host shows several windows in several UIWindowScenes IN ONE
 * PROCESS, so each scene needs its OWN connection, scoped to its window with a
 * one-time XIOS_IN_BIND. Hence the iosc_input_t handle instead of the single
 * static fd. Wire format and coordinate space are otherwise identical to the
 * Xios shim (fixed 24-byte record; coords are output/canvas pixels).
 *
 * XIOS_IN_BIND (code = window id) is authoritative in
 * x11/wayland/xios_input_socket.h and honored by iosc's bound-aware dispatch
 * path. See x11/docs/native-ipados-protocol.md.
 */

typedef struct iosc_input iosc_input_t;

/* Connect to `sock_path` and BIND the connection to `window`. NULL on failure. */
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
/* Two-finger / wheel scroll (wire type 9, xios_input_socket.h XIOS_IN_AXIS).
 * dx256/dy256 = deltas in 1/256 canvas-pixel fixed point, wl_pointer sign
 * (positive = content scrolls down/right). source: 0 finger, 1 wheel. mods:
 * 1 shift, 2 ctrl, 4 alt. stop ends the gesture (dx=dy=0) so clients can fling
 * kinetically. Mirrors apps/Xios/Sources/IoscInput.{c,h} iosc_input_axis(),
 * made handle-based like the rest of this file. */
void iosc_input_axis(iosc_input_t *h, int dx256, int dy256, unsigned source,
                     unsigned mods, bool stop);
/* Trackpad pinch/rotate (wire type 14, xios_input_socket.h XIOS_IN_GESTURE) ->
 * zwp_pointer_gestures_v1. kind: 1 swipe, 2 pinch, 3 hold. phase: 0 begin, 1 update,
 * 2 end, 3 cancel. scale256 = scale since begin in 1/256 (256 = 1.0), rot256 = rotation
 * since begin in 1/256 DEGREES clockwise; both ABSOLUTE since begin, as wl_pointer wants
 * them, not per-frame deltas. dx256/dy256 = gesture-centre movement in 1/256 canvas px.
 * Mirrors apps/Xios/Sources/IoscInput.{c,h} iosc_input_gesture(), handle-based. */
void iosc_input_gesture(iosc_input_t *h, unsigned kind, unsigned phase, unsigned fingers,
                        int dx256, int dy256, unsigned scale256, int rot256);
/* Drain the server->app stream. Returns 1 with ONE TRAITS record's fields filled
 * (call again for more; every enable/disable transition is delivered, nothing
 * coalesces), 0 when no complete record is pending, -1 on disconnect. */
int  iosc_input_poll_traits(iosc_input_t *h, unsigned *hint, unsigned *purpose, unsigned *enabled);

#endif
