/*
 * xios-glue-stub.h — LOCAL declarations of the planned libxios_glue API (the shared
 * iOS/GPU glue both iosc and MetaBackendIOS link; see docs/iosc-shared-glue.md).
 *
 * The MetaBackendIOS pieces (monitor manager, input, the Wayland IOSurface buffer type)
 * are developed and compile-checked OFF-DEVICE against the mutter source tree before they
 * go into src/backends/ios/. To let each piece compile independently of the (still-being-
 * factored) real libxios_glue, they target THIS header — the exact API surface the shared
 * lib will export. In the real backend these symbols come from libxios_glue; here the
 * compile check needs only the declarations (each piece is built with -c, so the externs
 * resolve at link time against the lib). No iosc.c is touched by any of this.
 *
 * Keep this in lock-step with iosc-shared-glue.md's API table. Grows as the backend does.
 */
#ifndef XIOS_GLUE_STUB_H
#define XIOS_GLUE_STUB_H

#include <stdint.h>
#include <stddef.h>

/* ---- output geometry / scale (for MetaMonitorManagerIOS) --------------------------
 * The Xios app presents one fullscreen output IOSurface at the iPad's native pixel size;
 * iosc computes the display scale (output_scale()). Today: 2160x1620 @ scale 2 (iosc.c
 * g_width/g_height/g_output_scale). MetaMonitorManagerIOS turns these into its single
 * hardwired MetaOutput/MetaCrtc/mode. In libxios_glue this is backed by xios_surface. */
void  xios_output_geometry (int *width, int *height);
float xios_output_scale (void);

/* ---- input socket (for the ClutterVirtualInputDevice pump) -------------------------
 * The Xios app streams a tiny AF_UNIX protocol of fixed 24-byte records (+ a variable
 * text payload for XIOS_IN_TEXT). This is wire-identical to iosc's built-in input socket
 * and ios-inputd.c's `struct iosc_in_msg`; libxios_glue owns the listener + framing so
 * both iosc's wl_seat and MetaBackendIOS's virtual device consume the same stream. */

#define XIOS_IN_MOTION 1u   /* x,y = absolute output-pixel position           */
#define XIOS_IN_BUTTON 2u   /* code = evdev button (or 0/1/2 -> L/R/M), state */
#define XIOS_IN_KEY    3u   /* code = X keysym, state = pressed/released, mods */
#define XIOS_IN_TEXT   4u   /* code = payload byte length; text follows        */
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
                             * mods = modifier mask (1 shift, 2 ctrl, 4 alt) held
                             * for the frame — pinch-zoom sends ctrl+scroll        */
#define XIOS_IN_OUTPUT 10u  /* app->server: output transform/size change       */
#define XIOS_IN_HAPTIC 11u  /* server->CLIENT broadcast: haptic feedback       */
#define XIOS_IN_VOLUME 12u  /* app->sysintd: absolute output volume            */
#define XIOS_IN_APPEARANCE 13u /* app->sysintd: iOS interface style            */

/* Fixed 24-byte record header. Layout matches ios-inputd.c struct iosc_in_msg exactly. */
struct xios_in_msg
{
  uint32_t type;      /* one of XIOS_IN_*                                   */
  int32_t  x, y;      /* pointer position (output pixels), MOTION only      */
  uint32_t code;      /* button / keysym / text length by type             */
  uint32_t state;     /* 0 released, 1 pressed (BUTTON/KEY)                 */
  uint32_t mods;      /* app modifier bitmask: 1 shift, 2 ctrl, 4 alt      */
};

typedef struct xios_input_socket xios_input_socket;

/* Per-message callback. For XIOS_IN_TEXT, `text`/`text_len` point at the payload
 * (owned by the socket, valid only for the callback); NULL/0 otherwise. */
typedef void (*xios_input_cb) (const struct xios_in_msg *m,
                               const char               *text,
                               size_t                    text_len,
                               uint32_t                  bound_window,
                               void                     *user);

/* Create the AF_UNIX listener at `path` (unlinks a stale node). NULL on failure. */
xios_input_socket *xios_input_socket_new (const char *path);

/* The single fd to poll for readability (accepts + client data multiplexed). */
int xios_input_socket_fd (xios_input_socket *s);

/* Drain every currently-complete record, invoking `cb` for each. Returns the count
 * dispatched (>=0), or <0 on a fatal socket error (caller should tear down). */
int xios_input_socket_dispatch (xios_input_socket *s, xios_input_cb cb, void *user);

/* Write `len` bytes (a fixed record, e.g. XIOS_IN_TRAITS) to every connected
 * client; a client whose write fails is dropped. Returns the number written to. */
int xios_input_socket_broadcast (xios_input_socket *s, const void *buf, size_t len);

int xios_input_socket_broadcast_bound (xios_input_socket *s, uint32_t bound_window,
                                       const void *buf, size_t len);

