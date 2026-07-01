/* systemd/sd-daemon.h — iOS stub for the libgdm client build.
 *
 * common/gdm-log.c includes this unconditionally but only uses sd_booted() to pick the
 * journal (stderr-prefix) log style over syslog. There is no systemd on iOS, so sd_booted()
 * is 0 and gdm-log falls to plain syslog. The SD_* prefixes are the standard <N> strings in
 * case any pulled-in code references them. GPL-2.0+.
 */
#ifndef _SD_DAEMON_H_XIOS_GDM_SHIM
#define _SD_DAEMON_H_XIOS_GDM_SHIM

#define SD_EMERG   "<0>"
#define SD_ALERT   "<1>"
#define SD_CRIT    "<2>"
#define SD_ERR     "<3>"
#define SD_WARNING "<4>"
#define SD_NOTICE  "<5>"
#define SD_INFO    "<6>"
#define SD_DEBUG   "<7>"

static inline int sd_booted(void) { return 0; }

#endif /* _SD_DAEMON_H_XIOS_GDM_SHIM */
