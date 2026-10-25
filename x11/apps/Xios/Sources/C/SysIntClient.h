#ifndef XIOS_SYSINTCLIENT_H
#define XIOS_SYSINTCLIENT_H

// Native-feel system-integration links, one handle per presented desktop
// (SystemIntegration.swift is the caller). Each handle owns two sockets:
//
//  - volume + appearance  ->  xios-sysintd (the session's sysint socket);
//    the session daemon applies app-originated volume via pactl and can send
//    desktop-originated volume and brightness requests back for the app to
//    apply to iOS.
//  - output (rotation)    ->  the config-advertised iosc input socket (a SECOND
//    connection: iosc's reader multiplexes clients), record type XIOS_IN_OUTPUT.
//  - haptics              <-  iosc broadcasts XIOS_IN_HAPTIC to every input
//    client; we read them off this aux connection so the input link's traits
//    parser never has to know about them.
//
// All sends are fire-and-forget with lazy (re)connect, and the last output /
// volume / appearance values are replayed automatically after a reconnect, so a
// compositor or daemon restart converges to the iPad's real state. A brand new
// handle has no replay state: the owner re-sends the current values on attach.
//
// Nothing here is thread-safe. The Swift owner serializes every call (open,
// send, poll, close) on one queue, and lazy connects therefore never run on the
// main thread.

typedef struct sysint_link sysint_link_t;

// Either path may be NULL or empty: that link is disabled. A path is never
// guessed from a process-global default because each desktop has its own
// sockets. Returns NULL only on allocation failure. Does not connect.
sysint_link_t *sysint_link_open(const char *sysint_path, const char *iosc_path);
void sysint_link_close(sysint_link_t *h);

// Volume 0..65535 (absolute; sysintd maps to sink 0..100%).
void sysint_send_volume(sysint_link_t *h, unsigned v16);

// dark: 1 = dark, 0 = light.
void sysint_send_appearance(sysint_link_t *h, int dark);

// wl_output transform 0/1/2/3 (normal/90/180/270); logical_w/h 0 = let iosc
// derive by swapping its launch logical size on quarter-turns.
void sysint_send_output(sysint_link_t *h, int transform, int logical_w, int logical_h);

// Drain haptic broadcasts. 1 = *style filled (0 light, 1 medium, 2 heavy,
// 3 selection), 0 = none pending. Also services the aux link's reconnect.
int sysint_poll_haptic(sysint_link_t *h, unsigned *style);

// Drain desktop-originated volume requests from xios-sysintd. 1 = *v16 filled
// with absolute volume 0..65535, 0 = none pending.
int sysint_poll_volume_set(sysint_link_t *h, unsigned *v16);

// Drain desktop-originated brightness requests from xios-sysintd. 1 = *v16 filled
// with absolute panel brightness 0..65535, 0 = none pending. The caller applies it
// with UIScreen.brightness: BKSDisplayBrightnessSet is inert outside SpringBoard,
// so xios-hwbridged cannot set the panel itself and hands the value to us instead.
//
// Shares one link with sysint_poll_volume_set, so each drains the other's records
// into a one-slot stash rather than discarding them. Call both every poll.
int sysint_poll_brightness_set(sysint_link_t *h, unsigned *v16);

#endif
