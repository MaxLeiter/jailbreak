/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-accounts-stub.c — a minimal org.freedesktop.Accounts for the iOS GNOME session.
 *
 * libaccountsservice (which gnome-shell imports at boot) connects to org.freedesktop.Accounts
 * to learn the current user's name and icon for the system menu, lock screen and end-session
 * dialog. There is no accounts-daemon on iOS (it is Linux-only: utmp/crypt/shadow). Without a
 * provider the shell degrades to an empty user name; this stub fills it in with the single
 * root user of the Xios session so the UI reads correctly.
 *
 * It exposes one user (uid = getuid(), name "mobile", real name "iOS User") as the Manager
 * plus one User object. Property setters are accepted and ignored. Accounts is a SYSTEM-bus
 * service; under dbus-run-session point DBUS_SYSTEM_BUS_ADDRESS at the session bus (so
 * G_BUS_TYPE_SYSTEM meets us) or set XIOS_ACCOUNTS_BUS=session. Pure GLib/GIO. GPL-2.0+.
 */

#include <gio/gio.h>
#include <unistd.h>
#include <pwd.h>

#define ACCOUNTS_NAME    "org.freedesktop.Accounts"
#define MANAGER_PATH     "/org/freedesktop/Accounts"
#define USER_IFACE       "org.freedesktop.Accounts.User"

static char user_path[64];      /* /org/freedesktop/Accounts/User<uid> */
static guint64 user_uid;
static const char *user_name = "mobile";
static const char *user_real = "iOS User";
static const char *user_home = "/var/mobile";
static const char *user_shell = "/bin/sh";

static const char manager_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.Accounts'>"
  "    <method name='FindUserByName'>"
  "      <arg type='s' name='name' direction='in'/>"
  "      <arg type='o' name='user' direction='out'/>"
  "    </method>"
  "    <method name='FindUserById'>"
  "      <arg type='x' name='id' direction='in'/>"
  "      <arg type='o' name='user' direction='out'/>"
  "    </method>"
  "    <method name='ListCachedUsers'>"
  "      <arg type='ao' name='users' direction='out'/>"
  "    </method>"
  "    <property name='DaemonVersion' type='s' access='read'/>"
  "    <signal name='UserAdded'><arg type='o' name='user'/></signal>"
  "    <signal name='UserDeleted'><arg type='o' name='user'/></signal>"
  "  </interface>"
  "</node>";

static const char user_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.Accounts.User'>"
  "    <method name='SetRealName'><arg type='s' name='name' direction='in'/></method>"
  "    <method name='SetIconFile'><arg type='s' name='filename' direction='in'/></method>"
  "    <method name='SetLanguage'><arg type='s' name='language' direction='in'/></method>"
  "    <property name='Uid' type='t' access='read'/>"
  "    <property name='UserName' type='s' access='read'/>"
  "    <property name='RealName' type='s' access='read'/>"
  "    <property name='AccountType' type='i' access='read'/>"
  "    <property name='HomeDirectory' type='s' access='read'/>"
  "    <property name='Shell' type='s' access='read'/>"
  "    <property name='Email' type='s' access='read'/>"
  "    <property name='Language' type='s' access='read'/>"
  "    <property name='Session' type='s' access='read'/>"
  "    <property name='IconFile' type='s' access='read'/>"
  "    <property name='Locked' type='b' access='read'/>"
  "    <property name='PasswordMode' type='i' access='read'/>"
  "    <property name='SystemAccount' type='b' access='read'/>"
  "    <property name='LoginFrequency' type='t' access='read'/>"
  "    <property name='AutomaticLogin' type='b' access='read'/>"
  "    <signal name='Changed'/>"
  "  </interface>"
  "</node>";

static void
manager_method_call (GDBusConnection       *connection,
                     const gchar           *sender,
                     const gchar           *object_path,
                     const gchar           *interface_name,
                     const gchar           *method_name,
                     GVariant              *parameters,
                     GDBusMethodInvocation *invocation,
                     gpointer               user_data)
{
  (void) connection; (void) sender; (void) object_path;
  (void) interface_name; (void) parameters; (void) user_data;

  if (g_str_equal (method_name, "FindUserByName") ||
      g_str_equal (method_name, "FindUserById"))
    {
      g_dbus_method_invocation_return_value (invocation,
                                             g_variant_new ("(o)", user_path));
    }
  else if (g_str_equal (method_name, "ListCachedUsers"))
    {
      GVariantBuilder b;

      g_variant_builder_init (&b, G_VARIANT_TYPE ("ao"));
      g_variant_builder_add (&b, "o", user_path);
      g_dbus_method_invocation_return_value (invocation, g_variant_new ("(ao)", &b));
    }
  else
    {
      g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "Accounts stub: %s not implemented",
                                             method_name);
    }
}

static GVariant *
manager_get_property (GDBusConnection *c, const gchar *s, const gchar *o,
                      const gchar *i, const gchar *prop, GError **e, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) e; (void) u;
  if (g_str_equal (prop, "DaemonVersion"))
    return g_variant_new_string ("xios-accounts-stub");
  return NULL;
}

