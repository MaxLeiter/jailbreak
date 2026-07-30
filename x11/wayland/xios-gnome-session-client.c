/*
 * xios-gnome-session-client.c
 *
 * GNOME Shell normally registers with the built-in gnome-session manager
 * through Mutter's XSMP client.  Mutter builds that client only with X11,
 * which is intentionally absent from the native iOS backend.  This small
 * process adapter uses gnome-session's native D-Bus client protocol instead:
 * it registers the launched Shell, supervises it, and participates in the
 * normal end-session handshake.
 */

#include <gio/gio.h>
#include <glib-unix.h>

#include <signal.h>
#include <stdlib.h>

#define SESSION_NAME "org.gnome.SessionManager"
#define SESSION_PATH "/org/gnome/SessionManager"
#define SESSION_INTERFACE "org.gnome.SessionManager"
#define CLIENT_INTERFACE "org.gnome.SessionManager.ClientPrivate"
#define SHELL_APP_ID "org.gnome.Shell.desktop"

static GMainLoop *main_loop;
static GDBusConnection *session_bus;
static GSubprocess *shell_process;
static char *client_path;
static gboolean stopping;
static gboolean shell_running;
static int shell_status = EXIT_FAILURE;

static void
stop_shell (void)
{
  if (shell_process != NULL && shell_running)
    g_subprocess_send_signal (shell_process, SIGTERM);
}

static void
respond_to_end_session (void)
{
  g_autoptr (GError) error = NULL;
  g_autoptr (GVariant) reply = NULL;

  reply = g_dbus_connection_call_sync (session_bus,
                                       SESSION_NAME,
                                       client_path,
                                       CLIENT_INTERFACE,
                                       "EndSessionResponse",
                                       g_variant_new ("(bs)", TRUE, ""),
                                       NULL,
                                       G_DBUS_CALL_FLAGS_NONE,
                                       -1,
                                       NULL,
                                       &error);
  if (reply == NULL)
    g_warning ("xios-gnome-session-client: EndSessionResponse failed: %s",
               error->message);
}

static void
session_signal (GDBusConnection *connection,
                const char      *sender_name,
                const char      *object_path,
                const char      *interface_name,
                const char      *signal_name,
                GVariant        *parameters,
                gpointer         user_data)
{
  (void) connection;
  (void) sender_name;
  (void) object_path;
  (void) interface_name;
  (void) parameters;
  (void) user_data;

  if (g_str_equal (signal_name, "QueryEndSession"))
    {
      respond_to_end_session ();
    }
  else if (g_str_equal (signal_name, "EndSession"))
    {
      stopping = TRUE;
      respond_to_end_session ();
      stop_shell ();
    }
  else if (g_str_equal (signal_name, "Stop"))
    {
      stopping = TRUE;
      stop_shell ();
    }
}

static gboolean
termination_signal (gpointer user_data)
{
  (void) user_data;

  stopping = TRUE;
  stop_shell ();
  return G_SOURCE_REMOVE;
}

static void
shell_exited (GObject      *source,
              GAsyncResult *result,
              gpointer      user_data)
{
  g_autoptr (GError) error = NULL;

  (void) user_data;

  shell_running = FALSE;
  if (!g_subprocess_wait_finish (G_SUBPROCESS (source), result, &error))
    {
      g_warning ("xios-gnome-session-client: waiting for GNOME Shell failed: %s",
                 error->message);
      shell_status = EXIT_FAILURE;
    }
  else if (g_subprocess_get_if_exited (shell_process))
    {
      shell_status = g_subprocess_get_exit_status (shell_process);
    }
  else
    {
      int signal_number = g_subprocess_get_term_sig (shell_process);

      shell_status = stopping ? EXIT_SUCCESS : 128 + signal_number;
    }

  g_main_loop_quit (main_loop);
}

