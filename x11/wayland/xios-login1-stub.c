/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-login1-stub.c — a minimal org.freedesktop.login1 for the iOS GNOME session.
 *
 * There is no logind on a jailbroken iPad, but gnome-session / gnome-settings-daemon (and,
 * to a lesser extent, Mutter itself) still talk to org.freedesktop.login1 over D-Bus for
 * idle/sleep inhibitors, the session Active/Locked hints, and screen-lock signalling. There
 * is no VT, seat, or DRM to manage — so this is a STUB, not elogind: it answers the handful
 * of Manager/Session/Seat calls those daemons actually make and holds no real power.
 *
 * See docs/mutter-on-iosc.md "The session / logind story" (Blocker #4). MetaBackendIOS's
 * own logind dependency is already removed (it takes over no devices); this covers the
 * remaining *session* need. Runs on the bus gsd looks at (the system bus by default; set
 * XIOS_LOGIN1_BUS=session to own it on the session bus under dbus-run-session).
 *
 * Pure GLib/GIO — no Mutter, no Wayland. GPL-2.0+.
 */

#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <glib-unix.h>

#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "xios-session-identity.h"

#define LOGIN1_NAME        "org.freedesktop.login1"
#define MANAGER_PATH       "/org/freedesktop/login1"
#define SESSION_ID         "1"
#define SESSION_PATH       "/org/freedesktop/login1/session/_31"
#define SEAT_ID            "seat0"
#define SEAT_PATH          "/org/freedesktop/login1/seat/seat0"

/* The real logged-in user, resolved once at startup from xios_identity(). logind forms a
 * user object path as a literal "_<uid>" (a uid needs no D-Bus path escaping). */
static guint32     user_uid;
static const char *user_name = "mobile";
static char        user_path[64];   /* /org/freedesktop/login1/user/_<uid> */

/* Only the members gnome-session / gsd / Mutter actually call. Clients invoke a subset;
 * anything unlisted returns org.freedesktop.DBus.Error.UnknownMethod, which those daemons
 * treat as "feature unavailable" and degrade past. */
static const char manager_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.login1.Manager'>"
  "    <method name='GetSession'>"
  "      <arg type='s' name='session_id' direction='in'/>"
  "      <arg type='o' name='object_path' direction='out'/>"
  "    </method>"
  "    <method name='GetSessionByPID'>"
  "      <arg type='u' name='pid' direction='in'/>"
  "      <arg type='o' name='object_path' direction='out'/>"
  "    </method>"
  "    <method name='GetUser'>"
  "      <arg type='u' name='uid' direction='in'/>"
  "      <arg type='o' name='object_path' direction='out'/>"
  "    </method>"
  "    <method name='GetSeat'>"
  "      <arg type='s' name='seat_id' direction='in'/>"
  "      <arg type='o' name='object_path' direction='out'/>"
  "    </method>"
  "    <method name='ListSessions'>"
  "      <arg type='a(susso)' name='sessions' direction='out'/>"
  "    </method>"
  "    <method name='Inhibit'>"
  "      <arg type='s' name='what' direction='in'/>"
  "      <arg type='s' name='who' direction='in'/>"
  "      <arg type='s' name='why' direction='in'/>"
  "      <arg type='s' name='mode' direction='in'/>"
  "      <arg type='h' name='fd' direction='out'/>"
  "    </method>"
  "    <method name='CanPowerOff'><arg type='s' name='result' direction='out'/></method>"
  "    <method name='CanReboot'><arg type='s' name='result' direction='out'/></method>"
  "    <method name='CanSuspend'><arg type='s' name='result' direction='out'/></method>"
  "    <method name='PowerOff'><arg type='b' name='interactive' direction='in'/></method>"
  "    <method name='Reboot'><arg type='b' name='interactive' direction='in'/></method>"
  "    <method name='Suspend'><arg type='b' name='interactive' direction='in'/></method>"
  "    <signal name='PrepareForSleep'><arg type='b' name='start'/></signal>"
  "    <signal name='PrepareForShutdown'><arg type='b' name='start'/></signal>"
  "    <signal name='SessionNew'>"
  "      <arg type='s' name='session_id'/><arg type='o' name='object_path'/>"
  "    </signal>"
  "    <signal name='SessionRemoved'>"
  "      <arg type='s' name='session_id'/><arg type='o' name='object_path'/>"
  "    </signal>"
  "  </interface>"
  "</node>";

static const char session_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.login1.Session'>"
  "    <method name='Activate'/>"
  "    <method name='Lock'/>"
  "    <method name='Unlock'/>"
  "    <method name='Terminate'/>"
  "    <method name='SetIdleHint'><arg type='b' name='idle' direction='in'/></method>"
  "    <method name='SetLockedHint'><arg type='b' name='locked' direction='in'/></method>"
  "    <method name='TakeControl'><arg type='b' name='force' direction='in'/></method>"
  "    <method name='ReleaseControl'/>"
  "    <property name='Id' type='s' access='read'/>"
  "    <property name='Name' type='s' access='read'/>"
  "    <property name='User' type='(uo)' access='read'/>"
  "    <property name='Seat' type='(so)' access='read'/>"
  "    <property name='VTNr' type='u' access='read'/>"
  "    <property name='Type' type='s' access='read'/>"
  "    <property name='Class' type='s' access='read'/>"
  "    <property name='Remote' type='b' access='read'/>"
  "    <property name='Active' type='b' access='read'/>"
  "    <property name='State' type='s' access='read'/>"
  "    <property name='IdleHint' type='b' access='read'/>"
  "    <property name='LockedHint' type='b' access='read'/>"
  "    <signal name='Lock'/>"
  "    <signal name='Unlock'/>"
  "  </interface>"
  "</node>";

static const char user_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.login1.User'>"
  "    <method name='Terminate'/>"
  "    <method name='Kill'><arg type='i' name='signal_number' direction='in'/></method>"
  "    <property name='UID' type='u' access='read'/>"
  "    <property name='GID' type='u' access='read'/>"
  "    <property name='Name' type='s' access='read'/>"
  "    <property name='RuntimePath' type='s' access='read'/>"
  "    <property name='State' type='s' access='read'/>"
  "    <property name='Display' type='(so)' access='read'/>"
  "    <property name='Sessions' type='a(so)' access='read'/>"
  "    <property name='IdleHint' type='b' access='read'/>"
  "    <property name='Linger' type='b' access='read'/>"
  "  </interface>"
  "</node>";

static const char seat_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.login1.Seat'>"
  "    <method name='ActivateSession'><arg type='s' name='session_id' direction='in'/></method>"
  "    <property name='Id' type='s' access='read'/>"
  "    <property name='ActiveSession' type='(so)' access='read'/>"
  "    <property name='CanGraphical' type='b' access='read'/>"
  "    <property name='CanTTY' type='b' access='read'/>"
  "    <property name='Sessions' type='a(so)' access='read'/>"
  "  </interface>"
  "</node>";

/* The stub's mutable session state (what SetIdleHint/SetLockedHint touch). */
static gboolean session_idle_hint = FALSE;
static gboolean session_locked_hint = FALSE;

/* Inhibitor cleanup: the client holds one end of the inhibitor pipe and releases the lock
 * by closing it (or by dying), which raises POLLHUP on our retained end. Close it and drop
 * the watch so nothing leaks across the many idle/lock inhibitors a session takes. */
static gboolean
inhibitor_hangup (gint fd, GIOCondition condition, gpointer user_data)
{
  (void) condition;
  (void) user_data;
  close (fd);
  return G_SOURCE_REMOVE;
}

/* ---- org.freedesktop.login1.Manager ------------------------------------------------- */

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
  if (g_str_equal (method_name, "GetSessionByPID") ||
      g_str_equal (method_name, "GetSession"))
    {
      g_dbus_method_invocation_return_value (invocation,
                                             g_variant_new ("(o)", SESSION_PATH));
    }
  else if (g_str_equal (method_name, "GetSeat"))
    {
      g_dbus_method_invocation_return_value (invocation,
                                             g_variant_new ("(o)", SEAT_PATH));
    }
  else if (g_str_equal (method_name, "GetUser"))
    {
      g_dbus_method_invocation_return_value (invocation,
                                             g_variant_new ("(o)", user_path));
    }
  else if (g_str_equal (method_name, "ListSessions"))
    {
      GVariantBuilder b;

      g_variant_builder_init (&b, G_VARIANT_TYPE ("a(susso)"));
      g_variant_builder_add (&b, "(susso)", SESSION_ID, user_uid, user_name,
                             SEAT_ID, SESSION_PATH);
      g_dbus_method_invocation_return_value (invocation,
                                             g_variant_new ("(a(susso))", &b));
    }
  else if (g_str_equal (method_name, "Inhibit"))
    {
      /* Hand the client the write end of a pipe; it holds it for the lifetime of the lock
       * and releases by closing it (or by exiting). We keep the read end and watch it for
       * POLLHUP so the retained fd is reclaimed on release — no per-inhibitor leak. We never
       * act on inhibitors; this just satisfies the API gsd-power / gnome-session use for
       * idle/sleep/shutdown locks. */
      GUnixFDList *fd_list;
      GError *error = NULL;
      int pipefd[2];
      int idx;

      if (pipe (pipefd) != 0)
        {
          g_dbus_method_invocation_return_error (invocation, G_IO_ERROR,
                                                 G_IO_ERROR_FAILED,
                                                 "pipe() failed for inhibitor");
          return;
        }
      (void) fcntl (pipefd[0], F_SETFD, FD_CLOEXEC);
      (void) fcntl (pipefd[1], F_SETFD, FD_CLOEXEC);

      fd_list = g_unix_fd_list_new ();
      idx = g_unix_fd_list_append (fd_list, pipefd[1], &error);
      close (pipefd[1]);   /* the fd list dup'd the client's write end */

      if (idx < 0)
        {
          close (pipefd[0]);
          g_object_unref (fd_list);
          g_dbus_method_invocation_return_gerror (invocation, error);
          g_clear_error (&error);
          return;
        }

      /* Reclaim our read end when the client drops its write end. */
      g_unix_fd_add (pipefd[0], G_IO_HUP | G_IO_ERR, inhibitor_hangup, NULL);

      g_dbus_method_invocation_return_value_with_unix_fd_list (
        invocation, g_variant_new ("(h)", idx), fd_list);
      g_object_unref (fd_list);
    }
  else if (g_str_has_prefix (method_name, "Can"))
    {
      /* CanPowerOff / CanReboot / CanSuspend: advertise "no" (single-user jailbreak, no
       * real power management), which gsd-power reads as "hide those menu items". */
      g_dbus_method_invocation_return_value (invocation, g_variant_new ("(s)", "no"));
    }
  else if (g_str_equal (method_name, "PowerOff") ||
           g_str_equal (method_name, "Reboot") ||
           g_str_equal (method_name, "Suspend"))
    {
      /* Accept and ignore — we do not drive the hardware. */
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else
    {
      g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "login1 stub: unhandled Manager.%s",
                                             method_name);
    }
}

