/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-backend-ios.c — the MetaBackend that ties MetaBackendIOS together.
 *
 * Modeled on meta-backend-native.c, minus every hardware seam (KMS/GBM/libinput/logind):
 *   create_clutter_backend -> MetaClutterBackendIOS
 *   create_renderer        -> MetaRendererIOS      (ANGLE-Metal winsys -> output IOSurface)
 *   create_monitor_manager -> MetaMonitorManagerIOS (fed by the MetaGpuIOS added in constructed)
 *   create_default_seat    -> MetaSeatIOS
 *   get_cursor_renderer    -> a software MetaCursorRenderer (no hardware cursor plane on iOS)
 * post_init starts the Xios input pump (meta-input-ios.c), which drives a
 * MetaVirtualInputDeviceIOS on the seat. The keymap/layout/stage/pointer-constraint vfuncs are
 * minimal (fixed "us" layout, single monitor, no constraints) — enough to bring the stage up;
 * the ones marked TODO are device-iteration fills. GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-backend-ios.h"

#include <xkbcommon/xkbcommon.h>

#include "backends/ios/meta-clutter-backend-ios.h"
#include "backends/ios/meta-input-ios.h"
#include "backends/ios/meta-monitor-manager-ios.h"
#include "backends/ios/meta-renderer-ios.h"
#include "backends/ios/meta-seat-ios.h"
#include "backends/meta-backend-private.h"
#include "backends/meta-color-manager.h"
#include "backends/meta-cursor-renderer.h"
#include "backends/meta-gpu.h"
#include "backends/meta-logical-monitor.h"
#include "clutter/clutter.h"

/* Where the Xios app streams its input protocol (overridable for testing). */
#define XIOS_INPUT_SOCKET_DEFAULT "/var/jb/tmp/xios-input.sock"

struct _MetaBackendIOS
{
  MetaBackend parent;

  MetaInputIOS       *input;
  MetaCursorRenderer *cursor_renderer;
};

G_DEFINE_TYPE (MetaBackendIOS, meta_backend_ios, META_TYPE_BACKEND)

static ClutterBackend *
meta_backend_ios_create_clutter_backend (MetaBackend *backend)
{
  return CLUTTER_BACKEND (meta_clutter_backend_ios_new (backend));
}

static ClutterSeat *
meta_backend_ios_create_default_seat (MetaBackend  *backend,
                                      GError      **error)
{
  return meta_seat_ios_new ();
}

static MetaBackendCapabilities
meta_backend_ios_get_capabilities (MetaBackend *backend)
{
  return META_BACKEND_CAPABILITY_NONE;
}

static MetaMonitorManager *
meta_backend_ios_create_monitor_manager (MetaBackend  *backend,
                                         GError      **error)
{
  return g_initable_new (META_TYPE_MONITOR_MANAGER_IOS, NULL, error,
                         "backend", backend,
                         NULL);
}

static MetaColorManager *
meta_backend_ios_create_color_manager (MetaBackend *backend)
{
  return g_object_new (META_TYPE_COLOR_MANAGER,
                       "backend", backend,
                       NULL);
}

static MetaCursorRenderer *
meta_backend_ios_get_cursor_renderer (MetaBackend        *backend,
                                      ClutterInputDevice *device)
{
  MetaBackendIOS *self = META_BACKEND_IOS (backend);

  /* One shared software cursor renderer (Clutter-drawn — iOS has no hardware cursor plane). */
  if (!self->cursor_renderer)
    {
      self->cursor_renderer = g_object_new (META_TYPE_CURSOR_RENDERER,
                                            "backend", backend,
                                            "device", device,
                                            NULL);
    }

  return self->cursor_renderer;
}

static MetaRenderer *
meta_backend_ios_create_renderer (MetaBackend  *backend,
                                  GError      **error)
{
  return meta_renderer_ios_new (backend);
}

static MetaInputSettings *
meta_backend_ios_get_input_settings (MetaBackend *backend)
{
  /* No physical input devices to configure (all input is synthetic). TODO: a stub
   * MetaInputSettings if gsd/mutter turns out to require a non-NULL one at runtime. */
  return NULL;
}

static MetaLogicalMonitor *
meta_backend_ios_get_current_logical_monitor (MetaBackend *backend)
{
  MetaMonitorManager *monitor_manager =
    meta_backend_get_monitor_manager (backend);
  GList *logical_monitors =
    meta_monitor_manager_get_logical_monitors (monitor_manager);

  /* Single fixed output: the current monitor is always the one. */
  return logical_monitors ? logical_monitors->data : NULL;
}

