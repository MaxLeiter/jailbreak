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
 *
 * Claims gate all the work, as in iio-sensor-proxy. With no claims held there
 * is no poll timer, no CoreMotion update stream and no file write. The first
 * ClaimAccelerometer starts the accelerometer (ClaimCompass the magnetometer)
 * and the last release stops it. Claims are tracked per bus client, and each
 * client's unique name is watched, so a client that exits or crashes without
 * releasing drops its claims instead of keeping the sensors running forever.
 * The gyroscope has no claim type on this interface, so it is never started.
 *
 * While a sensor runs, its IIO value files are rewritten only when the value
 * changes, in place and without fsync (see write_in_place).
 */

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

enum {
  CLAIM_ACCEL,
  CLAIM_LIGHT,
  CLAIM_PROX,
  CLAIM_COMPASS,
  N_CLAIM_KINDS
};

static const struct {
  const char *claim;
  const char *release;
} claim_methods[N_CLAIM_KINDS] = {
  [CLAIM_ACCEL]   = { "ClaimAccelerometer", "ReleaseAccelerometer" },
  [CLAIM_LIGHT]   = { "ClaimLight",         "ReleaseLight" },
  [CLAIM_PROX]    = { "ClaimProximity",     "ReleaseProximity" },
  [CLAIM_COMPASS] = { "ClaimCompass",       "ReleaseCompass" },
};

/* A bus client holding at least one claim, keyed by its unique name. Claims
 * are counted per client, so a client that claims twice must release twice. */
typedef struct {
  guint watch_id;
  int   claims[N_CLAIM_KINDS];
} SensorClient;

static GHashTable *clients;
static int claim_totals[N_CLAIM_KINDS];

/* One IIO value file, plus the value last written to it. */
typedef struct {
  const char *name;
  char       *path;
  int         raw;
  gboolean    valid;   /* raw is what the file holds */
  gboolean    warned;  /* one warning per failure streak, not one per tick */
} IioValue;

static IioValue iio_accel[3] = {
  { .name = "in_accel_x_raw" },
  { .name = "in_accel_y_raw" },
  { .name = "in_accel_z_raw" },
};
static IioValue iio_magn[3] = {
  { .name = "in_magn_x_raw" },
  { .name = "in_magn_y_raw" },
  { .name = "in_magn_z_raw" },
};

/* A CoreMotion update stream that runs only while something claims it. */
typedef struct {
  const char *label;
  const char *interval_sel;
  const char *start_sel;
  const char *stop_sel;
  IioValue   *iio;
  gboolean    running;
} MotionStream;

static MotionStream accel_stream = {
  "accelerometer", "setAccelerometerUpdateInterval:",
  "startAccelerometerUpdates", "stopAccelerometerUpdates", iio_accel, FALSE
};
static MotionStream mag_stream = {
  "magnetometer", "setMagnetometerUpdateInterval:",
  "startMagnetometerUpdates", "stopMagnetometerUpdates", iio_magn, FALSE
};

static guint poll_id;

static char *sys_root;
static char *iio_dir;

static double accel_x, accel_y, accel_z;  /* g */
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

/*
 * Rewrite a per-sample value file in place: pwrite at offset 0, then shrink
 * the file if the old value was longer. No temp file, no rename, no fsync.
 * These files are scratch data mirrored at up to 10 Hz, and g_file_set_contents
 * (temp + write + fsync + rename) forced every sample of every file out to
 * flash.
 *
 * A concurrent reader never sees an empty file (which O_TRUNC would allow).
 * The worst case is the moment between pwrite and ftruncate, when it can see
 * the new value followed by the tail of a longer old one ("12\n34\n").
 * Integer parsers stop at the first newline, so they still read the new value.
 *
 * ensure_iio_tree() recreates every value file at startup, so the files are
 * owned by this process's user and the in-place open has write permission.
 */
static gboolean
write_in_place (const char *path, const char *text)
{
  size_t len = strlen (text);
  struct stat st;
  ssize_t n;
  int saved_errno;
  int fd;

  fd = open (path, O_WRONLY | O_CREAT | O_CLOEXEC, 0666);
  if (fd < 0)
    return FALSE;

  do
    n = pwrite (fd, text, len, 0);
  while (n < 0 && errno == EINTR);

  if (n == (ssize_t) len)
    {
      if (fstat (fd, &st) == 0 && st.st_size > (off_t) len &&
          ftruncate (fd, (off_t) len) != 0)
        n = -1;
    }
  else if (n >= 0)
    {
      errno = EIO;  /* short write */
      n = -1;
    }

  saved_errno = errno;
  close (fd);
  errno = saved_errno;
  return n == (ssize_t) len;
}

