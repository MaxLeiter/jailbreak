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
// Coordinates are iosc output-space pixels (same space as the IOSurface the app maps),
// so XScreenView.framebufferPoint() output feeds straight in.
bool iosc_input_open(const char *sock_path);   // connect; true on success
void iosc_input_close(void);
bool iosc_input_is_open(void);
void iosc_input_motion(int x, int y);                       // absolute, output px
void iosc_input_button(int button, bool down, int x, int y);// 1=left 2=mid 3=right
void iosc_input_key(unsigned keysym, unsigned mods);        // X keysym + mod bitmask
void iosc_input_text(const char *utf8);                     // committed UTF-8 text

#endif
