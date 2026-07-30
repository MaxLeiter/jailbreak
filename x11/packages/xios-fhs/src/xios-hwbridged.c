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
 *              slider) when Control Center changes it behind our back. We also serve
 *              org.gnome.SettingsDaemon.Power.Screen (percent) on the session bus so the
 *              gnome-shell quick-settings slider works without a ported gsd-power.
 *
 * IOKit and BackBoardServices are resolved with dlopen/dlsym so the cross build needs no
 * private tbds or headers. Like the session stubs (wayland/xios-login1-stub.c) we own the
 * name on the "system" bus, which the Xios session points at the session bus via
 * DBUS_SYSTEM_BUS_ADDRESS; XIOS_HWBRIDGE_BUS=session forces the session bus for bring-up.
 */

#include <gio/gio.h>
#include "XiosProtocol.h"
#include <glib-unix.h>
#include <glib/gstdio.h>

#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <objc/message.h>
#include <objc/runtime.h>

#include <CoreFoundation/CoreFoundation.h>

/* libobjc autorelease pool (no ObjC syntax in this .c translation unit). */
extern void *objc_autoreleasePoolPush (void);
extern void  objc_autoreleasePoolPop (void *);

#define UPOWER_NAME       "org.freedesktop.UPower"
#define UPOWER_PATH       "/org/freedesktop/UPower"
#define DISPLAY_DEV_PATH  UPOWER_PATH "/devices/DisplayDevice"
#define BATTERY_DEV_PATH  UPOWER_PATH "/devices/battery_BAT0"
#define AC_DEV_PATH       UPOWER_PATH "/devices/line_power_AC0"
#define DEVICE_IFACE      "org.freedesktop.UPower.Device"

/* The gsd-power front-end (gnome-shell's quick-settings slider talks to this; served here
 * because gsd's power plugin is not ported — its non-Linux path needs gnome-rr, which our
 * GTK4 gnome-desktop drops). Interface copied verbatim from gsd 46 gsd-power-manager.c. */
#define GSD_POWER_NAME    "org.gnome.SettingsDaemon.Power"
#define GSD_POWER_PATH    "/org/gnome/SettingsDaemon/Power"

#ifndef DEFAULT_SYS_ROOT
#define DEFAULT_SYS_ROOT  "/var/jb/sys"
#endif
#define MAX_BRIGHTNESS    1000
#define PERCENT_STEP      5

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

/* Only the getter. BKSDisplayBrightnessSet and BKSDisplayBrightnessTransactionCreate
 * are deliberately not resolved: both exist and both are inert from a daemon on
 * iPadOS 17.6.1 (see send_brightness_to_app), so keeping them here would only
 * suggest a working setter that isn't. Reads are genuinely fine. */
typedef float (*BKSDisplayBrightnessGetCurrentFn) (void);

static IOPSCopyPowerSourcesInfoFn        iops_copy_info;
static IOPSCopyPowerSourcesListFn        iops_copy_list;
static IOPSGetPowerSourceDescriptionFn   iops_get_desc;

static BKSDisplayBrightnessGetCurrentFn        bks_get;

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
  bks_get = (BKSDisplayBrightnessGetCurrentFn) dlsym (h, "BKSDisplayBrightnessGetCurrent");
  if (!bks_get)
    {
      g_warning ("hwbridge: BKSDisplayBrightnessGetCurrent missing");
      return FALSE;
    }
  return TRUE;
}

/* AVFoundation is dlopen'd (like IOKit/BackBoardServices) so the cross build needs no
 * private tbds; we only need AVMediaTypeVideo resolved and the classes registered. */
static id av_media_video;   /* AVMediaTypeVideo (NSString *) */

