/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */
/*
 * gudev-stub.c — a functional, ABI-correct STUB implementation of libgudev-1.0 for iOS.
 *
 * gnome-control-center (and gnome-bluetooth) hard-require gudev-1.0 to enumerate udev devices.
 * A jailbroken iPad has no udev / sysfs, so a real libgudev is impossible. This stub exports
 * the full libgudev-1.0 public ABI (every symbol in the upstream libgudev-1.0.sym version
 * script) using the REAL upstream public headers, so consumers compile and link unchanged.
 * Behaviourally it is empty: GUdevClient enumerates zero devices, every query returns NULL,
 * and every property/attr getter returns the caller-supplied default. This is correct on iOS:
 * input devices come through the Wayland seat / Mutter, not udev; the panels that link gudev
 * (keyboard/mouse via panels/common/gsd-device-manager.c, and system>about hardware) simply
 * see an empty udev world and fall back to their non-udev paths.
 *
 * The three GObject types (GUdevClient/GUdevDevice/GUdevEnumerator) are real, registered types
 * with the correct class layout (incl. GUdevClient's "uevent" signal), so g_object_new/unref,
 * signal connection, and type checks all work. GPL-2.1+ (matches libgudev).
 */

#define _GUDEV_COMPILATION
#include <gudev/gudev.h>

/* ---- GUdevDeviceType enum GType (normally mkenums-generated) ------------------------------ */
GType
g_udev_device_type_get_type (void)
{
  static gsize id = 0;
  if (g_once_init_enter (&id))
    {
      static const GEnumValue values[] = {
        { G_UDEV_DEVICE_TYPE_NONE,  "G_UDEV_DEVICE_TYPE_NONE",  "none"  },
        { G_UDEV_DEVICE_TYPE_BLOCK, "G_UDEV_DEVICE_TYPE_BLOCK", "block" },
        { G_UDEV_DEVICE_TYPE_CHAR,  "G_UDEV_DEVICE_TYPE_CHAR",  "char"  },
        { 0, NULL, NULL }
      };
      GType t = g_enum_register_static ("GUdevDeviceType", values);
      g_once_init_leave (&id, t);
    }
  return (GType) id;
}

/* ---- GUdevDevice -------------------------------------------------------------------------- */
/* Class + instance structs come from the real headers; only register + implement here. */
G_DEFINE_TYPE (GUdevDevice, g_udev_device, G_TYPE_OBJECT)
static void g_udev_device_init (GUdevDevice *d) { (void) d; }
static void g_udev_device_class_init (GUdevDeviceClass *k) { (void) k; }

/* An empty, immutable strv the *_strv/_keys/_tags getters can return (never NULL-crashes a
 * caller that iterates, and needs no per-call allocation). */
static const gchar *const empty_strv[] = { NULL };

gboolean          g_udev_device_get_is_initialized (GUdevDevice *d) { (void) d; return FALSE; }
guint64           g_udev_device_get_usec_since_initialized (GUdevDevice *d) { (void) d; return 0; }
const gchar      *g_udev_device_get_subsystem (GUdevDevice *d) { (void) d; return NULL; }
const gchar      *g_udev_device_get_devtype (GUdevDevice *d) { (void) d; return NULL; }
const gchar      *g_udev_device_get_name (GUdevDevice *d) { (void) d; return NULL; }
const gchar      *g_udev_device_get_number (GUdevDevice *d) { (void) d; return NULL; }
const gchar      *g_udev_device_get_sysfs_path (GUdevDevice *d) { (void) d; return NULL; }
const gchar      *g_udev_device_get_driver (GUdevDevice *d) { (void) d; return NULL; }
const gchar      *g_udev_device_get_action (GUdevDevice *d) { (void) d; return NULL; }
guint64           g_udev_device_get_seqnum (GUdevDevice *d) { (void) d; return 0; }
GUdevDeviceType   g_udev_device_get_device_type (GUdevDevice *d) { (void) d; return G_UDEV_DEVICE_TYPE_NONE; }
GUdevDeviceNumber g_udev_device_get_device_number (GUdevDevice *d) { (void) d; return 0; }
const gchar      *g_udev_device_get_device_file (GUdevDevice *d) { (void) d; return NULL; }
const gchar *const *g_udev_device_get_device_file_symlinks (GUdevDevice *d) { (void) d; return empty_strv; }
GUdevDevice      *g_udev_device_get_parent (GUdevDevice *d) { (void) d; return NULL; }
GUdevDevice      *g_udev_device_get_parent_with_subsystem (GUdevDevice *d, const gchar *s, const gchar *t)
                    { (void) d; (void) s; (void) t; return NULL; }
