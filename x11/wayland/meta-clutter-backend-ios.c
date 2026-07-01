/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-clutter-backend-ios.c — the ClutterBackend for MetaBackendIOS.
 *
 * A near-copy of meta-clutter-backend-native.c: get_renderer from MetaRendererIOS,
 * get_default_seat from the MetaBackend (MetaSeatIOS), and create_stage from the generic
 * MetaStageImpl (no native/KMS stage needed — the renderer already targets the output
 * IOSurface). is_display_server is TRUE (we are a Wayland compositor). GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-clutter-backend-ios.h"

#include <glib-object.h>

#include "backends/meta-backend-private.h"
#include "backends/meta-renderer.h"
#include "backends/meta-stage-impl-private.h"
#include "clutter/clutter.h"
#include "meta/meta-backend.h"

struct _MetaClutterBackendIOS
{
  ClutterBackend parent;

  MetaBackend *backend;
};

G_DEFINE_TYPE (MetaClutterBackendIOS, meta_clutter_backend_ios,
               CLUTTER_TYPE_BACKEND)

static CoglRenderer *
meta_clutter_backend_ios_get_renderer (ClutterBackend  *clutter_backend,
                                       GError         **error)
{
  MetaClutterBackendIOS *self = META_CLUTTER_BACKEND_IOS (clutter_backend);
  MetaRenderer *renderer = meta_backend_get_renderer (self->backend);

  return meta_renderer_create_cogl_renderer (renderer);
}

static ClutterStageWindow *
meta_clutter_backend_ios_create_stage (ClutterBackend  *clutter_backend,
                                       ClutterStage    *wrapper,
                                       GError         **error)
{
  MetaClutterBackendIOS *self = META_CLUTTER_BACKEND_IOS (clutter_backend);

  return g_object_new (META_TYPE_STAGE_IMPL,
                       "backend", self->backend,
                       "wrapper", wrapper,
                       NULL);
}

static ClutterSeat *
meta_clutter_backend_ios_get_default_seat (ClutterBackend *clutter_backend)
{
  MetaClutterBackendIOS *self = META_CLUTTER_BACKEND_IOS (clutter_backend);

  return meta_backend_get_default_seat (self->backend);
}

static gboolean
meta_clutter_backend_ios_is_display_server (ClutterBackend *clutter_backend)
{
  return TRUE;
}

static void
meta_clutter_backend_ios_init (MetaClutterBackendIOS *self)
{
}

static void
meta_clutter_backend_ios_class_init (MetaClutterBackendIOSClass *klass)
{
  ClutterBackendClass *clutter_backend_class = CLUTTER_BACKEND_CLASS (klass);

  clutter_backend_class->get_renderer = meta_clutter_backend_ios_get_renderer;
  clutter_backend_class->create_stage = meta_clutter_backend_ios_create_stage;
  clutter_backend_class->get_default_seat = meta_clutter_backend_ios_get_default_seat;
  clutter_backend_class->is_display_server = meta_clutter_backend_ios_is_display_server;
}

MetaClutterBackendIOS *
meta_clutter_backend_ios_new (MetaBackend *backend)
{
  MetaClutterBackendIOS *self;

  self = g_object_new (META_TYPE_CLUTTER_BACKEND_IOS, NULL);
  self->backend = backend;

  return self;
}