static gboolean
load_avfoundation (void)
{
  void *h = dlopen ("/System/Library/Frameworks/AVFoundation.framework/AVFoundation",
                    RTLD_LAZY);
  if (!h)
    {
      g_warning ("hwbridge: dlopen AVFoundation failed: %s", dlerror ());
      return FALSE;
    }
  id *sym = (id *) dlsym (h, "AVMediaTypeVideo");
  av_media_video = sym ? *sym : NULL;
  if (!av_media_video || !objc_getClass ("AVCaptureDevice"))
    {
      g_warning ("hwbridge: AVFoundation torch symbols missing");
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

static GDBusConnection *bus_conn;   /* UPower connection, set once the name is acquired */
static GDBusConnection *gsd_conn;   /* session-bus connection for the gsd-power front-end */

static char *sys_root;              /* $XIOS_SYS or /var/jb/sys */
static char *backlight_dir;         /* <sys>/class/backlight/xios_backlight */
static char *bat_dir;               /* <sys>/class/power_supply/BAT0 */
static char *ac_dir;                /* <sys>/class/power_supply/AC0 */
static char *leds_dir;              /* <sys>/class/leds/xios:torch */

static int   last_applied_brightness = -1;  /* 0..MAX_BRIGHTNESS, -1 = never */
static int   last_applied_torch = -1;        /* 0/1, -1 = never */

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

static void emit_screen_brightness_changed (void);

static gboolean
sysint_transfer_full (int fd, void *buffer, size_t size, gboolean writing)
{
  char *p = buffer;
  size_t done = 0;
  while (done < size)
    {
      ssize_t n = writing ? send (fd, p + done, size - done, 0)
                          : recv (fd, p + done, size - done, 0);
      if (n > 0) { done += (size_t) n; continue; }
      if (n < 0 && errno == EINTR) continue;
      return FALSE;
    }
  return TRUE;
}

/* Hand a brightness level to the Xios app over xios-sysintd's socket.
 *
 * BKSDisplayBrightnessSet cannot do this job: on iPadOS 17.6.1 it is inert from a
 * daemon -- the symbols resolve, BKSDisplayBrightnessTransactionCreate returns
 * non-NULL, the com.apple.backboardd brightness entitlement is present, and
 * BKSDisplayBrightnessGetCurrent never budges, with the transaction released
 * immediately or held, and with auto-brightness on or explicitly off. Only an app
 * process can move the panel, via UIScreen.brightness, so the value has to travel
 * out to Xios.app. Reads are unaffected: GetCurrent works fine here, which is why
 * only the setter needs this detour.
 *
 * Fire-and-forget with a per-call connect. This runs at most once per 2 Hz tick and
 * only when the level actually changed, so a socket per applied change is cheaper
 * than holding a link that has to be reconnected after every session restart. */
static void
send_brightness_to_app (int value)
{
  const char *sock = g_getenv ("XIOS_SYSINT_SOCK");
  if (!sock || !*sock)
    sock = "/var/jb/tmp/xios-sysint.sock";

  int fd = socket (AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0)
    return;

  struct sockaddr_un addr = { 0 };
  addr.sun_family = AF_UNIX;
  g_strlcpy (addr.sun_path, sock, sizeof addr.sun_path);
  if (connect (fd, (struct sockaddr *) &addr, sizeof addr) != 0)
    {
      /* No session daemon: a bare compositor run, or the desktop is not up yet.
       * Not an error, and not worth logging every tick. */
      close (fd);
      return;
    }

  xios_msg hello = xios_protocol_hello ();
  xios_msg peer;
  xios_msg rec = xios_input_message (
    XIOS_IN_BRIGHTNESS, 0, 0,
    (uint32_t) ((value * 65535 + MAX_BRIGHTNESS / 2) / MAX_BRIGHTNESS),
    XIOS_BRIGHTNESS_STATE_TO_DEVICE, 0);
  if (!sysint_transfer_full (fd, &hello, sizeof hello, TRUE) ||
      !sysint_transfer_full (fd, &peer, sizeof peer, FALSE) ||
      !xios_protocol_is_exact_hello (&peer) ||
      !sysint_transfer_full (fd, &rec, sizeof rec, TRUE))
    g_warning ("hwbridge: strict-v1 brightness exchange failed");
  close (fd);
}

static void
apply_brightness (int value)
{
  value = CLAMP (value, 0, MAX_BRIGHTNESS);
  if (value == last_applied_brightness)
    return;

  send_brightness_to_app (value);

  last_applied_brightness = value;
  char buf[32];
  g_snprintf (buf, sizeof buf, "%d", value);
  write_sys_file (backlight_dir, "actual_brightness", buf);
  emit_screen_brightness_changed ();
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

/* Reconcile the node and the hardware in both directions.
 *
 * Inbound (`brightness` written by a client) is supposed to arrive via the directory
 * monitor, but GFileMonitor never fires on iOS -- GLib has no monitor backend for this
 * platform, so g_file_monitor_directory() hands back a monitor that reports nothing and
 * fails silently. Every write therefore landed in the file and stopped there: powerdevil,
 * the Plasma Mobile quicksetting and a plain shell redirect all set `brightness` with no
 * effect on the panel. This poll is what actually applies them, so it is load-bearing
 * rather than a backstop for the monitor.
 *
 * Outbound (Control Center, auto-brightness) is tracked so the sliders stay truthful. */
static gboolean
brightness_sync_tick (gpointer user_data)
{
  (void) user_data;
  if (!bks_get)
    return G_SOURCE_REMOVE;

  /* A value that is not the one we last applied is a client request, and it wins over
   * the hardware poll below. Skipped until we have applied something once, so the seeding
   * call cannot mistake a `brightness` file left behind by an earlier session for a
   * request and push last session's level onto the panel at startup. */
  if (last_applied_brightness >= 0)
    {
      g_autofree char *path = g_build_filename (backlight_dir, "brightness", NULL);
      g_autofree char *contents = NULL;
      if (g_file_get_contents (path, &contents, NULL, NULL))
        {
          int requested = CLAMP ((int) g_ascii_strtoll (contents, NULL, 10), 0, MAX_BRIGHTNESS);
          if (requested != last_applied_brightness)
            {
              apply_brightness (requested);
              return G_SOURCE_CONTINUE;
            }
        }
    }

  int hw = (int) lroundf (bks_get () * MAX_BRIGHTNESS);
  hw = CLAMP (hw, 0, MAX_BRIGHTNESS);
  if (last_applied_brightness < 0 || ABS (hw - last_applied_brightness) > 5)
    {
      last_applied_brightness = hw;
      char buf[32];
      g_snprintf (buf, sizeof buf, "%d", hw);
      write_sys_file (backlight_dir, "brightness", buf);
      write_sys_file (backlight_dir, "actual_brightness", buf);
      emit_screen_brightness_changed ();
    }
  return G_SOURCE_CONTINUE;
}

/* ---- torch / flashlight ---------------------------------------------------------------
 *
 * Same shape as the backlight bridge: a synthetic Linux `leds` node lives at
 * <sys>/class/leds/xios:torch. Anything may write `brightness` (0 = off, max_brightness =
 * on); we watch the directory and drive the camera torch through AVCaptureDevice. The
 * Plasma Mobile flashlight quicksetting normally reaches a real LED via libudev; on iOS its
 * backend (patched in plasma-mobile-ios-fixes.sh) reads/writes this node instead.
 *
 * max_brightness is 1 only when the device actually exposes an AVCaptureDevice torch, so
 * the tile's `available` stays truthful — most iPads have no torch LED. */

static id
torch_device (void)
{
  Class cls = objc_getClass ("AVCaptureDevice");
  if (!cls || !av_media_video)
    return NULL;
  return ((id (*) (id, SEL, id)) objc_msgSend)
           ((id) cls, sel_registerName ("defaultDeviceWithMediaType:"), av_media_video);
}

static gboolean
device_has_torch (id dev)
{
  if (!dev)
    return FALSE;
  return ((BOOL (*) (id, SEL)) objc_msgSend) (dev, sel_registerName ("hasTorch")) ? TRUE : FALSE;
}

/* Probe once at startup without starting a capture session (enumeration + hasTorch do not
 * require camera authorization; only lockForConfiguration/setTorchMode does). */
static gboolean
probe_torch (void)
{
  void *pool = objc_autoreleasePoolPush ();
  gboolean has = device_has_torch (torch_device ());
  objc_autoreleasePoolPop (pool);
  return has;
}

static void
apply_torch (int on)
{
  on = on ? 1 : 0;
  if (on == last_applied_torch)
    return;

  void *pool = objc_autoreleasePoolPush ();
  id dev = torch_device ();
  if (device_has_torch (dev))
    {
      id err = NULL;
      BOOL locked = ((BOOL (*) (id, SEL, id *)) objc_msgSend)
                      (dev, sel_registerName ("lockForConfiguration:"), &err);
      if (locked)
        {
          /* AVCaptureTorchModeOff = 0, AVCaptureTorchModeOn = 1 */
          ((void (*) (id, SEL, long)) objc_msgSend)
            (dev, sel_registerName ("setTorchMode:"), (long) on);
          ((void (*) (id, SEL)) objc_msgSend) (dev, sel_registerName ("unlockForConfiguration"));
          last_applied_torch = on;
        }
      else
        g_warning ("hwbridge: torch lockForConfiguration failed");
    }
  objc_autoreleasePoolPop (pool);
}

static void
on_leds_dir_event (GFileMonitor *monitor, GFile *file, GFile *other,
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

  g_autofree char *path = g_build_filename (leds_dir, "brightness", NULL);
  g_autofree char *contents = NULL;
  if (!g_file_get_contents (path, &contents, NULL, NULL))
    return;
  apply_torch ((int) g_ascii_strtoll (contents, NULL, 10) != 0);
}

/* Seed the synthetic LED node. `present` reflects real torch capability and is published as
 * max_brightness (1 = usable, 0 = no torch on this device). `brightness` is left world
 * writable so the unprivileged shell can toggle it in place, and is never rewritten by the
 * daemon (the writer owns it; we only read it on directory events). */
static void
ensure_leds_tree (gboolean present)
{
  if (g_mkdir_with_parents (leds_dir, 0775) != 0)
    g_warning ("hwbridge: mkdir %s failed", leds_dir);

  write_sys_file (leds_dir, "color", "white");
  write_sys_file (leds_dir, "function", "torch");
  write_sys_file (leds_dir, "max_brightness", present ? "1" : "0");

  g_autofree char *bpath = g_build_filename (leds_dir, "brightness", NULL);
  if (!g_file_test (bpath, G_FILE_TEST_EXISTS))
    {
      g_autoptr (GError) error = NULL;
      if (!g_file_set_contents (bpath, "0\n", -1, &error))
        g_warning ("hwbridge: seed %s: %s", bpath, error->message);
    }
  g_chmod (bpath, 0666);
}

/* ---- org.gnome.SettingsDaemon.Power (Screen) -------------------------------------------
 *
 * gnome-shell's quick-settings brightness slider is a proxy on this interface; it shows
 * whenever Brightness >= 0. Serving it here (percent -> raw -> BackBoardServices) makes the
 * slider work without a ported gsd-power. XIOS_HWBRIDGE_NO_GSD_SHIM=1 disables the claim if
 * a real gsd-power ever lands. */

static const char power_screen_xml[] =
  "<node>"
  "  <interface name='org.gnome.SettingsDaemon.Power.Screen'>"
  "    <property name='Brightness' type='i' access='readwrite'/>"
  "    <method name='StepUp'>"
  "      <arg type='i' name='new_percentage' direction='out'/>"
  "      <arg type='s' name='connector' direction='out'/>"
  "    </method>"
  "    <method name='StepDown'>"
  "      <arg type='i' name='new_percentage' direction='out'/>"
  "      <arg type='s' name='connector' direction='out'/>"
  "    </method>"
  "    <method name='Cycle'>"
  "      <arg type='i' name='new_percentage' direction='out'/>"
  "      <arg type='i' name='output_id' direction='out'/>"
  "    </method>"
  "  </interface>"
  "</node>";

static int
brightness_percent (void)
{
  if (last_applied_brightness < 0)
    return -1;
  return (last_applied_brightness * 100 + MAX_BRIGHTNESS / 2) / MAX_BRIGHTNESS;
}

/* Set from the D-Bus side: apply to hardware and keep the sysfs node truthful. The node
 * write retriggers the file monitor, but apply_brightness() no-ops on an unchanged value. */
static void
set_brightness_percent (int percent)
{
  int raw;

  percent = CLAMP (percent, 0, 100);
  raw = percent * MAX_BRIGHTNESS / 100;
  apply_brightness (raw);

  char buf[32];
  g_snprintf (buf, sizeof buf, "%d", raw);
  write_sys_file (backlight_dir, "brightness", buf);
}

static void
emit_screen_brightness_changed (void)
{
  GVariantBuilder changed;

  if (!gsd_conn)
    return;

  g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&changed, "{sv}", "Brightness",
                         g_variant_new_int32 (brightness_percent ()));
  g_dbus_connection_emit_signal (gsd_conn, NULL, GSD_POWER_PATH,
                                 "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                 g_variant_new ("(sa{sv}as)",
                                                "org.gnome.SettingsDaemon.Power.Screen",
                                                &changed, NULL),
                                 NULL);
}

static void
screen_method_call (GDBusConnection *connection, const char *sender, const char *object_path,
                    const char *interface_name, const char *method_name, GVariant *parameters,
                    GDBusMethodInvocation *invocation, gpointer user_data)
{
  (void) connection; (void) sender; (void) object_path; (void) interface_name;
  (void) parameters; (void) user_data;
  int cur = brightness_percent ();

  if (g_str_equal (method_name, "StepUp"))
    {
      set_brightness_percent (MIN (cur + PERCENT_STEP, 100));
      g_dbus_method_invocation_return_value (invocation,
          g_variant_new ("(is)", brightness_percent (), "xios"));
    }
  else if (g_str_equal (method_name, "StepDown"))
    {
      set_brightness_percent (MAX (cur - PERCENT_STEP, 0));
      g_dbus_method_invocation_return_value (invocation,
          g_variant_new ("(is)", brightness_percent (), "xios"));
    }
  else if (g_str_equal (method_name, "Cycle"))
    {
      set_brightness_percent (cur >= 100 ? 0 : MIN (cur + PERCENT_STEP, 100));
      g_dbus_method_invocation_return_value (invocation,
          g_variant_new ("(ii)", brightness_percent (), 0));
    }
  else
    g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                           G_DBUS_ERROR_UNKNOWN_METHOD,
                                           "no %s", method_name);
}

