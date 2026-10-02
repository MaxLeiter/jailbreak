/*
 * Host-side checks for xios-iosexec.h, the libiosexec routing ioscd uses.
 *
 * Built twice by test-iosexec.sh:
 *   -DWITH_STUBS  linked with test-iosexec-stubs.c, standing in for
 *                 libiosexec: every xios_exec* call must reach the ie_* entry
 *                 point (the device path).
 *   (no define)   ie_* left undefined (weak, so NULL at runtime), as when
 *                 the dylib cannot load: the wrappers must fall back to libc
 *                 and still run a "#!/bin/sh" script, which the host has.
 *
 * libiosexec's own shebang redirect (/bin/sh -> /var/jb/bin/sh) only exists
 * on the device and is not exercised here.
 */
#include "../src/xios-iosexec.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifdef WITH_STUBS
extern const char *g_last_ie_call;
extern const char *g_last_ie_target;

static void test_routes_through_iosexec(void)
{
    char *argv[] = { "crispy-doom", "-iwad", "freedoom1.wad", NULL };

    assert(xios_have_iosexec());

    g_last_ie_call = g_last_ie_target = NULL;
    assert(xios_execvp(argv[0], argv) == -1);
    assert(g_last_ie_call && strcmp(g_last_ie_call, "ie_execvp") == 0);
    assert(strcmp(g_last_ie_target, "crispy-doom") == 0);

    g_last_ie_call = g_last_ie_target = NULL;
    assert(xios_execv("/var/jb/usr/bin/dbus-run-session", argv) == -1);
    assert(g_last_ie_call && strcmp(g_last_ie_call, "ie_execv") == 0);
    assert(strcmp(g_last_ie_target, "/var/jb/usr/bin/dbus-run-session") == 0);

    g_last_ie_call = g_last_ie_target = NULL;
    assert(xios_execl("/var/jb/usr/local/bin/xios-start-a11y",
                      "xios-start-a11y", (char *)NULL) == -1);
    assert(g_last_ie_call && strcmp(g_last_ie_call, "ie_execl") == 0);
    assert(strcmp(g_last_ie_target, "/var/jb/usr/local/bin/xios-start-a11y") == 0);
}
#else
static void test_falls_back_to_libc(void)
{
    assert(!xios_have_iosexec());

    char dir[] = "/tmp/xios-iosexec.XXXXXX";
    assert(mkdtemp(dir));
    char script[1024], marker[1024];
    snprintf(script, sizeof(script), "%s/wrapper", dir);
    snprintf(marker, sizeof(marker), "%s/ran", dir);

    FILE *f = fopen(script, "w");
    assert(f);
    fprintf(f, "#!/bin/sh\necho \"$1\" > '%s'\n", marker);
    assert(fclose(f) == 0);
    assert(chmod(script, 0755) == 0);

    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        char *argv[] = { script, "argv-intact", NULL };
        xios_execvp(argv[0], argv);
        _exit(127);
    }
    int st = 0;
    assert(waitpid(pid, &st, 0) == pid);
    assert(WIFEXITED(st) && WEXITSTATUS(st) == 0);

    char buf[64] = "";
    f = fopen(marker, "r");
    assert(f);
    assert(fgets(buf, sizeof(buf), f));
    assert(fclose(f) == 0);
    assert(strcmp(buf, "argv-intact\n") == 0);

    assert(unlink(marker) == 0);
    assert(unlink(script) == 0);
    assert(rmdir(dir) == 0);
}
#endif

int main(void)
{
#ifdef WITH_STUBS
    test_routes_through_iosexec();
    puts("iosexec routing tests: ok");
#else
    test_falls_back_to_libc();
    puts("iosexec fallback tests: ok");
#endif
    return 0;
}
