/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * meta-backend-ios.c — the MetaBackend that ties MetaBackendIOS together.
 *
 * Modeled on meta-backend-native.c, minus every hardware seam (KMS/GBM/libinput/logind):
 *   create_clutter_backend -> MetaClutterBackendIOS
 *   create_renderer        -> MetaRendererIOS      (ANGLE-Metal winsys -> output IOSurface)
 *   create_monitor_manager -> MetaMonitorManagerIOS (fed by the MetaGpuIOS added in constructed)
 *   create_default_seat    -> MetaSeatIOS
 *   get_cursor_renderer    -> a no-paint MetaCursorRenderer; Xios draws the visible cursor
 *                             from CURSOR records in the app overlay
 * post_init starts the Xios input pump (meta-input-ios.c), which drives a
 * MetaVirtualInputDeviceIOS on the seat. get_keymap returns a real compiled "us" xkb_keymap
 * (same idiom as the native backend); layout is single-group, single monitor, no pointer
 * constraints. The stage-update vfunc is still a TODO device-iteration fill. GPL-2.0+.
 */

#include "config.h"

#include "backends/ios/meta-backend-ios.h"

#include <xkbcommon/xkbcommon.h>

#include "backends/ios/meta-clutter-backend-ios.h"
#include "backends/ios/meta-input-ios.h"
#include "backends/ios/meta-monitor-manager-ios.h"
#include "backends/ios/meta-renderer-ios.h"
#include "backends/ios/meta-seat-ios.h"
#include "backends/ios/xios-glue-stub.h"
#include "backends/meta-backend-private.h"
#include "backends/meta-color-manager.h"
#include "backends/meta-cursor-renderer.h"
#include "backends/meta-gpu.h"
#include "backends/meta-keymap-utils.h"
#include "backends/meta-logical-monitor.h"
#include "backends/meta-renderer.h"
#include "clutter/clutter.h"
#include "clutter/clutter-mutter.h"

/* Where the Xios app streams its input protocol (overridable for testing). */
#define XIOS_INPUT_SOCKET_DEFAULT "/var/jb/tmp/mutter-input.sock"

/* The one resolution of the input-socket path. Both the xios.json advertisement
 * (constructed) and the pump bind (post_init) call this — advertise MUST equal bind,
 * even under an env override, or the app's input goes into the void. */
static const char *
ios_input_socket_path (void)
{
  const char *path = g_getenv ("XIOS_INPUT_SOCKET");

  return path ? path : XIOS_INPUT_SOCKET_DEFAULT;
}

struct _MetaBackendIOS
{
  MetaBackend parent;

  MetaInputIOS       *input;
  MetaCursorRenderer *cursor_renderer;

  struct xkb_keymap  *xkb_keymap;      /* the compiled keyboard map get_keymap returns */
  xkb_layout_index_t  layout_index;    /* locked layout group (0 for the single "us" layout) */
};

G_DEFINE_TYPE (MetaBackendIOS, meta_backend_ios, META_TYPE_BACKEND)

typedef struct _MetaCursorRendererIOS
{
  MetaCursorRenderer parent;
} MetaCursorRendererIOS;

typedef struct _MetaCursorRendererIOSClass
{
  MetaCursorRendererClass parent_class;
} MetaCursorRendererIOSClass;

#define META_TYPE_CURSOR_RENDERER_IOS (meta_cursor_renderer_ios_get_type ())
GType meta_cursor_renderer_ios_get_type (void);
G_DEFINE_TYPE (MetaCursorRendererIOS,
               meta_cursor_renderer_ios,
               META_TYPE_CURSOR_RENDERER)

static gboolean
meta_cursor_renderer_ios_update_cursor (MetaCursorRenderer *renderer,
                                        MetaCursorSprite   *cursor_sprite)
{
  (void) renderer;
  (void) cursor_sprite;

  /* Xios draws the cursor as a present-side CALayer overlay from CURSOR records.
   * Keep Mutter's cursor bookkeeping alive, but do not paint a second software
   * cursor into the IOSurface. */
  return FALSE;
}

static void
meta_cursor_renderer_ios_class_init (MetaCursorRendererIOSClass *klass)
{
  MetaCursorRendererClass *cursor_renderer_class =
    META_CURSOR_RENDERER_CLASS (klass);

  cursor_renderer_class->update_cursor = meta_cursor_renderer_ios_update_cursor;
}

