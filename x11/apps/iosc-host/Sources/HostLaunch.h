#ifndef IOSC_HOST_HOSTLAUNCH_H
#define IOSC_HOST_HOSTLAUNCH_H

/*
 * The host, like the old IOSCLaunch stub, still asks the root ioscd daemon to
 * spawn the Linux client (a sandboxed app can't escape its own sandbox to run it;
 * see docs/iosc-desktop-env.md §2). ioscd runs the app as an iosc client; the
 * host then presents its windows via iosc-native.sock.
 *
 * Sends "LAUNCH_NATIVE\t<app_id>\n" to /var/jb/tmp/ioscd.sock. Returns
 * 0 only when ioscd acknowledges LAUNCHED or RAISED. Returns -1 for transport
 * failures and daemon ERR replies.
 */
int ioscd_send_launch(const char *app_id);

#endif
