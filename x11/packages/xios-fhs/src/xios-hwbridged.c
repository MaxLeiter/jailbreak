/*
 * xios-hwbridged.c — the Xios hardware bridge daemon (package xios-fhs).
 *
 * One small session daemon that owns the iOS hardware APIs the Linux desktop stack has no
 * access to, and presents them the way that stack expects (docs/xios-fhs-plan.md):
 *
 *   battery    org.freedesktop.UPower on the bus (gnome-shell's UpClient binds the
 *              DisplayDevice; gsd-power reads WarningLevel) backed by IOKit
 *              IOPSCopyPowerSourcesInfo, plus an informational mirror under
 *              $XIOS_SYS/class/power_supply/{BAT0,AC0}.
 *   brightness a synthetic $XIOS_SYS/class/backlight/xios_backlight/ tree. Anything may
 *              write `brightness` (0..1000); we watch the directory and apply the value
 *              through BackBoardServices. A timer syncs `actual_brightness` (and the
 *              slider) when Control Center changes it behind our back.
 *
 * IOKit and BackBoardServices are resolved with dlopen/dlsym so the cross build needs no
 * private tbds or headers. Like the session stubs (wayland/xios-login1-stub.c) we own the
 * name on the "system" bus, which the Xios session points at the session bus via
 * DBUS_SYSTEM_BUS_ADDRESS; XIOS_HWBRIDGE_BUS=session forces the session bus for bring-up.
 */

#include <gio/gio.h>
#include <glib-unix.h>

#include <dlfcn.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <CoreFoundation/CoreFoundation.h>

#define UPOWER_NAME       "org.freedesktop.UPower"
#define UPOWER_PATH       "/org/freedesktop/UPower"
#define DISPLAY_DEV_PATH  UPOWER_PATH "/devices/DisplayDevice"
#define BATTERY_DEV_PATH  UPOWER_PATH "/devices/battery_BAT0"
#define AC_DEV_PATH       UPOWER_PATH "/devices/line_power_AC0"
#define DEVICE_IFACE      "org.freedesktop.UPower.Device"

#define DEFAULT_SYS_ROOT  "/var/jb/sys"
#define MAX_BRIGHTNESS    1000

/* UpDeviceState */
#define STATE_UNKNOWN         0
#define STATE_CHARGING        1
#define STATE_DISCHARGING     2
#define STATE_FULLY_CHARGED   4
#define STATE_PENDING_CHARGE  5
/* UpDeviceKind */
#define KIND_LINE_POWER       1
#define KIND_BATTERY          2
/* UpDeviceLevel (WarningLevel / BatteryLevel) */
#define LEVEL_NONE            1
#define LEVEL_LOW             3
#define LEVEL_CRITICAL        4
/* upower's default percentage policy thresholds */
#define PCT_LOW               20.0
#define PCT_CRITICAL          5.0

/* ---- iOS API plumbing (dlopen, no SDK headers) --------------------------------------- */

typedef CFTypeRef       (*IOPSCopyPowerSourcesInfoFn) (void);
typedef CFArrayRef      (*IOPSCopyPowerSourcesListFn) (CFTypeRef);
typedef CFDictionaryRef (*IOPSGetPowerSourceDescriptionFn) (CFTypeRef, CFTypeRef);

typedef float     (*BKSDisplayBrightnessGetCurrentFn) (void);
typedef void      (*BKSDisplayBrightnessSetFn) (float, int);
typedef CFTypeRef (*BKSDisplayBrightnessTransactionCreateFn) (CFAllocatorRef);

static IOPSCopyPowerSourcesInfoFn        iops_copy_info;
static IOPSCopyPowerSourcesListFn        iops_copy_list;
static IOPSGetPowerSourceDescriptionFn   iops_get_desc;

static BKSDisplayBrightnessGetCurrentFn        bks_get;
static BKSDisplayBrightnessSetFn               bks_set;
static BKSDisplayBrightnessTransactionCreateFn bks_txn_create;

