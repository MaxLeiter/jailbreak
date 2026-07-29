#ifndef XIOS_SYSINTCLIENT_H
#define XIOS_SYSINTCLIENT_H

// Native-feel system-integration senders (SystemIntegration.swift is the caller).
// Deliberately separate from IoscInput.c: this file owns its OWN sockets, so the
// bundle lands without touching the input bridge that the gesture track is
// actively editing.
//
//  - volume + appearance  ->  xios-sysintd;
//    the session daemon applies app-originated volume via pactl and can send
//    desktop-originated volume requests back for the app to apply to iOS.
//  - output (rotation)    ->  the config-advertised iosc input socket (a SECOND
//    connection — iosc's reader multiplexes clients), record type XIOS_IN_OUTPUT.
//  - haptics              <-  iosc broadcasts XIOS_IN_HAPTIC to every input
//    client; we read them off our aux connection so IoscInput.c's traits
//    parser never has to know about them.
//
// All sends are fire-and-forget with lazy (re)connect, and the last output /
// volume / appearance values are replayed automatically after a reconnect, so a
// compositor or daemon restart converges to the iPad's real state.

// Set the endpoints before installing SystemIntegration. A NULL/empty iosc path
// disables the aux Wayland link; it is intentionally never guessed from a
// process-global default because each display/session can have its own socket.
void sysint_set_iosc_socket(const char *path);
void sysint_set_sysint_socket(const char *path);

// Volume 0..65535 (absolute; sysintd maps to sink 0..100%).
void sysint_send_volume(unsigned v16);

// dark: 1 = dark, 0 = light.
void sysint_send_appearance(int dark);

// wl_output transform 0/1/2/3 (normal/90/180/270); logical_w/h 0 = let iosc
// derive by swapping its launch logical size on quarter-turns.
void sysint_send_output(int transform, int logical_w, int logical_h);

// Drain haptic broadcasts. 1 = *style filled (0 light, 1 medium, 2 heavy,
// 3 selection), 0 = none pending. Also services the aux link's reconnect.
int sysint_poll_haptic(unsigned *style);

// Drain desktop-originated volume requests from xios-sysintd. 1 = *v16 filled
// with absolute volume 0..65535, 0 = none pending.
int sysint_poll_volume_set(unsigned *v16);

#endif
