/* -*- mode: ObjC; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-bluez-stub.m — a minimal org.bluez bridge for the iOS GNOME session.
 *
 * gnome-bluetooth (the backend of GNOME Settings' Bluetooth panel, and gnome-shell's
 * Bluetooth quick-toggle) talks to BlueZ over D-Bus: it opens a GDBusObjectManagerClient on
 * the well-known name `org.bluez` at the object-manager root "/", enumerates adapters
 * (org.bluez.Adapter1) and devices (org.bluez.Device1) via GetManagedObjects, and reacts to
 * InterfacesAdded/Removed + PropertiesChanged. There is NO BlueZ on a jailbroken iPad — iOS
 * has its own Bluetooth stack behind the private BluetoothManager.framework (which XPCs to
 * /usr/sbin/bluetoothd). So this is a SHIM, exactly like xios-login1-stub / xios-accounts-stub:
 * it OWNS org.bluez and answers the subset of the BlueZ D-Bus API gnome-bluetooth actually
 * uses, backed by BluetoothManager.
 *
 * WHAT IT MAPS
 *   org.bluez  (ObjectManager at "/")           <- objects below
 *   org.bluez.Adapter1  /org/bluez/hci0         <- BluetoothManager (powered/scanning/address)
 *     Powered/Discovering/Discoverable/Pairable  <-> setPowered:/setDeviceScanningEnabled:
 *     StartDiscovery/StopDiscovery/RemoveDevice
 *   org.bluez.Device1   /org/bluez/hci0/dev_XX_.. <- each BluetoothDevice
 *     Address/Name/Alias/Paired/Connected/Trusted/Class/Icon/RSSI
 *     Connect/Disconnect/Pair
 *
 * FEASIBILITY / STATUS (2026-07-02): BluetoothManager.framework is the well-trodden private
 * API used across the jailbreak tweak ecosystem to enumerate/toggle Bluetooth; it is reached
 * here by dlopen()+ObjC-runtime (no link-time framework stub needed in the cross SDK). This
 * daemon is fakesigned + unsandboxed (root), the same trust context those tweaks run in.
 *   - Enumeration of paired/connected devices + power/scan state + connect/disconnect of
 *     already-paired devices is expected to work (bluetoothd allows these for unsandboxed
 *     callers). This is the phase-1 target: a populated device list in the panel.
 *   - PAIRING of new devices may be gated behind a bluetoothd entitlement / require an agent;
 *     that is phase 2. Pair() is wired to BluetoothDevice's -connect/-pair but not yet
 *     device-validated. The org.bluez.Agent1 registration path (AgentManager1) is stubbed to
 *     accept RegisterAgent so gnome-bluetooth's agent registration succeeds without error.
 *
 * RUN LOOP: GDBus needs a GMainLoop; BluetoothManager delivers its callbacks on a CFRunLoop
 * (NSNotificationCenter). We run the GLib loop (xios_stub_run) and pump the CFRunLoop from a
 * short GLib timeout so BluetoothManager's notifications are serviced — then reflect state
 * changes back onto D-Bus (PropertiesChanged / InterfacesAdded/Removed).
 *
 * Pure GLib/GIO + Foundation/ObjC. No Mutter, no Wayland. GPL-2.0+.
 */

#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>

#include <gio/gio.h>

#include "xios-stub-dbus.h"

#define BLUEZ_NAME        "org.bluez"
#define OM_ROOT           "/"
#define ADAPTER_PATH      "/org/bluez/hci0"

/* ---- BluetoothManager.framework surface we use (private; resolved via the ObjC runtime) --
 * These declarations describe the long-stable MobileBluetooth API. We never link the
 * framework; -sharedInstance is fetched from the class object obtained with objc_getClass
 * after dlopen(), and every call is an ordinary objc_msgSend by selector. */
@protocol XiosBTDevice <NSObject>
- (NSString *)name;
- (NSString *)address;
- (BOOL)connected;
- (BOOL)paired;
- (unsigned int)classOfDevice;
- (void)connect;
- (void)disconnect;
- (void)pair;
- (void)unpair;
@end