static GVariant *
screen_get_property (GDBusConnection *connection, const char *sender, const char *object_path,
                     const char *interface_name, const char *property_name, GError **error,
                     gpointer user_data)
{
  (void) connection; (void) sender; (void) object_path; (void) interface_name;
  (void) error; (void) user_data;

  if (g_str_equal (property_name, "Brightness"))
    return g_variant_new_int32 (brightness_percent ());
  return NULL;
}

static gboolean
screen_set_property (GDBusConnection *connection, const char *sender, const char *object_path,
                     const char *interface_name, const char *property_name, GVariant *value,
                     GError **error, gpointer user_data)
{
  (void) connection; (void) sender; (void) object_path; (void) interface_name;
  (void) error; (void) user_data;

  if (g_str_equal (property_name, "Brightness"))
    {
      set_brightness_percent (g_variant_get_int32 (value));
      return TRUE;
    }
  return FALSE;
}

static const GDBusInterfaceVTable screen_vtable = {
  .method_call = screen_method_call,
  .get_property = screen_get_property,
  .set_property = screen_set_property,
};

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

static void
on_gsd_bus_acquired (GDBusConnection *connection, const char *name, gpointer user_data)
{
  (void) name; (void) user_data;
  gsd_conn = connection;
  register_object (connection, GSD_POWER_PATH, power_screen_xml, &screen_vtable, NULL);
}

