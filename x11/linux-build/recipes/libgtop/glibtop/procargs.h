#pragma once
#include <sys/types.h>

typedef struct _glibtop_proc_args {
  unsigned long flags;
  unsigned long size;
} glibtop_proc_args;

char **glibtop_get_proc_argv (glibtop_proc_args *buf, pid_t pid, unsigned int max_len);