static gboolean
load_iokit (void)
{
  void *h = dlopen ("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
  if (!h)
    {
      g_warning ("hwbridge: dlopen IOKit failed: %s", dlerror ());
      return FALSE;
    }
  iops_copy_info = (IOPSCopyPowerSourcesInfoFn) dlsym (h, "IOPSCopyPowerSourcesInfo");
  iops_copy_list = (IOPSCopyPowerSourcesListFn) dlsym (h, "IOPSCopyPowerSourcesList");
  iops_get_desc  = (IOPSGetPowerSourceDescriptionFn) dlsym (h, "IOPSGetPowerSourceDescription");
  if (!iops_copy_info || !iops_copy_list || !iops_get_desc)
    {
      g_warning ("hwbridge: IOPS symbols missing from IOKit");
      return FALSE;
    }
  return TRUE;
}

static gboolean
load_backboard (void)
{
  void *h = dlopen ("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
                    RTLD_LAZY);
  if (!h)
    {
      g_warning ("hwbridge: dlopen BackBoardServices failed: %s", dlerror ());
      return FALSE;
    }
  bks_get        = (BKSDisplayBrightnessGetCurrentFn) dlsym (h, "BKSDisplayBrightnessGetCurrent");
  bks_set        = (BKSDisplayBrightnessSetFn) dlsym (h, "BKSDisplayBrightnessSet");
  bks_txn_create = (BKSDisplayBrightnessTransactionCreateFn)
                     dlsym (h, "BKSDisplayBrightnessTransactionCreate");
  if (!bks_get || !bks_set)
    {
      g_warning ("hwbridge: BKSDisplayBrightness symbols missing");
      return FALSE;
    }
  return TRUE;
}

/* ---- battery state -------------------------------------------------------------------- */

typedef struct
{
  gboolean present;
  gboolean on_ac;
  guint32  state;        /* UpDeviceState */
  gdouble  percentage;
  gint64   time_to_empty; /* seconds, 0 = unknown */
  gint64   time_to_full;
  guint64  update_time;   /* unix seconds of last successful poll */
} BatteryState;

static BatteryState bat;   /* current, served over D-Bus + mirrored to sysfs */

static GDBusConnection *bus_conn;   /* set once the name is acquired */

static char *sys_root;              /* $XIOS_SYS or /var/jb/sys */
static char *backlight_dir;         /* <sys>/class/backlight/xios_backlight */
static char *bat_dir;               /* <sys>/class/power_supply/BAT0 */
static char *ac_dir;                /* <sys>/class/power_supply/AC0 */

static int   last_applied_brightness = -1;  /* 0..MAX_BRIGHTNESS, -1 = never */

static gboolean
dict_get_int (CFDictionaryRef d, const char *key, long *out)
{
  CFStringRef k = CFStringCreateWithCString (NULL, key, kCFStringEncodingUTF8);
  CFTypeRef v = CFDictionaryGetValue (d, k);
  CFRelease (k);
  if (!v || CFGetTypeID (v) != CFNumberGetTypeID ())
    return FALSE;
  return CFNumberGetValue ((CFNumberRef) v, kCFNumberLongType, out) ? TRUE : FALSE;
}

static gboolean
dict_get_bool (CFDictionaryRef d, const char *key, gboolean *out)
{
  CFStringRef k = CFStringCreateWithCString (NULL, key, kCFStringEncodingUTF8);
  CFTypeRef v = CFDictionaryGetValue (d, k);
  CFRelease (k);
  if (!v || CFGetTypeID (v) != CFBooleanGetTypeID ())
    return FALSE;
  *out = CFBooleanGetValue ((CFBooleanRef) v) ? TRUE : FALSE;
  return TRUE;
}

static gboolean
dict_str_equals (CFDictionaryRef d, const char *key, const char *want)
{
  CFStringRef k = CFStringCreateWithCString (NULL, key, kCFStringEncodingUTF8);
  CFTypeRef v = CFDictionaryGetValue (d, k);
  CFRelease (k);
  if (!v || CFGetTypeID (v) != CFStringGetTypeID ())
    return FALSE;
  char buf[64] = { 0 };
  if (!CFStringGetCString ((CFStringRef) v, buf, sizeof buf, kCFStringEncodingUTF8))
    return FALSE;
  return strcmp (buf, want) == 0;
}

/* Read IOKit power sources into *st. Returns FALSE if IOPS gave us nothing usable. */
static gboolean
read_battery (BatteryState *st)
{
  memset (st, 0, sizeof *st);
  st->update_time = (guint64) g_get_real_time () / G_USEC_PER_SEC;

  CFTypeRef info = iops_copy_info ();
  if (!info)
    return FALSE;
  CFArrayRef list = iops_copy_list (info);
  if (!list)
    {
      CFRelease (info);
      return FALSE;
    }

  gboolean found = FALSE;
  for (CFIndex i = 0; i < CFArrayGetCount (list); i++)
    {
      CFDictionaryRef d = iops_get_desc (info, CFArrayGetValueAtIndex (list, i));
      if (!d)
        continue;
      if (!dict_str_equals (d, "Type", "InternalBattery"))
        continue;

      long cur = 0, max = 100, minutes = 0;
      gboolean b = FALSE;

      st->present = TRUE;
      if (dict_get_bool (d, "Is Present", &b))
        st->present = b;

      if (dict_get_int (d, "Current Capacity", &cur))
        {
          if (!dict_get_int (d, "Max Capacity", &max) || max <= 0)
            max = 100;
          st->percentage = CLAMP (100.0 * (double) cur / (double) max, 0.0, 100.0);
        }

      st->on_ac = dict_str_equals (d, "Power Source State", "AC Power");
      gboolean charging = FALSE;
      dict_get_bool (d, "Is Charging", &charging);

      if (!st->on_ac)
        st->state = STATE_DISCHARGING;
      else if (charging)
        st->state = STATE_CHARGING;
      else if (st->percentage >= 99.5)
        st->state = STATE_FULLY_CHARGED;
      else
        st->state = STATE_PENDING_CHARGE;

      if (dict_get_int (d, "Time to Empty", &minutes) && minutes > 0)
        st->time_to_empty = (gint64) minutes * 60;
      if (dict_get_int (d, "Time to Full Charge", &minutes) && minutes > 0)
        st->time_to_full = (gint64) minutes * 60;

      found = TRUE;
      break;
    }

  CFRelease (list);
  CFRelease (info);
  return found;
}

static guint32
warning_level (const BatteryState *st)
{
  if (st->state != STATE_DISCHARGING)
    return LEVEL_NONE;
  if (st->percentage <= PCT_CRITICAL)
    return LEVEL_CRITICAL;
  if (st->percentage <= PCT_LOW)
    return LEVEL_LOW;
  return LEVEL_NONE;
}

static const char *
icon_name (const BatteryState *st)
{
  gboolean charging = (st->state == STATE_CHARGING || st->state == STATE_PENDING_CHARGE);
  if (!st->present)
    return "battery-missing-symbolic";
  if (st->state == STATE_FULLY_CHARGED)
    return "battery-full-charged-symbolic";
  if (st->percentage < 10)
    return charging ? "battery-caution-charging-symbolic" : "battery-caution-symbolic";
  if (st->percentage < 30)
    return charging ? "battery-low-charging-symbolic" : "battery-low-symbolic";
  if (st->percentage < 60)
    return charging ? "battery-good-charging-symbolic" : "battery-good-symbolic";
  return charging ? "battery-full-charging-symbolic" : "battery-full-symbolic";
}

/* ---- synthetic sysfs ------------------------------------------------------------------ */

static void
write_sys_file (const char *dir, const char *name, const char *contents)
{
  g_autofree char *path = g_build_filename (dir, name, NULL);
  g_autofree char *line = g_strdup_printf ("%s\n", contents);
  g_autoptr (GError) error = NULL;
  if (!g_file_set_contents (path, line, -1, &error))
    g_warning ("hwbridge: write %s: %s", path, error->message);
}

static const char *
sysfs_status (const BatteryState *st)
{
  switch (st->state)
    {
    case STATE_CHARGING:       return "Charging";
    case STATE_DISCHARGING:    return "Discharging";
    case STATE_FULLY_CHARGED:  return "Full";
    case STATE_PENDING_CHARGE: return "Not charging";
    default:                   return "Unknown";
    }
}

static void
sync_power_supply_tree (void)
{
  char buf[32];

  g_snprintf (buf, sizeof buf, "%d", (int) (bat.percentage + 0.5));
  write_sys_file (bat_dir, "capacity", buf);
  write_sys_file (bat_dir, "status", sysfs_status (&bat));
  write_sys_file (bat_dir, "present", bat.present ? "1" : "0");
  write_sys_file (ac_dir, "online", bat.on_ac ? "1" : "0");
}

static void
seed_sysfs_skeleton (void)
{
  /* Static identity files; postinst creates the dirs too, but the daemon must not depend
   * on install order. */
  if (g_mkdir_with_parents (backlight_dir, 0755) != 0 ||
      g_mkdir_with_parents (bat_dir, 0755) != 0 ||
      g_mkdir_with_parents (ac_dir, 0755) != 0)
    g_warning ("hwbridge: mkdir under %s failed", sys_root);

  char buf[32];
  g_snprintf (buf, sizeof buf, "%d", MAX_BRIGHTNESS);
  write_sys_file (backlight_dir, "max_brightness", buf);
  write_sys_file (backlight_dir, "type", "raw");

  write_sys_file (bat_dir, "type", "Battery");
  write_sys_file (bat_dir, "manufacturer", "Apple");
  write_sys_file (bat_dir, "model_name", "iPad");
  write_sys_file (bat_dir, "scope", "System");
  write_sys_file (ac_dir, "type", "Mains");
}

/* ---- brightness ------------------------------------------------------------------------ */

static void
apply_brightness (int value)
{
  value = CLAMP (value, 0, MAX_BRIGHTNESS);
  if (!bks_set)
    return;
  if (value == last_applied_brightness)
    return;

  CFTypeRef txn = bks_txn_create ? bks_txn_create (kCFAllocatorDefault) : NULL;
  bks_set ((float) value / (float) MAX_BRIGHTNESS, 1);
  if (txn)
    CFRelease (txn);

  last_applied_brightness = value;
  char buf[32];
  g_snprintf (buf, sizeof buf, "%d", value);
  write_sys_file (backlight_dir, "actual_brightness", buf);
}

static void
on_backlight_dir_event (GFileMonitor *monitor, GFile *file, GFile *other,
                        GFileMonitorEvent event, gpointer user_data)
{
  (void) monitor; (void) other; (void) user_data;

  if (event != G_FILE_MONITOR_EVENT_CHANGED &&
      event != G_FILE_MONITOR_EVENT_CREATED &&
      event != G_FILE_MONITOR_EVENT_MOVED_IN &&
      event != G_FILE_MONITOR_EVENT_RENAMED)
    return;

  g_autofree char *base = g_file_get_basename (file);
  if (g_strcmp0 (base, "brightness") != 0)
    return;

  g_autofree char *path = g_build_filename (backlight_dir, "brightness", NULL);
  g_autofree char *contents = NULL;
  if (!g_file_get_contents (path, &contents, NULL, NULL))
    return;
  apply_brightness ((int) g_ascii_strtoll (contents, NULL, 10));
}

/* Track brightness changed outside us (Control Center, auto-brightness) so the gsd slider
 * stays truthful. Writing `brightness` retriggers the monitor, but apply_brightness() is a
 * no-op on an unchanged value. */
static gboolean
brightness_sync_tick (gpointer user_data)
{
  (void) user_data;
  if (!bks_get)
    return G_SOURCE_REMOVE;

  int hw = (int) lroundf (bks_get () * MAX_BRIGHTNESS);
  hw = CLAMP (hw, 0, MAX_BRIGHTNESS);
  if (last_applied_brightness < 0 || ABS (hw - last_applied_brightness) > 5)
    {
      last_applied_brightness = hw;
      char buf[32];
      g_snprintf (buf, sizeof buf, "%d", hw);
      write_sys_file (backlight_dir, "brightness", buf);
      write_sys_file (backlight_dir, "actual_brightness", buf);
    }
  return G_SOURCE_CONTINUE;
}

/* ---- org.freedesktop.UPower ------------------------------------------------------------ */

static const char manager_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.UPower'>"
  "    <method name='EnumerateDevices'>"
  "      <arg direction='out' name='devices' type='ao'/>"
  "    </method>"
  "    <method name='GetDisplayDevice'>"
  "      <arg direction='out' name='device' type='o'/>"
  "    </method>"
  "    <method name='GetCriticalAction'>"
  "      <arg direction='out' name='action' type='s'/>"
  "    </method>"
  "    <signal name='DeviceAdded'><arg name='device' type='o'/></signal>"
  "    <signal name='DeviceRemoved'><arg name='device' type='o'/></signal>"
  "    <property name='DaemonVersion' type='s' access='read'/>"
  "    <property name='OnBattery' type='b' access='read'/>"
  "    <property name='LidIsClosed' type='b' access='read'/>"
  "    <property name='LidIsPresent' type='b' access='read'/>"
  "  </interface>"
  "</node>";

static const char device_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.UPower.Device'>"
  "    <method name='Refresh'/>"
  "    <method name='GetHistory'>"
  "      <arg direction='in' name='type' type='s'/>"
  "      <arg direction='in' name='timespan' type='u'/>"
  "      <arg direction='in' name='resolution' type='u'/>"
  "      <arg direction='out' name='data' type='a(udu)'/>"
  "    </method>"
  "    <method name='GetStatistics'>"
  "      <arg direction='in' name='type' type='s'/>"
  "      <arg direction='out' name='data' type='a(dd)'/>"
  "    </method>"
  "    <property name='NativePath' type='s' access='read'/>"
  "    <property name='Vendor' type='s' access='read'/>"
  "    <property name='Model' type='s' access='read'/>"
  "    <property name='Serial' type='s' access='read'/>"
  "    <property name='UpdateTime' type='t' access='read'/>"
  "    <property name='Type' type='u' access='read'/>"
  "    <property name='PowerSupply' type='b' access='read'/>"
  "    <property name='HasHistory' type='b' access='read'/>"
  "    <property name='HasStatistics' type='b' access='read'/>"
  "    <property name='Online' type='b' access='read'/>"
  "    <property name='Energy' type='d' access='read'/>"
  "    <property name='EnergyEmpty' type='d' access='read'/>"
  "    <property name='EnergyFull' type='d' access='read'/>"
  "    <property name='EnergyFullDesign' type='d' access='read'/>"
  "    <property name='EnergyRate' type='d' access='read'/>"
  "    <property name='Voltage' type='d' access='read'/>"
  "    <property name='ChargeCycles' type='i' access='read'/>"
  "    <property name='Luminosity' type='d' access='read'/>"
  "    <property name='TimeToEmpty' type='x' access='read'/>"
  "    <property name='TimeToFull' type='x' access='read'/>"
  "    <property name='Percentage' type='d' access='read'/>"
  "    <property name='Temperature' type='d' access='read'/>"
  "    <property name='IsPresent' type='b' access='read'/>"
  "    <property name='State' type='u' access='read'/>"
  "    <property name='IsRechargeable' type='b' access='read'/>"
  "    <property name='Capacity' type='d' access='read'/>"
  "    <property name='Technology' type='u' access='read'/>"
  "    <property name='WarningLevel' type='u' access='read'/>"
  "    <property name='BatteryLevel' type='u' access='read'/>"
  "    <property name='IconName' type='s' access='read'/>"
  "  </interface>"
  "</node>";

enum { DEV_DISPLAY, DEV_BATTERY, DEV_AC };

static void
manager_method_call (GDBusConnection *connection, const char *sender, const char *object_path,
                     const char *interface_name, const char *method_name, GVariant *parameters,
                     GDBusMethodInvocation *invocation, gpointer user_data)
{
  (void) connection; (void) sender; (void) object_path; (void) interface_name;
  (void) parameters; (void) user_data;

  if (g_str_equal (method_name, "EnumerateDevices"))
    {
      GVariantBuilder b;
      g_variant_builder_init (&b, G_VARIANT_TYPE ("ao"));
      g_variant_builder_add (&b, "o", BATTERY_DEV_PATH);
      g_variant_builder_add (&b, "o", AC_DEV_PATH);
      g_dbus_method_invocation_return_value (invocation, g_variant_new ("(ao)", &b));
    }
  else if (g_str_equal (method_name, "GetDisplayDevice"))
    g_dbus_method_invocation_return_value (invocation,
                                           g_variant_new ("(o)", DISPLAY_DEV_PATH));
  else if (g_str_equal (method_name, "GetCriticalAction"))
    g_dbus_method_invocation_return_value (invocation, g_variant_new ("(s)", "PowerOff"));
  else
    g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                           G_DBUS_ERROR_UNKNOWN_METHOD,
                                           "no %s", method_name);
}

