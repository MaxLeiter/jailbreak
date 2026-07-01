/* -*- mode: C; c-file-style: "gnu"; indent-tabs-mode: nil; -*- */

/*
 * xios-session-identity.h — the real logged-in user of the Xios GNOME session, resolved once
 * and shared by all the session stubs (login1, Accounts, and the accountsservice sd-login
 * shim) so the shell shows a real name/uid/home instead of fabricated constants.
 *
 * Resolution (see xios-session-identity.c):
 *   uid/username/home/shell : getpwuid(getuid())  (falls back to sensible iOS defaults)
 *   realname : $XIOS_REAL_NAME -> passwd gecos (if meaningful) -> MobileGestalt device name
 *              ("Max's iPad") -> gethostname -> "iOS User"
 *   icon_file: ~/.face if present, else "" (shell uses a default avatar)
 *   language : $LANG / $LC_MESSAGES, else ""
 *
 * GPL-2.0+.
 */
#ifndef XIOS_SESSION_IDENTITY_H
#define XIOS_SESSION_IDENTITY_H

#include <sys/types.h>

typedef struct {
  uid_t       uid;
  const char *username;    /* pw_name or "mobile"            */
  const char *realname;    /* display name (see above)        */
  const char *home;        /* pw_dir or "/var/mobile"         */
  const char *shell;       /* pw_shell or "/bin/sh"           */
  const char *icon_file;   /* ~/.face or ""                   */
  const char *language;    /* $LANG etc. or ""                */
} XiosIdentity;

/* Lazily resolved process-lifetime singleton. Never returns NULL; the string fields are
 * owned by the singleton (do not free). Thread-unsafe first call (the stubs are single main
 * loop, so this is fine). */
const XiosIdentity *xios_identity (void);

#endif /* XIOS_SESSION_IDENTITY_H */
