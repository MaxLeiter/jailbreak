/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-wayland-iosurface.c — IOSurface-backed wl_buffers for MetaBackendIOS.
 *
 * Modeled on src/wayland/meta-wayland-dma-buf.c (GPL-2.0+). A GPU client renders into its
 * own IOSurface, IOSurfaceCreateMachPort()s it, and calls iosc_iosurface.create_buffer with
 * the port name + geometry; the compositor reaches into the client task (libxios_glue) to
 * import the surface and wraps it as a wl_buffer. On attach, the surface is bridged to a
 * Cogl texture via an ANGLE EGLImage and returned as a MetaMultiTexture — exactly the path
 * egl_image_buffer_attach() / the dma-buf attach take, so the IOSurface type composites
 * through the same Cogl/Clutter machinery as every other GPU buffer.
 */

#include "config.h"

#include "backends/ios/meta-wayland-iosurface.h"

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include "backends/ios/xios-glue-stub.h"
/* wayland-scanner emits the protocol header BARE into <builddir>/src/ (reached via -Isrc),
 * like every other mutter wayland file (e.g. meta-wayland-gtk-shell.c includes
 * "gtk-shell-server-protocol.h"). Do NOT prefix it with backends/ios/. */
#include "iosc-iosurface-server-protocol.h"
#include "backends/meta-backend-private.h"
#include "clutter/clutter.h"
#include "cogl/cogl.h"
#include "cogl/cogl-egl.h"
#include "meta/meta-multi-texture.h"
#include "wayland/meta-wayland-buffer.h"
#include "wayland/meta-wayland-private.h"

/* ANGLE GLES core entrypoints. libmutter already links ANGLE's libGLESv2 (see
 * `otool -L libmutter-14.0.dylib`) and already imports glBindTexture, so declare
 * the two we need here rather than pulling <GLES2/gl2.h> into a cogl TU. The GL
 * ABI types are plain ints, matching cogl's own `unsigned int` GL handles. */
#ifndef GL_TEXTURE_2D
#define GL_TEXTURE_2D          0x0DE1
#endif
#ifndef GL_TEXTURE_BINDING_2D
#define GL_TEXTURE_BINDING_2D  0x8069
#endif
extern void glBindTexture (unsigned int target, unsigned int texture);
extern void glGetIntegerv (unsigned int pname, int *params);

enum
{
  IOSC_IOSURFACE_FORMAT_MASK = 0x0000ffffu,
  IOSC_IOSURFACE_KNOWN_FLAGS = IOSC_IOSURFACE_FORMAT_FLAG_TOP_LEFT,
  IOSC_IOSURFACE_SUPPORTED_CAPABILITIES =
    IOSC_IOSURFACE_CAPABILITY_BGRA8888 |
    IOSC_IOSURFACE_CAPABILITY_ORIGIN_FLAGS |
    IOSC_IOSURFACE_CAPABILITY_MACH_PORT_IMPORT,
};

struct _MetaWaylandIosurfaceBuffer
{
  GObject parent;

  void                  *iosurface;   /* opaque IOSurfaceRef (owned) */
  int                    width;
  int                    height;

  MetaMultiTexture      *texture;     /* cached import, reused across attach */
  EGLSurface             pbuffer;     /* ANGLE IOSurface pbuffer aliased into `texture` */
};

G_DEFINE_TYPE (MetaWaylandIosurfaceBuffer, meta_wayland_iosurface_buffer, G_TYPE_OBJECT)

static void
meta_wayland_iosurface_buffer_finalize (GObject *object)
{
  MetaWaylandIosurfaceBuffer *self = META_WAYLAND_IOSURFACE_BUFFER (object);

  g_clear_object (&self->texture);
  if (self->pbuffer != EGL_NO_SURFACE)
    {
      EGLDisplay dpy = xios_egl_display ();
      if (dpy != EGL_NO_DISPLAY)
        {
          eglReleaseTexImage (dpy, self->pbuffer, EGL_BACK_BUFFER);
          eglDestroySurface (dpy, self->pbuffer);
        }
      self->pbuffer = EGL_NO_SURFACE;
    }
  if (self->iosurface)
    {
      xios_release_client_iosurface (self->iosurface);
      self->iosurface = NULL;
    }

  G_OBJECT_CLASS (meta_wayland_iosurface_buffer_parent_class)->finalize (object);
}

static void
meta_wayland_iosurface_buffer_class_init (MetaWaylandIosurfaceBufferClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);

  object_class->finalize = meta_wayland_iosurface_buffer_finalize;
}