static void
user_method_call (GDBusConnection       *connection,
                  const gchar           *sender,
                  const gchar           *object_path,
                  const gchar           *interface_name,
                  const gchar           *method_name,
                  GVariant              *parameters,
                  GDBusMethodInvocation *invocation,
                  gpointer               user_data)
{
  (void) connection; (void) sender; (void) object_path;
  (void) interface_name; (void) parameters; (void) method_name; (void) user_data;
  /* Accept and ignore all setters (SetRealName/SetIconFile/SetLanguage). */
  g_dbus_method_invocation_return_value (invocation, NULL);
}

static GVariant *
user_get_property (GDBusConnection *c, const gchar *s, const gchar *o,
                   const gchar *i, const gchar *prop, GError **e, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) e; (void) u;

  if (g_str_equal (prop, "Uid"))            return g_variant_new_uint64 (user_uid);
  if (g_str_equal (prop, "UserName"))       return g_variant_new_string (user_name);
  if (g_str_equal (prop, "RealName"))       return g_variant_new_string (user_real);
  if (g_str_equal (prop, "AccountType"))    return g_variant_new_int32 (1);   /* administrator */
  if (g_str_equal (prop, "HomeDirectory"))  return g_variant_new_string (user_home);
  if (g_str_equal (prop, "Shell"))          return g_variant_new_string (user_shell);
  if (g_str_equal (prop, "Email"))          return g_variant_new_string ("");
  if (g_str_equal (prop, "Language"))       return g_variant_new_string ("");
  if (g_str_equal (prop, "Session"))        return g_variant_new_string ("");
  if (g_str_equal (prop, "IconFile"))       return g_variant_new_string ("");
  if (g_str_equal (prop, "Locked"))         return g_variant_new_boolean (FALSE);
  if (g_str_equal (prop, "PasswordMode"))   return g_variant_new_int32 (0);
  if (g_str_equal (prop, "SystemAccount"))  return g_variant_new_boolean (FALSE);
  if (g_str_equal (prop, "LoginFrequency")) return g_variant_new_uint64 (1);
  if (g_str_equal (prop, "AutomaticLogin")) return g_variant_new_boolean (FALSE);
  return NULL;
}

static const GDBusInterfaceVTable manager_vtable = {
  .method_call = manager_method_call, .get_property = manager_get_property,
};
static const GDBusInterfaceVTable user_vtable = {
  .method_call = user_method_call, .get_property = user_get_property,
};

static gboolean
register_object (GDBusConnection *connection, const char *path, const char *xml,
                 const GDBusInterfaceVTable *vtable)
{
  GDBusNodeInfo *node;
  GError *error = NULL;
  guint id;

  node = g_dbus_node_info_new_for_xml (xml, &error);
  if (!node)
    {
      g_warning ("accounts stub: bad XML: %s", error->message);
      g_clear_error (&error);
      return FALSE;
    }
  id = g_dbus_connection_register_object (connection, path, node->interfaces[0],
                                          vtable, NULL, NULL, &error);
  g_dbus_node_info_unref (node);
  if (id == 0)
    {
      g_warning ("accounts stub: register %s failed: %s", path, error->message);
      g_clear_error (&error);
      return FALSE;
    }
  return TRUE;
}

static void
on_bus_acquired (GDBusConnection *connection, const gchar *name, gpointer user_data)
{
  (void) name; (void) user_data;
  register_object (connection, MANAGER_PATH, manager_xml, &manager_vtable);
  register_object (connection, user_path, user_xml, &user_vtable);
}

static void
on_name_acquired (GDBusConnection *connection, const gchar *name, gpointer user_data)
{
  (void) connection; (void) user_data;
  g_message ("accounts stub: owning %s (user %s)", name, user_name);
}

static void
on_name_lost (GDBusConnection *connection, const gchar *name, gpointer user_data)
{
  GMainLoop *loop = user_data;

  (void) connection;
  g_warning ("accounts stub: lost %s — exiting", name);
  g_main_loop_quit (loop);
}

int
main (int argc, char **argv)
{
  GMainLoop *loop;
  GBusType bus_type = G_BUS_TYPE_SYSTEM;
  const char *which;
  struct passwd *pw;
  guint owner_id;

  (void) argc; (void) argv;

  user_uid = (guint64) getuid ();
  g_snprintf (user_path, sizeof user_path, "/org/freedesktop/Accounts/User%llu",
              (unsigned long long) user_uid);
  /* Prefer the real passwd entry if there is one, else keep the Xios defaults. */
  pw = getpwuid ((uid_t) user_uid);
  if (pw)
    {
      if (pw->pw_name && *pw->pw_name)
        user_name = g_strdup (pw->pw_name);
      if (pw->pw_gecos && *pw->pw_gecos)
        user_real = g_strdup (pw->pw_gecos);
      if (pw->pw_dir && *pw->pw_dir)
        user_home = g_strdup (pw->pw_dir);
      if (pw->pw_shell && *pw->pw_shell)
        user_shell = g_strdup (pw->pw_shell);
    }

  which = g_getenv ("XIOS_ACCOUNTS_BUS");
  if (which && g_str_equal (which, "session"))
    bus_type = G_BUS_TYPE_SESSION;

  loop = g_main_loop_new (NULL, FALSE);
  owner_id = g_bus_own_name (bus_type, ACCOUNTS_NAME,
                             G_BUS_NAME_OWNER_FLAGS_NONE,
                             on_bus_acquired, on_name_acquired, on_name_lost,
                             loop, NULL);
  g_main_loop_run (loop);

  g_bus_unown_name (owner_id);
  g_main_loop_unref (loop);
  return 0;
}
