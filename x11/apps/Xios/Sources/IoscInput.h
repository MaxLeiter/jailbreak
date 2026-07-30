#ifndef XIOS_IOSCINPUT_H
#define XIOS_IOSCINPUT_H
#include <stdbool.h>

// Thin C bridge to the iosc Wayland compositor's input socket. When the Xios app is
// displaying iosc's output (a Wayland desktop) rather than an X server, UIKit touch +
// keyboard are forwarded here instead of over XTEST (see XInput.h). iosc translates
// these into wl_pointer / wl_keyboard events for the focused xdg_toplevel.
//
// Wire protocol (a fixed 24-byte message per event; app + iosc are both arm64 LE):
//   type=1 MOTION  x,y in output pixels
//   type=2 BUTTON  x,y + code(1/2/3) + state(1=down,0=up)
//   type=3 KEY     code = X keysym, mods bit0=shift bit1=ctrl bit2=alt
//   type=4 TEXT    code = UTF-8 byte length, followed by that many bytes
//   type=5 TRAITS  server->app: code = content hint, state = content purpose,
//                  mods = enabled (an editable field holds focus); drives the
//                  auto keyboard (x11/docs/osk-plan.md)
// Coordinates are iosc output-space pixels (same space as the IOSurface the app maps),
// so XScreenView.framebufferPoint() output feeds straight in.
bool iosc_input_open(const char *sock_path);   // connect; true on success
void iosc_input_close(void);
bool iosc_input_is_open(void);
void iosc_input_motion(int x, int y);                       // absolute, output px
void iosc_input_button(int button, bool down, int x, int y);// 1=left 2=mid 3=right
void iosc_input_key(unsigned keysym, bool down, unsigned mods); // true key down/up + mod snapshot
void iosc_input_text(const char *utf8);                     // committed UTF-8 text
// Real multitouch + Apple Pencil (wire spec: x11/wayland/xios_input_socket.h).
// phase: 0 up, 1 down, 2 motion, 3 cancel. slot = stable per-touch id 0..9.
void iosc_input_touch(int slot, int phase, int x, int y);
void iosc_input_tablet(int phase, int x, int y, unsigned pressure16,
                       int tilt_x_deg, int tilt_y_deg);     // pressure 0..65535
// Two-finger / wheel scroll. dx256/dy256 = deltas in 1/256 framebuffer-pixel fixed
// point, wl_pointer sign (positive = content scrolls down/right). source: 0 finger,
// 1 wheel. mods: 1 shift, 2 ctrl, 4 alt latched for the frame (pinch-zoom sends ctrl).
// stop ends the gesture (clients then fling).
void iosc_input_axis(int dx256, int dy256, unsigned source, unsigned mods, bool stop);
// Trackpad pinch/rotate -> zwp_pointer_gestures_v1 (wire spec: XIOS_IN_GESTURE in
// x11/wayland/xios_input_socket.h). kind: 1 swipe, 2 pinch, 3 hold. phase: 0 begin,
// 1 update, 2 end, 3 cancel. scale256 = scale since begin in 1/256 (256 = 1.0),
// rot256 = rotation since begin in 1/256 DEGREES clockwise. Both are ABSOLUTE since
// begin, as wl_pointer wants them, not per-frame deltas. dx256/dy256 = gesture-centre
// movement in 1/256 framebuffer px. Only pinch has a source on iPadOS; iosc.c explains
// why swipe and hold are implemented anyway.
void iosc_input_gesture(unsigned kind, unsigned phase, unsigned fingers,
                        int dx256, int dy256, unsigned scale256, int rot256);
// Drain the server->app stream. Returns 1 with ONE TRAITS record's fields filled
// (call again for more; every enable/disable transition is delivered, nothing
// coalesces), 0 when no complete record is pending, -1 on disconnect.
int iosc_input_poll_traits(unsigned *hint, unsigned *purpose, unsigned *enabled);

#endif