static void
meta_wayland_iosurface_buffer_init (MetaWaylandIosurfaceBuffer *self)
{
  self->pbuffer = EGL_NO_SURFACE;
}

/* ---- the wl_buffer wrapping the IOSurface ------------------------------------------- */

static void
buffer_destroy (struct wl_client   *client,
                struct wl_resource *resource)
{
  wl_resource_destroy (resource);
}

static const struct wl_buffer_interface buffer_impl = {
  buffer_destroy,
};

static void
buffer_resource_destroy (struct wl_resource *resource)
{
  MetaWaylandIosurfaceBuffer *self = wl_resource_get_user_data (resource);

  if (self)
    g_object_unref (self);
}

MetaWaylandIosurfaceBuffer *
meta_wayland_iosurface_buffer_from_buffer (MetaWaylandBuffer *buffer)
{
  if (!buffer->resource)
    return NULL;

  if (wl_resource_instance_of (buffer->resource, &wl_buffer_interface, &buffer_impl))
    return wl_resource_get_user_data (buffer->resource);

  return NULL;
}

gboolean
meta_wayland_iosurface_buffer_attach (MetaWaylandBuffer  *buffer,
                                      MetaMultiTexture  **texture,
                                      GError            **error)
{
  MetaWaylandIosurfaceBuffer *self;
  MetaContext *context;
  MetaBackend *backend;
  ClutterBackend *clutter_backend;
  CoglContext *cogl_context;
  CoglTexture *texture_2d;
  EGLDisplay dpy;
  EGLSurface pbuffer;
  unsigned int gl_handle = 0;
  unsigned int gl_target = 0;
  int prev_tex = 0;

  self = meta_wayland_iosurface_buffer_from_buffer (buffer);
  if (!self)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "Not an IOSurface buffer");
      return FALSE;
    }

  if (self->texture)
    {
      /* The IOSurface is shared memory: its GL texture keeps sampling the latest client
       * contents, so the cached MetaMultiTexture is reused (no re-import per commit). */
      g_clear_object (texture);
      *texture = g_object_ref (self->texture);
      buffer->is_y_inverted = FALSE;
      return TRUE;
    }

  context = meta_wayland_compositor_get_context (buffer->compositor);
  backend = meta_context_get_backend (context);
  clutter_backend = meta_backend_get_clutter_backend (backend);
  cogl_context = clutter_backend_get_cogl_context (clutter_backend);

  /* ANGLE-Metal does NOT expose EGL_KHR_gl_texture_2D_image at runtime, so the
   * eglCreateImage(GL_TEXTURE_2D) bridge fails (EGL_BAD_PARAMETER 0x300c) and there
   * is no direct IOSurface->EGLImage. Instead alias the client IOSurface straight
   * into a cogl-owned GL_TEXTURE_2D via an ANGLE IOSurface pbuffer + eglBindTexImage
   * — the exact zero-copy primitive iosc uses (EGL_ANGLE_iosurface_client_buffer).
   * ANGLE presents the BGRA IOSurface as a correctly-ordered RGBA-sampled texture,
   * and, being shared memory, it keeps reflecting the latest client contents, so
   * the cogl texture is created once and reused across commits (cache above). */
  texture_2d = cogl_texture_2d_new_with_size (cogl_context,
                                              self->width, self->height);
  if (!texture_2d)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "iosurface: cogl_texture_2d_new_with_size failed");
      return FALSE;
    }
  cogl_texture_set_components (texture_2d, COGL_TEXTURE_COMPONENTS_RGBA);
  cogl_texture_set_premultiplied (texture_2d, TRUE);

  /* Force GL allocation (glTexImage2D storage) so the GL handle exists to bind onto. */
  if (!cogl_texture_allocate (texture_2d, error))
    {
      g_object_unref (texture_2d);
      return FALSE;
    }
  if (!cogl_texture_get_gl_texture (texture_2d, &gl_handle, &gl_target) ||
      gl_target != GL_TEXTURE_2D)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "iosurface: cogl texture is not a GL_TEXTURE_2D (target 0x%x)",
                   gl_target);
      g_object_unref (texture_2d);
      return FALSE;
    }

  dpy = xios_egl_display ();
  pbuffer = xios_egl_create_iosurface_pbuffer (self->iosurface,
                                               self->width, self->height);
  if (dpy == EGL_NO_DISPLAY || pbuffer == EGL_NO_SURFACE)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "iosurface: could not wrap client IOSurface as an ANGLE pbuffer (0x%x)",
                   eglGetError ());
      g_object_unref (texture_2d);
      return FALSE;
    }

  /* Bind the pbuffer onto cogl's GL texture, restoring the previous GL_TEXTURE_2D
   * binding so cogl's own texture-unit cache stays consistent. */
  glGetIntegerv (GL_TEXTURE_BINDING_2D, &prev_tex);
  glBindTexture (GL_TEXTURE_2D, gl_handle);
  if (!eglBindTexImage (dpy, pbuffer, EGL_BACK_BUFFER))
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "iosurface: eglBindTexImage(client IOSurface) failed (0x%x)",
                   eglGetError ());
      glBindTexture (GL_TEXTURE_2D, (unsigned int) prev_tex);
      eglDestroySurface (dpy, pbuffer);
      g_object_unref (texture_2d);
      return FALSE;
    }
  glBindTexture (GL_TEXTURE_2D, (unsigned int) prev_tex);

  self->pbuffer = pbuffer;                              /* keep alive while sampled */
  self->texture = meta_multi_texture_new_simple (texture_2d);  /* takes the ref */
  buffer->is_y_inverted = FALSE;

  g_clear_object (texture);
  *texture = g_object_ref (self->texture);

  return TRUE;
}

