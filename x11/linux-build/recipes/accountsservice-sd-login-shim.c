/* accountsservice-sd-login-shim.c — a single-session systemd sd-login shim for iOS.
 *
 * libaccountsservice's act-user-manager.c calls the sd-login API to learn the current
 * seat/sessions. There is no logind on jailbroken iOS, but the Xios GNOME session is a
 * single root user with one Wayland session ("1") on one seat ("seat0"). This shim returns
 * exactly that, so libaccountsservice loads and its UserManager reports the running user.
 * The change/monitor fd is a pipe that never fires (our session set never changes).
 *
 * Compiled INTO libaccountsservice by recipes/accountsservice-ios-fixes.sh, so there is no
 * separate libsystemd on the device. GPL-2.0+.
 */
#include <systemd/sd-login.h>

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define XIOS_SESSION_ID "1"
#define XIOS_SEAT_ID    "seat0"

struct sd_login_monitor {
  int read_fd;
  int write_fd;
};

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

static int
dup_string (char **out, const char *value)
{
  char *s = strdup (value);

  if (!s)
    return -ENOMEM;
  *out = s;
  return 0;
}

int
sd_get_sessions (char ***sessions)
{
  if (!sessions)
    return -EINVAL;
  return one_session_list (sessions);
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
sd_session_get_uid (const char *session, uid_t *uid)
{
  (void) session;
  if (!uid)
    return -EINVAL;
  *uid = getuid ();
  return 0;
}

int
sd_session_get_seat (const char *session, char **seat)
{
  (void) session;
  if (!seat)
    return -EINVAL;
  return dup_string (seat, XIOS_SEAT_ID);
}

int
sd_session_get_class (const char *session, char **clazz)
{
  (void) session;
  if (!clazz)
    return -EINVAL;
  return dup_string (clazz, "user");
}

int
sd_session_get_type (const char *session, char **type)
{
  (void) session;
  if (!type)
    return -EINVAL;
  return dup_string (type, "wayland");
}

int
sd_session_get_state (const char *session, char **state)
{
  (void) session;
  if (!state)
    return -EINVAL;
  return dup_string (state, "active");
}

int
sd_session_get_display (const char *session, char **display)
{
  (void) session;
  if (!display)
    return -EINVAL;
  return dup_string (display, "wayland-0");
}

int
sd_seat_can_multi_session (const char *seat)
{
  (void) seat;
  return 0;   /* single seat, no VT switching */
}

int
sd_login_monitor_new (const char *category, sd_login_monitor **ret)
{
  struct sd_login_monitor *m;
  int fds[2];

  (void) category;
  if (!ret)
    return -EINVAL;

  m = calloc (1, sizeof *m);
  if (!m)
    return -ENOMEM;

  if (pipe (fds) != 0)
    {
      free (m);
      return -errno;
    }
  (void) fcntl (fds[0], F_SETFD, FD_CLOEXEC);
  (void) fcntl (fds[1], F_SETFD, FD_CLOEXEC);
  m->read_fd = fds[0];
  m->write_fd = fds[1];   /* held open so the read end never reports EOF/POLLHUP */

  *ret = m;
  return 0;
}

sd_login_monitor *
sd_login_monitor_unref (sd_login_monitor *m)
{
  if (m)
    {
      if (m->read_fd >= 0)
        close (m->read_fd);
      if (m->write_fd >= 0)
        close (m->write_fd);
      free (m);
    }
  return NULL;
}

int
sd_login_monitor_flush (sd_login_monitor *m)
{
  (void) m;
  return 0;   /* nothing ever queued */
}

int
sd_login_monitor_get_fd (sd_login_monitor *m)
{
  if (!m)
    return -EINVAL;
  return m->read_fd;   /* never becomes readable: our session set is fixed */
}
