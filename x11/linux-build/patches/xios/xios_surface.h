/*
 * xios_surface.h — IOSurface-backed output shared by Xios compositors and the app.
 *
 * Plain C, with no compositor headers, so all Apple-framework code stays behind
 * this narrow interface.
 *
 * Sharing model (validated on iPadOS 17.6.1 — global IOSurfaceLookup(id) is dead,
 * so we hand the IOSurface's mach port to the app over a Unix socket rendezvous):
 *   1. The compositor creates a BGRA8 IOSurface and renders into it on the GPU.
 *   2. App connects and sends a canonical v1 HELLO naming its Mach receive port.
 *   3. Server task_for_pid()s the app, mach_port_extract_right()s a send right to
 *      that port, and mach_msg()s IOSurfaceCreateMachPort() across as a port
 *      descriptor. App does IOSurfaceLookupFromMachPort() -> same backing memory.
 *   4. Server streams damage bounding-boxes over the socket so the app only
 *      re-presents on change (zero-copy: no per-frame texture upload).
 */
#ifndef XIOS_SURFACE_H
#define XIOS_SURFACE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "XiosProtocol.h"

/* Select how many compositor output IOSurfaces xios_surface_create() allocates.
 * The default is one for fixed-target users (Xorg/Mutter). iosc selects three
 * before create so rendering and app presentation can overlap without either
 * GPU queue touching the same allocation. Values outside 1..3 are rejected. */
int xios_set_output_buffer_count(unsigned count);

/* Create the shared BGRA8 IOSurface set for a `width`x`height` screen.
 * Returns the framebuffer base address (the X server draws directly here), or
 * NULL on failure. On success *stride is the real bytes-per-row (may be padded
 * for alignment) and *alloc_size is the total allocation in bytes. */
void *xios_surface_create(int width, int height, int *stride, int *alloc_size);

/* Replace the output IOSurface with a new width x height one (device rotation).
 * The new surface is created first; on failure the old surface stays live. On
 * success the geometry state and xios.json sidecar are updated, current app
 * clients are disconnected so they re-handshake, and the new framebuffer base is
 * returned with the same contract as xios_surface_create(). */
void *xios_surface_resize(int width, int height, int *stride, int *alloc_size);

/* Acquire an output buffer for a compositor frame. `age` follows EGL buffer-age
 * semantics: 0 means undefined contents (redraw everything), 1 means the
 * preceding output frame, N means accumulate the preceding N-1 frames' damage.
 * `release_wait_value` is a value on the compositor-owned release timeline that
 * must be GPU-waited before writing this allocation. Returns 1 on success and 0
 * when every output is still awaiting a release submission from the app. */
int xios_output_acquire(void **iosurface, uint32_t *surface_id,
                        unsigned *age, uint64_t *release_wait_value);
void xios_output_cancel(uint32_t surface_id);

/* Configure the compositor-owned release MTLSharedEvent token advertised to
 * stream-v2 app clients. Must be called before xios_server_start(). */
int xios_set_release_fence_token(const void *token, size_t token_size);

/* Start the AF_UNIX rendezvous/damage socket at sock_path and write the geometry
 * handshake to json_path (so the app can detect IOSurface mode and find the
 * socket). Spawns one background thread that accepts clients and performs the
 * mach-port hand-off. Must be called after xios_surface_create(). 0 on success.
 * Idempotent: a second call while already serving is a no-op. */
int xios_server_start(const char *sock_path, const char *json_path,
                      int width, int height, int stride);

/* Notify every connected app that a GPU frame is ready. `shared_event_token` is the
 * fixed 32-byte capability under which the producer published its persistent
 * MTLSharedEventHandle to the package broker. `event_value` is the value the
 * Xios Metal command buffer must wait for before sampling the output IOSurface.
 * DIRTY marks window_id as XIOS_DIRTY_FENCE_BROKER_TOKEN, carries the token as
 * payload, and carries the value in c/d. Returns 0 when queued to live clients
 * and -1 for invalid input. */
int xios_notify_dirty_with_fence(const void *shared_event_token,
                                 size_t token_size,
                                 uint64_t event_value);

/* Surface-addressed form used by the output swapchain and direct IOSurface
 * pass-through. On success seq_out receives the DIRTY sequence. */
int xios_notify_surface_with_fence(uint32_t surface_id,
                                   const void *shared_event_token,
                                   size_t token_size,
                                   uint64_t event_value,
                                   uint64_t *seq_out);

/* Export an already-existing client IOSurface into the app stream without a
 * compositor copy. Registration retains the surface until unregister. The
 * returned id is stable for repeated registration of the same IOSurface. */
uint32_t xios_stream_register_surface(void *iosurface, uint32_t flags);
void xios_stream_unregister_surface(uint32_t surface_id);
uint64_t xios_stream_released_generation(uint32_t surface_id);

/* True only when the sole attached app negotiated stream-v2. Direct
 * pass-through must fall back to composition otherwise. */
int xios_stream_v2_active(void);

uint64_t xios_dirty_generation(void);
uint64_t xios_presented_generation(void);

