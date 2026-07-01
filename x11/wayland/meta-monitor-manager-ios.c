/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-monitor-manager-ios.c — the MetaBackendIOS monitor manager.
 *
 * Derived from src/backends/meta-monitor-manager-dummy.c (GPL-2.0+, the same license).
 * Where the dummy synthesizes 1..N env-var-configurable monitors, this exposes exactly
 * ONE fixed output: the Xios app's fullscreen output IOSurface, at its native pixel size
 * (2160x1620 today) and iosc's display scale (2). No EDID, no XRandR, no KMS/DRM probe —
 * the geometry is a constant handed over by libxios_glue (here the xios-glue-stub API).
 *
 * This is the "virtual MonitorManager" of docs/mutter-on-iosc.md Option (b), Step 3. Like
 * the dummy it drives a MetaGpu (read_current), a MetaCrtc (no gamma), and a MetaOutput
 * (carrying the scale). The renderer/present path is MetaRendererIOS (the Cogl winsys,
 * iosc-cogl-smoke.c); input is a ClutterVirtualInputDevice. Only the monitor layer lives
 * here.
 */

#include "config.h"

#include "backends/ios/meta-monitor-manager-ios.h"

#include "backends/ios/xios-glue-stub.h"
#include "backends/meta-backend-private.h"
#include "backends/meta-crtc.h"
#include "backends/meta-monitor.h"
#include "backends/meta-monitor-config-manager.h"
#include "backends/meta-output.h"

struct _MetaMonitorManagerIOS
{
  MetaMonitorManager parent_instance;
};

struct _MetaOutputIOS
{
  MetaOutput parent;

  float scale;
};

struct _MetaCrtcIOS
{
  MetaCrtc parent;
};

struct _MetaGpuIOS
{
  MetaGpu parent;
};

G_DEFINE_TYPE (MetaOutputIOS, meta_output_ios, META_TYPE_OUTPUT)
G_DEFINE_TYPE (MetaCrtcIOS, meta_crtc_ios, META_TYPE_CRTC)
G_DEFINE_TYPE (MetaMonitorManagerIOS, meta_monitor_manager_ios,
               META_TYPE_MONITOR_MANAGER)
G_DEFINE_TYPE (MetaGpuIOS, meta_gpu_ios, META_TYPE_GPU)

static MetaGpu *
get_gpu (MetaMonitorManager *manager)
{
  MetaBackend *backend = meta_monitor_manager_get_backend (manager);

  return META_GPU (meta_backend_get_gpus (backend)->data);
}

static void
append_output (MetaMonitorManager  *manager,
               GList              **modes,
               GList              **crtcs,
               GList              **outputs,
               int                  width,
               int                  height,
               float                scale)
{
  MetaGpu *gpu = get_gpu (manager);
  g_autoptr (MetaCrtcModeInfo) crtc_mode_info = NULL;
  MetaCrtcMode *mode;
  MetaCrtc *crtc;
  MetaOutput *output;
  MetaOutputIOS *output_ios;
  g_autoptr (MetaOutputInfo) output_info = NULL;

  crtc_mode_info = meta_crtc_mode_info_new ();
  crtc_mode_info->width = width;
  crtc_mode_info->height = height;
  crtc_mode_info->refresh_rate = 60.0;
  mode = g_object_new (META_TYPE_CRTC_MODE,
                       "id", (uint64_t) 1,
                       "info", crtc_mode_info,
                       NULL);
  *modes = g_list_append (*modes, mode);

  crtc = g_object_new (META_TYPE_CRTC_IOS,
                       "id", (uint64_t) 1,
                       "backend", meta_gpu_get_backend (gpu),
                       "gpu", gpu,
                       NULL);
  *crtcs = g_list_append (*crtcs, crtc);

  output_info = meta_output_info_new ();
  output_info->name = g_strdup ("iOS-1");
  output_info->vendor = g_strdup ("Xios");
  output_info->product = g_strdup ("iPad Display");
  output_info->serial = g_strdup ("0x105");
  /* iPad 10.2" panel is ~197x148 mm; only used for the default-scale heuristic. */
  output_info->width_mm = 197;
  output_info->height_mm = 148;
  output_info->subpixel_order = COGL_SUBPIXEL_ORDER_UNKNOWN;
  output_info->preferred_mode = mode;
  output_info->n_possible_clones = 0;
  /* Internal panel; DSI is the honest connector type for the iPad display. */
  output_info->connector_type = META_CONNECTOR_TYPE_DSI;

  output_info->modes = g_new0 (MetaCrtcMode *, 1);
  output_info->modes[0] = mode;
  output_info->n_modes = 1;
  output_info->possible_crtcs = g_new0 (MetaCrtc *, 1);
  output_info->possible_crtcs[0] = crtc;
  output_info->n_possible_crtcs = 1;

  output = g_object_new (META_TYPE_OUTPUT_IOS,
                         "id", (uint64_t) 1,
                         "gpu", gpu,
                         "info", output_info,
                         NULL);
  output_ios = META_OUTPUT_IOS (output);
  output_ios->scale = scale;

  *outputs = g_list_append (*outputs, output);
}

