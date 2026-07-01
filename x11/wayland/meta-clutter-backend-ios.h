/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-clutter-backend-ios.h — the ClutterBackend for MetaBackendIOS.
 *
 * A ClutterBackend (the Clutter-side object, distinct from the MetaBackend) that sources its
 * Cogl renderer from MetaRendererIOS, its default seat from MetaBackendIOS (MetaSeatIOS), and
 * its stage from the generic MetaStageImpl. Modeled on MetaClutterBackendNative. GPL-2.0+.
 */
#pragma once

#include "backends/meta-backend-types.h"
#include "clutter/clutter.h"
#include "clutter/clutter-mutter.h"   /* complete ClutterBackendClass (subclassing it) */

#define META_TYPE_CLUTTER_BACKEND_IOS (meta_clutter_backend_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaClutterBackendIOS, meta_clutter_backend_ios,
                      META, CLUTTER_BACKEND_IOS, ClutterBackend)

MetaClutterBackendIOS *meta_clutter_backend_ios_new (MetaBackend *backend);