gboolean          g_udev_device_has_property (GUdevDevice *d, const gchar *k) { (void) d; (void) k; return FALSE; }
const gchar      *g_udev_device_get_property (GUdevDevice *d, const gchar *k) { (void) d; (void) k; return NULL; }
const gchar *const *g_udev_device_get_property_keys (GUdevDevice *d) { (void) d; return empty_strv; }
gint              g_udev_device_get_property_as_int (GUdevDevice *d, const gchar *k) { (void) d; (void) k; return 0; }
guint64           g_udev_device_get_property_as_uint64 (GUdevDevice *d, const gchar *k) { (void) d; (void) k; return 0; }
gdouble           g_udev_device_get_property_as_double (GUdevDevice *d, const gchar *k) { (void) d; (void) k; return 0.0; }
gboolean          g_udev_device_get_property_as_boolean (GUdevDevice *d, const gchar *k) { (void) d; (void) k; return FALSE; }
const gchar *const *g_udev_device_get_property_as_strv (GUdevDevice *d, const gchar *k) { (void) d; (void) k; return empty_strv; }
gboolean          g_udev_device_has_sysfs_attr (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return FALSE; }
const gchar      *g_udev_device_get_sysfs_attr (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return NULL; }
const gchar *const *g_udev_device_get_sysfs_attr_keys (GUdevDevice *d) { (void) d; return empty_strv; }
gint              g_udev_device_get_sysfs_attr_as_int (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return 0; }
guint64           g_udev_device_get_sysfs_attr_as_uint64 (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return 0; }
gdouble           g_udev_device_get_sysfs_attr_as_double (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return 0.0; }
gboolean          g_udev_device_get_sysfs_attr_as_boolean (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return FALSE; }
const gchar *const *g_udev_device_get_sysfs_attr_as_strv (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return empty_strv; }
gboolean          g_udev_device_has_sysfs_attr_uncached (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return FALSE; }
const gchar      *g_udev_device_get_sysfs_attr_uncached (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return NULL; }
gint              g_udev_device_get_sysfs_attr_as_int_uncached (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return 0; }
guint64           g_udev_device_get_sysfs_attr_as_uint64_uncached (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return 0; }
gdouble           g_udev_device_get_sysfs_attr_as_double_uncached (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return 0.0; }
gboolean          g_udev_device_get_sysfs_attr_as_boolean_uncached (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return FALSE; }
const gchar *const *g_udev_device_get_sysfs_attr_as_strv_uncached (GUdevDevice *d, const gchar *n) { (void) d; (void) n; return empty_strv; }
const gchar *const *g_udev_device_get_tags (GUdevDevice *d) { (void) d; return empty_strv; }
const gchar *const *g_udev_device_get_current_tags (GUdevDevice *d) { (void) d; return empty_strv; }

/* ---- GUdevEnumerator ---------------------------------------------------------------------- */
G_DEFINE_TYPE (GUdevEnumerator, g_udev_enumerator, G_TYPE_OBJECT)
static void g_udev_enumerator_init (GUdevEnumerator *e) { (void) e; }
static void g_udev_enumerator_class_init (GUdevEnumeratorClass *k) { (void) k; }

GUdevEnumerator *g_udev_enumerator_new (GUdevClient *c) { (void) c; return g_object_new (G_UDEV_TYPE_ENUMERATOR, NULL); }
/* All add_match_* return the enumerator for chaining. */
GUdevEnumerator *g_udev_enumerator_add_match_subsystem (GUdevEnumerator *e, const gchar *s) { (void) s; return e; }
GUdevEnumerator *g_udev_enumerator_add_nomatch_subsystem (GUdevEnumerator *e, const gchar *s) { (void) s; return e; }
GUdevEnumerator *g_udev_enumerator_add_match_sysfs_attr (GUdevEnumerator *e, const gchar *n, const gchar *v) { (void) n; (void) v; return e; }
GUdevEnumerator *g_udev_enumerator_add_nomatch_sysfs_attr (GUdevEnumerator *e, const gchar *n, const gchar *v) { (void) n; (void) v; return e; }
GUdevEnumerator *g_udev_enumerator_add_match_property (GUdevEnumerator *e, const gchar *n, const gchar *v) { (void) n; (void) v; return e; }
GUdevEnumerator *g_udev_enumerator_add_match_name (GUdevEnumerator *e, const gchar *n) { (void) n; return e; }
GUdevEnumerator *g_udev_enumerator_add_match_tag (GUdevEnumerator *e, const gchar *t) { (void) t; return e; }
GUdevEnumerator *g_udev_enumerator_add_match_is_initialized (GUdevEnumerator *e) { return e; }
GUdevEnumerator *g_udev_enumerator_add_sysfs_path (GUdevEnumerator *e, const gchar *p) { (void) p; return e; }
GList           *g_udev_enumerator_execute (GUdevEnumerator *e) { (void) e; return NULL; }

/* ---- GUdevClient -------------------------------------------------------------------------- */
enum { UEVENT_SIGNAL, LAST_SIGNAL };
static guint client_signals[LAST_SIGNAL] = { 0 };
G_DEFINE_TYPE (GUdevClient, g_udev_client, G_TYPE_OBJECT)
static void g_udev_client_init (GUdevClient *c) { (void) c; }
static void
g_udev_client_class_init (GUdevClientClass *klass)
{
  /* Register the "uevent" signal so callers can g_signal_connect (it just never fires). */
  client_signals[UEVENT_SIGNAL] =
    g_signal_new ("uevent", G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST,
                  G_STRUCT_OFFSET (GUdevClientClass, uevent), NULL, NULL, NULL,
                  G_TYPE_NONE, 2, G_TYPE_STRING, G_UDEV_TYPE_DEVICE);
}

GUdevClient *g_udev_client_new (const gchar *const *subsystems)
              { (void) subsystems; return g_object_new (G_UDEV_TYPE_CLIENT, NULL); }
GList       *g_udev_client_query_by_subsystem (GUdevClient *c, const gchar *s) { (void) c; (void) s; return NULL; }
GUdevDevice *g_udev_client_query_by_device_number (GUdevClient *c, GUdevDeviceType t, GUdevDeviceNumber n)
              { (void) c; (void) t; (void) n; return NULL; }
GUdevDevice *g_udev_client_query_by_device_file (GUdevClient *c, const gchar *f) { (void) c; (void) f; return NULL; }
GUdevDevice *g_udev_client_query_by_sysfs_path (GUdevClient *c, const gchar *p) { (void) c; (void) p; return NULL; }
GUdevDevice *g_udev_client_query_by_subsystem_and_name (GUdevClient *c, const gchar *s, const gchar *n)
              { (void) c; (void) s; (void) n; return NULL; }
