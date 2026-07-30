/*
 * xios_input_socket.{c,h} — the Xios app input-socket reader (libxios_glue).
 *
 * The Xios iOS app streams UIKit touch/keyboard back to whichever display server
 * is running as a tiny AF_UNIX protocol: the canonical 32-byte xios_msg, plus a
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
#include "XiosProtocol.h"

typedef struct xios_input_socket xios_input_socket;

/* Per-message callback. For XIOS_IN_TEXT, `text`/`text_len` point at the payload
 * (owned by the socket, valid only for the callback); NULL/0 otherwise. */
typedef void (*xios_input_cb)(const xios_msg           *m,
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
 * DISPLAY-HOST client; a client whose write fails is dropped. Returns the number
 * written to. The reader owns the client fds, so this is the server->client path.
 * Clients that registered XIOS_IN_IMPROXY are skipped: they are not hosts and
 * would only hear their own traits echoed back. */
int xios_input_socket_broadcast(xios_input_socket *s, const void *buf, size_t len);

/* Same server->client path, but scoped to native per-window clients that have
 * sent XIOS_IN_BIND for `bound_window`. Clients that have not sent BIND yet are
 * included so the first traits snapshot after accept is not lost in the
 * connect-before-bind race. */
int xios_input_socket_broadcast_bound(xios_input_socket *s, uint32_t bound_window,
                                      const void *buf, size_t len);

/* Send `len` bytes to every client that registered XIOS_IN_IMPROXY (header plus
 * payload must be one contiguous buffer, as on the wire). Returns the number of
 * proxies written to; 0 means no proxy is registered, so the caller must handle
 * the record itself (iosc's own text-input commit / keysym fallback). */
int xios_input_socket_send_improxy(xios_input_socket *s, const void *buf, size_t len);

/* 1 while an input-method proxy is registered. Poll it after _dispatch(): the
 * proxy going away (nested compositor exited) has to clear the caller's latched
 * traits, or a keyboard raised for a field that no longer exists never lowers. */
int xios_input_socket_has_improxy(xios_input_socket *s);

/* Number of currently-connected clients (lets a caller detect a new connection
 * across dispatch calls, e.g. to send initial state). */
int xios_input_socket_client_count(xios_input_socket *s);

void xios_input_socket_free(xios_input_socket *s);

#endif /* XIOS_INPUT_SOCKET_H */
