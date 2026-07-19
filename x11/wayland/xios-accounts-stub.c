/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-accounts-stub.c — a single-user org.freedesktop.Accounts bridge for Xios.
 *
 * libaccountsservice (which gnome-shell imports at boot) connects to org.freedesktop.Accounts
 * to learn the current user's name and icon for the system menu, lock screen and end-session
 * dialog. There is no accounts-daemon on iOS (it is Linux-only: utmp/crypt/shadow). Without a
 * provider the shell degrades to an empty user name; this bridge fills it in with the single
 * root user of the Xios session so the UI reads correctly.
 *
 * It exposes one user, resolved via xios_identity() (uid, username, display name, home,
 * avatar, locale — see xios-session-identity.c), as the Manager plus one User object.
 * The editable profile fields are persisted in a small key file and emit the
 * same D-Bus change notifications as accounts-daemon. Accounts is a SYSTEM-bus
 * service; under dbus-run-session point DBUS_SYSTEM_BUS_ADDRESS at the session bus (so
 * G_BUS_TYPE_SYSTEM meets us) or set XIOS_ACCOUNTS_BUS=session. Pure GLib/GIO. GPL-2.0+.
 */

#include <gio/gio.h>
#include <glib/gstdio.h>
#include <errno.h>
#include <unistd.h>

#include "xios-session-identity.h"
#include "xios-stub-dbus.h"

#define ACCOUNTS_NAME    "org.freedesktop.Accounts"
#define MANAGER_PATH     "/org/freedesktop/Accounts"
#define USER_IFACE       "org.freedesktop.Accounts.User"

#ifndef XIOS_ACCOUNTS_STATE_PATH
#define XIOS_ACCOUNTS_STATE_PATH "/var/jb/var/lib/xios/account.ini"
#endif

/* The single user we expose, filled from xios_identity() at startup (real uid, username,
 * display name, home, avatar, locale — see xios-session-identity.c). */
static char user_path[64];      /* /org/freedesktop/Accounts/User<uid> */
static guint64 user_uid;
static const char *user_name;
static char *user_real;
static const char *user_home;
static const char *user_shell;
static char *user_icon;
static char *user_lang;

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
  (void) interface_name; (void) user_data;

  if (g_str_equal (method_name, "FindUserByName"))
    {
      const char *requested;
      g_variant_get (parameters, "(&s)", &requested);
      if (g_str_equal (requested, user_name))
        g_dbus_method_invocation_return_value (invocation,
                                               g_variant_new ("(o)", user_path));
      else
        g_dbus_method_invocation_return_dbus_error (
          invocation, "org.freedesktop.Accounts.Error.Failed", "No such user");
    }
  else if (g_str_equal (method_name, "FindUserById"))
    {
      gint64 requested;
      g_variant_get (parameters, "(x)", &requested);
      if (requested >= 0 && (guint64) requested == user_uid)
        g_dbus_method_invocation_return_value (invocation,
                                               g_variant_new ("(o)", user_path));
      else
        g_dbus_method_invocation_return_dbus_error (
          invocation, "org.freedesktop.Accounts.Error.Failed", "No such user");
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
                                             "Accounts bridge: %s not implemented",
                                             method_name);
    }
}

static GVariant *
manager_get_property (GDBusConnection *c, const gchar *s, const gchar *o,
                      const gchar *i, const gchar *prop, GError **e, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;
  if (g_str_equal (prop, "DaemonVersion"))
    return g_variant_new_string ("xios-accounts-bridge-1");
  g_set_error (e, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
               "Accounts bridge: unknown property %s", prop);
  return NULL;
}

static gboolean
save_profile (GError **error)
{
  GKeyFile *key_file = g_key_file_new ();
  char *data;
  char *directory;
  gsize length;
  gboolean ok;

  g_key_file_set_string (key_file, "User", "RealName", user_real);
  g_key_file_set_string (key_file, "User", "IconFile", user_icon);
  g_key_file_set_string (key_file, "User", "Language", user_lang);
  data = g_key_file_to_data (key_file, &length, error);
  g_key_file_unref (key_file);
  if (!data)
    return FALSE;

  directory = g_path_get_dirname (XIOS_ACCOUNTS_STATE_PATH);
  if (g_mkdir_with_parents (directory, 0755) != 0)
    {
      g_set_error (error, G_FILE_ERROR, g_file_error_from_errno (errno),
                   "Could not create %s", directory);
      g_free (directory);
      g_free (data);
      return FALSE;
    }
  g_free (directory);

  ok = g_file_set_contents (XIOS_ACCOUNTS_STATE_PATH, data, (gssize) length, error);
  g_free (data);
  return ok;
}