static void
iio_value_set (IioValue *v, double value)
{
  int raw = (int) lrint (value * 1000.0);
  char text[32];

  if (v->valid && v->raw == raw)
    return;

  g_snprintf (text, sizeof text, "%d\n", raw);
  if (write_in_place (v->path, text))
    {
      v->raw = raw;
      v->valid = TRUE;
      v->warned = FALSE;
      return;
    }

  v->valid = FALSE;
  if (!v->warned)
    {
      g_warning ("sensord: write %s failed: %s", v->path, g_strerror (errno));
      v->warned = TRUE;
    }
}

static void
iio_values_init (IioValue *values, guint n)
{
  for (guint i = 0; i < n; i++)
    values[i].path = g_build_filename (iio_dir, values[i].name, NULL);
}

static void
iio_values_free (IioValue *values, guint n)
{
  for (guint i = 0; i < n; i++)
    g_clear_pointer (&values[i].path, g_free);
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
  gboolean got_accel = FALSE;
  gboolean got_mag = FALSE;

  (void) user_data;

  @autoreleasepool {
    if (accel_stream.running)
      {
        id d = objc_call_id (motion_manager, "accelerometerData");
        if (d)
          {
            MotionVec3 v = objc_call_vec3 (d, "acceleration");
            accel_x = v.x;
            accel_y = v.y;
            accel_z = v.z;
            got_accel = TRUE;
          }
      }

    if (mag_stream.running)
      {
        id d = objc_call_id (motion_manager, "magnetometerData");
        if (d)
          {
            MotionVec3 v = objc_call_vec3 (d, "magneticField");
            mag_x = v.x;
            mag_y = v.y;
            mag_z = v.z;
            got_mag = TRUE;
          }
      }
  }

  /* Only a real sample moves the orientation. Right after a claim starts the
   * stream, CoreMotion has no data yet, and the old zeros would read as
   * "normal". */
  if (got_accel)
    {
      const char *next = orientation_from_accel (accel_x, accel_y, accel_z);
      if (strcmp (next, orientation) != 0)
        {
          orientation = next;
          emit_property_change_string ("AccelerometerOrientation", orientation);
        }

      iio_value_set (&iio_accel[0], accel_x);
      iio_value_set (&iio_accel[1], accel_y);
      iio_value_set (&iio_accel[2], accel_z);
    }

  if (got_mag)
    {
      iio_value_set (&iio_magn[0], mag_x);
      iio_value_set (&iio_magn[1], mag_y);
      iio_value_set (&iio_magn[2], mag_z);
    }

  return G_SOURCE_CONTINUE;
}

/* Probe what the hardware has. Nothing starts until a client claims it. */
static void
init_coremotion (void)
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
  }

  g_message ("sensord: CoreMotion accel=%s gyro=%s magnetometer=%s",
             has_accel ? "yes" : "no",
             has_gyro ? "yes" : "no",
             has_mag ? "yes" : "no");
}

static void
motion_stream_set_running (MotionStream *s, gboolean run)
{
  if (s->running == run)
    return;

  @autoreleasepool {
    if (run)
      {
        objc_call_void_double (motion_manager, s->interval_sel, POLL_MS / 1000.0);
        objc_call_void (motion_manager, s->start_sel);
      }
    else
      {
        objc_call_void (motion_manager, s->stop_sel);
      }
  }

  s->running = run;

  /* The first sample after a start always lands on disk, even if something
   * else touched the file while the stream was stopped. */
  if (run)
    for (guint i = 0; i < 3; i++)
      s->iio[i].valid = FALSE;

  g_message ("sensord: %s updates %s", s->label, run ? "started" : "stopped");
}

/* Make the running streams and the poll timer match the claims held. */
static void
sync_sensors (void)
{
  gboolean polling;

  motion_stream_set_running (&accel_stream,
                             has_accel && claim_totals[CLAIM_ACCEL] > 0);
  motion_stream_set_running (&mag_stream,
                             has_mag && claim_totals[CLAIM_COMPASS] > 0);

  polling = accel_stream.running || mag_stream.running;
  if (polling && poll_id == 0)
    {
      poll_id = g_timeout_add (POLL_MS, poll_motion, NULL);
    }
  else if (!polling && poll_id != 0)
    {
      g_source_remove (poll_id);
      poll_id = 0;
    }
}