@protocol XiosBTManager <NSObject>
- (BOOL)available;
- (BOOL)powered;
- (BOOL)enabled;
- (void)setPowered:(BOOL)powered;
- (void)setEnabled:(BOOL)enabled;
- (BOOL)deviceScanningEnabled;
- (void)setDeviceScanningEnabled:(BOOL)enabled;
- (NSArray *)devices;         /* all known (paired + discovered) */
- (NSArray *)pairedDevices;
- (NSArray *)connectedDevices;
- (void)connectDevice:(id)device;
- (void)disconnectDevice:(id)device;
- (NSString *)hardwareAddress;
@end

/* BluetoothManager NSNotificationCenter names (posted on the CF run loop). */
static NSString *const kBTPowerChanged        = @"BluetoothPowerChangedNotification";
static NSString *const kBTAvailabilityChanged = @"BluetoothAvailabilityChangedNotification";
static NSString *const kBTDiscoveryStateChg   = @"BluetoothDiscoveryStateChangedNotification";
static NSString *const kBTDeviceDiscovered    = @"BluetoothDeviceDiscoveredNotification";
static NSString *const kBTDeviceRemoved       = @"BluetoothDeviceRemovedNotification";
static NSString *const kBTDeviceUpdated       = @"BluetoothDeviceUpdatedNotification";
static NSString *const kBTDeviceConnectOK     = @"BluetoothDeviceConnectSuccessNotification";
static NSString *const kBTDeviceDisconnectOK  = @"BluetoothConnectionStatusChangedNotification";

static id<XiosBTManager> g_bt;                 /* [BluetoothManager sharedInstance] */
static GDBusConnection  *g_conn;               /* set on bus-acquired */

/* One tracked device object exported on D-Bus. */
typedef struct {
  char      path[96];        /* /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX */
  char      address[18];     /* XX:XX:XX:XX:XX:XX (uppercased) */
  guint     reg_id;          /* g_dbus_connection_register_object id (0 = not registered) */
  __unsafe_unretained id dev;/* the BluetoothDevice; kept alive by g_dev_keepalive (ARC) */
} XiosBTDeviceObj;

static GHashTable *g_devices;  /* address(str, owned) -> XiosBTDeviceObj* */
/* ARC-strong container that owns the BluetoothDevice objects (the C struct only holds an
 * unretained alias, since ARC forbids ownership-qualified id in a plain C struct). */
static NSMutableDictionary<NSString *, id> *g_dev_keepalive;

/* ------------------------------------------------------------------------------------------
 * Address / path helpers
 * ---------------------------------------------------------------------------------------- */

/* iOS returns "xx:xx:xx:xx:xx:xx" (case varies). BlueZ canonicalises to uppercase and the
 * device object path replaces ':' with '_'. */
static void
addr_canon (const char *in, char out[18])
{
  int j = 0;
  for (int i = 0; in && in[i] && j < 17; i++)
    {
      char c = in[i];
      if (c >= 'a' && c <= 'f') c = (char) (c - 'a' + 'A');
      out[j++] = c;
    }
  out[j] = 0;
}

static void
addr_to_path (const char *addr, char out[96])
{
  g_snprintf (out, 96, "%s/dev_", ADAPTER_PATH);
  size_t base = strlen (out);
  size_t j = base;
  for (int i = 0; addr[i] && j < 94; i++)
    out[j++] = (addr[i] == ':') ? '_' : addr[i];
  out[j] = 0;
}

/* Map an iOS class-of-device to a BlueZ "icon" hint (what gnome-bluetooth renders). */
static const char *
icon_for_class (unsigned int cod)
{
  unsigned int major = (cod >> 8) & 0x1f;
  switch (major)
    {
    case 0x01: return "computer";
    case 0x02: return "phone";
    case 0x04: return "audio-headset";     /* audio/video */
    case 0x05: return "input-keyboard";    /* peripheral */
    case 0x06: return "camera-photo";      /* imaging */
    default:   return "bluetooth";
    }
}

/* ------------------------------------------------------------------------------------------
 * Introspection XML
 * ---------------------------------------------------------------------------------------- */

static const char om_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.DBus.ObjectManager'>"
  "    <method name='GetManagedObjects'>"
  "      <arg type='a{oa{sa{sv}}}' name='objects' direction='out'/>"
  "    </method>"
  "    <signal name='InterfacesAdded'>"
  "      <arg type='o' name='object_path'/>"
  "      <arg type='a{sa{sv}}' name='interfaces_and_properties'/>"
  "    </signal>"
  "    <signal name='InterfacesRemoved'>"
  "      <arg type='o' name='object_path'/>"
  "      <arg type='as' name='interfaces'/>"
  "    </signal>"
  "  </interface>"
  "</node>";

