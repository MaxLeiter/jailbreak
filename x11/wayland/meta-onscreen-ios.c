/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-onscreen-ios.c — the IOSurface-pbuffer CoglOnscreen (see the header).
 *
 * The EGLSurface backing this onscreen is the output IOSurface wrapped as an ANGLE pbuffer,
 * so binding it (the base CoglOnscreenEgl::bind -> eglMakeCurrent(pbuffer, pbuffer, ctx))
 * makes FBO 0 the IOSurface and Cogl renders the stage straight into it. Present is the only
 * platform-specific step: there is no back buffer, so instead of the base
 * cogl_onscreen_egl_swap_buffers_with_damage (which calls eglSwapBuffers on the pbuffer — a
 * no-op / undefined), we finish (so ANGLE/Metal commits the GL writes into the IOSurface) and
 * signal the Xios app to re-present. GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-onscreen-ios.h"

#include "backends/ios/xios-glue-stub.h"
#include "clutter/clutter.h"
#include "cogl/cogl.h"
/* CoglFramebufferDriverConfig + COGL_FRAMEBUFFER_DRIVER_TYPE_BACK come in via cogl/cogl.h's
 * cogl-mutter.h chain, exactly as in meta-onscreen-native.c (which constructs the same
 * driver_config without an explicit private include). */

struct _MetaOnscreenIOS
{
  CoglOnscreenEgl parent;
};

G_DEFINE_TYPE (MetaOnscreenIOS, meta_onscreen_ios, COGL_TYPE_ONSCREEN_EGL)

static gboolean
meta_onscreen_ios_is_y_flipped (CoglFramebuffer *framebuffer)
{
  /* This "onscreen" is an IOSurface pbuffer the Xios app samples TOP-LEFT (like a texture /
   * offscreen), NOT presented by a window-system eglSwapBuffers — and that swap is exactly what
   * makes a normal onscreen's GL bottom-left origin come out upright on screen. Without it, the
   * GL driver's onscreen Y-flip (cogl-framebuffer-gl.c: the !is_y_flipped branch) writes the
   * stage bottom-up into the IOSurface, so the app's top-left sampling shows the whole desktop
   * upside down. Report the OFFSCREEN convention (TRUE): the driver then renders top-left-correct
   * into the surface, exactly like render-to-texture, matching the app + iosc's own dest-Y flip
   * (iosc_gl.c). Y-only; no horizontal mirror. */
  return TRUE;
}

static void
meta_onscreen_ios_swap_buffers_with_damage (CoglOnscreen  *onscreen,
                                            const int     *rectangles,
                                            int            n_rectangles,
                                            CoglFrameInfo *info,
                                            gpointer       user_data)
{
  /* FBO 0 is the output IOSurface (the pbuffer); there is no back buffer to swap. Finish so
   * ANGLE/Metal commits the GL writes into the IOSurface, then nudge the Xios app to
   * re-present it. Do NOT call eglSwapBuffers on a pbuffer. */
  cogl_framebuffer_finish (COGL_FRAMEBUFFER (onscreen));
  xios_notify_dirty ();

  /* A swap DID happen for this frame, so a presentation notification is coming: the public
   * cogl_onscreen_swap_buffers_with_damage() wrapper that invoked us auto-queues SYNC + COMPLETE
   * frame events (no winsys has the SYNC_AND_COMPLETE_EVENT feature), which dispatch on the next
   * cogl idle -> MetaStageView::frame_cb -> clutter_stage_view_notify_presented. Mark the frame
   * PENDING_PRESENTED so the ClutterFrameClock waits for that COMPLETE and then re-arms. user_data
   * is the ClutterFrame (MetaStageImpl::swap_framebuffer passes `frame` as the swap user_data),
   * exactly as meta_onscreen_native_swap_buffers_with_damage sets its result. WITHOUT this the
   * result was set unconditionally in finish_frame, which stalled the clock on any no-redraw-clip
   * frame (input alone doesn't dirty the stage -> no swap -> no COMPLETE -> PENDING_PRESENTED
   * forever). See meta-stage-ios.c finish_frame for the IDLE (no-swap) half. */
  if (user_data)
    clutter_frame_set_result ((ClutterFrame *) user_data,
                              CLUTTER_FRAME_RESULT_PENDING_PRESENTED);
}

MetaOnscreenIOS *
meta_onscreen_ios_new (CoglContext *cogl_context,
                       int          width,
                       int          height)
{
  CoglFramebufferDriverConfig driver_config;

  /* BACK == render to the default framebuffer (FBO 0), as every real onscreen does; here
   * FBO 0 is the IOSurface pbuffer set on this onscreen before allocation. */
  driver_config = (CoglFramebufferDriverConfig) {
    .type = COGL_FRAMEBUFFER_DRIVER_TYPE_BACK,
  };

  return g_object_new (META_TYPE_ONSCREEN_IOS,
                       "context", cogl_context,
                       "driver-config", &driver_config,
                       "width", width,
                       "height", height,
                       NULL);
}

static void
meta_onscreen_ios_init (MetaOnscreenIOS *onscreen_ios)
{
}

static void
meta_onscreen_ios_class_init (MetaOnscreenIOSClass *klass)
{
  CoglFramebufferClass *framebuffer_class = COGL_FRAMEBUFFER_CLASS (klass);
  CoglOnscreenClass *onscreen_class = COGL_ONSCREEN_CLASS (klass);

  /* Render top-left (offscreen convention) since the app samples the IOSurface top-left. */
  framebuffer_class->is_y_flipped = meta_onscreen_ios_is_y_flipped;

  onscreen_class->swap_buffers_with_damage =
    meta_onscreen_ios_swap_buffers_with_damage;
}
