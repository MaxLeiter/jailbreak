/*
 * iosc-cogl-smoke.c — Step-0 de-risk: can Cogl init + render on ANGLE-Metal-ES3?
 *
 * This is the make-or-break for MetaBackendIOS (mutter-on-iosc.md): Cogl is a stricter,
 * older GL consumer than GTK4's GSK (which we already proved on this A10/ANGLE/ES3 stack).
 * It must be exercised before any backend code. The winsys here is NOT throwaway — it IS
 * the MetaRendererIOS Cogl winsys, modeled line-for-line on mutter's own native backend
 * (src/backends/native/meta-renderer-native.c) and cogl's cogl-winsys-egl-x11.c: a custom
 * winsys (cogl_renderer_set_custom_winsys, the exact hook the native backend uses) that
 * subclasses cogl's EGL base winsys and supplies an ANGLE-Metal EGLDisplay + a small
 * platform vtable.
 *
 * MUST build INSIDE the mutter source tree: it needs cogl's PRIVATE winsys headers
 * (cogl-winsys-egl-private.h, cogl-winsys-private.h), which are not in libmutter-14-dev.
 * So this folds into the on-device mutter window alongside the typelib generation.
 *
 * The ANGLE/IOSurface primitives are LOCAL STUBS here (xios_egl_* — the planned
 * libxios_glue API, see docs/iosc-shared-glue.md). In MetaRendererIOS they come from
 * libxios_glue (the split-out job-1 of iosc_gl.c). This test renders a CoglPipeline quad
 * into a plain CoglTexture2D offscreen and reads it back — isolating the headline risk
 * (Cogl init / feature detection / GLSL / FBO on ANGLE-Metal-ES3). The IOSurface-as-output
 * path is separately M4-proven (iosc-fbtest) and is the winsys *onscreen* step that comes
 * after this gate is green.
 *
 *   PASS: "RESULT: COGL-ON-ANGLE OK" + a red-ish center pixel.
 *   FAIL: a cogl_*_new error message pinpoints where ANGLE/Cogl disagree (the wall).
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

/* Built "internally" (-DCOGL_COMPILATION) because the winsys types are private — so include
 * the specific cogl headers (the umbrella <cogl/cogl.h> refuses COGL_COMPILATION), mirroring
 * cogl's own winsys .c files. config.h must come first (it sets HAVE_X11 etc. that the
 * CoglWinsysVtable struct layout depends on — must match the linked libcogl). */
#include "config.h"
#include "cogl/cogl-renderer.h"
#include "cogl/cogl-display.h"
#include "cogl/cogl-context.h"
#include "cogl/cogl-framebuffer.h"
#include "cogl/cogl-offscreen.h"
#include "cogl/cogl-texture-2d.h"
#include "cogl/cogl-pipeline.h"
#include "cogl/cogl-color.h"
#include "cogl/cogl-mutter.h"                     /* cogl_renderer_set_custom_winsys */
#include "cogl/cogl-egl.h"
#include "cogl/winsys/cogl-winsys-private.h"      /* CoglWinsysVtable, COGL_WINSYS_ERROR */
#include "cogl/winsys/cogl-winsys-egl-private.h"  /* CoglRendererEGL/CoglDisplayEGL, base vtable */

#include <stdio.h>
#include <stdint.h>

/* ANGLE platform-display enums (ANGLE headers may predate these names) */
#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE            0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE       0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

/* ---- xios_egl stub (the planned libxios_glue job-1 API) ----------------------------- */
/* In MetaRendererIOS this is libxios_glue's xios_egl_get_display(); here it is the same
 * ANGLE-Metal display setup as iosc_gl.c's proven path. */
static EGLDisplay
xios_egl_get_display (void)
{
  PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
    (void *) eglGetProcAddress ("eglGetPlatformDisplayEXT");
  if (!get_platform_display)
    return EGL_NO_DISPLAY;
  const EGLint da[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE,
                        EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
  return get_platform_display (EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, da);
}

/* ---- the iOS Cogl EGL platform vtable (CoglWinsysEGLVtable) -------------------------- */

static int
ios_add_config_attributes (CoglDisplay                 *display,
                           const CoglFramebufferConfig *config,
                           EGLint                      *attributes)
{
  int i = 0;
  /* Offscreen-only for the smoke test: a pbuffer-capable config is all we need (the dummy
   * surface is a pbuffer). MetaRendererIOS will add EGL_BIND_TO_TEXTURE_RGBA for the
   * IOSurface onscreen. */
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
                   "iosc-cogl: no compatible EGL config (0x%x)", eglGetError ());
      return FALSE;
    }
  return TRUE;
}

