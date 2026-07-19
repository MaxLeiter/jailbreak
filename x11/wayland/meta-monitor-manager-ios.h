/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-monitor-manager-ios.h — the MetaBackendIOS monitor manager: one resizable virtual
 * output backed by Xios IOSurface geometry + scale. No EDID / XRandR / KMS probe.
 *
 * Modeled on MetaMonitorManagerDummy (src/backends/meta-monitor-manager-dummy.h). Part of
 * the iOS/IOSurface Wayland backend (docs/mutter-on-iosc.md, "Option (b)"). GPL-2.0+, the
 * same license as the mutter file it derives from.
 */
#pragma once

#include "backends/meta-crtc.h"
#include "backends/meta-gpu.h"
#include "backends/meta-monitor-manager-private.h"
#include "backends/meta-output.h"

#define META_TYPE_OUTPUT_IOS (meta_output_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaOutputIOS, meta_output_ios,
                      META, OUTPUT_IOS,
                      MetaOutput)

#define META_TYPE_CRTC_IOS (meta_crtc_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaCrtcIOS, meta_crtc_ios,
                      META, CRTC_IOS,
                      MetaCrtc)

#define META_TYPE_MONITOR_MANAGER_IOS (meta_monitor_manager_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaMonitorManagerIOS, meta_monitor_manager_ios,
                      META, MONITOR_MANAGER_IOS, MetaMonitorManager)

/* XIOS_IN_OUTPUT (device rotation / logical resize): resize the backing IOSurface and
 * record the physical WxH the next read_current() should report.
 * `transform` is the wl_output transform (0/1/2/3); when logical_width/height are <= 0
 * ("derive"), the launch (transform-0) size is swapped on a quarter turn (1 or 3) instead.
 * Returns FALSE without changing state if IOSurface allocation fails. The caller must
 * follow TRUE with meta_monitor_manager_reload() so Mutter rebuilds the renderer view
 * and its ANGLE pbuffer against the replacement surface. */
gboolean meta_monitor_manager_ios_set_output_size (MetaMonitorManagerIOS *manager_ios,
                                                   int                    transform,
                                                   int                    logical_width,
                                                   int                    logical_height);

#define META_TYPE_GPU_IOS (meta_gpu_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaGpuIOS, meta_gpu_ios, META, GPU_IOS, MetaGpu)
