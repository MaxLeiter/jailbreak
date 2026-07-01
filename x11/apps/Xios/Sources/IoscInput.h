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
void iosc_input_key(unsigned keysym, unsigned mods);        // X keysym + mod bitmask
void iosc_input_text(const char *utf8);                     // committed UTF-8 text
// Real multitouch + Apple Pencil (wire spec: x11/wayland/xios_input_socket.h).
// phase: 0 up, 1 down, 2 motion, 3 cancel. slot = stable per-touch id 0..9.
void iosc_input_touch(int slot, int phase, int x, int y);
void iosc_input_tablet(int phase, int x, int y, unsigned pressure16,
                       int tilt_x_deg, int tilt_y_deg);     // pressure 0..65535
// Drain the server->app stream. Returns 1 with ONE TRAITS record's fields filled
// (call again for more; every enable/disable transition is delivered, nothing
// coalesces), 0 when no complete record is pending, -1 on disconnect.
int iosc_input_poll_traits(unsigned *hint, unsigned *purpose, unsigned *enabled);

#endif
