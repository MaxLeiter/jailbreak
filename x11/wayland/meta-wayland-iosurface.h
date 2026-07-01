/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-wayland-iosurface.h — the IOSurface MetaWaylandBuffer type.
 *
 * iOS has no dma-buf, so GPU clients share buffers via IOSurface + a mach-port rendezvous
 * (the iosc_iosurface protocol, iosc-iosurface.xml). This is the mutter-side counterpart to
 * meta-wayland-dma-buf.{c,h}: it serves the iosc_iosurface global, imports the client's
 * IOSurface (libxios_glue), and bridges it to a Cogl texture via an ANGLE EGLImage — the
 * same idiomatic path (cogl_egl_texture_2d_new_from_image) mutter uses for its EGL_IMAGE
 * and DMA_BUF buffer types (docs/mutter-on-iosc.md Option (b), Step 4). GPL-2.0+.
 */
#pragma once

#include <glib-object.h>

#include "meta/meta-multi-texture.h"
#include "wayland/meta-wayland-types.h"

#define META_TYPE_WAYLAND_IOSURFACE_BUFFER (meta_wayland_iosurface_buffer_get_type ())
G_DECLARE_FINAL_TYPE (MetaWaylandIosurfaceBuffer, meta_wayland_iosurface_buffer,
                      META, WAYLAND_IOSURFACE_BUFFER, GObject)

/* Return the IOSurface buffer bound to this wl_buffer (set up by the iosc_iosurface
 * protocol), or NULL if `buffer` is not IOSurface-backed. Mirrors
 * meta_wayland_dma_buf_from_buffer(); used by meta_wayland_buffer_realize(). */
MetaWaylandIosurfaceBuffer *
meta_wayland_iosurface_buffer_from_buffer (MetaWaylandBuffer *buffer);

/* Import the client IOSurface as a Cogl texture (via an ANGLE EGLImage) and hand back a
 * MetaMultiTexture. The IOSurface case of meta_wayland_buffer_attach(). */
gboolean
meta_wayland_iosurface_buffer_attach (MetaWaylandBuffer  *buffer,
                                      MetaMultiTexture  **texture,
                                      GError            **error);

/* Install the iosc_iosurface global — the factory clients use to wrap an IOSurface as a
 * wl_buffer. Call from the compositor bring-up, like meta_wayland_dma_buf_manager_new(). */
void meta_wayland_iosurface_init (MetaWaylandCompositor *compositor);
