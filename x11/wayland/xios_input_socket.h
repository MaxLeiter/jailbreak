/*
 * xios_input_socket.{c,h} — the Xios app input-socket reader (libxios_glue).
 *
 * The Xios iOS app streams UIKit touch/keyboard back to whichever display server
 * is running as a tiny AF_UNIX protocol: a fixed 24-byte record header, plus a
 * variable UTF-8 payload for XIOS_IN_TEXT. This module owns the listener, the
 * accept loop, and the per-client framing, and hands each complete record to a
 * callback — so BOTH iosc's wl_seat and MetaBackendIOS's ClutterVirtualInputDevice
 * consume ONE implementation of the wire format instead of forking it.
 *
 * The declarations here are the authoritative twin of the input section of
 * x11/wayland/xios-glue-stub.h (the frozen contract MetaBackendIOS compiles
 * against off-device); keep them identical.
 *
 * Multiplexing: xios_input_socket_fd() returns a single kqueue descriptor that
 * watches the listen socket + all client sockets, so a caller's poll()/event loop
 * wakes on either a new connection or client data and then calls _dispatch().
 * kqueue is in the iOS SDK, so this adds no dependency.
 */
#ifndef XIOS_INPUT_SOCKET_H
#define XIOS_INPUT_SOCKET_H

#include <stdint.h>
#include <stddef.h>

#ifndef XIOS_IN_MOTION
#define XIOS_IN_MOTION 1u   /* x,y = absolute output-pixel position            */
#define XIOS_IN_BUTTON 2u   /* code = button (1/2/3 -> L/R/M), state = up/down */
#define XIOS_IN_KEY    3u   /* code = X keysym, state = pressed/released, mods */
#define XIOS_IN_TEXT   4u   /* code = payload byte length; UTF-8 text follows  */
/* Additive fixed 24-byte records (no payload); readers that predate them pass
 * unknown types through untouched. Phases for both: state = 0 up, 1 down,
 * 2 motion, 3 cancel. */
#define XIOS_IN_TOUCH  6u   /* real multitouch: code = touch id (slot 0..9)    */
#define XIOS_IN_TABLET 7u   /* pen/stylus: code = pressure 0..65535,
                             * mods = (tilt_x_deg+90) | (tilt_y_deg+90)<<8     */
#define XIOS_IN_TRAITS 5u   /* server->CLIENT: on-screen-keyboard traits (code=hint,
                             * state=purpose, mods=enabled); sent via _broadcast   */
#define XIOS_IN_BIND   8u   /* scope this connection's input to one window
                             * (code = window id); sent once after connect by
                             * native-ipadOS per-window hosts (IoscInput.c had 8
                             * on-wire before this header did — 8 is BIND forever) */
#define XIOS_IN_AXIS   9u   /* two-finger / wheel scroll: x,y = dx,dy in 1/256
                             * output-pixel fixed point, wl_pointer sign (positive
                             * = content scrolls down/right); code = source
                             * (0 finger, 1 wheel); state bit0 = axis_stop (end of
                             * gesture, deltas 0 — lets clients fling kinetically);
                             * mods = wire modifier mask held for the frame;
                             * see XIOS_MOD_* below                                */
/* Native-feel system integration (rotation / volume / appearance / haptics).
 * OUTPUT + HAPTIC ride the compositor input socket; VOLUME + APPEARANCE go to
 * the separate xios-sysintd session daemon (same 24-byte framing, its own
 * socket /var/jb/tmp/xios-sysint.sock) so the compositor stays out of audio
 * and theme policy. One shared type registry so the families never collide. */
#define XIOS_IN_OUTPUT 10u  /* app->server: reconfigure the output for a device
                             * rotation. code = wl_output transform (0 normal,
                             * 1 = 90, 2 = 180, 3 = 270); x,y = requested LOGICAL
                             * WxH (0,0 = derive: quarter-turns swap the launch
                             * logical size); state/mods reserved (0)           */
#define XIOS_IN_HAPTIC 11u  /* server->CLIENT broadcast: fire a haptic. code =
                             * style (0 light, 1 medium, 2 heavy, 3 selection);
                             * sent e.g. when a press lands on shell chrome     */
#define XIOS_IN_VOLUME 12u  /* bidirectional via sysintd: app->daemon mirrors
                             * iOS hardware volume into PA; desktop->daemon with
                             * XIOS_VOLUME_STATE_TO_DEVICE asks the app to set
                             * iOS hardware volume. code = 0..65535            */
#define XIOS_VOLUME_STATE_TO_DEVICE 1u /* desktop/PA -> Xios app system volume */
#define XIOS_IN_APPEARANCE 13u /* app->sysintd: iOS interface style,
                             * code = 1 dark, 0 light                           */
