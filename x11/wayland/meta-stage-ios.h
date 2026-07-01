/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-stage-ios.h — the MetaBackendIOS ClutterStageWindow.
 *
 * The base MetaStageImpl does NOT implement the ClutterStageWindow get_geometry / get_views /
 * prepare_frame / finish_frame / can_clip_redraws vfuncs — every real backend subclasses it
 * (MetaStageNative, MetaStageX11). MetaBackendIOS previously created the base MetaStageImpl
 * directly, so those NULL vfuncs crashed at stage realize. This subclass supplies them,
 * bridged to MetaRendererIOS (its views + the IOSurface present), exactly as MetaStageNative
 * bridges to the native renderer. GPL-2.0+.
 */
#pragma once

#include "backends/meta-stage-impl-private.h"
#include "clutter/clutter-mutter.h"

#define META_TYPE_STAGE_IOS (meta_stage_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaStageIOS, meta_stage_ios, META, STAGE_IOS, MetaStageImpl)
