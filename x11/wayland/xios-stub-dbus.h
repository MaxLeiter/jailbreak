/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-stub-dbus.h — the D-Bus scaffold shared by the Xios session stub daemons (login1,
 * Accounts, PolicyKit1): register an object from inline introspection XML, and the own-name
 * main loop each stub's main() runs. One implementation instead of three drifting copies.
 *
 * GPL-2.0+.
 */
#ifndef XIOS_STUB_DBUS_H
#define XIOS_STUB_DBUS_H

#include <gio/gio.h>

/* Parse one-interface introspection XML and register it at path. Warnings are logged with
 * the stub's logname prefix; returns FALSE on bad XML or registration failure. */
gboolean xios_stub_register_object (GDBusConnection            *connection,
                                    const char                 *path,
                                    const char                 *xml,
                                    const GDBusInterfaceVTable *vtable,
                                    const char                 *logname);

/* Own bus_name and run the main loop until the name is lost (a real daemon appeared, or the
 * bus went away). The bus is the system bus unless the env var named by bus_env_var is set
 * to "session" (the dbus-run-session bring-up, where there is no system bus). One stub per
 * process, single main loop — call once from main() and return its result. */
int xios_stub_run (const char          *logname,
                   const char          *bus_env_var,
                   const char          *bus_name,
                   GBusAcquiredCallback on_bus_acquired);

#endif /* XIOS_STUB_DBUS_H */