static GVariant *
manager_get_property (GDBusConnection *connection, const char *sender, const char *object_path,
                      const char *interface_name, const char *property_name, GError **error,
                      gpointer user_data)
{
  (void) connection; (void) sender; (void) object_path; (void) interface_name;
  (void) error; (void) user_data;

  if (g_str_equal (property_name, "DaemonVersion"))
    return g_variant_new_string ("1.90.2-xios");
  if (g_str_equal (property_name, "OnBattery"))
    return g_variant_new_boolean (bat.state == STATE_DISCHARGING);
  if (g_str_equal (property_name, "LidIsClosed") || g_str_equal (property_name, "LidIsPresent"))
    return g_variant_new_boolean (FALSE);
  return NULL;
}

static void
device_method_call (GDBusConnection *connection, const char *sender, const char *object_path,
                    const char *interface_name, const char *method_name, GVariant *parameters,
                    GDBusMethodInvocation *invocation, gpointer user_data)
{
  (void) connection; (void) sender; (void) object_path; (void) interface_name;
  (void) parameters; (void) user_data;

  if (g_str_equal (method_name, "Refresh"))
    {
      read_battery (&bat);
      sync_power_supply_tree ();
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else if (g_str_equal (method_name, "GetHistory"))
    g_dbus_method_invocation_return_value (invocation,
        g_variant_new ("(a(udu))", NULL));
  else if (g_str_equal (method_name, "GetStatistics"))
    g_dbus_method_invocation_return_value (invocation,
        g_variant_new ("(a(dd))", NULL));
  else
    g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                           G_DBUS_ERROR_UNKNOWN_METHOD,
                                           "no %s", method_name);
}