#define XIOS_IN_BRIGHTNESS 15u /* desktop->sysintd->app, always with
                             * XIOS_BRIGHTNESS_STATE_TO_DEVICE: set the panel
                             * backlight. code = 0..65535.
                             *
                             * This exists because the obvious path does not work:
                             * BKSDisplayBrightnessSet is inert on iPadOS 17.6.1
                             * outside SpringBoard (symbols resolve, the brightness
                             * transaction creates, the entitlement is there, and
                             * BKSDisplayBrightnessGetCurrent never moves), so
                             * xios-hwbridged cannot drive the panel from a daemon.
                             * UIScreen.brightness works, but only inside a real app
                             * process, which is why this has to make the trip out to
                             * the Xios app the way desktop volume already does.
                             *
                             * One direction only. The reverse (iOS auto-brightness /
                             * Control Center moving the panel) needs no wire:
                             * BKSDisplayBrightnessGetCurrent READS fine from a
                             * daemon, so hwbridged already polls it and writes the
                             * value back into its synthetic sysfs node.          */
#define XIOS_BRIGHTNESS_STATE_TO_DEVICE 1u /* desktop -> Xios app panel backlight */
#define XIOS_IN_GESTURE 14u /* trackpad pinch/rotate/swipe -> pointer-gestures.
                             * code packs the gesture: bits 0-7 kind
                             * (XIOS_GESTURE_SWIPE/PINCH/HOLD), bits 8-15 phase
                             * (XIOS_GESTURE_BEGIN/UPDATE/END/CANCEL), bits 16-23
                             * finger count (2 for every trackpad gesture iPadOS
                             * reports to an app).
                             * x,y = translation delta in 1/256 output px, the
                             * same fixed point AXIS uses. state = pinch scale in
                             * 1/256 (256 = 1.0), ABSOLUTE since BEGIN rather
                             * than a per-frame delta, matching wl_pointer.
                             * mods = rotation in 1/256 DEGREES clockwise, an
                             * int32 riding in an unsigned field: cast it back
                             * before use. BEGIN and END/CANCEL carry no deltas;
                             * CANCEL sets wl_pointer's cancelled flag.         */
#define XIOS_GESTURE_SWIPE  1u
#define XIOS_GESTURE_PINCH  2u
#define XIOS_GESTURE_HOLD   3u
#define XIOS_GESTURE_BEGIN  0u
#define XIOS_GESTURE_UPDATE 1u
#define XIOS_GESTURE_END    2u
#define XIOS_GESTURE_CANCEL 3u
#endif

/* Fixed 24-byte record header. Layout matches iosc.c/ios-inputd.c iosc_in_msg. */
#ifndef XIOS_IN_MSG_DEFINED
#define XIOS_IN_MSG_DEFINED
struct xios_in_msg {
    uint32_t type;      /* one of XIOS_IN_*                                   */
    int32_t  x, y;      /* pointer position (output pixels), MOTION/BUTTON    */
    uint32_t code;      /* button / keysym / text length by type             */
    uint32_t state;     /* 0 released, 1 pressed (BUTTON/KEY)                 */
    uint32_t mods;      /* 1 shift, 2 ctrl, 4 alt, 8 super, 16 caps, 32 num */
};
#endif

typedef struct xios_input_socket xios_input_socket;

/* Per-message callback. For XIOS_IN_TEXT, `text`/`text_len` point at the payload
 * (owned by the socket, valid only for the callback); NULL/0 otherwise. */
typedef void (*xios_input_cb)(const struct xios_in_msg *m,
                              const char               *text,
                              size_t                    text_len,
                              uint32_t                  bound_window,
                              void                     *user);

/* Create the AF_UNIX listener at `path` (unlinks a stale node, mobile-owned
 * 0660 so the host app can connect). NULL on failure. */
xios_input_socket *xios_input_socket_new(const char *path);

/* The single fd to poll for readability (accepts + client data multiplexed). */
int xios_input_socket_fd(xios_input_socket *s);

/* Drain every currently-complete record, invoking `cb` for each. Returns the count
 * dispatched (>=0), or <0 on a fatal socket error (caller should tear down). */
int xios_input_socket_dispatch(xios_input_socket *s, xios_input_cb cb, void *user);

/* Write `len` bytes (a fixed record, e.g. XIOS_IN_TRAITS) to every connected
 * client; a client whose write fails is dropped. Returns the number written to.
 * The reader owns the client fds, so this is the server->client path. */
int xios_input_socket_broadcast(xios_input_socket *s, const void *buf, size_t len);

/* Same server->client path, but scoped to native per-window clients that have
 * sent XIOS_IN_BIND for `bound_window`. Clients that have not sent BIND yet are
 * included so the first traits snapshot after accept is not lost in the
 * connect-before-bind race. */
int xios_input_socket_broadcast_bound(xios_input_socket *s, uint32_t bound_window,
                                      const void *buf, size_t len);

/* Number of currently-connected clients (lets a caller detect a new connection
 * across dispatch calls, e.g. to send initial state). */
int xios_input_socket_client_count(xios_input_socket *s);

void xios_input_socket_free(xios_input_socket *s);

#endif /* XIOS_INPUT_SOCKET_H */
