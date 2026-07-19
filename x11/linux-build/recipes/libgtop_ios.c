/* libgtop_ios.c — the small libgtop-2.0 surface GNOME Console needs on iOS.
 *
 * Upstream libgtop's Darwin backend is much broader than this port needs. The
 * iOS package intentionally exports only the three entry points consumed by
 * kgx-process.c, but they are real implementations: process lists and parent/
 * uid data come from kern.proc sysctls, and argv comes from kern.procargs2.
 * Policy failures degrade per-process instead of taking the terminal down.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <unistd.h>

#include "glibtop/proclist.h"
#include "glibtop/procuid.h"
#include "glibtop/procargs.h"

#ifndef KERN_PROCARGS2
#define KERN_PROCARGS2 49
#endif

#define XIOS_GTOP_VALID 1UL
#define XIOS_GTOP_MAX_ARGS_BYTES (1024U * 1024U)

static void
clear_proclist (glibtop_proclist *buf)
{
  if (buf)
    {
      memset (buf, 0, sizeof *buf);
      buf->size = sizeof (pid_t);
    }
}

pid_t *
glibtop_get_proclist (glibtop_proclist *buf, long long which, long long arg)
{
  struct kinfo_proc *entries = NULL;
  pid_t *pids = NULL;
  size_t bytes = 0;
  size_t count = 0;
  int mib[4] = { CTL_KERN, KERN_PROC, (int) which, (int) arg };
  u_int mib_len = which == GLIBTOP_KERN_PROC_ALL ? 3U : 4U;

  clear_proclist (buf);

  /* The table may grow between sizing and reading. Leave spare room and
   * retry ENOMEM instead of returning partially initialized state. */
  for (unsigned attempt = 0; attempt < 4; attempt++)
    {
      size_t needed = 0;
      if (sysctl (mib, mib_len, NULL, &needed, NULL, 0) != 0)
        break;

      needed += 16U * sizeof (struct kinfo_proc);
      free (entries);
      entries = calloc (1, needed);
      if (!entries)
        break;

      bytes = needed;
      if (sysctl (mib, mib_len, entries, &bytes, NULL, 0) == 0)
        {
          count = bytes / sizeof *entries;
          break;
        }
      if (errno != ENOMEM)
        {
          count = 0;
          break;
        }
    }

  /* kgx expects a freeable non-NULL result even when inspection is denied. */
  pids = calloc (count ? count : 1, sizeof *pids);
  if (!pids)
    {
      free (entries);
      return NULL;
    }

  size_t written = 0;
  for (size_t i = 0; i < count; i++)
    if (entries[i].kp_proc.p_pid > 0)
      pids[written++] = entries[i].kp_proc.p_pid;
  free (entries);

  if (buf)
    {
      buf->flags = XIOS_GTOP_VALID;
      buf->number = written;
      buf->total = written * sizeof (pid_t);
      buf->size = sizeof (pid_t);
    }
  return pids;
}

void
glibtop_get_proc_uid (glibtop_proc_uid *buf, pid_t pid)
{
  struct kinfo_proc entry;
  size_t bytes = sizeof entry;
  int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };

  if (!buf)
    return;
  memset (buf, 0, sizeof *buf);

  memset (&entry, 0, sizeof entry);
  if (pid > 0 && sysctl (mib, 4, &entry, &bytes, NULL, 0) == 0 &&
      bytes >= sizeof entry)
    {
      buf->flags = XIOS_GTOP_VALID;
      buf->ppid = entry.kp_eproc.e_ppid;
      buf->euid = (int) entry.kp_eproc.e_ucred.cr_uid;
    }
}

static size_t
bounded_argmax (void)
{
  int argmax = 0;
  size_t bytes = sizeof argmax;
  int mib[2] = { CTL_KERN, KERN_ARGMAX };

  if (sysctl (mib, 2, &argmax, &bytes, NULL, 0) != 0 || argmax <= 0)
    argmax = 256 * 1024;
  if ((unsigned) argmax > XIOS_GTOP_MAX_ARGS_BYTES)
    argmax = (int) XIOS_GTOP_MAX_ARGS_BYTES;
  return (size_t) argmax;
}

char **
glibtop_get_proc_argv (glibtop_proc_args *buf, pid_t pid, unsigned int max_len)
{
  char **argv = NULL;
  char *raw = NULL;
  char *cursor;
  char *end;
  int argc = 0;
  size_t raw_size;
  size_t used = 0;
  size_t written = 0;
  int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };

  if (buf)
    memset (buf, 0, sizeof *buf);
  if (pid <= 0)
    return NULL;

  raw_size = bounded_argmax ();
  raw = calloc (1, raw_size);
  if (!raw)
    return NULL;
  if (sysctl (mib, 3, raw, &raw_size, NULL, 0) != 0 ||
      raw_size <= sizeof argc)
    goto out;

  memcpy (&argc, raw, sizeof argc);
  if (argc <= 0 || argc > 65536)
    goto out;

  cursor = raw + sizeof argc;
  end = raw + raw_size;

  /* procargs2 starts with the executable path, followed by NUL padding and
   * then argc NUL-terminated argument strings (argv[0] included). */
  cursor += strnlen (cursor, (size_t) (end - cursor));
  while (cursor < end && *cursor == '\0')
    cursor++;

  argv = calloc ((size_t) argc + 1, sizeof *argv);
  if (!argv)
    goto out;

  while (cursor < end && written < (size_t) argc)
    {
      size_t remaining = (size_t) (end - cursor);
      size_t length = strnlen (cursor, remaining);
      if (length == remaining)
        break;
      if (length == 0)
        {
          cursor++;
          continue;
        }
      if (max_len && used + length + 1 > max_len)
        break;
      argv[written] = strdup (cursor);
      if (!argv[written])
        break;
      written++;
      used += length + 1;
      cursor += length + 1;
    }

  if (buf)
    {
      buf->flags = written ? XIOS_GTOP_VALID : 0;
      buf->size = used;
    }
  free (raw);
  return argv;

out:
  free (raw);
  free (argv);
  return NULL;
}