static GVariant *
device_get_property (GDBusConnection *connection, const char *sender, const char *object_path,
                     const char *interface_name, const char *property_name, GError **error,
                     gpointer user_data)
{
  (void) connection; (void) sender; (void) object_path; (void) interface_name; (void) error;
  int which = GPOINTER_TO_INT (user_data);
  gboolean is_ac = (which == DEV_AC);

  if (g_str_equal (property_name, "NativePath"))
    return g_variant_new_string (which == DEV_BATTERY ? "BAT0" : is_ac ? "AC0" : "");
  if (g_str_equal (property_name, "Vendor"))
    return g_variant_new_string (is_ac ? "" : "Apple");
  if (g_str_equal (property_name, "Model"))
    return g_variant_new_string (is_ac ? "" : "iPad");
  if (g_str_equal (property_name, "Serial"))
    return g_variant_new_string ("");
  if (g_str_equal (property_name, "UpdateTime"))
    return g_variant_new_uint64 (bat.update_time);
  if (g_str_equal (property_name, "Type"))
    return g_variant_new_uint32 (is_ac ? KIND_LINE_POWER : KIND_BATTERY);
  if (g_str_equal (property_name, "PowerSupply"))
    return g_variant_new_boolean (TRUE);
  if (g_str_equal (property_name, "HasHistory") || g_str_equal (property_name, "HasStatistics"))
    return g_variant_new_boolean (FALSE);
  if (g_str_equal (property_name, "Online"))
    return g_variant_new_boolean (is_ac ? bat.on_ac : FALSE);
  if (g_str_equal (property_name, "TimeToEmpty"))
    return g_variant_new_int64 (is_ac ? 0 : bat.time_to_empty);
  if (g_str_equal (property_name, "TimeToFull"))
    return g_variant_new_int64 (is_ac ? 0 : bat.time_to_full);
  if (g_str_equal (property_name, "Percentage"))
    return g_variant_new_double (is_ac ? 0.0 : bat.percentage);
  if (g_str_equal (property_name, "IsPresent"))
    return g_variant_new_boolean (is_ac ? FALSE : bat.present);
  if (g_str_equal (property_name, "State"))
    return g_variant_new_uint32 (is_ac ? STATE_UNKNOWN : bat.state);
  if (g_str_equal (property_name, "IsRechargeable"))
    return g_variant_new_boolean (!is_ac);
  if (g_str_equal (property_name, "Technology"))
    return g_variant_new_uint32 (is_ac ? 0 : 1 /* lithium-ion */);
  if (g_str_equal (property_name, "WarningLevel"))
    return g_variant_new_uint32 (is_ac ? LEVEL_NONE : warning_level (&bat));
  if (g_str_equal (property_name, "BatteryLevel"))
    return g_variant_new_uint32 (LEVEL_NONE);  /* "none" = fine-grained percentage */
  if (g_str_equal (property_name, "IconName"))
    return g_variant_new_string (is_ac ? "ac-adapter-symbolic" : icon_name (&bat));
  if (g_str_equal (property_name, "ChargeCycles"))
    return g_variant_new_int32 (-1);
  /* Energy/EnergyEmpty/EnergyFull/EnergyFullDesign/EnergyRate/Voltage/Luminosity/
   * Temperature/Capacity — IOPS on iOS exposes percent only; report zeros. */
  if (g_str_equal (property_name, "Capacity"))
    return g_variant_new_double (is_ac ? 0.0 : 100.0);
  return g_variant_new_double (0.0);
}