static void
sensor_client_free (gpointer data)
{
  SensorClient *client = data;

  if (client->watch_id != 0)
    g_bus_unwatch_name (client->watch_id);
  g_free (client);
}

/* Forget everything a client claimed. The caller runs sync_sensors(). */
static void
client_drop (const char *name)
{
  SensorClient *client = g_hash_table_lookup (clients, name);

  if (!client)
    return;

  for (int kind = 0; kind < N_CLAIM_KINDS; kind++)
    claim_totals[kind] -= client->claims[kind];
  g_hash_table_remove (clients, name);
}

static void
client_vanished (GDBusConnection *connection, const char *name, gpointer user_data)
{
  (void) connection;
  (void) user_data;

  if (!g_hash_table_contains (clients, name))
    return;

  g_message ("sensord: client %s left the bus, dropping its claims", name);
  client_drop (name);
  sync_sensors ();
}

static void
client_claim (GDBusConnection *connection, const char *sender, int kind)
{
  const char *key = sender ? sender : "";
  SensorClient *client = g_hash_table_lookup (clients, key);

  if (!client)
    {
      client = g_new0 (SensorClient, 1);
      g_hash_table_insert (clients, g_strdup (key), client);
      /* A peer-to-peer connection has no sender to watch. */
      if (sender)
        client->watch_id =
          g_bus_watch_name_on_connection (connection, sender,
                                          G_BUS_NAME_WATCHER_FLAGS_NONE,
                                          NULL, client_vanished, NULL, NULL);
    }

  client->claims[kind]++;
  claim_totals[kind]++;
  sync_sensors ();
}

static void
client_release (const char *sender, int kind)
{
  const char *key = sender ? sender : "";
  SensorClient *client = g_hash_table_lookup (clients, key);
  gboolean holds_any = FALSE;

  /* Releasing a claim this client never made is a no-op, as in
   * iio-sensor-proxy. It must not cancel another client's claim. */
  if (!client || client->claims[kind] == 0)
    return;

  client->claims[kind]--;
  claim_totals[kind]--;

  for (int k = 0; k < N_CLAIM_KINDS; k++)
    holds_any = holds_any || client->claims[k] > 0;
  if (!holds_any)
    g_hash_table_remove (clients, key);

  sync_sensors ();
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
  int kind;

  (void) object_path;
  (void) interface_name;
  (void) parameters;
  (void) user_data;

  for (kind = 0; kind < N_CLAIM_KINDS; kind++)
    {
      if (g_str_equal (method_name, claim_methods[kind].claim))
        {
          client_claim (connection, sender, kind);
          break;
        }
      if (g_str_equal (method_name, claim_methods[kind].release))
        {
          client_release (sender, kind);
          break;
        }
    }

  if (kind == N_CLAIM_KINDS)
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

  /* Clients follow the name to its new owner, or went away with the bus, so
   * nothing will release the claims they made here. Drop them all. */
  if (g_hash_table_size (clients) > 0)
    {
      g_hash_table_remove_all (clients);
      memset (claim_totals, 0, sizeof claim_totals);
      sync_sensors ();
    }
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
    iio_values_init (iio_accel, G_N_ELEMENTS (iio_accel));
    iio_values_init (iio_magn, G_N_ELEMENTS (iio_magn));
    clients = g_hash_table_new_full (g_str_hash, g_str_equal,
                                     g_free, sensor_client_free);

    ensure_iio_tree ();
    init_coremotion ();

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

    /* No poll timer here: sync_sensors() starts one on the first claim. */
    loop = g_main_loop_new (NULL, FALSE);
    g_main_loop_run (loop);

    g_bus_unown_name (owner_id);
    g_main_loop_unref (loop);
    g_dbus_node_info_unref (sensor_node_info);
    g_hash_table_destroy (clients);
    iio_values_free (iio_accel, G_N_ELEMENTS (iio_accel));
    iio_values_free (iio_magn, G_N_ELEMENTS (iio_magn));
    g_free (iio_dir);
    g_free (sys_root);
  }

  return 0;
}
