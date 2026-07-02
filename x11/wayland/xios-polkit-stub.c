/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-polkit-stub.c — a minimal org.freedesktop.PolicyKit1 Authority for the iOS GNOME
 * session.
 *
 * There is no polkitd on a jailbroken iPad, but gnome-shell's polkit agent
 * (Shell.PolkitAuthenticationAgent, via libpolkit-agent) registers with the Authority at
 * startup, and GNOME apps call CheckAuthorization before privileged operations. Without an
 * Authority the shell logs "Failed to register AuthenticationAgent" and privileged actions
 * hang waiting on a dialog that never comes.
 *
 * The iPad session is a single root user, so this Authority AUTO-ALLOWS: CheckAuthorization
 * always returns authorized, agent registration is accepted (and ignored, since nothing is
 * ever challenged), and the action/temp-authorization enumerations are empty. It holds no
 * real policy — it exists so the polkit clients find a service and proceed.
 *
 * polkitd normally lives on the SYSTEM bus. Under a dbus-run-session bring-up there is only
 * a session bus; point DBUS_SYSTEM_BUS_ADDRESS at it (so G_BUS_TYPE_SYSTEM resolves there
 * for both this stub and its clients) or set XIOS_POLKIT_BUS=session to own it on the
 * session bus directly. Pure GLib/GIO. GPL-2.0+.
 */

#include <gio/gio.h>

#include "xios-stub-dbus.h"

#define POLKIT_NAME  "org.freedesktop.PolicyKit1"
#define AUTH_PATH    "/org/freedesktop/PolicyKit1/Authority"
#define AUTH_IFACE   "org.freedesktop.PolicyKit1.Authority"

/* Only the members libpolkit-gobject / libpolkit-agent and GNOME clients actually call.
 * CheckAuthorization result is (bba{ss}) = (is_authorized, is_challenge, details). */
static const char authority_xml[] =
  "<node>"
  "  <interface name='org.freedesktop.PolicyKit1.Authority'>"
  "    <method name='EnumerateActions'>"
  "      <arg type='s' name='locale' direction='in'/>"
  "      <arg type='a(ssssssuuua{ss})' name='action_descriptions' direction='out'/>"
  "    </method>"
  "    <method name='CheckAuthorization'>"
  "      <arg type='(sa{sv})' name='subject' direction='in'/>"
  "      <arg type='s' name='action_id' direction='in'/>"
  "      <arg type='a{ss}' name='details' direction='in'/>"
  "      <arg type='u' name='flags' direction='in'/>"
  "      <arg type='s' name='cancellation_id' direction='in'/>"
  "      <arg type='(bba{ss})' name='result' direction='out'/>"
  "    </method>"
  "    <method name='CancelCheckAuthorization'>"
  "      <arg type='s' name='cancellation_id' direction='in'/>"
  "    </method>"
  "    <method name='RegisterAuthenticationAgent'>"
  "      <arg type='(sa{sv})' name='subject' direction='in'/>"
  "      <arg type='s' name='locale' direction='in'/>"
  "      <arg type='s' name='object_path' direction='in'/>"
  "    </method>"
  "    <method name='RegisterAuthenticationAgentWithOptions'>"
  "      <arg type='(sa{sv})' name='subject' direction='in'/>"
  "      <arg type='s' name='locale' direction='in'/>"
  "      <arg type='s' name='object_path' direction='in'/>"
  "      <arg type='a{sv}' name='options' direction='in'/>"
  "    </method>"
  "    <method name='UnregisterAuthenticationAgent'>"
  "      <arg type='(sa{sv})' name='subject' direction='in'/>"
  "      <arg type='s' name='object_path' direction='in'/>"
  "    </method>"
  "    <method name='AuthenticationAgentResponse2'>"
  "      <arg type='u' name='uid' direction='in'/>"
  "      <arg type='s' name='cookie' direction='in'/>"
  "      <arg type='(sa{sv})' name='identity' direction='in'/>"
  "    </method>"
  "    <method name='EnumerateTemporaryAuthorizations'>"
  "      <arg type='(sa{sv})' name='subject' direction='in'/>"
  "      <arg type='a(ss(sa{sv})tt)' name='temporary_authorizations' direction='out'/>"
  "    </method>"
  "    <method name='RevokeTemporaryAuthorizations'>"
  "      <arg type='(sa{sv})' name='subject' direction='in'/>"
  "    </method>"
  "    <method name='RevokeTemporaryAuthorizationById'>"
  "      <arg type='s' name='id' direction='in'/>"
  "    </method>"
  "    <property name='BackendName' type='s' access='read'/>"
  "    <property name='BackendVersion' type='s' access='read'/>"
  "    <property name='BackendFeatures' type='u' access='read'/>"
  "    <signal name='Changed'/>"
  "  </interface>"
  "</node>";

