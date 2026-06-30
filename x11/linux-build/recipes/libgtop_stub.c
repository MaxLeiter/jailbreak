/* libgtop_stub.c — minimal libgtop-2.0 implementation for iOS (see libgtop.mk).
 *
 * GNOME Console (kgx) hard-links libgtop to enumerate child processes for window
 * styling and the "command still running" close warning. Upstream libgtop has no
 * Procursus recipe and its darwin backend leans on sysctl(KERN_PROC)/libproc paths
 * that are restricted under the iOS sandbox. This stub satisfies the three calls
 * kgx-process.c makes so the app links and launches; process enumeration is simply
 * empty, which degrades only that styling — the terminal itself works normally.
 */
#include <stdlib.h>
#include <unistd.h>

#include "glibtop/proclist.h"
#include "glibtop/procuid.h"
#include "glibtop/procargs.h"

pid_t *
glibtop_get_proclist (glibtop_proclist *buf, long long which, long long arg)
{
  (void) which; (void) arg;
  if (buf) {
    buf->flags = 0; buf->number = 0; buf->total = 0; buf->size = sizeof (pid_t);
  }
  /* Non-NULL empty array: kgx asserts the result is non-NULL and frees it. */
  return (pid_t *) calloc (1, sizeof (pid_t));
}

void
glibtop_get_proc_uid (glibtop_proc_uid *buf, pid_t pid)
{
  (void) pid;
  if (buf) { buf->flags = 0; buf->ppid = 0; buf->euid = (int) getuid (); }
}

char **
glibtop_get_proc_argv (glibtop_proc_args *buf, pid_t pid, unsigned int max_len)
{
  (void) pid; (void) max_len;
  if (buf) { buf->flags = 0; buf->size = 0; }
  return NULL;
}
