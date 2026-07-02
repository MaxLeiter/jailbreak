#ifndef IOSC_HOST_HOSTLAUNCH_H
#define IOSC_HOST_HOSTLAUNCH_H

/*
 * The host, like the old IOSCLaunch stub, still asks the root ioscd daemon to
 * spawn the Linux client (a sandboxed app can't escape its own sandbox to run it;
 * see docs/iosc-desktop-env.md §2). ioscd runs the app as an iosc client; the
 * host then presents its windows via iosc-native.sock.
 *
 * Sends "LAUNCH_NATIVE\t<app_id>\t<exec>\n" to /var/jb/tmp/ioscd.sock. Returns
 * 0 on a delivered request, -1 if ioscd is unreachable (not installed / not
 * running).
 */
int ioscd_send_launch(const char *app_id, const char *exec);

#endif
