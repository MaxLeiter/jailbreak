/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-stub-dbus.c — see xios-stub-dbus.h. Pure GLib/GIO. GPL-2.0+.
 */

#include "xios-stub-dbus.h"

/* The running stub's log prefix, set once by xios_stub_run (one stub per process, single
 * main loop — same singleton justification as xios_identity). */
static const char *stub_logname;

gboolean
xios_stub_register_object (GDBusConnection            *connection,
                           const char                 *path,
                           const char                 *xml,
                           const GDBusInterfaceVTable *vtable,
                           const char                 *logname)
{
  GDBusNodeInfo *node;
  GError *error = NULL;
  guint id;

  node = g_dbus_node_info_new_for_xml (xml, &error);
  if (!node)
    {
      g_warning ("%s: bad introspection XML: %s", logname, error->message);
      g_clear_error (&error);
      return FALSE;
    }

  id = g_dbus_connection_register_object (connection, path, node->interfaces[0],
                                          vtable, NULL, NULL, &error);
  g_dbus_node_info_unref (node);

  if (id == 0)
    {
      g_warning ("%s: failed to register %s: %s", logname, path, error->message);
      g_clear_error (&error);
      return FALSE;
    }

  return TRUE;
}

static void
on_name_acquired (GDBusConnection *connection,
                  const gchar     *name,
                  gpointer         user_data)
{
  (void) connection; (void) user_data;
  g_message ("%s: owning %s", stub_logname, name);
}

static void
on_name_lost (GDBusConnection *connection,
              const gchar     *name,
              gpointer         user_data)
{
  GMainLoop *loop = user_data;

  (void) connection;
  g_warning ("%s: lost %s (real daemon present, or bus gone) — exiting",
             stub_logname, name);
  g_main_loop_quit (loop);
}

int
xios_stub_run (const char          *logname,
               const char          *bus_env_var,
               const char          *bus_name,
               GBusAcquiredCallback on_bus_acquired)
{
  GMainLoop *loop;
  GBusType bus_type = G_BUS_TYPE_SYSTEM;
  const char *which;
  guint owner_id;

  stub_logname = logname;

  /* These daemons normally live on the system bus; allow the session bus for a
   * dbus-run-session bring-up where there is no system bus. */
  which = g_getenv (bus_env_var);
  if (which && g_str_equal (which, "session"))
    bus_type = G_BUS_TYPE_SESSION;

  loop = g_main_loop_new (NULL, FALSE);

  owner_id = g_bus_own_name (bus_type, bus_name,
                             G_BUS_NAME_OWNER_FLAGS_NONE,
                             on_bus_acquired, on_name_acquired, on_name_lost,
                             loop, NULL);

  g_main_loop_run (loop);

  g_bus_unown_name (owner_id);
  g_main_loop_unref (loop);
  return 0;
}