static const char adapter_xml[] =
  "<node>"
  "  <interface name='org.bluez.Adapter1'>"
  "    <method name='StartDiscovery'/>"
  "    <method name='StopDiscovery'/>"
  "    <method name='RemoveDevice'><arg type='o' name='device' direction='in'/></method>"
  "    <property name='Address' type='s' access='read'/>"
  "    <property name='Name' type='s' access='read'/>"
  "    <property name='Alias' type='s' access='readwrite'/>"
  "    <property name='Class' type='u' access='read'/>"
  "    <property name='Powered' type='b' access='readwrite'/>"
  "    <property name='Discoverable' type='b' access='readwrite'/>"
  "    <property name='Pairable' type='b' access='readwrite'/>"
  "    <property name='Discovering' type='b' access='read'/>"
  "  </interface>"
  "</node>";

static const char device_xml[] =
  "<node>"
  "  <interface name='org.bluez.Device1'>"
  "    <method name='Connect'/>"
  "    <method name='Disconnect'/>"
  "    <method name='Pair'/>"
  "    <property name='Address' type='s' access='read'/>"
  "    <property name='Name' type='s' access='read'/>"
  "    <property name='Alias' type='s' access='readwrite'/>"
  "    <property name='Class' type='u' access='read'/>"
  "    <property name='Icon' type='s' access='read'/>"
  "    <property name='Paired' type='b' access='read'/>"
  "    <property name='Trusted' type='b' access='readwrite'/>"
  "    <property name='Connected' type='b' access='read'/>"
  "    <property name='Adapter' type='o' access='read'/>"
  "  </interface>"
  "</node>";

static const char agentmgr_xml[] =
  "<node>"
  "  <interface name='org.bluez.AgentManager1'>"
  "    <method name='RegisterAgent'>"
  "      <arg type='o' name='agent' direction='in'/>"
  "      <arg type='s' name='capability' direction='in'/>"
  "    </method>"
  "    <method name='UnregisterAgent'><arg type='o' name='agent' direction='in'/></method>"
  "    <method name='RequestDefaultAgent'><arg type='o' name='agent' direction='in'/></method>"
  "  </interface>"
  "</node>";

/* ------------------------------------------------------------------------------------------
 * Property builders (a{sv}) for GetManagedObjects / InterfacesAdded
 * ---------------------------------------------------------------------------------------- */

static GVariant *
adapter_props_dict (void)
{
  GVariantBuilder b;
  g_variant_builder_init (&b, G_VARIANT_TYPE ("a{sv}"));
  NSString *hw = [g_bt respondsToSelector:@selector(hardwareAddress)] ? [g_bt hardwareAddress] : nil;
  char addr[18] = "00:00:00:00:00:00";
  if (hw) addr_canon ([hw UTF8String], addr);
  g_variant_builder_add (&b, "{sv}", "Address", g_variant_new_string (addr));
  g_variant_builder_add (&b, "{sv}", "Name", g_variant_new_string ("iPad"));
  g_variant_builder_add (&b, "{sv}", "Alias", g_variant_new_string ("iPad"));
  g_variant_builder_add (&b, "{sv}", "Powered", g_variant_new_boolean ([g_bt powered]));
  g_variant_builder_add (&b, "{sv}", "Discoverable", g_variant_new_boolean (FALSE));
  g_variant_builder_add (&b, "{sv}", "Pairable", g_variant_new_boolean (TRUE));
  g_variant_builder_add (&b, "{sv}", "Discovering",
                         g_variant_new_boolean ([g_bt deviceScanningEnabled]));
  return g_variant_builder_end (&b);
}

static GVariant *
device_props_dict (XiosBTDeviceObj *o)
{
  id<XiosBTDevice> d = o->dev;
  GVariantBuilder b;
  g_variant_builder_init (&b, G_VARIANT_TYPE ("a{sv}"));
  const char *name = "Unknown";
  NSString *n = [d name];
  if (n) name = [n UTF8String];
  unsigned int cod = [d respondsToSelector:@selector(classOfDevice)] ? [d classOfDevice] : 0;
  g_variant_builder_add (&b, "{sv}", "Address", g_variant_new_string (o->address));
  g_variant_builder_add (&b, "{sv}", "Name", g_variant_new_string (name));
  g_variant_builder_add (&b, "{sv}", "Alias", g_variant_new_string (name));
  g_variant_builder_add (&b, "{sv}", "Class", g_variant_new_uint32 (cod));
  g_variant_builder_add (&b, "{sv}", "Icon", g_variant_new_string (icon_for_class (cod)));
  g_variant_builder_add (&b, "{sv}", "Paired", g_variant_new_boolean ([d paired]));
  g_variant_builder_add (&b, "{sv}", "Trusted", g_variant_new_boolean ([d paired]));
  g_variant_builder_add (&b, "{sv}", "Connected", g_variant_new_boolean ([d connected]));
  g_variant_builder_add (&b, "{sv}", "Adapter",
                         g_variant_new_object_path (ADAPTER_PATH));
  return g_variant_builder_end (&b);
}

