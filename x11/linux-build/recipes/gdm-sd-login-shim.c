/* gdm-sd-login-shim.c — a single-session systemd sd-login shim for the libgdm client build.
 *
 * There is no logind on jailbroken iOS; the Xios GNOME session is one user with one Wayland
 * session ("1") on one seat ("seat0"), matching the xios-login1-stub D-Bus daemon. The
 * answers are shaped so gdm's client logic takes the right branches:
 *   - sd_pid_get_user_unit returns -ENODATA (no systemd user units), which routes
 *     libgdm/gdm-sessions.c:get_systemd_session() to sd_pid_get_session -> "1".
 *   - sd_session_get_class returns "user" (never "greeter"), so
 *     gdm_get_login_window_session_id() correctly reports no login-window session.
 *
 * Compiled INTO libgdmcommon by recipes/libgdm-ios-fixes.sh, so no libsystemd exists on
 * the device. GPL-2.0+.
 */
#include <systemd/sd-login.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define XIOS_SESSION_ID "1"
#define XIOS_SEAT_ID    "seat0"

static int
dup_string (char **out, const char *value)
{
  char *s;

  if (!out)
    return -EINVAL;
  s = strdup (value);
  if (!s)
    return -ENOMEM;
  *out = s;
  return 0;
}

/* Allocate a NULL-terminated char** with our single session id; returns the count (1). */
static int
one_session_list (char ***out)
{
  char **v = malloc (2 * sizeof *v);

  if (!v)
    return -ENOMEM;
  v[0] = strdup (XIOS_SESSION_ID);
  v[1] = NULL;
  if (!v[0])
    {
      free (v);
      return -ENOMEM;
    }
  *out = v;
  return 1;
}

int
sd_pid_get_user_unit (pid_t pid, char **unit)
{
  (void) pid;
  (void) unit;
  return -ENODATA;   /* no systemd user units on iOS */
}

int
sd_pid_get_session (pid_t pid, char **session)
{
  (void) pid;
  return dup_string (session, XIOS_SESSION_ID);
}

int
sd_uid_get_display (uid_t uid, char **session)
{
  (void) uid;
  return dup_string (session, XIOS_SESSION_ID);
}

int
sd_uid_get_sessions (uid_t uid, int require_active, char ***sessions)
{
  (void) uid;
  (void) require_active;
  if (!sessions)
    return -EINVAL;
  return one_session_list (sessions);
}

int
sd_seat_get_sessions (const char *seat, char ***sessions, uid_t **uids, unsigned *n_uids)
{
  (void) seat;

  if (sessions)
    {
      int r = one_session_list (sessions);
      if (r < 0)
        return r;
    }
  if (uids)
    {
      *uids = malloc (sizeof **uids);
      if (!*uids)
        return -ENOMEM;
      (*uids)[0] = getuid ();
    }
  if (n_uids)
    *n_uids = 1;
  return 1;
}

int
sd_session_get_seat (const char *session, char **seat)
{
  (void) session;
  return dup_string (seat, XIOS_SEAT_ID);
}

int
sd_session_get_class (const char *session, char **clazz)
{
  (void) session;
  return dup_string (clazz, "user");
}

int
sd_session_get_state (const char *session, char **state)
{
  (void) session;
  return dup_string (state, "active");
}

int
sd_session_get_type (const char *session, char **type)
{
  (void) session;
  return dup_string (type, "wayland");
}

int
sd_session_get_service (const char *session, char **service)
{
  (void) session;
  return dup_string (service, "xios-session");
}
