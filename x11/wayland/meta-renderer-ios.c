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
 * create_view renders the stage into the Xios app's output IOSurface, imported zero-copy as
 * a Cogl framebuffer (the same IOSurface->EGLImage->Cogl bridge the IOSurface wl_buffer type
 * uses). present() flushes and nudges the Xios app to re-present — the single-surface
 * equivalent of a CoglOnscreen swap. GPL-2.0+, modeled on meta-renderer-native.c.
 */

#include "config.h"

#include "backends/ios/meta-renderer-ios.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>

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

  attributes[i++] = EGL_SURFACE_TYPE;
  attributes[i++] = EGL_PBUFFER_BIT;
  attributes[i++] = EGL_RED_SIZE;   attributes[i++] = 8;
  attributes[i++] = EGL_GREEN_SIZE; attributes[i++] = 8;
  attributes[i++] = EGL_BLUE_SIZE;  attributes[i++] = 8;
  attributes[i++] = EGL_ALPHA_SIZE; attributes[i++] = 8;
  return i;
}

static gboolean
ios_choose_config (CoglDisplay *display,
                   EGLint      *attributes,
                   EGLConfig   *out_config,
                   GError     **error)
{
  CoglRenderer *renderer = display->renderer;
  CoglRendererEGL *egl_renderer = renderer->winsys;
  EGLint n = 0;

  if (!eglChooseConfig (egl_renderer->edpy, attributes, out_config, 1, &n) || n == 0)
    {
      g_set_error (error, COGL_WINSYS_ERROR, COGL_WINSYS_ERROR_CREATE_CONTEXT,
                   "MetaRendererIOS: no compatible EGL config (0x%x)", eglGetError ());
      return FALSE;
    }
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

/* Bind the Xios output IOSurface as a renderable Cogl framebuffer (zero-copy): reuse the
 * IOSurface->EGLImage->Cogl bridge the IOSurface wl_buffer type uses, then wrap the texture
 * in a CoglOffscreen the stage renders into. */
static CoglOffscreen *
create_output_offscreen (CoglContext  *cogl_context,
                         int           width,
                         int           height,
                         GError      **error)
{
  void *iosurface = xios_get_output_iosurface ();
  EGLImageKHR egl_image;
  g_autoptr (CoglTexture) texture = NULL;
  CoglOffscreen *offscreen;

  if (!iosurface)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "no output IOSurface (Xios app not yet attached)");
      return NULL;
    }

  egl_image = xios_egl_image_from_iosurface (iosurface, width, height);
  if (egl_image == EGL_NO_IMAGE_KHR)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "failed to bridge the output IOSurface to an ANGLE EGLImage");
      return NULL;
    }

  texture = cogl_egl_texture_2d_new_from_image (cogl_context, width, height,
                                                COGL_PIXEL_FORMAT_BGRA_8888_PRE,
                                                egl_image, COGL_EGL_IMAGE_FLAG_NONE,
                                                error);
  xios_egl_destroy_image (egl_image);
  if (!texture)
    return NULL;

  offscreen = cogl_offscreen_new_with_texture (texture);
  if (!cogl_framebuffer_allocate (COGL_FRAMEBUFFER (offscreen), error))
    {
      g_object_unref (offscreen);
      return NULL;
    }
  return offscreen;
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
  g_autoptr (CoglOffscreen) framebuffer = NULL;
  MtkRectangle view_layout;
  float scale;
  GError *error = NULL;

  framebuffer = create_output_offscreen (cogl_context, width, height, &error);
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

void
meta_renderer_ios_present (MetaRendererIOS *renderer_ios)
{
  GList *l;

  for (l = meta_renderer_get_views (META_RENDERER (renderer_ios)); l; l = l->next)
    {
      ClutterStageView *stage_view = l->data;
      CoglFramebuffer *framebuffer =
        clutter_stage_view_get_framebuffer (stage_view);

      if (framebuffer)
        cogl_framebuffer_finish (framebuffer);
    }

  /* Single-surface present: no CoglOnscreen swap — just tell the Xios app the output
   * IOSurface changed so it re-presents it via Metal. */
  xios_notify_dirty ();
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