/* ------------------------------------------------------------------------------------------
 * Device1 vtable
 * ---------------------------------------------------------------------------------------- */

static XiosBTDeviceObj *
device_for_path (const char *path)
{
  GHashTableIter it;
  gpointer k, v;
  g_hash_table_iter_init (&it, g_devices);
  while (g_hash_table_iter_next (&it, &k, &v))
    {
      XiosBTDeviceObj *o = v;
      if (g_str_equal (o->path, path)) return o;
    }
  return NULL;
}

static void
device_method_call (GDBusConnection *c, const gchar *sender, const gchar *path,
                    const gchar *iface, const gchar *method, GVariant *params,
                    GDBusMethodInvocation *inv, gpointer user_data)
{
  (void) c; (void) sender; (void) iface; (void) params; (void) user_data;
  XiosBTDeviceObj *o = device_for_path (path);
  if (!o) {
    g_dbus_method_invocation_return_error (inv, G_DBUS_ERROR, G_DBUS_ERROR_FAILED,
                                           "unknown device %s", path);
    return;
  }
  id<XiosBTDevice> d = o->dev;
  if (g_str_equal (method, "Connect")) {
    if ([g_bt respondsToSelector:@selector(connectDevice:)]) [g_bt connectDevice:d];
    else [d connect];
    g_dbus_method_invocation_return_value (inv, NULL);
  } else if (g_str_equal (method, "Disconnect")) {
    if ([g_bt respondsToSelector:@selector(disconnectDevice:)]) [g_bt disconnectDevice:d];
    else [d disconnect];
    g_dbus_method_invocation_return_value (inv, NULL);
  } else if (g_str_equal (method, "Pair")) {
    /* phase 2: pairing may need an agent / entitlement. Best-effort via BluetoothDevice. */
    if ([d respondsToSelector:@selector(pair)]) [d pair];
    else if ([g_bt respondsToSelector:@selector(connectDevice:)]) [g_bt connectDevice:d];
    g_dbus_method_invocation_return_value (inv, NULL);
  } else {
    g_dbus_method_invocation_return_error (inv, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                           "Device1.%s unhandled", method);
  }
}

static GVariant *
device_get_property (GDBusConnection *c, const gchar *sender, const gchar *path,
                     const gchar *iface, const gchar *prop, GError **error, gpointer user_data)
{
  (void) c; (void) sender; (void) iface; (void) user_data;
  XiosBTDeviceObj *o = device_for_path (path);
  if (!o) { g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_OBJECT, "no dev"); return NULL; }
  id<XiosBTDevice> d = o->dev;
  if (g_str_equal (prop, "Address")) return g_variant_new_string (o->address);
  if (g_str_equal (prop, "Name") || g_str_equal (prop, "Alias")) {
    NSString *n = [d name];
    return g_variant_new_string (n ? [n UTF8String] : "Unknown");
  }
  if (g_str_equal (prop, "Class")) {
    unsigned int cod = [d respondsToSelector:@selector(classOfDevice)] ? [d classOfDevice] : 0;
    return g_variant_new_uint32 (cod);
  }
  if (g_str_equal (prop, "Icon")) {
    unsigned int cod = [d respondsToSelector:@selector(classOfDevice)] ? [d classOfDevice] : 0;
    return g_variant_new_string (icon_for_class (cod));
  }
  if (g_str_equal (prop, "Paired"))    return g_variant_new_boolean ([d paired]);
  if (g_str_equal (prop, "Trusted"))   return g_variant_new_boolean ([d paired]);
  if (g_str_equal (prop, "Connected")) return g_variant_new_boolean ([d connected]);
  if (g_str_equal (prop, "Adapter"))   return g_variant_new_object_path (ADAPTER_PATH);
  g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Device1.%s", prop);
  return NULL;
}

