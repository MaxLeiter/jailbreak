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
#endif

/* Fixed 24-byte record header. Layout matches iosc.c/ios-inputd.c iosc_in_msg. */
#ifndef XIOS_IN_MSG_DEFINED
#define XIOS_IN_MSG_DEFINED
struct xios_in_msg {
    uint32_t type;      /* one of XIOS_IN_*                                   */
    int32_t  x, y;      /* pointer position (output pixels), MOTION/BUTTON    */
    uint32_t code;      /* button / keysym / text length by type             */
    uint32_t state;     /* 0 released, 1 pressed (BUTTON/KEY)                 */
    uint32_t mods;      /* app modifier bitmask: 1 shift, 2 ctrl, 4 alt      */
};
#endif

typedef struct xios_input_socket xios_input_socket;

/* Per-message callback. For XIOS_IN_TEXT, `text`/`text_len` point at the payload
 * (owned by the socket, valid only for the callback); NULL/0 otherwise. */
typedef void (*xios_input_cb)(const struct xios_in_msg *m,
                              const char               *text,
                              size_t                    text_len,
                              void                     *user);

/* Create the AF_UNIX listener at `path` (unlinks a stale node, chmod 0777 so the
 * mobile-uid app can connect). NULL on failure. */
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

/* Number of currently-connected clients (lets a caller detect a new connection
 * across dispatch calls, e.g. to send initial state). */
int xios_input_socket_client_count(xios_input_socket *s);

void xios_input_socket_free(xios_input_socket *s);

#endif /* XIOS_INPUT_SOCKET_H */
