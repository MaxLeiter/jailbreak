#include "iosc_util.h"

#include <stdio.h>
#include <string.h>
#include <strings.h>

int iosc_env_truthy(const char *env)
{
    return env && *env &&
           strcmp(env, "0") &&
           strcasecmp(env, "false") &&
           strcasecmp(env, "no") &&
           strcasecmp(env, "off");
}

int iosc_parse_size(const char *s, int *w, int *h)
{
    int tw = 0, th = 0;
    if (!s || sscanf(s, "%dx%d", &tw, &th) != 2 || tw <= 0 || th <= 0)
        return 0;
    *w = tw;
    *h = th;
    return 1;
}
