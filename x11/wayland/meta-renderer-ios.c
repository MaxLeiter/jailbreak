/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-renderer-ios.c — the MetaBackendIOS renderer + its ANGLE-Metal Cogl winsys.
 *
 * The custom Cogl EGL winsys here is the one proven on the A10 by iosc-cogl-smoke.c
 * ("RESULT: COGL-ON-ANGLE OK"): a CoglWinsysEGLVtable platform whose display is
 * eglGetPlatformDisplay(ANGLE, METAL) and which subclasses cogl's EGL base winsys, plugged
 * in with cogl_renderer_set_custom_winsys() — the exact hook mutter's own native renderer
 * uses (meta-renderer-native.c). It is carried inline as a normal backend file (cogl's
 * private winsys types come via cogl/cogl-mutter.h, same as the native renderer — no
 * COGL_COMPILATION needed).
 *
 * create_view renders the stage into the Xios app's output IOSurface. The IOSurface is bound
 * as the DEFAULT framebuffer (FBO 0) of a CoglOnscreen (MetaOnscreenIOS) whose EGLSurface is
 * the ANGLE iosurface pbuffer — route A: ANGLE-Metal has no working IOSurface->EGLImage render
 * target (eglCreateImageKHR(GL_TEXTURE_2D) fails 0x3000) and the cogl fork dropped the
 * foreign-GL-texture wrap, so we render straight into the pbuffer as FBO 0 (proven path)
 * instead of an offscreen. Present is the onscreen's swap (finish + xios_notify_dirty; see
 * meta-onscreen-ios.c). The Cogl winsys config is xios_egl_config() so the display, context,
 * and pbuffer share ONE EGLConfig (else eglMakeCurrent(pbuffer) => EGL_BAD_MATCH). GPL-2.0+,
 * modeled on meta-renderer-native.c.
 */

#include "config.h"

#include "backends/ios/meta-renderer-ios.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include "backends/ios/meta-onscreen-ios.h"
#include "backends/ios/xios-glue-stub.h"
#include "backends/meta-backend-private.h"
#include "backends/meta-crtc.h"
#include "backends/meta-logical-monitor.h"
#include "backends/meta-output.h"
#include "backends/meta-renderer-view.h"
#include "clutter/clutter.h"
#include "cogl/cogl.h"
#include "cogl/cogl-mutter.h"

/* ANGLE platform-display enums (ANGLE headers may predate these names) */
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE            0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE       0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

struct _MetaRendererIOS
{
  MetaRenderer parent;
};

G_DEFINE_TYPE (MetaRendererIOS, meta_renderer_ios, META_TYPE_RENDERER)

/* ---- the iOS Cogl EGL platform vtable (the MetaRendererIOS winsys) ------------------ */

static int
ios_add_config_attributes (CoglDisplay                 *display,
                           const CoglFramebufferConfig *config,
                           EGLint                      *attributes)
{
  int i = 0;

  /* Only set EGL_SURFACE_TYPE here — exactly what the stock platform vtables do. The base
   * cogl_display_egl_determine_attributes appends RGB/ALPHA/DEPTH/BUFFER/RENDERABLE (+ optional
   * STENCIL/SAMPLES) after this into a fixed MAX_EGL_CONFIG_ATTRIBS(=30) array and asserts no
   * overflow, so this MUST stay small: an earlier version added RGBA + RENDERABLE_TYPE +
   * BIND_TO_TEXTURE_RGBA here (14 entries) which overflowed the array once the stage requested a
   * stencil buffer. Those attribs are pointless anyway — ios_choose_config forces
   * xios_egl_config() and IGNORES this array, so config identity does not depend on it. */
  attributes[i++] = EGL_SURFACE_TYPE;
  attributes[i++] = EGL_PBUFFER_BIT;
  return i;
}

static gboolean
ios_choose_config (CoglDisplay *display,
                   EGLint      *attributes,
                   EGLConfig   *out_config,
                   GError     **error)
{
  /* The linchpin of route A: return the SAME EGLConfig xios_egl created its IOSurface
   * pbuffers against. The Cogl display's context is built against this config, and the
   * output onscreen's pbuffer (xios_egl_create_iosurface_pbuffer) uses it too, so
   * eglMakeCurrent(pbuffer, pbuffer, ctx) never hits EGL_BAD_MATCH. We deliberately ignore
   * the attributes cogl derived — config identity beats config search. */
  EGLConfig config = xios_egl_config ();

  if (config == NULL)
    {
      g_set_error (error, COGL_WINSYS_ERROR, COGL_WINSYS_ERROR_CREATE_CONTEXT,
                   "MetaRendererIOS: xios_egl_config() returned no config (0x%x)",
                   eglGetError ());
      return FALSE;
    }
  *out_config = config;
  return TRUE;
}