static gboolean
device_set_property (GDBusConnection *c, const gchar *sender, const gchar *path,
                     const gchar *iface, const gchar *prop, GVariant *value,
                     GError **error, gpointer user_data)
{
  (void) c; (void) sender; (void) path; (void) iface; (void) value; (void) user_data; (void) error;
  /* Alias/Trusted are accepted no-ops (iOS has no per-device trust/alias to persist here). */
  (void) prop;
  return TRUE;
}

static const GDBusInterfaceVTable device_vtable = {
  .method_call = device_method_call,
  .get_property = device_get_property,
  .set_property = device_set_property,
};

/* ------------------------------------------------------------------------------------------
 * Register / unregister a device object + emit InterfacesAdded/Removed
 * ---------------------------------------------------------------------------------------- */

static void
emit_interfaces_added (const char *path, const char *iface, GVariant *props)
{
  GVariantBuilder ifaces;
  g_variant_builder_init (&ifaces, G_VARIANT_TYPE ("a{sa{sv}}"));
  g_variant_builder_add (&ifaces, "{s@a{sv}}", iface, props);
  g_dbus_connection_emit_signal (g_conn, NULL, OM_ROOT,
                                 "org.freedesktop.DBus.ObjectManager", "InterfacesAdded",
                                 g_variant_new ("(o@a{sa{sv}})", path,
                                                g_variant_builder_end (&ifaces)), NULL);
}

static void
emit_interfaces_removed (const char *path, const char *iface)
{
  const char *ifs[] = { iface, NULL };
  g_dbus_connection_emit_signal (g_conn, NULL, OM_ROOT,
                                 "org.freedesktop.DBus.ObjectManager", "InterfacesRemoved",
                                 g_variant_new ("(o^as)", path, ifs), NULL);
}

/* Emit PropertiesChanged for one Device1 property. */
static void
device_emit_changed (XiosBTDeviceObj *o, const char *prop, GVariant *value)
{
  GVariantBuilder changed;
  g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&changed, "{sv}", prop, value);
  g_dbus_connection_emit_signal (g_conn, NULL, o->path,
                                 "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                 g_variant_new ("(sa{sv}@as)", "org.bluez.Device1", &changed,
                                                g_variant_new_strv (NULL, 0)), NULL);
}

static GDBusNodeInfo *device_node;  /* parsed once */

static void
register_device (id dev)
{
  NSString *a = [(id<XiosBTDevice>) dev address];
  if (!a) return;
  char addr[18];
  addr_canon ([a UTF8String], addr);
  if (g_hash_table_contains (g_devices, addr)) return;   /* already exported */

  XiosBTDeviceObj *o = g_new0 (XiosBTDeviceObj, 1);
  g_strlcpy (o->address, addr, sizeof o->address);
  addr_to_path (addr, o->path);
  o->dev = dev;
  g_dev_keepalive[[NSString stringWithUTF8String:addr]] = dev;  /* ARC keeps it alive */

  GError *err = NULL;
  o->reg_id = g_dbus_connection_register_object (g_conn, o->path,
                                                 device_node->interfaces[0], &device_vtable,
                                                 NULL, NULL, &err);
  if (o->reg_id == 0) {
    g_warning ("bluez stub: register device %s failed: %s", o->path,
               err ? err->message : "?");
    g_clear_error (&err);
    [g_dev_keepalive removeObjectForKey:[NSString stringWithUTF8String:addr]];
    g_free (o);
    return;
  }
  g_hash_table_insert (g_devices, g_strdup (addr), o);
  emit_interfaces_added (o->path, "org.bluez.Device1", device_props_dict (o));
  g_message ("bluez stub: + device %s (%s)", o->path,
             [[(id<XiosBTDevice>) dev name] UTF8String] ?: "?");
}

/* ------------------------------------------------------------------------------------------
 * Adapter1 vtable
 * ---------------------------------------------------------------------------------------- */