static void
meta_monitor_manager_ios_read_current (MetaMonitorManager *manager)
{
  MetaGpu *gpu = get_gpu (manager);
  GList *modes = NULL;
  GList *crtcs = NULL;
  GList *outputs = NULL;
  int width = 2160;
  int height = 1620;
  float scale;

  /* The one fixed output: Xios' fullscreen IOSurface geometry + iosc's scale. */
  xios_output_geometry (&width, &height);
  scale = xios_output_scale ();

  append_output (manager, &modes, &crtcs, &outputs, width, height, scale);

  meta_gpu_take_modes (gpu, modes);
  meta_gpu_take_crtcs (gpu, crtcs);
  meta_gpu_take_outputs (gpu, outputs);
}

static void
meta_monitor_manager_ios_ensure_initial_config (MetaMonitorManager *manager)
{
  MetaMonitorsConfig *config;

  config = meta_monitor_manager_ensure_configured (manager);

  meta_monitor_manager_update_logical_state (manager, config);
}

static void
apply_crtc_assignments (MetaMonitorManager    *manager,
                        MetaCrtcAssignment   **crtcs,
                        unsigned int           n_crtcs,
                        MetaOutputAssignment **outputs,
                        unsigned int           n_outputs)
{
  g_autoptr (GList) to_configure_outputs = NULL;
  g_autoptr (GList) to_configure_crtcs = NULL;
  unsigned i;

  to_configure_outputs = g_list_copy (meta_gpu_get_outputs (get_gpu (manager)));
  to_configure_crtcs = g_list_copy (meta_gpu_get_crtcs (get_gpu (manager)));

  for (i = 0; i < n_crtcs; i++)
    {
      MetaCrtcAssignment *crtc_assignment = crtcs[i];
      MetaCrtc *crtc = crtc_assignment->crtc;

      to_configure_crtcs = g_list_remove (to_configure_crtcs, crtc);

      if (crtc_assignment->mode == NULL)
        {
          meta_crtc_unset_config (crtc);
        }
      else
        {
          MetaCrtcConfig *crtc_config;
          unsigned int j;

          crtc_config = meta_crtc_config_new (&crtc_assignment->layout,
                                              crtc_assignment->mode,
                                              crtc_assignment->transform);
          meta_crtc_set_config (crtc, crtc_config,
                                crtc_assignment->backend_private);

          for (j = 0; j < crtc_assignment->outputs->len; j++)
            {
              MetaOutput *output;
              MetaOutputAssignment *output_assignment;

              output = ((MetaOutput **) crtc_assignment->outputs->pdata)[j];

              to_configure_outputs = g_list_remove (to_configure_outputs,
                                                    output);

              output_assignment = meta_find_output_assignment (outputs,
                                                               n_outputs,
                                                               output);
              meta_output_assign_crtc (output, crtc, output_assignment);
            }
        }
    }

  g_list_foreach (to_configure_crtcs,
                  (GFunc) meta_crtc_unset_config,
                  NULL);
  g_list_foreach (to_configure_outputs,
                  (GFunc) meta_output_unassign_crtc,
                  NULL);
}

