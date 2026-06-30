#pragma once
#include <sys/types.h>

typedef struct _glibtop_proc_uid {
  unsigned long flags;
  pid_t ppid;   /* parent pid */
  int   euid;   /* effective uid */
} glibtop_proc_uid;

void glibtop_get_proc_uid (glibtop_proc_uid *buf, pid_t pid);