static gboolean
ios_context_created (CoglDisplay *display, GError **error)
{
  CoglRenderer *renderer = display->renderer;
  CoglRendererEGL *egl_renderer = renderer->winsys;
  CoglDisplayEGL *egl_display = display->winsys;
  const EGLint pb[] = { EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE };

  egl_display->dummy_surface =
    eglCreatePbufferSurface (egl_renderer->edpy, egl_display->egl_config, pb);
  if (egl_display->dummy_surface == EGL_NO_SURFACE)
    {
      g_set_error (error, COGL_WINSYS_ERROR, COGL_WINSYS_ERROR_CREATE_CONTEXT,
                   "MetaRendererIOS: dummy pbuffer failed (0x%x)", eglGetError ());
      return FALSE;
    }
  if (!_cogl_winsys_egl_make_current (display,
                                      egl_display->dummy_surface,
                                      egl_display->dummy_surface,
                                      egl_display->egl_context))
    {
      g_set_error (error, COGL_WINSYS_ERROR, COGL_WINSYS_ERROR_CREATE_CONTEXT,
                   "MetaRendererIOS: eglMakeCurrent on dummy failed (0x%x)", eglGetError ());
      return FALSE;
    }
  return TRUE;
}

static void
ios_cleanup_context (CoglDisplay *display)
{
  CoglRenderer *renderer = display->renderer;
  CoglRendererEGL *egl_renderer = renderer->winsys;
  CoglDisplayEGL *egl_display = display->winsys;

  if (egl_display->dummy_surface != EGL_NO_SURFACE)
    {
      eglDestroySurface (egl_renderer->edpy, egl_display->dummy_surface);
      egl_display->dummy_surface = EGL_NO_SURFACE;
    }
}

static const CoglWinsysEGLVtable _ios_winsys_egl_vtable = {
  .add_config_attributes = ios_add_config_attributes,
  .choose_config         = ios_choose_config,
  .context_created       = ios_context_created,
  .cleanup_context       = ios_cleanup_context,
};

static gboolean
ios_renderer_connect (CoglRenderer *renderer, GError **error)
{
  CoglRendererEGL *egl_renderer;

  renderer->winsys = g_new0 (CoglRendererEGL, 1);
  egl_renderer = renderer->winsys;
  egl_renderer->platform_vtable = &_ios_winsys_egl_vtable;

  egl_renderer->edpy = xios_egl_display ();
  if (egl_renderer->edpy == EGL_NO_DISPLAY)
    {
      g_set_error (error, COGL_WINSYS_ERROR, COGL_WINSYS_ERROR_INIT,
                   "MetaRendererIOS: could not get an ANGLE-Metal EGLDisplay");
      g_free (renderer->winsys);
      renderer->winsys = NULL;
      return FALSE;
    }

  if (!_cogl_winsys_egl_renderer_connect_common (renderer, error))
    {
      g_free (renderer->winsys);
      renderer->winsys = NULL;
      return FALSE;
    }
  return TRUE;
}

static const CoglWinsysVtable *
get_ios_cogl_winsys_vtable (CoglRenderer *renderer)
{
  static gboolean inited = FALSE;
  static CoglWinsysVtable vtable;

  if (!inited)
    {
      vtable = *_cogl_winsys_egl_get_vtable ();
      vtable.id = COGL_WINSYS_ID_CUSTOM;
      vtable.name = "EGL_IOS";
      vtable.renderer_connect = ios_renderer_connect;
      inited = TRUE;
    }
  return &vtable;
}

/* ---- MetaRenderer vfuncs ------------------------------------------------------------ */

static CoglRenderer *
meta_renderer_ios_create_cogl_renderer (MetaRenderer *renderer)
{
  CoglRenderer *cogl_renderer;

  cogl_renderer = cogl_renderer_new ();
  cogl_renderer_set_custom_winsys (cogl_renderer, get_ios_cogl_winsys_vtable, renderer);
  cogl_renderer_set_driver (cogl_renderer, COGL_DRIVER_GLES2);
  return cogl_renderer;
}

