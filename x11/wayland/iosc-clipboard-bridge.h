/*
 * iosc-clipboard-bridge.h — the compositor half of Linux<->iOS clipboard sync.
 *
 * Owns the dedicated clipboard AF_UNIX socket (iosc-clipboard.sock) and speaks
 * an exact v1 HELLO followed by XIOS_MSG_CLIPBOARD records (the shared
 * 32-byte xios_msg envelope, see
 * linux-build/patches/xios/xios_surface.h) to the host app both directions:
 *
 *   Linux app copied   -> iosc.c publishes each snapshotted mime here ->
 *                         broadcast to connected hosts -> UIPasteboard.
 *   iOS-side copy      -> host sends records -> recv callback into iosc.c ->
 *                         wl_data_device selection offer.
 *
 * Everything lives on the compositor's wl_event_loop (no threads). Sends are
 * buffered per client and drained on WL_EVENT_WRITABLE, so a suspended app
 * never stalls the compositor AND a multi-megabyte PNG is never dropped for
 * mere backpressure (unlike the present stream's drop-on-EAGAIN posture —
 * that is why clipboard has its own socket). A client is dropped only on
 * protocol violation, hangup, or a runaway (>64 MiB) send backlog.
 *
 * iosc.c keeps the wl_data_device/offer store; this file never touches
 * Wayland protocol objects. Design + integration hooks: docs/clipboard-plan.md.
 */
#ifndef IOSC_CLIPBOARD_BRIDGE_H
#define IOSC_CLIPBOARD_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

struct wl_event_loop;

/* An iOS-side clipboard item arrived. `kind` is XIOS_CLIP_KIND_* (never NONE:
 * a clear is delivered as kind NONE ONLY via first_of_set=1, len=0, see below).
 * `first_of_set` is 1 when this record started a new logical clipboard (new
 * generation) — clear the previous selection's items before storing this one.
 * `data` is only valid during the call (len bytes, plus a NUL just past the
 * end for convenience with text kinds). Called on the wl_event_loop thread. */
typedef void (*ioscclip_recv_fn)(uint32_t kind, const void *data, size_t len,
                                 int first_of_set, void *user_data);

/* Create the listening socket at `path` on `loop` and register the receive
 * callback. Restricts the socket to the mobile user (0660) when resolvable,
 * like the ddx socket. Returns 0 on success. */
int ioscclip_start(struct wl_event_loop *loop, const char *path,
                   ioscclip_recv_fn on_recv, void *user_data);

/* A new Linux-side selection is starting (wl_data_device.set_selection):
 * bumps the outbound generation and forgets the previous set's items. Follow
 * with one ioscclip_publish() per snapshotted mime as each pipe read lands. */
void ioscclip_selection_begin(void);

/* Add one representation to the current Linux-side selection and broadcast it
 * to connected hosts. Data is copied. Returns 0 on success, -1 when the kind
 * is unusable or len exceeds XIOS_CLIP_ITEM_MAX. */
int ioscclip_publish(uint32_t kind, const void *data, size_t len);

/* The Linux-side selection was cleared: broadcast a KIND_NONE record. */
void ioscclip_selection_clear(void);

/* mime <-> XIOS_CLIP_KIND_* for the bridged representations. Returns
 * XIOS_CLIP_KIND_NONE / NULL for anything the bridge does not carry. Text
 * mime aliases (text/plain, UTF8_STRING, ...) all map to KIND_TEXT. */
uint32_t    ioscclip_kind_for_mime(const char *mime);
const char *ioscclip_mime_for_kind(uint32_t kind);

#endif /* IOSC_CLIPBOARD_BRIDGE_H */