/* ---- the iosc_iosurface global (the client-facing factory) -------------------------- */

static void
iosurface_destroy (struct wl_client   *client,
                   struct wl_resource *resource)
{
  wl_resource_destroy (resource);
}

static void
iosurface_create_buffer (struct wl_client   *client,
                         struct wl_resource *resource,
                         uint32_t            id,
                         uint32_t            mach_port_name,
                         int32_t             width,
                         int32_t             height,
                         uint32_t            format)
{
  MetaWaylandIosurfaceBuffer *self;
  struct wl_resource *buffer_resource;
  pid_t pid = 0;
  int w = width;
  int h = height;
  void *iosurface;
  uint32_t layout = format & IOSC_IOSURFACE_FORMAT_MASK;
  uint32_t flags = format & ~IOSC_IOSURFACE_FORMAT_MASK;

  if (layout != IOSC_IOSURFACE_FORMAT_BGRA8888_GL_ORIGIN ||
      (flags & ~IOSC_IOSURFACE_KNOWN_FLAGS) != 0)
    {
      wl_resource_post_error (resource, IOSC_IOSURFACE_ERROR_UNSUPPORTED_FORMAT,
                              "unsupported IOSurface format/flags 0x%x", format);
      return;
    }

  /* pid comes from the Wayland socket peer credentials, not the client; a client
   * cannot forge which task the compositor reaches into. */
  wl_client_get_credentials (client, &pid, NULL, NULL);
  iosurface = xios_import_client_iosurface ((int) pid, mach_port_name, &w, &h);

  buffer_resource = wl_resource_create (client, &wl_buffer_interface, 1, id);
  if (!buffer_resource)
    {
      wl_client_post_no_memory (client);
      if (iosurface)
        xios_release_client_iosurface (iosurface);
      return;
    }

  if (!iosurface)
    {
      /* Per protocol: create the buffer, then flag the import failure. */
      wl_resource_set_implementation (buffer_resource, &buffer_impl, NULL, NULL);
      wl_resource_post_error (resource, IOSC_IOSURFACE_ERROR_IMPORT_FAILED,
                              "could not import IOSurface from mach port %u",
                              mach_port_name);
      return;
    }

  self = g_object_new (META_TYPE_WAYLAND_IOSURFACE_BUFFER, NULL);
  self->iosurface = iosurface;
  self->width = w;
  self->height = h;

  wl_resource_set_implementation (buffer_resource, &buffer_impl, self,
                                  buffer_resource_destroy);
}

static const struct iosc_iosurface_interface iosurface_impl = {
  iosurface_destroy,
  iosurface_create_buffer,
};

static void
iosurface_bind (struct wl_client *client,
                void             *data,
                uint32_t          version,
                uint32_t          id)
{
  MetaWaylandCompositor *compositor = data;
  struct wl_resource *resource;

  resource = wl_resource_create (client, &iosc_iosurface_interface,
                                 (int) version, id);
  if (!resource)
    {
      wl_client_post_no_memory (client);
      return;
    }

  wl_resource_set_implementation (resource, &iosurface_impl, compositor, NULL);
  if (wl_resource_get_version (resource) >= 2)
    iosc_iosurface_send_capabilities (resource, IOSC_IOSURFACE_SUPPORTED_CAPABILITIES);
}

void
meta_wayland_iosurface_init (MetaWaylandCompositor *compositor)
{
  wl_global_create (compositor->wayland_display, &iosc_iosurface_interface,
                    2, compositor, iosurface_bind);
}
