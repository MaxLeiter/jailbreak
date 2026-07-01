/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-monitor-manager-ios.h — the MetaBackendIOS monitor manager: one fixed virtual
 * output at the Xios display's native size + iosc's scale. No EDID / XRandR / KMS probe.
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

#define META_TYPE_GPU_IOS (meta_gpu_ios_get_type ())
G_DECLARE_FINAL_TYPE (MetaGpuIOS, meta_gpu_ios, META, GPU_IOS, MetaGpu)
