/*
 * xios-sensord.m - CoreMotion-backed sensor bridge for the Xios desktop.
 *
 * Low-rate sensors are part of the xios-fhs hardware-bridge family: this daemon
 * owns the iOS CoreMotion API and exposes the Linux desktop shape clients
 * already know:
 *
 *   - net.hadess.SensorProxy on D-Bus (/net/hadess/SensorProxy), compatible
 *     with the small surface GNOME/KDE orientation users normally consume via
 *     iio-sensor-proxy.
 *   - a synthetic IIO sysfs mirror under $XIOS_SYS/bus/iio/devices/iio:device0
 *     for file-based probes and future QtSensors/native backends.
 *
 * It is deliberately separate from xios-hwbridged. Battery/brightness remain
 * in xios-hwbridged; motion/orientation belongs here; camera/mic/location need
 * separate media/location bridges because their permission and streaming models
 * are different.
 */

#include <errno.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

#include <gio/gio.h>
#include <glib/gstdio.h>

#define SENSOR_NAME  "net.hadess.SensorProxy"
#define SENSOR_PATH  "/net/hadess/SensorProxy"
#define SENSOR_IFACE "net.hadess.SensorProxy"

#ifndef DEFAULT_SYS_ROOT
#define DEFAULT_SYS_ROOT "/var/jb/sys"
#endif
#define IIO_DEVICE       "iio:device0"
#define POLL_MS          100

static const char sensor_xml[] =
  "<node>"
  "  <interface name='net.hadess.SensorProxy'>"
  "    <method name='ClaimAccelerometer'/>"
  "    <method name='ReleaseAccelerometer'/>"
  "    <method name='ClaimLight'/>"
  "    <method name='ReleaseLight'/>"
  "    <method name='ClaimProximity'/>"
  "    <method name='ReleaseProximity'/>"
  "    <method name='ClaimCompass'/>"
  "    <method name='ReleaseCompass'/>"
  "    <property name='HasAccelerometer' type='b' access='read'/>"
  "    <property name='AccelerometerOrientation' type='s' access='read'/>"
  "    <property name='HasAmbientLight' type='b' access='read'/>"
  "    <property name='LightLevelUnit' type='s' access='read'/>"
  "    <property name='LightLevel' type='d' access='read'/>"
  "    <property name='HasProximity' type='b' access='read'/>"
  "    <property name='ProximityNear' type='b' access='read'/>"
  "    <property name='HasCompass' type='b' access='read'/>"
  "    <property name='CompassHeading' type='d' access='read'/>"
  "  </interface>"
  "</node>";

static GDBusNodeInfo *sensor_node_info;
static GDBusConnection *bus_conn;

typedef struct {
  double x;
  double y;
  double z;
} MotionVec3;

static id motion_manager;
static gboolean has_accel;
static gboolean has_gyro;
static gboolean has_mag;

static int accel_claims;
static int light_claims;
static int prox_claims;
static int compass_claims;

static char *sys_root;
static char *iio_dir;

static double accel_x, accel_y, accel_z;  /* g */
static double gyro_x, gyro_y, gyro_z;     /* rad/s */
static double mag_x, mag_y, mag_z;        /* microtesla */
static const char *orientation = "undefined";

static void
write_text (const char *path, const char *text)
{
  GError *error = NULL;
  if (!g_file_set_contents (path, text, -1, &error))
    {
      g_warning ("sensord: write %s failed: %s", path, error->message);
      g_clear_error (&error);
    }
}

static void
writef (const char *dir, const char *name, const char *fmt, ...)
{
  va_list ap;
  char *path;
  char *text;

  va_start (ap, fmt);
  text = g_strdup_vprintf (fmt, ap);
  va_end (ap);

  path = g_build_filename (dir, name, NULL);
  write_text (path, text);
  g_free (path);
  g_free (text);
}