static void
unregister_client (void)
{
  g_autoptr (GError) error = NULL;
  g_autoptr (GVariant) reply = NULL;

  if (session_bus == NULL || client_path == NULL || g_dbus_connection_is_closed (session_bus))
    return;

  reply = g_dbus_connection_call_sync (session_bus,
                                       SESSION_NAME,
                                       SESSION_PATH,
                                       SESSION_INTERFACE,
                                       "UnregisterClient",
                                       g_variant_new ("(o)", client_path),
                                       NULL,
                                       G_DBUS_CALL_FLAGS_NONE,
                                       -1,
                                       NULL,
                                       &error);
  if (reply == NULL && !stopping)
    g_warning ("xios-gnome-session-client: UnregisterClient failed: %s",
               error->message);
}

int
main (int argc, char **argv)
{
  const char *startup_id;
  g_autoptr (GError) error = NULL;
  g_autoptr (GSubprocessLauncher) launcher = NULL;
  g_autoptr (GVariant) reply = NULL;
  guint signal_subscription;

  if (argc < 2)
    {
      g_printerr ("usage: %s COMMAND [ARG...]\n", argv[0]);
      return EXIT_FAILURE;
    }

  startup_id = g_getenv ("DESKTOP_AUTOSTART_ID");
  if (startup_id == NULL || startup_id[0] == '\0')
    {
      g_printerr ("xios-gnome-session-client: DESKTOP_AUTOSTART_ID is missing\n");
      return EXIT_FAILURE;
    }

  session_bus = g_bus_get_sync (G_BUS_TYPE_SESSION, NULL, &error);
  if (session_bus == NULL)
    {
      g_printerr ("xios-gnome-session-client: session bus unavailable: %s\n",
                  error->message);
      return EXIT_FAILURE;
    }

  launcher = g_subprocess_launcher_new (G_SUBPROCESS_FLAGS_NONE);
  g_subprocess_launcher_unsetenv (launcher, "DESKTOP_AUTOSTART_ID");
  shell_process = g_subprocess_launcher_spawnv (launcher,
                                                (const char * const *) &argv[1],
                                                &error);
  if (shell_process == NULL)
    {
      g_printerr ("xios-gnome-session-client: could not launch GNOME Shell: %s\n",
                  error->message);
      g_clear_object (&session_bus);
      return EXIT_FAILURE;
    }
  shell_running = TRUE;

  g_clear_error (&error);
  reply = g_dbus_connection_call_sync (session_bus,
                                       SESSION_NAME,
                                       SESSION_PATH,
                                       SESSION_INTERFACE,
                                       "RegisterClient",
                                       g_variant_new ("(ss)", SHELL_APP_ID, startup_id),
                                       G_VARIANT_TYPE ("(o)"),
                                       G_DBUS_CALL_FLAGS_NONE,
                                       -1,
                                       NULL,
                                       &error);
  if (reply == NULL)
    {
      g_printerr ("xios-gnome-session-client: RegisterClient failed: %s\n",
                  error->message);
      g_subprocess_force_exit (shell_process);
      g_subprocess_wait (shell_process, NULL, NULL);
      g_clear_object (&shell_process);
      g_clear_object (&session_bus);
      return EXIT_FAILURE;
    }

  g_variant_get (reply, "(o)", &client_path);
  g_message ("xios-gnome-session-client: registered %s at %s",
             SHELL_APP_ID, client_path);

  signal_subscription =
    g_dbus_connection_signal_subscribe (session_bus,
                                        SESSION_NAME,
                                        CLIENT_INTERFACE,
                                        NULL,
                                        client_path,
                                        NULL,
                                        G_DBUS_SIGNAL_FLAGS_NONE,
                                        session_signal,
                                        NULL,
                                        NULL);

  main_loop = g_main_loop_new (NULL, FALSE);
  g_subprocess_wait_async (shell_process, NULL, shell_exited, NULL);
  g_unix_signal_add (SIGTERM, termination_signal, NULL);
  g_unix_signal_add (SIGINT, termination_signal, NULL);
  g_main_loop_run (main_loop);

  unregister_client ();
  g_dbus_connection_signal_unsubscribe (session_bus, signal_subscription);
  g_clear_pointer (&client_path, g_free);
  g_clear_pointer (&main_loop, g_main_loop_unref);
  g_clear_object (&shell_process);
  g_clear_object (&session_bus);

  return shell_status;
}