/* Number of currently-connected clients (detect a new connection across dispatch). */
int xios_input_socket_client_count (xios_input_socket *s);

void xios_input_socket_free (xios_input_socket *s);

/* ---- client IOSurface import (for the IOSurface MetaWaylandBuffer type) -------------
 * A GPU client renders into its own IOSurface, IOSurfaceCreateMachPort()s it, and names
 * that port (+ its pid, from the Wayland socket peer creds) over the iosc_iosurface
 * protocol. libxios_glue reaches into the client task (task_for_pid +
 * mach_port_extract_right, xios_surface.c) and imports the surface, then bridges it to a
 * GL texture for the compositor. Signatures match xios_surface.h. */

#include <EGL/egl.h>
#include <EGL/eglext.h>

/* Import a client IOSurface by pid + mach port name; retained (release with
 * xios_release_client_iosurface). Returns an opaque IOSurfaceRef, or NULL; fills w,h. */
void *xios_import_client_iosurface (int pid, unsigned port_name, int *w, int *h);
void  xios_release_client_iosurface (void *iosurface);

/* Bridge an imported IOSurface to an EGLImage on the ANGLE-Metal EGLDisplay the Cogl
 * context was created against, so the compositor can wrap it with the idiomatic
 * cogl_egl_texture_2d_new_from_image() (the same path mutter uses for EGL_IMAGE / DMA_BUF).
 * ANGLE-Metal has no direct IOSurface->EGLImage: the glue makes it via a wrapping
 * MTLTexture + EGL_ANGLE_metal_texture_client_buffer (the pbuffer+bind client-buffer route
 * is the glue's internal fallback). This keeps ALL the ANGLE-specific mechanics in the
 * shared lib and the mutter buffer type uniform with the other GPU buffer types.
 * Returns EGL_NO_IMAGE_KHR on failure. */
EGLImageKHR xios_egl_image_from_iosurface (void *iosurface, int width, int height);
void        xios_egl_destroy_image (EGLImageKHR image);

/* ---- output surface + present (for MetaRendererIOS) --------------------------------
 * The ANGLE-Metal EGLDisplay MetaRendererIOS's Cogl winsys renders against, the output
 * IOSurface the stage view renders into (zero-copy — imported as a Cogl texture the same
 * way client buffers are), and the "the output changed, re-present" nudge to the Xios app.
 * All three are xios_surface / xios_egl in the real libxios_glue. */
EGLDisplay xios_egl_display (void);          /* lazy getter; matches libxios_glue */
void      *xios_get_output_iosurface (void);
void       xios_notify_dirty (void);
void       xios_notify_cursor (int x, int y, int visible, int shape_id);

/* The pbuffer + RGBA8 + BIND_TO_TEXTURE_RGBA EGLConfig xios_egl chose the IOSurface pbuffers
 * against (matches libxios_glue xios_egl.h). MetaRendererIOS points its Cogl winsys config at
 * this so the Cogl display/context and the pbuffer share ONE EGLConfig — otherwise
 * eglMakeCurrent(pbuffer) throws EGL_BAD_MATCH. */
EGLConfig xios_egl_config (void);

/* Wrap the output IOSurface as an ANGLE pbuffer (EGL_ANGLE_iosurface_client_buffer). Used as
 * the CoglOnscreenEgl's EGLSurface so Cogl renders to FBO 0 == the IOSurface (route A: the
 * IOSurface->EGLImage render-target path fails on ANGLE-Metal). EGL_NO_SURFACE on failure. */
EGLSurface xios_egl_create_iosurface_pbuffer (void *iosurface, int w, int h);

/* ---- output-surface + Xios-app rendezvous creation (MetaBackendIOS::constructed) ---
 * The mutter backend must CREATE the output IOSurface and start the Xios-app rendezvous
 * (which writes xios.json so the app finds + displays the surface) before the renderer
 * imports it in create_view — exactly what iosc.c main() does. Real impl in xios_surface.c;
 * signatures match linux-build/patches/xios/xios_surface.h. */
void *xios_surface_create (int width, int height, int *stride, int *alloc_size);
int   xios_server_start (const char *sock_path, const char *json_path,
                         int width, int height, int stride);
void  xios_server_stop (void);

/* Call BEFORE xios_server_start. xios_set_compositor_id names the flavor ("mutter-ios") in the
 * typed in-band HELLO so the app enables the cursor overlay. xios_set_input_socket makes the
 * json writer emit "input_socket":<path> in xios.json, so the app routes keyboard/pointer/scroll
 * to mutter's AF_UNIX input socket instead of falling through to a dead XTEST path. Real impls in
 * xios_surface.c (libxios_glue, commit 0027261); prototypes match xios_surface.h. */
void  xios_set_compositor_id (const char *id);
void  xios_set_input_socket (const char *path);

#endif /* XIOS_GLUE_STUB_H */