static void
ensure_iio_tree (void)
{
  char *trigger;

  g_mkdir_with_parents (iio_dir, 0775);

  writef (iio_dir, "name", "xios-coremotion\n");
  writef (iio_dir, "sampling_frequency", "%u\n", 1000 / POLL_MS);

  writef (iio_dir, "in_accel_scale", "0.00980665\n");
  writef (iio_dir, "in_anglvel_scale", "0.001\n");
  writef (iio_dir, "in_magn_scale", "0.001\n");

  writef (iio_dir, "in_accel_x_raw", "0\n");
  writef (iio_dir, "in_accel_y_raw", "0\n");
  writef (iio_dir, "in_accel_z_raw", "0\n");
  writef (iio_dir, "in_anglvel_x_raw", "0\n");
  writef (iio_dir, "in_anglvel_y_raw", "0\n");
  writef (iio_dir, "in_anglvel_z_raw", "0\n");
  writef (iio_dir, "in_magn_x_raw", "0\n");
  writef (iio_dir, "in_magn_y_raw", "0\n");
  writef (iio_dir, "in_magn_z_raw", "0\n");

  /* iio-sensor-proxy commonly looks for this marker in Linux sysfs. */
  trigger = g_build_filename (sys_root, "bus", "iio", "devices",
                              "trigger0", NULL);
  g_mkdir_with_parents (trigger, 0775);
  writef (trigger, "name", "xios-coremotion-trigger\n");
  g_free (trigger);
}

static const char *
orientation_from_accel (double x, double y, double z)
{
  double ax = fabs (x);
  double ay = fabs (y);

  if (fabs (z) > 0.85 && ax < 0.45 && ay < 0.45)
    return "undefined";

  if (ax > ay)
    return x > 0.0 ? "left-up" : "right-up";

  return y > 0.0 ? "bottom-up" : "normal";
}

static void
emit_property_change_string (const char *name, const char *value)
{
  GVariantBuilder changed;
  GVariantBuilder invalidated;

  if (!bus_conn)
    return;

  g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&changed, "{sv}", name, g_variant_new_string (value));
  g_variant_builder_init (&invalidated, G_VARIANT_TYPE ("as"));

  g_dbus_connection_emit_signal (bus_conn, NULL, SENSOR_PATH,
                                 "org.freedesktop.DBus.Properties",
                                 "PropertiesChanged",
                                 g_variant_new ("(sa{sv}as)", SENSOR_IFACE,
                                                &changed, &invalidated),
                                 NULL);
}

static void
update_iio_values (void)
{
  writef (iio_dir, "in_accel_x_raw", "%d\n", (int) lrint (accel_x * 1000.0));
  writef (iio_dir, "in_accel_y_raw", "%d\n", (int) lrint (accel_y * 1000.0));
  writef (iio_dir, "in_accel_z_raw", "%d\n", (int) lrint (accel_z * 1000.0));

  writef (iio_dir, "in_anglvel_x_raw", "%d\n", (int) lrint (gyro_x * 1000.0));
  writef (iio_dir, "in_anglvel_y_raw", "%d\n", (int) lrint (gyro_y * 1000.0));
  writef (iio_dir, "in_anglvel_z_raw", "%d\n", (int) lrint (gyro_z * 1000.0));

  writef (iio_dir, "in_magn_x_raw", "%d\n", (int) lrint (mag_x * 1000.0));
  writef (iio_dir, "in_magn_y_raw", "%d\n", (int) lrint (mag_y * 1000.0));
  writef (iio_dir, "in_magn_z_raw", "%d\n", (int) lrint (mag_z * 1000.0));
}

static id
objc_call_id (id obj, const char *sel)
{
  return ((id (*)(id, SEL)) objc_msgSend) (obj, sel_registerName (sel));
}

static void
objc_call_void (id obj, const char *sel)
{
  ((void (*)(id, SEL)) objc_msgSend) (obj, sel_registerName (sel));
}

static void
objc_call_void_double (id obj, const char *sel, double value)
{
  ((void (*)(id, SEL, double)) objc_msgSend) (obj, sel_registerName (sel), value);
}

static gboolean
objc_call_bool (id obj, const char *sel)
{
  return ((BOOL (*)(id, SEL)) objc_msgSend) (obj, sel_registerName (sel)) ? TRUE : FALSE;
}

static MotionVec3
objc_call_vec3 (id obj, const char *sel)
{
  return ((MotionVec3 (*)(id, SEL)) objc_msgSend) (obj, sel_registerName (sel));
}

