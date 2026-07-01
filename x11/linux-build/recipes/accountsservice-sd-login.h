/* systemd/sd-login.h — iOS shim for libaccountsservice.
 *
 * accountsservice 23.x hard-uses the systemd sd-login C API to enumerate the current
 * seat/sessions. iOS has no systemd/logind, but the Xios GNOME session is single-user
 * (root) with exactly one Wayland session on one seat, so the shim (recipes/
 * accountsservice-sd-login-shim.c) answers with those constants. Only the subset that
 * src/libaccountsservice/act-user-manager.c actually calls is declared. GPL-2.0+.
 */
#ifndef _SD_LOGIN_H_XIOS_SHIM
#define _SD_LOGIN_H_XIOS_SHIM

#include <sys/types.h>

typedef struct sd_login_monitor sd_login_monitor;

int  sd_get_sessions(char ***sessions);
int  sd_uid_get_sessions(uid_t uid, int require_active, char ***sessions);
int  sd_session_get_uid(const char *session, uid_t *uid);
int  sd_session_get_seat(const char *session, char **seat);
int  sd_session_get_class(const char *session, char **clazz);
int  sd_session_get_type(const char *session, char **type);
int  sd_session_get_state(const char *session, char **state);
int  sd_session_get_display(const char *session, char **display);
int  sd_seat_can_multi_session(const char *seat);

int  sd_login_monitor_new(const char *category, sd_login_monitor **ret);
sd_login_monitor *sd_login_monitor_unref(sd_login_monitor *m);
int  sd_login_monitor_flush(sd_login_monitor *m);
int  sd_login_monitor_get_fd(sd_login_monitor *m);

#endif /* _SD_LOGIN_H_XIOS_SHIM */