/* Create the dummy pbuffer so the context can be made current without an onscreen, then
 * make it current. (The base try_create_context calls this after eglCreateContext.) */
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
                   "iosc-cogl: dummy pbuffer failed (0x%x)", eglGetError ());
      return FALSE;
    }
  if (!_cogl_winsys_egl_make_current (display,
                                      egl_display->dummy_surface,
                                      egl_display->dummy_surface,
                                      egl_display->egl_context))
    {
      g_set_error (error, COGL_WINSYS_ERROR, COGL_WINSYS_ERROR_CREATE_CONTEXT,
                   "iosc-cogl: eglMakeCurrent on dummy failed (0x%x)", eglGetError ());
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

/* ---- the custom CoglWinsysVtable (subclasses cogl's EGL base, like meta-renderer-native) */

static gboolean
ios_renderer_connect (CoglRenderer *renderer, GError **error)
{
  CoglRendererEGL *egl_renderer;

  renderer->winsys = g_new0 (CoglRendererEGL, 1);
  egl_renderer = renderer->winsys;
  egl_renderer->platform_vtable = &_ios_winsys_egl_vtable;

  egl_renderer->edpy = xios_egl_get_display ();
  if (egl_renderer->edpy == EGL_NO_DISPLAY)
    {
      g_set_error (error, COGL_WINSYS_ERROR, COGL_WINSYS_ERROR_INIT,
                   "iosc-cogl: could not get an ANGLE-Metal EGLDisplay");
      g_free (renderer->winsys);
      renderer->winsys = NULL;
      return FALSE;
    }

  /* The base does eglInitialize + extension/feature probing + dummy-context teardown. */
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
      /* Subclass cogl's EGL winsys: copy its vtable, override only the platform-specific
       * connect (renderer_disconnect from the base already frees renderer->winsys). */
      vtable = *_cogl_winsys_egl_get_vtable ();
      vtable.id = COGL_WINSYS_ID_CUSTOM;
      vtable.name = "EGL_IOS";
      vtable.renderer_connect = ios_renderer_connect;
      inited = TRUE;
    }
  return &vtable;
}

/* ---- the test ----------------------------------------------------------------------- */

int
main (void)
{
  GError *error = NULL;

  CoglRenderer *renderer = cogl_renderer_new ();
  cogl_renderer_set_custom_winsys (renderer, get_ios_cogl_winsys_vtable, NULL);
  cogl_renderer_set_driver (renderer, COGL_DRIVER_GLES2);   /* force the GLES driver */

  if (!cogl_renderer_connect (renderer, &error))
    { fprintf (stderr, "FAIL cogl_renderer_connect: %s\n", error->message); return 1; }
  fprintf (stderr, "ok: renderer connected (ANGLE-Metal EGLDisplay)\n");

  CoglDisplay *display = cogl_display_new (renderer, NULL);
  if (!cogl_display_setup (display, &error))
    { fprintf (stderr, "FAIL cogl_display_setup: %s\n", error->message); return 1; }

  CoglContext *ctx = cogl_context_new (display, &error);
  if (!ctx)
    { fprintf (stderr, "FAIL cogl_context_new (feature/GLSL detection): %s\n", error->message); return 1; }
  fprintf (stderr, "ok: CoglContext created on ANGLE-Metal-ES3\n");

  /* Render: red quad over a green clear into a 256x256 RGBA offscreen. */
  CoglTexture *tex = cogl_texture_2d_new_with_size (ctx, 256, 256);
  CoglOffscreen *off = cogl_offscreen_new_with_texture (tex);
  CoglFramebuffer *fb = COGL_FRAMEBUFFER (off);
  if (!cogl_framebuffer_allocate (fb, &error))
    { fprintf (stderr, "FAIL cogl_framebuffer_allocate (FBO over CoglTexture2D): %s\n", error->message); return 1; }
  fprintf (stderr, "ok: offscreen FBO allocated\n");

  cogl_framebuffer_clear4f (fb, COGL_BUFFER_BIT_COLOR, 0.f, 1.f, 0.f, 1.f);   /* green */

  CoglPipeline *pipe = cogl_pipeline_new (ctx);
  CoglColor red;
  cogl_color_init_from_4f (&red, 1.f, 0.f, 0.f, 1.f);                         /* red */
  cogl_pipeline_set_color (pipe, &red);
  cogl_framebuffer_draw_rectangle (fb, pipe, -0.5f, -0.5f, 0.5f, 0.5f);       /* exercises GLSL */
  cogl_framebuffer_finish (fb);

  uint8_t px[4] = { 0, 0, 0, 0 };
  cogl_framebuffer_read_pixels (fb, 128, 128, 1, 1,
                                COGL_PIXEL_FORMAT_RGBA_8888, px);
  fprintf (stderr, "center pixel RGBA=%02x%02x%02x%02x\n", px[0], px[1], px[2], px[3]);

  if (px[0] > 0x80 && px[1] < 0x40)
    { printf ("RESULT: COGL-ON-ANGLE OK (init + GLSL draw + FBO readback all work)\n"); return 0; }
  printf ("RESULT: rendered but center not red — investigate swizzle/draw\n");
  return 0;
}