static gboolean
poll_motion (gpointer user_data)
{
  (void) user_data;

  @autoreleasepool {
    if (has_accel)
      {
        id d = objc_call_id (motion_manager, "accelerometerData");
        if (d)
          {
            MotionVec3 v = objc_call_vec3 (d, "acceleration");
            accel_x = v.x;
            accel_y = v.y;
            accel_z = v.z;
          }
      }

    if (has_gyro)
      {
        id d = objc_call_id (motion_manager, "gyroData");
        if (d)
          {
            MotionVec3 v = objc_call_vec3 (d, "rotationRate");
            gyro_x = v.x;
            gyro_y = v.y;
            gyro_z = v.z;
          }
      }

    if (has_mag)
      {
        id d = objc_call_id (motion_manager, "magnetometerData");
        if (d)
          {
            MotionVec3 v = objc_call_vec3 (d, "magneticField");
            mag_x = v.x;
            mag_y = v.y;
            mag_z = v.z;
          }
      }
  }

  if (has_accel)
    {
      const char *next = orientation_from_accel (accel_x, accel_y, accel_z);
      if (strcmp (next, orientation) != 0)
        {
          orientation = next;
          emit_property_change_string ("AccelerometerOrientation", orientation);
        }
    }

  update_iio_values ();
  return G_SOURCE_CONTINUE;
}

static void
start_coremotion (void)
{
  @autoreleasepool {
    Class cls = objc_getClass ("CMMotionManager");
    if (!cls)
      {
        g_warning ("sensord: CMMotionManager class not found");
        return;
      }

    motion_manager = objc_call_id (objc_call_id ((id) cls, "alloc"), "init");
    has_accel = objc_call_bool (motion_manager, "isAccelerometerAvailable");
    has_gyro = objc_call_bool (motion_manager, "isGyroAvailable");
    has_mag = objc_call_bool (motion_manager, "isMagnetometerAvailable");

    if (has_accel)
      {
        objc_call_void_double (motion_manager, "setAccelerometerUpdateInterval:",
                               POLL_MS / 1000.0);
        objc_call_void (motion_manager, "startAccelerometerUpdates");
      }
    if (has_gyro)
      {
        objc_call_void_double (motion_manager, "setGyroUpdateInterval:",
                               POLL_MS / 1000.0);
        objc_call_void (motion_manager, "startGyroUpdates");
      }
    if (has_mag)
      {
        objc_call_void_double (motion_manager, "setMagnetometerUpdateInterval:",
                               POLL_MS / 1000.0);
        objc_call_void (motion_manager, "startMagnetometerUpdates");
      }
  }

  g_message ("sensord: CoreMotion accel=%s gyro=%s magnetometer=%s",
             has_accel ? "yes" : "no",
             has_gyro ? "yes" : "no",
             has_mag ? "yes" : "no");
}

static void
handle_method_call (GDBusConnection       *connection,
                    const char            *sender,
                    const char            *object_path,
                    const char            *interface_name,
                    const char            *method_name,
                    GVariant              *parameters,
                    GDBusMethodInvocation *invocation,
                    void                  *user_data)
{
  (void) connection;
  (void) sender;
  (void) object_path;
  (void) interface_name;
  (void) parameters;
  (void) user_data;

  if (g_str_equal (method_name, "ClaimAccelerometer"))
    accel_claims++;
  else if (g_str_equal (method_name, "ReleaseAccelerometer"))
    accel_claims = MAX (0, accel_claims - 1);
  else if (g_str_equal (method_name, "ClaimLight"))
    light_claims++;
  else if (g_str_equal (method_name, "ReleaseLight"))
    light_claims = MAX (0, light_claims - 1);
  else if (g_str_equal (method_name, "ClaimProximity"))
    prox_claims++;
  else if (g_str_equal (method_name, "ReleaseProximity"))
    prox_claims = MAX (0, prox_claims - 1);
  else if (g_str_equal (method_name, "ClaimCompass"))
    compass_claims++;
  else if (g_str_equal (method_name, "ReleaseCompass"))
    compass_claims = MAX (0, compass_claims - 1);
  else
    {
      g_dbus_method_invocation_return_error (invocation,
                                             G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "Unknown method %s", method_name);
      return;
    }

  g_dbus_method_invocation_return_value (invocation, NULL);
}

