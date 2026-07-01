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
#include "cogl/cogl.h"
#include "cogl/cogl-framebuffer-private.h"

struct _MetaOnscreenIOS
{
  CoglOnscreenEgl parent;
};

G_DEFINE_TYPE (MetaOnscreenIOS, meta_onscreen_ios, COGL_TYPE_ONSCREEN_EGL)

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
  CoglOnscreenClass *onscreen_class = COGL_ONSCREEN_CLASS (klass);

  onscreen_class->swap_buffers_with_damage =
    meta_onscreen_ios_swap_buffers_with_damage;
}
