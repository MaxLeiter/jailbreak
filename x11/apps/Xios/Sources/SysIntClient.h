#ifndef XIOS_SYSINTCLIENT_H
#define XIOS_SYSINTCLIENT_H

// Native-feel system-integration senders (SystemIntegration.swift is the caller).
// Deliberately separate from IoscInput.c: this file owns its OWN sockets, so the
// bundle lands without touching the input bridge that the gesture track is
// actively editing.
//
//  - volume + appearance  ->  xios-sysintd  (/var/jb/tmp/xios-sysint.sock);
//    the session daemon applies them via pactl / gsettings.
//  - output (rotation)    ->  the iosc input socket (a SECOND connection —
//    iosc's reader multiplexes clients), record type XIOS_IN_OUTPUT.
//  - haptics              <-  iosc broadcasts XIOS_IN_HAPTIC to every input
//    client; we read them off our aux connection so IoscInput.c's traits
//    parser never has to know about them.
//
// All sends are fire-and-forget with lazy (re)connect, and the last output /
// volume / appearance values are replayed automatically after a reconnect, so a
// compositor or daemon restart converges to the iPad's real state.

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

#endif