/* Bind the Xios output IOSurface as FBO 0 of a CoglOnscreen (route A): wrap it as an ANGLE
 * pbuffer (xios_egl_create_iosurface_pbuffer), set that as the onscreen's EGLSurface, and
 * allocate. Binding the onscreen (eglMakeCurrent(pbuffer, pbuffer, ctx)) then makes the stage
 * render straight into the IOSurface — no EGLImage, no copy. The onscreen's swap presents it
 * (meta-onscreen-ios.c). */
static MetaOnscreenIOS *
create_output_onscreen (CoglContext  *cogl_context,
                        int           width,
                        int           height,
                        GError      **error)
{
  void *iosurface = xios_get_output_iosurface ();
  EGLSurface pbuffer;
  MetaOnscreenIOS *onscreen;

  if (!iosurface)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "no output IOSurface (Xios app not yet attached)");
      return NULL;
    }

  pbuffer = xios_egl_create_iosurface_pbuffer (iosurface, width, height);
  if (pbuffer == EGL_NO_SURFACE)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "failed to wrap the output IOSurface as an ANGLE pbuffer (0x%x)",
                   eglGetError ());
      return NULL;
    }

  onscreen = meta_onscreen_ios_new (cogl_context, width, height);
  /* Inject the pbuffer as the onscreen's EGLSurface BEFORE allocate/bind — the base
   * CoglOnscreenEgl::bind makes it current; there is no window/pbuffer for it to create. */
  cogl_onscreen_egl_set_egl_surface (COGL_ONSCREEN_EGL (onscreen), pbuffer);

  if (!cogl_framebuffer_allocate (COGL_FRAMEBUFFER (onscreen), error))
    {
      g_object_unref (onscreen);
      return NULL;
    }
  return onscreen;
}

static MetaRendererView *
meta_renderer_ios_create_view (MetaRenderer       *renderer,
                               MetaLogicalMonitor *logical_monitor,
                               MetaOutput         *output,
                               MetaCrtc           *crtc)
{
  MetaBackend *backend = meta_renderer_get_backend (renderer);
  ClutterBackend *clutter_backend = meta_backend_get_clutter_backend (backend);
  CoglContext *cogl_context = clutter_backend_get_cogl_context (clutter_backend);
  const MetaCrtcConfig *crtc_config = meta_crtc_get_config (crtc);
  const MetaCrtcModeInfo *mode_info = meta_crtc_mode_get_info (crtc_config->mode);
  int width = mode_info->width;
  int height = mode_info->height;
  g_autoptr (MetaOnscreenIOS) framebuffer = NULL;
  MtkRectangle view_layout;
  float scale;
  GError *error = NULL;

  framebuffer = create_output_onscreen (cogl_context, width, height, &error);
  if (!framebuffer)
    g_error ("MetaRendererIOS: failed to make the output IOSurface renderable: %s",
             error->message);

  if (meta_backend_is_stage_views_scaled (backend))
    scale = meta_logical_monitor_get_scale (logical_monitor);
  else
    scale = 1.0;

  mtk_rectangle_from_graphene_rect (&crtc_config->layout,
                                    MTK_ROUNDING_STRATEGY_ROUND,
                                    &view_layout);

  return g_object_new (META_TYPE_RENDERER_VIEW,
                       "name", meta_output_get_name (output),
                       "stage", meta_backend_get_stage (backend),
                       "layout", &view_layout,
                       "crtc", crtc,
                       "scale", scale,
                       "framebuffer", COGL_FRAMEBUFFER (framebuffer),
                       "transform", META_MONITOR_TRANSFORM_NORMAL,
                       "refresh-rate", mode_info->refresh_rate,
                       NULL);
}

MetaRenderer *
meta_renderer_ios_new (MetaBackend *backend)
{
  return g_object_new (META_TYPE_RENDERER_IOS,
                       "backend", backend,
                       NULL);
}

static void
meta_renderer_ios_init (MetaRendererIOS *renderer_ios)
{
}

static void
meta_renderer_ios_class_init (MetaRendererIOSClass *klass)
{
  MetaRendererClass *renderer_class = META_RENDERER_CLASS (klass);

  renderer_class->create_cogl_renderer = meta_renderer_ios_create_cogl_renderer;
  renderer_class->create_view = meta_renderer_ios_create_view;
}