static void
update_screen_size (MetaMonitorManager *manager,
                    MetaMonitorsConfig *config)
{
  GList *l;
  int screen_width = 0;
  int screen_height = 0;

  for (l = config->logical_monitor_configs; l; l = l->next)
    {
      MetaLogicalMonitorConfig *logical_monitor_config = l->data;
      int right_edge;
      int bottom_edge;

      right_edge = (logical_monitor_config->layout.width +
                    logical_monitor_config->layout.x);
      if (right_edge > screen_width)
        screen_width = right_edge;

      bottom_edge = (logical_monitor_config->layout.height +
                     logical_monitor_config->layout.y);
      if (bottom_edge > screen_height)
        screen_height = bottom_edge;
    }

  manager->screen_width = screen_width;
  manager->screen_height = screen_height;
}

static gboolean
meta_monitor_manager_ios_apply_monitors_config (MetaMonitorManager      *manager,
                                                MetaMonitorsConfig      *config,
                                                MetaMonitorsConfigMethod method,
                                                GError                 **error)
{
  GPtrArray *crtc_assignments;
  GPtrArray *output_assignments;

  if (!config)
    {
      manager->screen_width = META_MONITOR_MANAGER_MIN_SCREEN_WIDTH;
      manager->screen_height = META_MONITOR_MANAGER_MIN_SCREEN_HEIGHT;

      meta_monitor_manager_rebuild (manager, NULL);
      return TRUE;
    }

  if (!meta_monitor_config_manager_assign (manager, config,
                                           &crtc_assignments,
                                           &output_assignments,
                                           error))
    return FALSE;

  if (method == META_MONITORS_CONFIG_METHOD_VERIFY)
    {
      g_ptr_array_free (crtc_assignments, TRUE);
      g_ptr_array_free (output_assignments, TRUE);
      return TRUE;
    }

  apply_crtc_assignments (manager,
                          (MetaCrtcAssignment **) crtc_assignments->pdata,
                          crtc_assignments->len,
                          (MetaOutputAssignment **) output_assignments->pdata,
                          output_assignments->len);

  g_ptr_array_free (crtc_assignments, TRUE);
  g_ptr_array_free (output_assignments, TRUE);

  update_screen_size (manager, config);
  meta_monitor_manager_rebuild (manager, config);

  return TRUE;
}

static gboolean
meta_monitor_manager_ios_is_transform_handled (MetaMonitorManager  *manager,
                                               MetaCrtc            *crtc,
                                               MetaMonitorTransform transform)
{
  /* The Xios app presents the output IOSurface as-is; we do not rotate a hardware
   * plane. Report the transform as handled so Clutter does not add an offscreen
   * rotation pass (identity is the only transform we hand out). */
  return TRUE;
}

static float
meta_monitor_manager_ios_calculate_monitor_mode_scale (MetaMonitorManager           *manager,
                                                       MetaLogicalMonitorLayoutMode  layout_mode,
                                                       MetaMonitor                  *monitor,
                                                       MetaMonitorMode              *monitor_mode)
{
  MetaOutput *output;
  MetaOutputIOS *output_ios;

  output = meta_monitor_get_main_output (monitor);
  output_ios = META_OUTPUT_IOS (output);

  return output_ios->scale;
}

static float *
meta_monitor_manager_ios_calculate_supported_scales (MetaMonitorManager           *manager,
                                                     MetaLogicalMonitorLayoutMode  layout_mode,
                                                     MetaMonitor                  *monitor,
                                                     MetaMonitorMode              *monitor_mode,
                                                     int                          *n_supported_scales)
{
  MetaMonitorScalesConstraint constraints =
    META_MONITOR_SCALES_CONSTRAINT_NONE;

  switch (layout_mode)
    {
    case META_LOGICAL_MONITOR_LAYOUT_MODE_LOGICAL:
      break;
    case META_LOGICAL_MONITOR_LAYOUT_MODE_PHYSICAL:
      constraints |= META_MONITOR_SCALES_CONSTRAINT_NO_FRAC;
      break;
    }

  return meta_monitor_calculate_supported_scales (monitor, monitor_mode,
                                                  constraints,
                                                  n_supported_scales);
}

static gboolean
is_monitor_framebuffers_scaled (MetaMonitorManager *manager)
{
  MetaBackend *backend = meta_monitor_manager_get_backend (manager);
  MetaSettings *settings = meta_backend_get_settings (backend);

  return meta_settings_is_experimental_feature_enabled (
    settings,
    META_EXPERIMENTAL_FEATURE_SCALE_MONITOR_FRAMEBUFFER);
}

