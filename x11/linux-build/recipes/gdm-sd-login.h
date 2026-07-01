/* systemd/sd-login.h — iOS shim for the libgdm client build.
 *
 * gdm 46's client-side sources (libgdm/gdm-sessions.c, common/gdm-common.c) hard-use the
 * systemd sd-login C API with no #ifdef. iOS has no systemd/logind; the Xios GNOME session
 * is single-user with exactly one Wayland session ("1") on one seat ("seat0"), so the shim
 * (recipes/gdm-sd-login-shim.c) answers with those constants. Only the subset those two
 * files actually call is declared. Sibling of accountsservice-sd-login.h (kept separate so
 * neither recipe's staging depends on the other). GPL-2.0+.
 */
#ifndef _SD_LOGIN_H_XIOS_GDM_SHIM
#define _SD_LOGIN_H_XIOS_GDM_SHIM

#include <sys/types.h>

int  sd_pid_get_user_unit(pid_t pid, char **unit);
int  sd_pid_get_session(pid_t pid, char **session);
int  sd_uid_get_display(uid_t uid, char **session);
int  sd_uid_get_sessions(uid_t uid, int require_active, char ***sessions);
int  sd_seat_get_sessions(const char *seat, char ***sessions, uid_t **uids, unsigned *n_uids);
int  sd_session_get_seat(const char *session, char **seat);
int  sd_session_get_class(const char *session, char **clazz);
int  sd_session_get_state(const char *session, char **state);
int  sd_session_get_type(const char *session, char **type);
int  sd_session_get_service(const char *session, char **service);

#endif /* _SD_LOGIN_H_XIOS_GDM_SHIM */