static const GDBusInterfaceVTable manager_vtable = {
  .method_call = manager_method_call,
  .get_property = manager_get_property,
};
static const GDBusInterfaceVTable device_vtable = {
  .method_call = device_method_call,
  .get_property = device_get_property,
};

/* Push the dynamic battery properties at bound clients (UpClient/GDBusProxy caches). */
static void
emit_battery_changed (void)
{
  if (!bus_conn)
    return;

  static const char *paths[] = { DISPLAY_DEV_PATH, BATTERY_DEV_PATH, AC_DEV_PATH };
  for (unsigned i = 0; i < G_N_ELEMENTS (paths); i++)
    {
      gboolean is_ac = (i == 2);
      GVariantBuilder changed;
      g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
      if (is_ac)
        g_variant_builder_add (&changed, "{sv}", "Online",
                               g_variant_new_boolean (bat.on_ac));
      else
        {
          g_variant_builder_add (&changed, "{sv}", "State", g_variant_new_uint32 (bat.state));
          g_variant_builder_add (&changed, "{sv}", "Percentage",
                                 g_variant_new_double (bat.percentage));
          g_variant_builder_add (&changed, "{sv}", "TimeToEmpty",
                                 g_variant_new_int64 (bat.time_to_empty));
          g_variant_builder_add (&changed, "{sv}", "TimeToFull",
                                 g_variant_new_int64 (bat.time_to_full));
          g_variant_builder_add (&changed, "{sv}", "IsPresent",
                                 g_variant_new_boolean (bat.present));
          g_variant_builder_add (&changed, "{sv}", "IconName",
                                 g_variant_new_string (icon_name (&bat)));
          g_variant_builder_add (&changed, "{sv}", "WarningLevel",
                                 g_variant_new_uint32 (warning_level (&bat)));
          g_variant_builder_add (&changed, "{sv}", "UpdateTime",
                                 g_variant_new_uint64 (bat.update_time));
        }
      g_dbus_connection_emit_signal (bus_conn, NULL, paths[i],
                                     "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                     g_variant_new ("(sa{sv}as)", DEVICE_IFACE, &changed, NULL),
                                     NULL);
    }

  GVariantBuilder mchanged;
  g_variant_builder_init (&mchanged, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&mchanged, "{sv}", "OnBattery",
                         g_variant_new_boolean (bat.state == STATE_DISCHARGING));
  g_dbus_connection_emit_signal (bus_conn, NULL, UPOWER_PATH,
                                 "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                 g_variant_new ("(sa{sv}as)", UPOWER_NAME, &mchanged, NULL),
                                 NULL);
}