static GVariant *
handle_get_property (GDBusConnection  *connection,
                     const char       *sender,
                     const char       *object_path,
                     const char       *interface_name,
                     const char       *property_name,
                     GError          **error,
                     void             *user_data)
{
  (void) connection;
  (void) sender;
  (void) object_path;
  (void) interface_name;
  (void) error;
  (void) user_data;

  if (g_str_equal (property_name, "HasAccelerometer"))
    return g_variant_new_boolean (has_accel);
  if (g_str_equal (property_name, "AccelerometerOrientation"))
    return g_variant_new_string (has_accel ? orientation : "undefined");
  if (g_str_equal (property_name, "HasAmbientLight"))
    return g_variant_new_boolean (FALSE);
  if (g_str_equal (property_name, "LightLevelUnit"))
    return g_variant_new_string ("vendor");
  if (g_str_equal (property_name, "LightLevel"))
    return g_variant_new_double (-1.0);
  if (g_str_equal (property_name, "HasProximity"))
    return g_variant_new_boolean (FALSE);
  if (g_str_equal (property_name, "ProximityNear"))
    return g_variant_new_boolean (FALSE);
  if (g_str_equal (property_name, "HasCompass"))
    return g_variant_new_boolean (FALSE);
  if (g_str_equal (property_name, "CompassHeading"))
    return g_variant_new_double (-1.0);

  return NULL;
}

static const GDBusInterfaceVTable sensor_vtable = {
  .method_call = handle_method_call,
  .get_property = handle_get_property
};

static void
on_bus_acquired (GDBusConnection *connection, const char *name, void *user_data)
{
  GError *error = NULL;
  guint id;

  (void) name;
  (void) user_data;

  bus_conn = connection;
  id = g_dbus_connection_register_object (connection,
                                          SENSOR_PATH,
                                          sensor_node_info->interfaces[0],
                                          &sensor_vtable,
                                          NULL,
                                          NULL,
                                          &error);
  if (id == 0)
    {
      g_warning ("sensord: register %s failed: %s", SENSOR_PATH, error->message);
      g_clear_error (&error);
      return;
    }

  g_message ("sensord: serving %s on %s", SENSOR_NAME, SENSOR_PATH);
}

static void
on_name_lost (GDBusConnection *connection, const char *name, void *user_data)
{
  (void) connection;
  (void) user_data;
  g_warning ("sensord: lost %s (bus gone or another provider won)", name);
}

int
main (int argc, char **argv)
{
  GError *error = NULL;
  GMainLoop *loop;
  const char *env_sys;
  guint owner_id;

  (void) argc;
  (void) argv;

  @autoreleasepool {
    env_sys = getenv ("XIOS_SYS");
    sys_root = g_strdup ((env_sys && *env_sys) ? env_sys : DEFAULT_SYS_ROOT);
    iio_dir = g_build_filename (sys_root, "bus", "iio", "devices",
                                IIO_DEVICE, NULL);

    ensure_iio_tree ();
    start_coremotion ();

    sensor_node_info = g_dbus_node_info_new_for_xml (sensor_xml, &error);
    if (!sensor_node_info)
      {
        g_printerr ("xios-sensord: bad introspection XML: %s\n", error->message);
        g_clear_error (&error);
        return 1;
      }

    owner_id = g_bus_own_name (G_BUS_TYPE_SYSTEM,
                               SENSOR_NAME,
                               G_BUS_NAME_OWNER_FLAGS_ALLOW_REPLACEMENT,
                               on_bus_acquired,
                               NULL,
                               on_name_lost,
                               NULL,
                               NULL);

    g_timeout_add (POLL_MS, poll_motion, NULL);

    loop = g_main_loop_new (NULL, FALSE);
    g_main_loop_run (loop);

    g_bus_unown_name (owner_id);
    g_main_loop_unref (loop);
    g_dbus_node_info_unref (sensor_node_info);
    g_free (iio_dir);
    g_free (sys_root);
  }

  return 0;
}