static void
meta_backend_ios_set_keymap (MetaBackend *backend,
                             const char  *layouts,
                             const char  *variants,
                             const char  *options,
                             const char  *model)
{
  /* Fixed "us" layout (iosc_input owns the xkb keymap); layout switching is a no-op. */
}

static struct xkb_keymap *
meta_backend_ios_get_keymap (MetaBackend *backend)
{
  /* TODO: expose iosc_input's compiled "us" xkb_keymap through libxios_glue. NULL until
   * then (the synthetic key path carries keysyms directly via notify_keyval). */
  return NULL;
}

static xkb_layout_index_t
meta_backend_ios_get_keymap_layout_group (MetaBackend *backend)
{
  return 0;
}

static void
meta_backend_ios_lock_layout_group (MetaBackend *backend,
                                    guint        idx)
{
}

static void
meta_backend_ios_update_stage (MetaBackend *backend)
{
  /* TODO: schedule a stage update/present. The renderer presents via
   * meta_renderer_ios_present() (xios_notify_dirty) after paint. */
}

static void
meta_backend_ios_set_pointer_constraint (MetaBackend           *backend,
                                         MetaPointerConstraint *constraint)
{
  /* No pointer constraints for the synthetic pointer. */
}

static gboolean
meta_backend_ios_is_headless (MetaBackend *backend)
{
  return FALSE;
}

static void
meta_backend_ios_post_init (MetaBackend *backend)
{
  MetaBackendIOS *self = META_BACKEND_IOS (backend);
  const char *socket_path;

  META_BACKEND_CLASS (meta_backend_ios_parent_class)->post_init (backend);

  socket_path = g_getenv ("XIOS_INPUT_SOCKET");
  if (!socket_path)
    socket_path = XIOS_INPUT_SOCKET_DEFAULT;

  /* Start pumping the Xios input socket into a MetaVirtualInputDeviceIOS on the seat. */
  self->input = meta_input_ios_new (backend, socket_path);
  if (!self->input)
    g_warning ("MetaBackendIOS: could not start the Xios input pump at %s", socket_path);
}

static void
meta_backend_ios_constructed (GObject *object)
{
  MetaBackend *backend = META_BACKEND (object);
  MetaGpu *gpu;

  G_OBJECT_CLASS (meta_backend_ios_parent_class)->constructed (object);

  /* One synthetic GPU so MetaMonitorManagerIOS has something to read_current from. */
  gpu = g_object_new (META_TYPE_GPU_IOS,
                      "backend", backend,
                      NULL);
  meta_backend_add_gpu (backend, gpu);
}

static void
meta_backend_ios_finalize (GObject *object)
{
  MetaBackendIOS *self = META_BACKEND_IOS (object);

  g_clear_pointer (&self->input, meta_input_ios_free);
  g_clear_object (&self->cursor_renderer);

  G_OBJECT_CLASS (meta_backend_ios_parent_class)->finalize (object);
}

static void
meta_backend_ios_init (MetaBackendIOS *self)
{
}

static void
meta_backend_ios_class_init (MetaBackendIOSClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  MetaBackendClass *backend_class = META_BACKEND_CLASS (klass);

  object_class->constructed = meta_backend_ios_constructed;
  object_class->finalize = meta_backend_ios_finalize;

  backend_class->create_clutter_backend = meta_backend_ios_create_clutter_backend;
  backend_class->create_default_seat = meta_backend_ios_create_default_seat;
  backend_class->post_init = meta_backend_ios_post_init;
  backend_class->get_capabilities = meta_backend_ios_get_capabilities;
  backend_class->create_monitor_manager = meta_backend_ios_create_monitor_manager;
  backend_class->create_color_manager = meta_backend_ios_create_color_manager;
  backend_class->get_cursor_renderer = meta_backend_ios_get_cursor_renderer;
  backend_class->create_renderer = meta_backend_ios_create_renderer;
  backend_class->get_input_settings = meta_backend_ios_get_input_settings;
  backend_class->get_current_logical_monitor = meta_backend_ios_get_current_logical_monitor;
  backend_class->set_keymap = meta_backend_ios_set_keymap;
  backend_class->get_keymap = meta_backend_ios_get_keymap;
  backend_class->get_keymap_layout_group = meta_backend_ios_get_keymap_layout_group;
  backend_class->lock_layout_group = meta_backend_ios_lock_layout_group;
  backend_class->update_stage = meta_backend_ios_update_stage;
  backend_class->set_pointer_constraint = meta_backend_ios_set_pointer_constraint;
  backend_class->is_headless = meta_backend_ios_is_headless;
}

MetaBackend *
meta_backend_ios_new (MetaContext  *context,
                      GError      **error)
{
  return g_initable_new (META_TYPE_BACKEND_IOS, NULL, error,
                         "context", context,
                         NULL);
}