static gboolean
battery_poll_tick (gpointer user_data)
{
  (void) user_data;
  BatteryState fresh;
  if (!read_battery (&fresh))
    return G_SOURCE_CONTINUE;

  gboolean changed = (fresh.present != bat.present || fresh.state != bat.state ||
                      fresh.on_ac != bat.on_ac ||
                      (int) fresh.percentage != (int) bat.percentage ||
                      fresh.time_to_empty != bat.time_to_empty ||
                      fresh.time_to_full != bat.time_to_full);
  bat = fresh;
  if (changed)
    {
      sync_power_supply_tree ();
      emit_battery_changed ();
    }
  return G_SOURCE_CONTINUE;
}

/* ---- wiring ----------------------------------------------------------------------------- */

static gboolean
register_object (GDBusConnection *connection, const char *path, const char *xml,
                 const GDBusInterfaceVTable *vtable, gpointer user_data)
{
  g_autoptr (GError) error = NULL;
  GDBusNodeInfo *node = g_dbus_node_info_new_for_xml (xml, &error);
  if (!node)
    {
      g_warning ("hwbridge: bad interface XML: %s", error->message);
      return FALSE;
    }
  guint id = g_dbus_connection_register_object (connection, path, node->interfaces[0],
                                                vtable, user_data, NULL, &error);
  g_dbus_node_info_unref (node);
  if (id == 0)
    {
      g_warning ("hwbridge: failed to register %s: %s", path, error->message);
      return FALSE;
    }
  return TRUE;
}