static void
adapter_method_call (GDBusConnection *c, const gchar *sender, const gchar *path,
                     const gchar *iface, const gchar *method, GVariant *params,
                     GDBusMethodInvocation *inv, gpointer user_data)
{
  (void) c; (void) sender; (void) path; (void) iface; (void) user_data;
  if (g_str_equal (method, "StartDiscovery")) {
    [g_bt setDeviceScanningEnabled:YES];
    g_dbus_method_invocation_return_value (inv, NULL);
  } else if (g_str_equal (method, "StopDiscovery")) {
    [g_bt setDeviceScanningEnabled:NO];
    g_dbus_method_invocation_return_value (inv, NULL);
  } else if (g_str_equal (method, "RemoveDevice")) {
    /* Best-effort: unpair the referenced device. */
    const char *dpath = NULL;
    g_variant_get (params, "(&o)", &dpath);
    XiosBTDeviceObj *o = dpath ? device_for_path (dpath) : NULL;
    if (o && [(id<XiosBTDevice>) o->dev respondsToSelector:@selector(unpair)])
      [(id<XiosBTDevice>) o->dev unpair];
    g_dbus_method_invocation_return_value (inv, NULL);
  } else {
    g_dbus_method_invocation_return_error (inv, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                           "Adapter1.%s unhandled", method);
  }
}

static GVariant *
adapter_get_property (GDBusConnection *c, const gchar *sender, const gchar *path,
                      const gchar *iface, const gchar *prop, GError **error, gpointer user_data)
{
  (void) c; (void) sender; (void) path; (void) iface; (void) user_data;
  if (g_str_equal (prop, "Address")) {
    NSString *hw = [g_bt respondsToSelector:@selector(hardwareAddress)] ? [g_bt hardwareAddress] : nil;
    char addr[18] = "00:00:00:00:00:00";
    if (hw) addr_canon ([hw UTF8String], addr);
    return g_variant_new_string (addr);
  }
  if (g_str_equal (prop, "Name") || g_str_equal (prop, "Alias"))
    return g_variant_new_string ("iPad");
  if (g_str_equal (prop, "Class"))        return g_variant_new_uint32 (0x0000010c); /* computer */
  if (g_str_equal (prop, "Powered"))      return g_variant_new_boolean ([g_bt powered]);
  if (g_str_equal (prop, "Discoverable")) return g_variant_new_boolean (FALSE);
  if (g_str_equal (prop, "Pairable"))     return g_variant_new_boolean (TRUE);
  if (g_str_equal (prop, "Discovering"))  return g_variant_new_boolean ([g_bt deviceScanningEnabled]);
  g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY, "Adapter1.%s", prop);
  return NULL;
}

static gboolean
adapter_set_property (GDBusConnection *c, const gchar *sender, const gchar *path,
                      const gchar *iface, const gchar *prop, GVariant *value,
                      GError **error, gpointer user_data)
{
  (void) c; (void) sender; (void) path; (void) iface; (void) error; (void) user_data;
  if (g_str_equal (prop, "Powered")) {
    gboolean on = g_variant_get_boolean (value);
    if ([g_bt respondsToSelector:@selector(setPowered:)]) [g_bt setPowered:on];
    else [g_bt setEnabled:on];
  } else if (g_str_equal (prop, "Discoverable") || g_str_equal (prop, "Pairable")
             || g_str_equal (prop, "Alias")) {
    /* no-ops on iOS */
  }
  return TRUE;
}

static const GDBusInterfaceVTable adapter_vtable = {
  .method_call = adapter_method_call,
  .get_property = adapter_get_property,
  .set_property = adapter_set_property,
};

/* Broadcast Adapter1 PropertiesChanged (Powered/Discovering). */
static void
adapter_emit_changed (const char *prop, GVariant *value)
{
  GVariantBuilder changed;
  g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&changed, "{sv}", prop, value);
  g_dbus_connection_emit_signal (g_conn, NULL, ADAPTER_PATH,
                                 "org.freedesktop.DBus.Properties", "PropertiesChanged",
                                 g_variant_new ("(sa{sv}@as)", "org.bluez.Adapter1", &changed,
                                                g_variant_new_strv (NULL, 0)), NULL);
}

/* ------------------------------------------------------------------------------------------
 * AgentManager1 vtable (accept agent registration so gnome-bluetooth is happy)
 * ---------------------------------------------------------------------------------------- */

static void
agentmgr_method_call (GDBusConnection *c, const gchar *sender, const gchar *path,
                      const gchar *iface, const gchar *method, GVariant *params,
                      GDBusMethodInvocation *inv, gpointer user_data)
{
  (void) c; (void) sender; (void) path; (void) iface; (void) params; (void) user_data;
  (void) method;
  /* RegisterAgent / UnregisterAgent / RequestDefaultAgent: accept as no-ops for now. Full
   * agent-driven pairing (PIN/passkey callbacks) is phase 2. */
  g_dbus_method_invocation_return_value (inv, NULL);
}

