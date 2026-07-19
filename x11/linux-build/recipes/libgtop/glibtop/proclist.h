#pragma once
/* Focused libgtop header — the process-list surface GNOME Console uses. */
#include <sys/types.h>

#define GLIBTOP_KERN_PROC_ALL 0

typedef struct _glibtop_proclist {
  unsigned long flags;
  unsigned long number;   /* count of pids in the returned array */
  unsigned long total;
  unsigned long size;
} glibtop_proclist;

/* Returns a heap array of @buf->number pids; caller frees it (kgx uses g_autofree). */
pid_t *glibtop_get_proclist (glibtop_proclist *buf, long long which, long long arg);