/* ---- org.freedesktop.login1.Session ------------------------------------------------- */

static void
session_method_call (GDBusConnection       *connection,
                     const gchar           *sender,
                     const gchar           *object_path,
                     const gchar           *interface_name,
                     const gchar           *method_name,
                     GVariant              *parameters,
                     GDBusMethodInvocation *invocation,
                     gpointer               user_data)
{
  if (g_str_equal (method_name, "SetIdleHint"))
    g_variant_get (parameters, "(b)", &session_idle_hint);
  else if (g_str_equal (method_name, "SetLockedHint"))
    g_variant_get (parameters, "(b)", &session_locked_hint);

  /* Activate / Lock / Unlock / Terminate / TakeControl / ReleaseControl / the two hints:
   * all accepted as no-ops (there is no VT to switch, no device to lease). */
  if (g_str_equal (method_name, "Activate") ||
      g_str_equal (method_name, "Lock") ||
      g_str_equal (method_name, "Unlock") ||
      g_str_equal (method_name, "Terminate") ||
      g_str_equal (method_name, "TakeControl") ||
      g_str_equal (method_name, "ReleaseControl") ||
      g_str_equal (method_name, "SetIdleHint") ||
      g_str_equal (method_name, "SetLockedHint"))
    {
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else
    {
      g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "login1 stub: unhandled Session.%s",
                                             method_name);
    }
}