static void
meta_cursor_renderer_ios_init (MetaCursorRendererIOS *renderer)
{
  (void) renderer;
}

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
  /* MetaMonitorManager (and our subclass) is NOT a GInitable — g_initable_new() would assert
   * G_TYPE_IS_INITABLE, return NULL, and the caller would crash. Plain g_object_new, exactly
   * like MetaBackendX11Nested's dummy monitor manager; setup runs later via
   * meta_monitor_manager_setup() and the MetaGpuIOS read_current. */
  return g_object_new (META_TYPE_MONITOR_MANAGER_IOS,
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

  /* One shared no-paint cursor renderer. Xios draws the visible cursor from
   * xios_notify_cursor(), so Mutter must not also draw a software cursor into
   * the IOSurface. */
  if (!self->cursor_renderer)
    {
      self->cursor_renderer = g_object_new (META_TYPE_CURSOR_RENDERER_IOS,
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

static struct xkb_keymap *
ios_compile_keymap (const char *layouts,
                    const char *variants,
                    const char *options,
                    const char *model)
{
  struct xkb_rule_names names;
  struct xkb_context *context;
  struct xkb_keymap *keymap;

  names.rules = DEFAULT_XKB_RULES_FILE;
  names.model = model;
  names.layout = layouts;
  names.variant = variants;
  names.options = options;

  context = meta_create_xkb_context ();
  keymap = xkb_keymap_new_from_names (context, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  xkb_context_unref (context);

  return keymap;
}

static void
meta_backend_ios_set_keymap (MetaBackend *backend,
                             const char  *layouts,
                             const char  *variants,
                             const char  *options,
                             const char  *model)
{
  MetaBackendIOS *self = META_BACKEND_IOS (backend);
  struct xkb_keymap *keymap;

  /* The synthetic key path carries keysyms directly (notify_keyval), so no xkb_state is
   * driven from this map — but gnome-shell/Clutter still query it (keybinding labels, IM,
   * layout group). Recompile + publish it, same as the native backend. */
  keymap = ios_compile_keymap (layouts, variants, options, model);
  if (!keymap)
    {
      g_warning ("MetaBackendIOS: could not compile keymap "
                 "(rules=%s model=%s layout=%s variant=%s options=%s) — is xkeyboard-config "
                 "installed?", DEFAULT_XKB_RULES_FILE, model, layouts, variants, options);
      return;
    }

  g_clear_pointer (&self->xkb_keymap, xkb_keymap_unref);
  self->xkb_keymap = keymap;
  self->layout_index = 0;

  meta_backend_notify_keymap_changed (backend);
}

static struct xkb_keymap *
meta_backend_ios_get_keymap (MetaBackend *backend)
{
  MetaBackendIOS *self = META_BACKEND_IOS (backend);

  /* Compiled in constructed; recompile the default "us" map lazily if that failed (e.g.
   * xkeyboard-config data landed after startup). NULL only if the data is truly absent. */
  if (!self->xkb_keymap)
    self->xkb_keymap = ios_compile_keymap ("us", "", "", DEFAULT_XKB_MODEL);

  return self->xkb_keymap;
}

static xkb_layout_index_t
meta_backend_ios_get_keymap_layout_group (MetaBackend *backend)
{
  return META_BACKEND_IOS (backend)->layout_index;
}

static void
meta_backend_ios_lock_layout_group (MetaBackend *backend,
                                    guint        idx)
{
  MetaBackendIOS *self = META_BACKEND_IOS (backend);

  if (self->layout_index == idx)
    return;

  self->layout_index = idx;
  meta_backend_notify_keymap_layout_group_changed (backend, idx);
}

static void
meta_backend_ios_update_stage (MetaBackend *backend)
{
  ClutterActor *stage = meta_backend_get_stage (backend);
  MetaRenderer *renderer = meta_backend_get_renderer (backend);
  MetaMonitorManager *monitor_manager =
    meta_backend_get_monitor_manager (backend);
  int width, height;

  /* Build the per-monitor MetaRendererView — THIS is what invokes MetaRendererIOS::create_view
   * (which imports the output IOSurface as the render target). Native does the same via
   * meta_stage_native_rebuild_views in its update_stage; without it no view exists and nothing
   * paints. update_stage runs in post_init AFTER meta_monitor_manager_setup, so the monitor +
   * the output IOSurface (created in constructed) both exist by now. */
  meta_renderer_rebuild_views (renderer);
  clutter_stage_clear_stage_views (CLUTTER_STAGE (stage));

  /* Size the stage actor to the (single, fixed) screen — without this the stage stays 0x0. */
  meta_monitor_manager_get_screen_size (monitor_manager, &width, &height);
  clutter_actor_set_size (stage, width, height);
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

/* The single MetaBackendIOS instance, so meta_backend_ios_notify_osk_traits() (called
 * from the generic Wayland text-input code) can reach the input socket without threading
 * a backend pointer through every layer. The backend lives for the whole process. */
static MetaBackendIOS *_meta_backend_ios_singleton;

void
meta_backend_ios_notify_osk_traits (guint32  hint,
                                    guint32  purpose,
                                    gboolean enabled)
{
  MetaBackendIOS *self = _meta_backend_ios_singleton;

  if (self && self->input)
    meta_input_ios_send_osk_traits (self->input, hint, purpose, enabled);
}

static void
meta_backend_ios_post_init (MetaBackend *backend)
{
  MetaBackendIOS *self = META_BACKEND_IOS (backend);
  const char *socket_path;

  META_BACKEND_CLASS (meta_backend_ios_parent_class)->post_init (backend);

  socket_path = ios_input_socket_path ();

  /* Start pumping the Xios input socket into a MetaVirtualInputDeviceIOS on the seat. */
  self->input = meta_input_ios_new (backend, socket_path);
  if (!self->input)
    g_warning ("MetaBackendIOS: could not start the Xios input pump at %s", socket_path);

  _meta_backend_ios_singleton = self;   /* enable OSK-traits forwarding (outbound socket) */
}

static void
meta_backend_ios_constructed (GObject *object)
{
  MetaBackend *backend = META_BACKEND (object);
  MetaGpu *gpu;

  G_OBJECT_CLASS (meta_backend_ios_parent_class)->constructed (object);

  /* Create the output IOSurface + start the Xios-app rendezvous BEFORE the renderer imports it
   * (create_view) or the monitor manager reads its geometry. xios_server_start writes
   * /var/jb/tmp/xios.json so the Xios app finds + displays the surface — exactly iosc.c main()'s
   * bring-up. Geometry is the iPad's native 2160x1620 (xios_output_geometry only returns it AFTER
   * creation, so it can't be queried here — MetaMonitorManagerIOS reads it back post-creation). */
  {
    int width = 2160, height = 1620, stride = 0, alloc = 0;

    if (!xios_surface_create (width, height, &stride, &alloc))
      g_warning ("MetaBackendIOS: xios_surface_create failed (IOSurface entitlement?) — "
                 "nothing will be displayable");
    else
      {
        /* Before serving: name the flavor (typed HELLO -> app cursor overlay) and advertise the
         * input socket in xios.json so the app routes keyboard/pointer/scroll here (else it falls
         * to a dead XTEST path — mutter runs no X server). ios_input_socket_path keeps advertise
         * == the pump's bind path in post_init. Must precede xios_server_start (the writer emits
         * "input_socket" at serve time). */
        const char *input_sock = ios_input_socket_path ();

        xios_set_compositor_id ("mutter-ios");
        xios_set_input_socket (input_sock);

        if (xios_server_start ("/var/jb/tmp/mutter-ddx.sock", "/var/jb/tmp/xios.json",
                               width, height, stride) != 0)
          g_warning ("MetaBackendIOS: xios_server_start failed — the Xios app can't find the output");
      }
  }

  /* One synthetic GPU so MetaMonitorManagerIOS has something to read_current from. */
  gpu = g_object_new (META_TYPE_GPU_IOS,
                      "backend", backend,
                      NULL);
  meta_backend_add_gpu (backend, gpu);

  /* Compile the default "us" keyboard map up front (get_keymap has a lazy fallback). */
  META_BACKEND_IOS (object)->xkb_keymap =
    ios_compile_keymap ("us", "", "", DEFAULT_XKB_MODEL);
  if (!META_BACKEND_IOS (object)->xkb_keymap)
    g_warning ("MetaBackendIOS: initial 'us' keymap failed to compile "
               "(xkeyboard-config data missing?)");
}

static void
meta_backend_ios_finalize (GObject *object)
{
  MetaBackendIOS *self = META_BACKEND_IOS (object);

  g_clear_pointer (&self->input, meta_input_ios_free);
  g_clear_object (&self->cursor_renderer);
  g_clear_pointer (&self->xkb_keymap, xkb_keymap_unref);
  xios_server_stop ();

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