static void
on_bus_acquired (GDBusConnection *connection, const char *name, gpointer user_data)
{
  (void) name; (void) user_data;
  bus_conn = connection;
  register_object (connection, UPOWER_PATH, manager_xml, &manager_vtable, NULL);
  register_object (connection, DISPLAY_DEV_PATH, device_xml, &device_vtable,
                   GINT_TO_POINTER (DEV_DISPLAY));
  register_object (connection, BATTERY_DEV_PATH, device_xml, &device_vtable,
                   GINT_TO_POINTER (DEV_BATTERY));
  register_object (connection, AC_DEV_PATH, device_xml, &device_vtable,
                   GINT_TO_POINTER (DEV_AC));
}

static void
on_name_acquired (GDBusConnection *connection, const char *name, gpointer user_data)
{
  (void) connection; (void) user_data;
  g_message ("hwbridge: owning %s", name);
}

static void
on_name_lost (GDBusConnection *connection, const char *name, gpointer user_data)
{
  (void) connection;
  g_warning ("hwbridge: lost %s (bus gone?) — exiting", name);
  g_main_loop_quit ((GMainLoop *) user_data);
}

static gboolean
on_sigterm (gpointer user_data)
{
  g_main_loop_quit ((GMainLoop *) user_data);
  return G_SOURCE_REMOVE;
}