static GVariant *
session_get_property (GDBusConnection *connection,
                      const gchar     *sender,
                      const gchar     *object_path,
                      const gchar     *interface_name,
                      const gchar     *property_name,
                      GError         **error,
                      gpointer         user_data)
{
  if (g_str_equal (property_name, "Id"))
    return g_variant_new_string (SESSION_ID);
  if (g_str_equal (property_name, "Name"))
    return g_variant_new_string (user_name);
  if (g_str_equal (property_name, "User"))
    return g_variant_new ("(uo)", user_uid, user_path);
  if (g_str_equal (property_name, "Seat"))
    return g_variant_new ("(so)", SEAT_ID, SEAT_PATH);
  if (g_str_equal (property_name, "VTNr"))
    return g_variant_new_uint32 (0);
  if (g_str_equal (property_name, "Type"))
    return g_variant_new_string ("wayland");
  if (g_str_equal (property_name, "Class"))
    return g_variant_new_string ("user");
  if (g_str_equal (property_name, "Remote"))
    return g_variant_new_boolean (FALSE);
  if (g_str_equal (property_name, "Active"))
    return g_variant_new_boolean (TRUE);
  if (g_str_equal (property_name, "State"))
    return g_variant_new_string ("active");
  if (g_str_equal (property_name, "IdleHint"))
    return g_variant_new_boolean (session_idle_hint);
  if (g_str_equal (property_name, "LockedHint"))
    return g_variant_new_boolean (session_locked_hint);

  g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
               "login1 stub: unknown Session property %s", property_name);
  return NULL;
}