static void
authority_method_call (GDBusConnection       *connection,
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

  if (g_str_equal (method_name, "CheckAuthorization"))
    {
      /* Single-user root: always authorized, never a challenge, no details. */
      GVariantBuilder details;

      g_variant_builder_init (&details, G_VARIANT_TYPE ("a{ss}"));
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("((bba{ss}))", TRUE, FALSE, &details));
    }
  else if (g_str_equal (method_name, "EnumerateActions"))
    {
      GVariantBuilder b;

      g_variant_builder_init (&b, G_VARIANT_TYPE ("a(ssssssuuua{ss})"));
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(a(ssssssuuua{ss}))", &b));
    }
  else if (g_str_equal (method_name, "EnumerateTemporaryAuthorizations"))
    {
      GVariantBuilder b;

      g_variant_builder_init (&b, G_VARIANT_TYPE ("a(ss(sa{sv})tt)"));
      g_dbus_method_invocation_return_value (
        invocation, g_variant_new ("(a(ss(sa{sv})tt))", &b));
    }
  else if (g_str_equal (method_name, "RegisterAuthenticationAgent") ||
           g_str_equal (method_name, "RegisterAuthenticationAgentWithOptions") ||
           g_str_equal (method_name, "UnregisterAuthenticationAgent") ||
           g_str_equal (method_name, "CancelCheckAuthorization") ||
           g_str_equal (method_name, "AuthenticationAgentResponse2") ||
           g_str_equal (method_name, "RevokeTemporaryAuthorizations") ||
           g_str_equal (method_name, "RevokeTemporaryAuthorizationById"))
    {
      /* Accept and ignore: nothing is ever challenged, so agents are never invoked. */
      g_dbus_method_invocation_return_value (invocation, NULL);
    }
  else
    {
      g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
                                             G_DBUS_ERROR_UNKNOWN_METHOD,
                                             "PolicyKit1 stub: %s not implemented",
                                             method_name);
    }
}

static GVariant *
authority_get_property (GDBusConnection *connection,
                        const gchar     *sender,
                        const gchar     *object_path,
                        const gchar     *interface_name,
                        const gchar     *property_name,
                        GError         **error,
                        gpointer         user_data)
{
  (void) connection; (void) sender; (void) object_path;
  (void) interface_name; (void) user_data;

  if (g_str_equal (property_name, "BackendName"))
    return g_variant_new_string ("xios-polkit-stub");
  if (g_str_equal (property_name, "BackendVersion"))
    return g_variant_new_string ("1");
  if (g_str_equal (property_name, "BackendFeatures"))
    return g_variant_new_uint32 (0);
  g_set_error (error, G_DBUS_ERROR, G_DBUS_ERROR_UNKNOWN_PROPERTY,
               "PolicyKit1 stub: unknown property %s", property_name);
  return NULL;
}

static const GDBusInterfaceVTable authority_vtable = {
  .method_call = authority_method_call,
  .get_property = authority_get_property,
  .set_property = NULL,
};

static void
on_bus_acquired (GDBusConnection *connection,
                 const gchar     *name,
                 gpointer         user_data)
{
  (void) name; (void) user_data;
  xios_stub_register_object (connection, AUTH_PATH, authority_xml, &authority_vtable,
                             "polkit stub");
}

int
main (int argc, char **argv)
{
  (void) argc; (void) argv;

  /* Under dbus-run-session, point DBUS_SYSTEM_BUS_ADDRESS at the session bus so clients
   * that ask for G_BUS_TYPE_SYSTEM (libpolkit) meet us. */
  return xios_stub_run ("polkit stub", "XIOS_POLKIT_BUS", POLKIT_NAME, on_bus_acquired);
}
