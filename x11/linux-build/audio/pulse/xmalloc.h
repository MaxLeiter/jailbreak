#ifndef PULSE_XMALLOC_H
#define PULSE_XMALLOC_H

#include <stdlib.h>

#define pa_xmalloc malloc
#define pa_xmalloc0(size) calloc(1, (size))
#define pa_xfree free

#endif

