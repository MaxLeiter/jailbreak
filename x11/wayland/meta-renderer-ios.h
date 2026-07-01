/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-renderer-ios.h — the MetaBackendIOS renderer.
 *
 * A MetaRenderer whose Cogl renderer uses a custom EGL winsys backed by ANGLE-Metal (the
 * winsys proven on the A10 by iosc-cogl-smoke.c — "RESULT: COGL-ON-ANGLE OK"), and whose
 * single MetaRendererView renders into the Xios app's output IOSurface. This completes
 * Step 2 of docs/mutter-on-iosc.md: Mutter's stage rendering into the display IOSurface,
 * GPU-composited via ANGLE→Metal, presented by the Xios app. GPL-2.0+.
 */
#pragma once

#include "backends/meta-renderer.h"

#define META_TYPE_RENDERER_IOS (meta_renderer_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaRendererIOS, meta_renderer_ios,
                      META, RENDERER_IOS, MetaRenderer)

MetaRenderer *meta_renderer_ios_new (MetaBackend *backend);

/* Flush the stage's view framebuffer and nudge the Xios app to re-present the output
 * IOSurface. Called by the backend after a stage paint (the IOSurface single-surface
 * present, in place of a CoglOnscreen swap). */
void meta_renderer_ios_present (MetaRendererIOS *renderer_ios);