/* ---- org.freedesktop.login1.Seat ---------------------------------------------------- */

static void
seat_method_call (GDBusConnection       *connection,
                  const gchar           *sender,
                  const gchar           *object_path,
                  const gchar           *interface_name,
                  const gchar           *method_name,
                  GVariant              *parameters,
                  GDBusMethodInvocation *invocation,
                  gpointer               user_data)
{
  if (g_str_equal (method_name, "ActivateSession"))
    {
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else
    {
      g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "login1 stub: unhandled Seat.%s",
                                             method_name);
    }
}

static GVariant *
seat_get_property (GDBusConnection *connection,
                   const gchar     *sender,
                   const gchar     *object_path,
                   const gchar     *interface_name,
                   const gchar     *property_name,
                   GError         **error,
                   gpointer         user_data)
{
  if (g_str_equal (property_name, "Id"))
    return g_variant_new_string (SEAT_ID);
  if (g_str_equal (property_name, "ActiveSession"))
    return g_variant_new ("(so)", SESSION_ID, SESSION_PATH);
  if (g_str_equal (property_name, "CanGraphical"))
    return g_variant_new_boolean (TRUE);
  if (g_str_equal (property_name, "CanTTY"))
    return g_variant_new_boolean (FALSE);
  if (g_str_equal (property_name, "Sessions"))
    {
      GVariantBuilder b;

      g_variant_builder_init (&b, G_VARIANT_TYPE ("a(so)"));
      g_variant_builder_add (&b, "(so)", SESSION_ID, SESSION_PATH);
      return g_variant_new ("a(so)", &b);
    }

  g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
               "login1 stub: unknown Seat property %s", property_name);
  return NULL;
}

/* ---- org.freedesktop.login1.User ---------------------------------------------------- */

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
  /* Terminate / Kill: accepted as no-ops (we do not manage the user's processes). */
  if (g_str_equal (method_name, "Terminate") ||
      g_str_equal (method_name, "Kill"))
    {
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else
    {
      g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "login1 stub: unhandled User.%s",
                                             method_name);
    }
}

static GVariant *
user_get_property (GDBusConnection *connection,
                   const gchar     *sender,
                   const gchar     *object_path,
                   const gchar     *interface_name,
                   const gchar     *property_name,
                   GError         **error,
                   gpointer         user_data)
{
  if (g_str_equal (property_name, "UID"))
    return g_variant_new_uint32 (user_uid);
  if (g_str_equal (property_name, "GID"))
    return g_variant_new_uint32 (user_uid);   /* single-user: gid tracks uid */
  if (g_str_equal (property_name, "Name"))
    return g_variant_new_string (user_name);
  if (g_str_equal (property_name, "RuntimePath"))
    {
      const char *rd = g_getenv ("XDG_RUNTIME_DIR");
      return g_variant_new_string (rd && *rd ? rd : "/var/jb/tmp/xios-run");
    }
  if (g_str_equal (property_name, "State"))
    return g_variant_new_string ("active");
  if (g_str_equal (property_name, "Display"))
    return g_variant_new ("(so)", SESSION_ID, SESSION_PATH);
  if (g_str_equal (property_name, "Sessions"))
    {
      GVariantBuilder b;

      g_variant_builder_init (&b, G_VARIANT_TYPE ("a(so)"));
      g_variant_builder_add (&b, "(so)", SESSION_ID, SESSION_PATH);
      return g_variant_new ("a(so)", &b);
    }
  if (g_str_equal (property_name, "IdleHint"))
    return g_variant_new_boolean (session_idle_hint);
  if (g_str_equal (property_name, "Linger"))
    return g_variant_new_boolean (FALSE);

  g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
               "login1 stub: unknown User property %s", property_name);
  return NULL;
}