static MetaMonitorManagerCapability
meta_monitor_manager_ios_get_capabilities (MetaMonitorManager *manager)
{
  MetaMonitorManagerCapability capabilities =
    META_MONITOR_MANAGER_CAPABILITY_NONE;

  if (is_monitor_framebuffers_scaled (manager))
    capabilities |= META_MONITOR_MANAGER_CAPABILITY_LAYOUT_MODE;

  return capabilities;
}

static gboolean
meta_monitor_manager_ios_get_max_screen_size (MetaMonitorManager *manager,
                                              int                *max_width,
                                              int                *max_height)
{
  return FALSE;
}

static MetaLogicalMonitorLayoutMode
meta_monitor_manager_ios_get_default_layout_mode (MetaMonitorManager *manager)
{
  if (is_monitor_framebuffers_scaled (manager))
    return META_LOGICAL_MONITOR_LAYOUT_MODE_LOGICAL;
  else
    return META_LOGICAL_MONITOR_LAYOUT_MODE_PHYSICAL;
}

static void
meta_monitor_manager_ios_class_init (MetaMonitorManagerIOSClass *klass)
{
  MetaMonitorManagerClass *manager_class = META_MONITOR_MANAGER_CLASS (klass);

  manager_class->ensure_initial_config = meta_monitor_manager_ios_ensure_initial_config;
  manager_class->apply_monitors_config = meta_monitor_manager_ios_apply_monitors_config;
  manager_class->is_transform_handled = meta_monitor_manager_ios_is_transform_handled;
  manager_class->calculate_monitor_mode_scale = meta_monitor_manager_ios_calculate_monitor_mode_scale;
  manager_class->calculate_supported_scales = meta_monitor_manager_ios_calculate_supported_scales;
  manager_class->get_capabilities = meta_monitor_manager_ios_get_capabilities;
  manager_class->get_max_screen_size = meta_monitor_manager_ios_get_max_screen_size;
  manager_class->get_default_layout_mode = meta_monitor_manager_ios_get_default_layout_mode;
}

static void
meta_monitor_manager_ios_init (MetaMonitorManagerIOS *manager_ios)
{
}

static gboolean
meta_gpu_ios_read_current (MetaGpu  *gpu,
                           GError  **error)
{
  MetaBackend *backend = meta_gpu_get_backend (gpu);
  MetaMonitorManager *manager = meta_backend_get_monitor_manager (backend);

  meta_monitor_manager_ios_read_current (manager);

  return TRUE;
}

static void
meta_gpu_ios_init (MetaGpuIOS *gpu_ios)
{
}

static void
meta_gpu_ios_class_init (MetaGpuIOSClass *klass)
{
  MetaGpuClass *gpu_class = META_GPU_CLASS (klass);

  gpu_class->read_current = meta_gpu_ios_read_current;
}

static void
meta_output_ios_init (MetaOutputIOS *output_ios)
{
  output_ios->scale = 1;
}

static void
meta_output_ios_class_init (MetaOutputIOSClass *klass)
{
}

static size_t
meta_crtc_ios_get_gamma_lut_size (MetaCrtc *crtc)
{
  return 0;
}

static MetaGammaLut *
meta_crtc_ios_get_gamma_lut (MetaCrtc *crtc)
{
  return NULL;
}

static void
meta_crtc_ios_set_gamma_lut (MetaCrtc           *crtc,
                             const MetaGammaLut *lut)
{
  g_warn_if_reached ();
}

static void
meta_crtc_ios_init (MetaCrtcIOS *crtc_ios)
{
}

static void
meta_crtc_ios_class_init (MetaCrtcIOSClass *klass)
{
  MetaCrtcClass *crtc_class = META_CRTC_CLASS (klass);

  crtc_class->get_gamma_lut_size = meta_crtc_ios_get_gamma_lut_size;
  crtc_class->get_gamma_lut = meta_crtc_ios_get_gamma_lut;
  crtc_class->set_gamma_lut = meta_crtc_ios_set_gamma_lut;
}