/* ---- display pacing (fed by XIOS_MSG_PACING / XIOS_MSG_PRESENTED) ----------
 *
 * The app's display clock, translated into the compositor's own CLOCK_MONOTONIC on
 * arrival. Returns 1 when a live clock is available and fills whichever out-params
 * are non-NULL; returns 0 when no app has reported one recently (no app attached,
 * an app from before display pacing, or a backgrounded app whose link is paused) —
 * in which case the caller must keep its previous, event-loop-paced behaviour.
 *
 *   next_deadline_ms  absolute CLOCK_MONOTONIC ms of the app's next frame deadline.
 *                     Already advanced past `now` in whole refresh intervals, so it
 *                     always names a FUTURE vblank.
 *   interval_us       refresh interval in microseconds (16667 on a 60 Hz panel).
 *   min_mfps/max_mfps the frame-rate range the app asked CoreAnimation for, in
 *                     fps*1000. 0 when the app did not say.
 */
int xios_display_clock(uint64_t *next_deadline_ms, uint32_t *interval_us,
                       int *min_mfps, int *max_mfps);

/* How long before the most recent PRESENTED ack the frame ACTUALLY reached the
 * display, in microseconds, from MTLDrawable.addPresentedHandler — plus the
 * absolute CLOCK_MONOTONIC ms at which that ack arrived, so the caller can
 * reconstruct the present time on its own clock. Returns 1 when the app reported a
 * real present time, 0 when it did not (in which case presentation feedback should
 * fall back to timing the repaint, as it did before pacing). */
int xios_last_present_time(uint32_t *age_us, uint64_t *ack_at_ms);

/* ---- app-socket framing (present / cursor / native envelope) ----------------
 * Both directions begin with an exact-version XIOS_MSG_HELLO, followed by the
 * same typed 32-byte record stream used by every private iosc<->host channel.
 * The record grammar itself — including XIOS_MSG_PACING and the present-time
 * fields PRESENTED carries — lives in apps/shared/XiosProtocol.h. */

/* ---- XIOS_MSG_CLIPBOARD (0x04): clipboard sync record ----------------------
 * Rides the DEDICATED clipboard socket (iosc-clipboard.sock), NOT the app/ddx
 * socket above — the present stream's never-stall/drop-on-backpressure posture
 * is wrong for bulk clipboard payloads that must arrive whole. Same 32-byte
 * xios_msg envelope though, so there is ONE record grammar across every
 * iosc<->host channel (same decision osk-plan.md made for TRAITS).
 *
 * Fields:  window_id = 0
 *          length    = item data bytes (payload follows the header)
 *          a         = XIOS_CLIP_KIND_* (which representation this is)
 *          b         = generation: the sender's copy-event counter. Records
 *                      sharing a generation are representations of ONE logical
 *                      clipboard (e.g. text + html of the same copy). A record
 *                      whose generation differs from the receiver's last-seen
 *                      REPLACES the clipboard; an equal one MERGES into it.
 *                      Compare with !=, not < (counters start at 1 and wrap).
 *          c, d      = 0 (reserved; c is earmarked for chunked transfers)
 *
 * Both directions are symmetric (compositor->app on Linux-side copy, app->
 * compositor on UIPasteboard change). KIND_NONE with length 0 clears. On
 * connect the compositor replays its current set if non-empty. Items above
 * XIOS_CLIP_ITEM_MAX are a protocol violation: receiver drops the connection. */

/* Send a CURSOR record (pointer position + wp_cursor_shape id, shape_id 0 = hidden)
 * to every app client. No-op when none are attached. Lets
 * a present-side cursor overlay in the app move the pointer with ZERO compositor
 * recomposite. Non-blocking, same never-stall posture as fenced frame delivery. */
void xios_notify_cursor(int x, int y, int visible, int shape_id);

/* Send the PIXELS of a client-supplied cursor so the app's overlay can act as a
 * real cursor plane, and the compositor never has to paint the cursor into the
 * shared output buffer (which is what forfeits direct scanout). Sent on cursor
 * IMAGE change only — never per frame, never per pointer move, which is why
 * this one may briefly wait for socket space instead of coalescing.
 * `bgra` is tightly packed premultiplied BGRA, stride = width*4. Passing NULL
 * (or a zero size) withdraws the image and returns the app to the named shape.
 * Edges above XIOS_CURSOR_IMAGE_MAX are refused. */
void xios_notify_cursor_image(const void *bgra, int width, int height,
                              int hot_x, int hot_y);

/* True if at least one app client is attached (so the compositor knows the app
 * can draw its own cursor overlay and can stop compositing the cursor into the
 * output). */
int xios_have_app_client(void);

/* Bumped every time an app client attaches. The compositor re-sends cursor
 * CONTENT when this changes, since a reconnecting app missed the last one. */
unsigned xios_app_client_generation(void);

/* Identify which compositor is driving (e.g. "iosc", "mutter-ios"). Sent to
 * clients in the in-band XIOS_MSG_HELLO on connect, so the app learns the
 * flavor + geometry from the socket itself. xios.json remains the startup
 * discovery sidecar that tells the app which socket to adopt. Call before/after
 * xios_server_start; default is empty (unknown). */