static const GDBusInterfaceVTable agentmgr_vtable = { .method_call = agentmgr_method_call };

/* ------------------------------------------------------------------------------------------
 * ObjectManager root vtable
 * ---------------------------------------------------------------------------------------- */

static void
add_object_to_managed (GVariantBuilder *objs, const char *path,
                       const char *iface, GVariant *props)
{
  GVariantBuilder ifaces;
  g_variant_builder_init (&ifaces, G_VARIANT_TYPE ("a{sa{sv}}"));
  g_variant_builder_add (&ifaces, "{s@a{sv}}", iface, props);
  g_variant_builder_add (objs, "{o@a{sa{sv}}}", path, g_variant_builder_end (&ifaces));
}

static void
om_method_call (GDBusConnection *c, const gchar *sender, const gchar *path,
                const gchar *iface, const gchar *method, GVariant *params,
                GDBusMethodInvocation *inv, gpointer user_data)
{
  (void) c; (void) sender; (void) path; (void) iface; (void) params; (void) user_data;
  if (!g_str_equal (method, "GetManagedObjects")) {
    g_dbus_method_invocation_return_error (inv, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_METHOD,
                                           "ObjectManager.%s", method);
    return;
  }
  GVariantBuilder objs;
  g_variant_builder_init (&objs, G_VARIANT_TYPE ("a{oa{sa{sv}}}"));
  add_object_to_managed (&objs, ADAPTER_PATH, "org.bluez.Adapter1", adapter_props_dict ());
  GHashTableIter it; gpointer k, v;
  g_hash_table_iter_init (&it, g_devices);
  while (g_hash_table_iter_next (&it, &k, &v)) {
    XiosBTDeviceObj *o = v;
    add_object_to_managed (&objs, o->path, "org.bluez.Device1", device_props_dict (o));
  }
  g_dbus_method_invocation_return_value (inv,
    g_variant_new ("(a{oa{sa{sv}}})", &objs));
}

static const GDBusInterfaceVTable om_vtable = { .method_call = om_method_call };

/* ------------------------------------------------------------------------------------------
 * BluetoothManager -> D-Bus sync
 * ---------------------------------------------------------------------------------------- */

/* Re-enumerate iOS devices, exporting any newly seen ones and refreshing tracked props. */
static void
sync_devices (void)
{
  if (!g_bt) return;
  NSMutableArray *all = [NSMutableArray array];
  if ([g_bt respondsToSelector:@selector(devices)])         [all addObjectsFromArray:[g_bt devices]];
  if ([g_bt respondsToSelector:@selector(pairedDevices)])   [all addObjectsFromArray:[g_bt pairedDevices]];
  if ([g_bt respondsToSelector:@selector(connectedDevices)])[all addObjectsFromArray:[g_bt connectedDevices]];
  for (id dev in all)
    register_device (dev);

  /* Refresh Connected/Paired on already-exported devices. */
  GHashTableIter it; gpointer k, v;
  g_hash_table_iter_init (&it, g_devices);
  while (g_hash_table_iter_next (&it, &k, &v)) {
    XiosBTDeviceObj *o = v;
    device_emit_changed (o, "Connected", g_variant_new_boolean ([(id<XiosBTDevice>) o->dev connected]));
    device_emit_changed (o, "Paired", g_variant_new_boolean ([(id<XiosBTDevice>) o->dev paired]));
  }
}

@interface XiosBTObserver : NSObject
@end
@implementation XiosBTObserver
- (void)powerChanged:(NSNotification *)n {
  (void) n;
  adapter_emit_changed ("Powered", g_variant_new_boolean ([g_bt powered]));
}
- (void)discoveryChanged:(NSNotification *)n {
  (void) n;
  adapter_emit_changed ("Discovering", g_variant_new_boolean ([g_bt deviceScanningEnabled]));
}
- (void)devicesChanged:(NSNotification *)n {
  (void) n;
  sync_devices ();
}
@end

static XiosBTObserver *g_observer;

/* Pump the CoreFoundation run loop from the GLib loop so BluetoothManager's XPC callbacks
 * (and thus our NSNotification handlers) run. 0-timeout, one pass, non-blocking. */