static void
on_gsd_name_acquired (GDBusConnection *connection, const char *name, gpointer user_data)
{
  (void) connection; (void) user_data;
  g_message ("hwbridge: owning %s (brightness slider front-end)", name);
}

/* Unlike UPower, losing this name is not fatal: a real ported gsd-power owning it instead
 * is the intended hand-off. */
static void
on_gsd_name_lost (GDBusConnection *connection, const char *name, gpointer user_data)
{
  (void) connection; (void) user_data;
  g_message ("hwbridge: not owning %s (real gsd-power present?)", name);
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
  leds_dir = g_build_filename (sys_root, "class/leds/xios:torch", NULL);

  seed_sysfs_skeleton ();

  gboolean have_battery = load_iokit ();
  gboolean have_backlight = load_backboard ();
  /* Torch is optional and non-fatal: publish the node's capability either way so the
   * flashlight tile can read a truthful `available`, but only watch it when usable. */
  gboolean have_torch = load_avfoundation () && probe_torch ();
  ensure_leds_tree (have_torch);
  if (have_torch)
    last_applied_torch = 0;
  if (!have_battery && !have_backlight && !have_torch)
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
  guint gsd_owner_id = 0;
  if (have_backlight)
    {
      brightness_sync_tick (NULL);  /* seed brightness files from current hardware level */

      /* gsd-power front-end for the shell slider (session bus proper — gsd names never
       * lived on the system bus). */
      if (!g_getenv ("XIOS_HWBRIDGE_NO_GSD_SHIM"))
        gsd_owner_id = g_bus_own_name (G_BUS_TYPE_SESSION, GSD_POWER_NAME,
                                       G_BUS_NAME_OWNER_FLAGS_NONE,
                                       on_gsd_bus_acquired, on_gsd_name_acquired,
                                       on_gsd_name_lost, NULL, NULL);

      g_autoptr (GFile) dir = g_file_new_for_path (backlight_dir);
      g_autoptr (GError) error = NULL;
      /* Watch the directory, not the file: g_file_set_contents() writers replace
       * `brightness` by rename, which would orphan a file watch.
       *
       * Kept, but do not rely on it: on iOS this call succeeds and then delivers no
       * events at all, so it warns about nothing while silently doing nothing. The
       * poll below is what carries client writes through to the panel. */
      monitor = g_file_monitor_directory (dir, G_FILE_MONITOR_WATCH_MOVES, NULL, &error);
      if (monitor)
        g_signal_connect (monitor, "changed", G_CALLBACK (on_backlight_dir_event), NULL);
      else
        g_warning ("hwbridge: backlight monitor failed: %s", error->message);
      /* Sub-second, because this is the latency of a brightness slider, not of a
       * background sync: at the old 10s the panel lagged a drag hopelessly. Two small
       * reads at 2 Hz is not measurable next to a compositor. */
      g_timeout_add (500, brightness_sync_tick, NULL);
    }

  GFileMonitor *leds_monitor = NULL;
  if (have_torch)
    {
      /* Watch the directory, not the file: writers replace `brightness` by rename. */
      g_autoptr (GFile) dir = g_file_new_for_path (leds_dir);
      g_autoptr (GError) error = NULL;
      leds_monitor = g_file_monitor_directory (dir, G_FILE_MONITOR_WATCH_MOVES, NULL, &error);
      if (leds_monitor)
        g_signal_connect (leds_monitor, "changed", G_CALLBACK (on_leds_dir_event), NULL);
      else
        g_warning ("hwbridge: torch monitor failed: %s", error->message);
    }

  g_message ("hwbridge: up (battery=%s backlight=%s torch=%s sys=%s)",
             have_battery ? "iokit" : "none",
             have_backlight ? "backboardd" : "none",
             have_torch ? "avcapture" : "none", sys_root);
  g_main_loop_run (loop);

  if (owner_id)
    g_bus_unown_name (owner_id);
  if (gsd_owner_id)
    g_bus_unown_name (gsd_owner_id);
  g_clear_object (&monitor);
  g_clear_object (&leds_monitor);
  g_main_loop_unref (loop);
  return 0;
}
