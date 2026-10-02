/* Stand-ins for libiosexec's exec entry points (see test-iosexec.c). They
 * record which entry point was reached and fail like a missing target. */
#include <errno.h>

const char *g_last_ie_call;
const char *g_last_ie_target;

int ie_execl(const char *path, const char *arg0, ...)
{
    (void)arg0;
    g_last_ie_call = "ie_execl";
    g_last_ie_target = path;
    errno = ENOENT;
    return -1;
}

int ie_execv(const char *path, char *const argv[])
{
    (void)argv;
    g_last_ie_call = "ie_execv";
    g_last_ie_target = path;
    errno = ENOENT;
    return -1;
}

int ie_execvp(const char *file, char *const argv[])
{
    (void)argv;
    g_last_ie_call = "ie_execvp";
    g_last_ie_target = file;
    errno = ENOENT;
    return -1;
}