static gboolean
pump_cfrunloop (gpointer data)
{
  (void) data;
  @autoreleasepool {
    CFRunLoopRunInMode (kCFRunLoopDefaultMode, 0.0, true);
  }
  return G_SOURCE_CONTINUE;
}

/* Periodic reconcile (belt-and-suspenders on top of notifications). */
static gboolean
periodic_sync (gpointer data)
{
  (void) data;
  sync_devices ();
  return G_SOURCE_CONTINUE;
}

/* ------------------------------------------------------------------------------------------
 * Bring-up
 * ---------------------------------------------------------------------------------------- */

static gboolean
init_bluetooth_manager (void)
{
  /* Private framework: not in the SDK — dlopen the binary then message the class. */
  const char *fw =
    "/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager";
  void *h = dlopen (fw, RTLD_NOW | RTLD_GLOBAL);
  if (!h) { g_warning ("bluez stub: dlopen BluetoothManager failed: %s", dlerror ()); return FALSE; }

  Class BM = objc_getClass ("BluetoothManager");
  if (!BM) { g_warning ("bluez stub: class BluetoothManager not found"); return FALSE; }

  SEL shared = sel_registerName ("sharedInstance");
  if (![BM respondsToSelector:shared]) {
    g_warning ("bluez stub: BluetoothManager has no +sharedInstance"); return FALSE;
  }
  id mgr = ((id (*)(Class, SEL)) objc_msgSend) (BM, shared);
  if (!mgr) { g_warning ("bluez stub: +sharedInstance returned nil"); return FALSE; }
  g_bt = (id<XiosBTManager>) mgr;   /* ARC-strong global keeps the singleton alive */

  /* Subscribe to the state notifications on the default center. */
  g_observer = [[XiosBTObserver alloc] init];
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc addObserver:g_observer selector:@selector(powerChanged:) name:kBTPowerChanged object:nil];
  [nc addObserver:g_observer selector:@selector(powerChanged:) name:kBTAvailabilityChanged object:nil];
  [nc addObserver:g_observer selector:@selector(discoveryChanged:) name:kBTDiscoveryStateChg object:nil];
  [nc addObserver:g_observer selector:@selector(devicesChanged:) name:kBTDeviceDiscovered object:nil];
  [nc addObserver:g_observer selector:@selector(devicesChanged:) name:kBTDeviceRemoved object:nil];
  [nc addObserver:g_observer selector:@selector(devicesChanged:) name:kBTDeviceUpdated object:nil];
  [nc addObserver:g_observer selector:@selector(devicesChanged:) name:kBTDeviceConnectOK object:nil];
  [nc addObserver:g_observer selector:@selector(devicesChanged:) name:kBTDeviceDisconnectOK object:nil];

  g_message ("bluez stub: BluetoothManager up (powered=%d available=%d)",
             (int) [g_bt powered],
             [g_bt respondsToSelector:@selector(available)] ? (int) [g_bt available] : -1);
  return TRUE;
}

static void
on_bus_acquired (GDBusConnection *connection, const gchar *name, gpointer user_data)
{
  (void) name; (void) user_data;
  g_conn = connection;

  device_node = g_dbus_node_info_new_for_xml (device_xml, NULL);

  xios_stub_register_object (connection, OM_ROOT, om_xml, &om_vtable, "bluez stub");
  xios_stub_register_object (connection, ADAPTER_PATH, adapter_xml, &adapter_vtable, "bluez stub");
  xios_stub_register_object (connection, "/org/bluez", agentmgr_xml, &agentmgr_vtable, "bluez stub");

  /* First enumeration + the CF pump + a slow reconcile. */
  sync_devices ();
  g_timeout_add (100, pump_cfrunloop, NULL);
  g_timeout_add_seconds (5, periodic_sync, NULL);
}

int
main (int argc, char **argv)
{
  (void) argc; (void) argv;
  @autoreleasepool {
    g_devices = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
    g_dev_keepalive = [NSMutableDictionary dictionary];
    if (!init_bluetooth_manager ()) {
      g_warning ("bluez stub: BluetoothManager unavailable — exiting");
      return 1;
    }
    /* Owns org.bluez on the system bus (or session bus if XIOS_BLUEZ_BUS=session). */
    return xios_stub_run ("bluez stub", "XIOS_BLUEZ_BUS", BLUEZ_NAME, on_bus_acquired);
  }
}