int
main (int argc, char **argv)
{
  (void) argc; (void) argv;

  sys_root = g_strdup (g_getenv ("XIOS_SYS") ? g_getenv ("XIOS_SYS") : DEFAULT_SYS_ROOT);
  backlight_dir = g_build_filename (sys_root, "class/backlight/xios_backlight", NULL);
  bat_dir = g_build_filename (sys_root, "class/power_supply/BAT0", NULL);
  ac_dir = g_build_filename (sys_root, "class/power_supply/AC0", NULL);

  seed_sysfs_skeleton ();

  gboolean have_battery = load_iokit ();
  gboolean have_backlight = load_backboard ();
  if (!have_battery && !have_backlight)
    {
      g_warning ("hwbridge: no hardware backends available, nothing to do");
      return 1;
    }

  GMainLoop *loop = g_main_loop_new (NULL, FALSE);
  g_unix_signal_add (SIGTERM, on_sigterm, loop);
  g_unix_signal_add (SIGINT, on_sigterm, loop);

  guint owner_id = 0;
  if (have_battery)
    {
      read_battery (&bat);
      sync_power_supply_tree ();

      /* UPower lives on the system bus; the Xios session redirects that to the session bus
       * (DBUS_SYSTEM_BUS_ADDRESS), same as the login1/polkit/accounts stubs. */
      GBusType bus_type = G_BUS_TYPE_SYSTEM;
      const char *which = g_getenv ("XIOS_HWBRIDGE_BUS");
      if (which && g_str_equal (which, "session"))
        bus_type = G_BUS_TYPE_SESSION;

      owner_id = g_bus_own_name (bus_type, UPOWER_NAME, G_BUS_NAME_OWNER_FLAGS_NONE,
                                 on_bus_acquired, on_name_acquired, on_name_lost,
                                 loop, NULL);
      g_timeout_add_seconds (30, battery_poll_tick, NULL);
    }

  GFileMonitor *monitor = NULL;
  if (have_backlight)
    {
      brightness_sync_tick (NULL);  /* seed brightness files from current hardware level */

      g_autoptr (GFile) dir = g_file_new_for_path (backlight_dir);
      g_autoptr (GError) error = NULL;
      /* Watch the directory, not the file: g_file_set_contents() writers replace
       * `brightness` by rename, which would orphan a file watch. */
      monitor = g_file_monitor_directory (dir, G_FILE_MONITOR_WATCH_MOVES, NULL, &error);
      if (monitor)
        g_signal_connect (monitor, "changed", G_CALLBACK (on_backlight_dir_event), NULL);
      else
        g_warning ("hwbridge: backlight monitor failed: %s", error->message);
      g_timeout_add_seconds (10, brightness_sync_tick, NULL);
    }

  g_message ("hwbridge: up (battery=%s backlight=%s sys=%s)",
             have_battery ? "iokit" : "none",
             have_backlight ? "backboardd" : "none", sys_root);
  g_main_loop_run (loop);

  if (owner_id)
    g_bus_unown_name (owner_id);
  g_clear_object (&monitor);
  g_main_loop_unref (loop);
  return 0;
}
