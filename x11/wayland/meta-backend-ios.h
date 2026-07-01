/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-backend-ios.h — the MetaBackend for iOS/IOSurface (the capstone of MetaBackendIOS).
 *
 * A Wayland-mode MetaBackend, structured like MetaBackendNative but with no KMS/GBM/libinput/
 * logind: it wires together MetaClutterBackendIOS, MetaRendererIOS, MetaMonitorManagerIOS +
 * MetaGpuIOS, MetaSeatIOS, and the Xios input pump. This is what a MetaContext instantiates
 * (compositor type = Wayland) so gnome-shell/Mutter render + composite on ANGLE-Metal into the
 * Xios output IOSurface. GPL-2.0+, modeled on meta-backend-native.c.
 */
#pragma once

#include "backends/meta-backend-private.h"
#include "meta/meta-context.h"

#define META_TYPE_BACKEND_IOS (meta_backend_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaBackendIOS, meta_backend_ios, META, BACKEND_IOS, MetaBackend)

MetaBackend *meta_backend_ios_new (MetaContext  *context,
                                   GError      **error);
