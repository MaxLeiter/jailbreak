/* iOS declarations-only stub of systemd sd-login. Usage is HAVE_LIBSYSTEMD-gated (off), so these
 * are not compiled/linked; the header only needs to exist for the HAVE_WAYLAND-gated #include.
 * CANONICAL COPY: staged as <systemd/sd-login.h> into the cross sysroot by build-mutter.sh and
 * onto the device by gir-build-mutter-ondevice.sh — both builds must see this same stub. */
#ifndef _SD_LOGIN_H_IOS_STUB
#define _SD_LOGIN_H_IOS_STUB
#include <sys/types.h>
int sd_pid_get_session(pid_t pid, char **session);
int sd_pid_get_user_unit(pid_t pid, char **unit);
int sd_session_get_type(const char *session, char **type);
int sd_uid_get_sessions(uid_t uid, int require_active, char ***sessions);
#endif