static void
emit_user_changed (GDBusConnection *connection,
                   const char      *property,
                   GVariant        *value)
{
  GVariantBuilder changed;

  g_variant_builder_init (&changed, G_VARIANT_TYPE ("a{sv}"));
  g_variant_builder_add (&changed, "{sv}", property, value);
  g_dbus_connection_emit_signal (
    connection, NULL, user_path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
    g_variant_new ("(sa{sv}@as)", USER_IFACE, &changed, g_variant_new_strv (NULL, 0)), NULL);
  g_dbus_connection_emit_signal (connection, NULL, user_path, USER_IFACE, "Changed", NULL, NULL);
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
  const char *value;
  char **field;
  const char *property;
  GError *error = NULL;

  (void) sender; (void) object_path; (void) interface_name; (void) user_data;

  if (g_str_equal (method_name, "SetRealName"))
    { field = &user_real; property = "RealName"; }
  else if (g_str_equal (method_name, "SetIconFile"))
    { field = &user_icon; property = "IconFile"; }
  else if (g_str_equal (method_name, "SetLanguage"))
    { field = &user_lang; property = "Language"; }
  else
    {
      g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "Accounts bridge: %s not implemented",
                                             method_name);
      return;
    }

  g_variant_get (parameters, "(&s)", &value);
  if (g_str_equal (*field, value))
    {
      g_dbus_method_invocation_return_value (invocation, NULL);
      return;
    }

  char *replacement = g_strdup (value);
  if (!replacement)
    {
      g_dbus_method_invocation_return_error (invocation, G_IO_ERROR,
                                             G_IO_ERROR_NO_SPACE,
                                             "Could not allocate profile value");
      return;
    }

  char *previous = *field;
  *field = replacement;
  if (!save_profile (&error))
    {
      g_free (*field);
      *field = previous;
      g_dbus_method_invocation_return_gerror (invocation, error);
      g_clear_error (&error);
      return;
    }
  g_free (previous);
  emit_user_changed (connection, property, g_variant_new_string (*field));
  g_dbus_method_invocation_return_value (invocation, NULL);
}

static void
load_profile (void)
{
  GKeyFile *key_file = g_key_file_new ();
  GError *error = NULL;

  if (g_key_file_load_from_file (key_file, XIOS_ACCOUNTS_STATE_PATH,
                                 G_KEY_FILE_NONE, &error))
    {
      char *value;
      value = g_key_file_get_string (key_file, "User", "RealName", NULL);
      if (value) { g_free (user_real); user_real = value; }
      value = g_key_file_get_string (key_file, "User", "IconFile", NULL);
      if (value) { g_free (user_icon); user_icon = value; }
      value = g_key_file_get_string (key_file, "User", "Language", NULL);
      if (value) { g_free (user_lang); user_lang = value; }
    }
  else if (!g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT))
    g_warning ("accounts bridge: could not load %s: %s",
               XIOS_ACCOUNTS_STATE_PATH, error->message);
  g_clear_error (&error);
  g_key_file_unref (key_file);
}

static GVariant *
user_get_property (GDBusConnection *c, const gchar *s, const gchar *o,
                   const gchar *i, const gchar *prop, GError **e, gpointer u)
{
  (void) c; (void) s; (void) o; (void) i; (void) u;

  if (g_str_equal (prop, "Uid"))            return g_variant_new_uint64 (user_uid);
  if (g_str_equal (prop, "UserName"))       return g_variant_new_string (user_name);
  if (g_str_equal (prop, "RealName"))       return g_variant_new_string (user_real);
  if (g_str_equal (prop, "AccountType"))    return g_variant_new_int32 (1);   /* administrator */
  if (g_str_equal (prop, "HomeDirectory"))  return g_variant_new_string (user_home);
  if (g_str_equal (prop, "Shell"))          return g_variant_new_string (user_shell);
  if (g_str_equal (prop, "Email"))          return g_variant_new_string ("");
  if (g_str_equal (prop, "Language"))       return g_variant_new_string (user_lang);
  if (g_str_equal (prop, "Session"))        return g_variant_new_string ("xios");
  if (g_str_equal (prop, "IconFile"))       return g_variant_new_string (user_icon);
  if (g_str_equal (prop, "Locked"))         return g_variant_new_boolean (FALSE);
  if (g_str_equal (prop, "PasswordMode"))   return g_variant_new_int32 (0);
  if (g_str_equal (prop, "SystemAccount"))  return g_variant_new_boolean (FALSE);
  if (g_str_equal (prop, "LoginFrequency")) return g_variant_new_uint64 (1);
  if (g_str_equal (prop, "AutomaticLogin")) return g_variant_new_boolean (FALSE);
  g_set_error (e, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
               "Accounts bridge: unknown property %s", prop);
  return NULL;
}

static const GDBusInterfaceVTable manager_vtable = {
  .method_call = manager_method_call, .get_property = manager_get_property,
};
static const GDBusInterfaceVTable user_vtable = {
  .method_call = user_method_call, .get_property = user_get_property,
};

static void
on_bus_acquired (GDBusConnection *connection, const gchar *name, gpointer user_data)
{
  (void) name; (void) user_data;
  xios_stub_register_object (connection, MANAGER_PATH, manager_xml, &manager_vtable,
                             "accounts bridge");
  xios_stub_register_object (connection, user_path, user_xml, &user_vtable,
                             "accounts bridge");
}

int
main (int argc, char **argv)
{
  const XiosIdentity *id;

  (void) argc; (void) argv;

  /* The shared identity resolves username, display name (MobileGestalt device name), home,
   * avatar (~/.face), and locale once for all the session bridges. */
  id = xios_identity ();
  user_uid   = (guint64) id->uid;
  user_name  = id->username;
  user_real  = g_strdup (id->realname);
  user_home  = id->home;
  user_shell = id->shell;
  user_icon  = g_strdup (id->icon_file);
  user_lang  = g_strdup (id->language);
  load_profile ();
  g_snprintf (user_path, sizeof user_path, "/org/freedesktop/Accounts/User%llu",
              (unsigned long long) user_uid);

  return xios_stub_run ("accounts bridge", "XIOS_ACCOUNTS_BUS", ACCOUNTS_NAME,
                        on_bus_acquired);
}
