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
#include "backends/ios/iosc-iosurface-server-protocol.h"
#include "backends/meta-backend-private.h"
#include "clutter/clutter.h"
#include "cogl/cogl-egl.h"
#include "meta/meta-multi-texture.h"
#include "wayland/meta-wayland-buffer.h"
#include "wayland/meta-wayland-private.h"

struct _MetaWaylandIosurfaceBuffer
{
  GObject parent;

  MetaWaylandCompositor *compositor;
  void                  *iosurface;   /* opaque IOSurfaceRef (owned) */
  int                    width;
  int                    height;

  MetaMultiTexture      *texture;     /* cached import, reused across attach */
};

G_DEFINE_TYPE (MetaWaylandIosurfaceBuffer, meta_wayland_iosurface_buffer, G_TYPE_OBJECT)

static void
meta_wayland_iosurface_buffer_finalize (GObject *object)
{
  MetaWaylandIosurfaceBuffer *self = META_WAYLAND_IOSURFACE_BUFFER (object);

  g_clear_object (&self->texture);
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
  EGLImageKHR egl_image;
  CoglTexture *texture_2d;

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

  egl_image = xios_egl_image_from_iosurface (self->iosurface,
                                             self->width, self->height);
  if (egl_image == EGL_NO_IMAGE_KHR)
    {
      g_set_error (error, G_IO_ERROR, G_IO_ERROR_FAILED,
                   "Failed to bridge IOSurface to an ANGLE EGLImage");
      return FALSE;
    }

  /* BGRA8 premultiplied, matching the IOSurface Xios/ANGLE clients render into. */
  texture_2d = cogl_egl_texture_2d_new_from_image (cogl_context,
                                                   self->width, self->height,
                                                   COGL_PIXEL_FORMAT_BGRA_8888_PRE,
                                                   egl_image,
                                                   COGL_EGL_IMAGE_FLAG_NONE,
                                                   error);
  /* cogl has bound the image into a GL texture; the EGLImage is no longer needed
   * (mirrors egl_image_buffer_attach, which destroys it immediately after). */
  xios_egl_destroy_image (egl_image);

  if (!texture_2d)
    return FALSE;

  self->texture = meta_multi_texture_new_simple (texture_2d);
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
  MetaWaylandCompositor *compositor = wl_resource_get_user_data (resource);
  MetaWaylandIosurfaceBuffer *self;
  struct wl_resource *buffer_resource;
  pid_t pid = 0;
  int w = width;
  int h = height;
  void *iosurface;

  /* pid comes from the Wayland socket peer credentials, not the client (a client cannot
   * forge which task the compositor reaches into). format is advisory (0 = BGRA8). */
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
  self->compositor = compositor;
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
}

void
meta_wayland_iosurface_init (MetaWaylandCompositor *compositor)
{
  wl_global_create (compositor->wayland_display, &iosc_iosurface_interface,
                    1, compositor, iosurface_bind);
}