void xios_set_compositor_id(const char *id);

/* Advertise the input socket the app should send keyboard/pointer to, emitted as
 * the "input_socket" field in xios.json. The app only auto-infers an input socket
 * when the ddx socket path contains "iosc", so any other compositor (e.g. mutter
 * on mutter-ddx.sock) MUST set this or it gets no input. Call before
 * xios_server_start; if unset the field is omitted (app keeps its inference). */
void xios_set_input_socket(const char *path);

/* Advertise the dedicated clipboard endpoint in xios.json. Compositors that do
 * not provide an iOS pasteboard bridge leave it unset. */
void xios_set_clipboard_socket(const char *path);

/* Present-side upscaling hint, emitted as xios.json's "upscale" field. Purely a
 * message to the display app: the compositor's own output IOSurface, geometry, and
 * wl_output state are unaffected, and no Wayland client can observe it. Accepted
 * spellings are the app's business (see XScreen.UpscaleMode) — "off", "auto", or a
 * factor like "1.5". Unset means off, which is the default. */
void xios_set_upscale_hint(const char *spec);

/* Tear down the socket, clients, and IOSurface (server exit). */
void xios_server_stop(void);

/* ---- client→server IOSurface import (Wayland zero-copy GPU buffers) --------
 *
 * The reverse of the app hand-off above: a Wayland client (e.g. an ANGLE-Metal
 * GLES client) renders into its OWN IOSurface, calls IOSurfaceCreateMachPort()
 * to get a port name in its task, and passes that name + its pid to the
 * compositor over the Wayland protocol. These helpers let the compositor import
 * that surface using the SAME task_for_pid + mach_port_extract_right primitives
 * as deliver_surface_port(), then composite it into the output surface. All the
 * Apple-framework code stays in this file (callers see only opaque void*). */

/* Import a client's IOSurface by reaching into its task. `pid` is the client's
 * pid (from the Wayland socket peer credentials); `port_name` is the
 * IOSurfaceCreateMachPort() name in the client's IPC space. Returns an opaque
 * IOSurfaceRef (retained; release with xios_release_client_iosurface), or NULL.
 * On success the w and h out-params receive the surface dimensions. */
void *xios_import_client_iosurface(int pid, unsigned port_name, int *w, int *h);

/* Release a surface returned by xios_import_client_iosurface(). */
void xios_release_client_iosurface(void *client_surface);

/* Copy a small client surface to tightly packed top-down BGRA (stride w*4),
 * flipping when it carries GL bottom-left origin. Used for the cursor plane:
 * an IOSurface is CPU-mappable, so this is a lock plus a memcpy rather than a
 * GPU readback. Returns 1 on success. */
int xios_read_client_iosurface(void *client_surface, unsigned char *dst,
                               int width, int height, int flip_v);

/* Debug: report what a client actually committed into its IOSurface.
 * Counts pixels with any non-zero colour separately from pixels with non-zero
 * alpha, which is what distinguishes the three ways a client can end up
 * invisible: it drew nothing (colour == 0), it drew content but left alpha at
 * zero so compositing erases it (colour > 0, alpha == 0), or it drew a correct
 * opaque frame and the fault is downstream in the compositor. Locks read-only,
 * so it is a synchronous GPU->CPU stall: call it from a debug path only.
 * `tag` labels the log line. Safe to call with NULL. */
void xios_probe_client_iosurface(void *client_surface, const char *tag);

/* The output IOSurface (opaque IOSurfaceRef) the Xios app displays — so a GPU
 * compositor can bind it as an ANGLE render target. NULL before xios_surface_create(). */
void *xios_get_output_iosurface(void);

/* The created output surface's pixel dimensions (0x0 before xios_surface_create()).
 * Backs xios_output_geometry() in the shared glue (MetaMonitorManagerIOS). */
void xios_surface_geometry(int *width, int *height);

/* Read one pixel of the output IOSurface in APP/display space (top-left origin) as
 * a 32-bit little-endian BGRA value — i.e. exactly what the Xios app shows at (x,y).
 * Locks read-only so GPU (Metal/ANGLE) writes are made coherent to the CPU first.
 * Validation/diagnostics only (orientation + placement ground truth, off the hot
 * path). Returns 0 if there is no surface or (x,y) is out of range. */
uint32_t xios_read_output_pixel(int x, int y);

/* Bulk read-back of a w x h region of the output IOSurface at (x,y) in APP/display
 * space (top-left origin) into `dst` (BGRA8, `dst_stride` bytes per row). Locks the
 * surface read-only ONCE so GPU (Metal/ANGLE) writes are made coherent, then copies
 * row by row; the rect is clamped to the surface (out-of-range columns/rows in dst
 * are left untouched). Returns 0 on success, -1 if there is no surface / bad args.
 *
 * This is the SOFTWARE screencopy seam (zwlr_screencopy_v1): a later GPU-blit path
 * (blit the output IOSurface straight into the client's IOSurface-backed buffer, no
 * CPU round-trip) can replace this body without touching the protocol callers. */
int xios_read_output_region(int x, int y, int w, int h, void *dst, int dst_stride);

#endif /* XIOS_SURFACE_H */