/* ---- registration ------------------------------------------------------------------- */

static const GDBusInterfaceVTable manager_vtable = {
  .method_call = manager_method_call,
};
static const GDBusInterfaceVTable session_vtable = {
  .method_call = session_method_call,
  .get_property = session_get_property,
};
static const GDBusInterfaceVTable seat_vtable = {
  .method_call = seat_method_call,
  .get_property = seat_get_property,
};
static const GDBusInterfaceVTable user_vtable = {
  .method_call = user_method_call,
  .get_property = user_get_property,
};

static gboolean
register_object (GDBusConnection              *connection,
                 const char                   *path,
                 const char                   *xml,
                 const GDBusInterfaceVTable   *vtable)
{
  GDBusNodeInfo *node;
  GError *error = NULL;
  guint id;

  node = g_dbus_node_info_new_for_xml (xml, &error);
  if (!node)
    {
      g_warning ("login1 stub: bad introspection XML: %s", error->message);
      g_clear_error (&error);
      return FALSE;
    }

  id = g_dbus_connection_register_object (connection, path, node->interfaces[0],
                                          vtable, NULL, NULL, &error);
  g_dbus_node_info_unref (node);

  if (id == 0)
    {
      g_warning ("login1 stub: failed to register %s: %s", path, error->message);
      g_clear_error (&error);
      return FALSE;
    }

  return TRUE;
}

static void
on_bus_acquired (GDBusConnection *connection,
                 const gchar     *name,
                 gpointer         user_data)
{
  register_object (connection, MANAGER_PATH, manager_xml, &manager_vtable);
  register_object (connection, SESSION_PATH, session_xml, &session_vtable);
  register_object (connection, SEAT_PATH, seat_xml, &seat_vtable);
  register_object (connection, user_path, user_xml, &user_vtable);
}

static void
on_name_acquired (GDBusConnection *connection,
                  const gchar     *name,
                  gpointer         user_data)
{
  g_message ("login1 stub: owning %s", name);
}

static void
on_name_lost (GDBusConnection *connection,
              const gchar     *name,
              gpointer         user_data)
{
  GMainLoop *loop = user_data;

  g_warning ("login1 stub: lost %s (real logind present, or bus gone) — exiting", name);
  g_main_loop_quit (loop);
}

int
main (int argc, char **argv)
{
  GMainLoop *loop;
  GBusType bus_type = G_BUS_TYPE_SYSTEM;
  const char *which;
  const XiosIdentity *id;
  guint owner_id;

  (void) argc;
  (void) argv;

  /* Resolve the real logged-in user once, and form its logind object path. */
  id = xios_identity ();
  user_uid = (guint32) id->uid;
  user_name = id->username;
  g_snprintf (user_path, sizeof user_path,
              "/org/freedesktop/login1/user/_%u", user_uid);

  /* logind normally lives on the system bus; allow the session bus for a
   * dbus-run-session bring-up where there is no system bus. */
  which = g_getenv ("XIOS_LOGIN1_BUS");
  if (which && g_str_equal (which, "session"))
    bus_type = G_BUS_TYPE_SESSION;

  loop = g_main_loop_new (NULL, FALSE);

  owner_id = g_bus_own_name (bus_type, LOGIN1_NAME,
                             G_BUS_NAME_OWNER_FLAGS_NONE,
                             on_bus_acquired, on_name_acquired, on_name_lost,
                             loop, NULL);

  g_main_loop_run (loop);

  g_bus_unown_name (owner_id);
  g_main_loop_unref (loop);
  return 0;
}
