/*
 * Host checks that ioscd's children do not inherit its descriptors.
 * ioscd.c is compiled in whole (its main renamed); this binary doubles as the
 * child that reports what it inherited (--list).
 *
 *   1. ioscd's own main loop answers APPS_LIST by running xios-launcher-sync,
 *      here a link to this binary: the listing must show neither the
 *      listening socket nor the SIGCHLD pipe.
 *   2. launch_client(), which drops to mobile, must close even fds that were
 *      opened without close-on-exec.
 *
 * As in test-session-bus.c, "mobile" is the current user and initgroups() is
 * a no-op.
 */
#include <pwd.h>
#include <unistd.h>

static struct passwd *test_getpwnam(const char *name);
static int test_initgroups(const char *name, int gid);
#define getpwnam test_getpwnam
#define initgroups test_initgroups
#define main ioscd_main
#include "../src/ioscd.c"
#undef main
#undef initgroups
#undef getpwnam

#include <assert.h>

static struct passwd *test_getpwnam(const char *name)
{
    static struct passwd pw;
    static char nm[64], home[] = "/var/mobile";
    if (strcmp(name, "mobile") != 0) return NULL;
    struct passwd *me = getpwuid(getuid());
    memset(&pw, 0, sizeof(pw));
    pw.pw_uid = getuid();
    pw.pw_gid = getgid();
    snprintf(nm, sizeof(nm), "%s", me ? me->pw_name : "mobile");
    pw.pw_name = nm;
    pw.pw_dir = home;
    return &pw;
}

static int test_initgroups(const char *name, int gid)
{
    (void)name; (void)gid;
    return 0;
}

static int list_inherited_fds(void)
{
    int n = 0;
    for (int fd = 3; fd < 1024; fd++)
        if (fcntl(fd, F_GETFD) != -1) { printf("inherited fd %d\n", fd); n++; }
    printf("inherited fds: %d\n", n);
    return 0;
}

static char g_root[64];

static void slurp(const char *path, char *buf, size_t len)
{
    FILE *f = fopen(path, "r");
    size_t n = f ? fread(buf, 1, len - 1, f) : 0;
    buf[n] = 0;
    if (f) fclose(f);
}

int main(int argc, char **argv)
{
    if (argc > 1 && (strcmp(argv[1], "--list") == 0 || strcmp(argv[1], "--list-fds") == 0))
        return list_inherited_fds();

    char self[PATH_MAX], tmp[128], jb[128], dir[160], link_path[200], log[200];
    char reply_buf[4096];
    assert(realpath(argv[0], self));
    snprintf(g_root, sizeof(g_root), "/tmp/xios-fds.XXXXXX");
    assert(mkdtemp(g_root));
    snprintf(tmp, sizeof(tmp), "%s/t", g_root);
    snprintf(jb, sizeof(jb), "%s/jb", g_root);
    assert(mkdir(tmp, 01777) == 0 && mkdir(jb, 0755) == 0);
    const char *parts[] = { "/usr", "/usr/local", "/usr/local/bin", NULL };
    for (int i = 0; parts[i]; i++) {
        snprintf(dir, sizeof(dir), "%s%s", jb, parts[i]);
        assert(mkdir(dir, 0755) == 0);
    }
    snprintf(link_path, sizeof(link_path), "%s/usr/local/bin/xios-launcher-sync", jb);
    assert(symlink(self, link_path) == 0);
    setenv("IOSC_JBROOT", jb, 1);
    setenv("XIOS_RUNTIME_TMP", tmp, 1);

    /* 1. the daemon's own loop */
    pid_t daemon = fork();
    assert(daemon >= 0);
    if (daemon == 0) {
        int null = open("/dev/null", O_WRONLY);
        if (null >= 0) {
            dup2(null, 2);
            if (null > 2) close(null);
        }
        _exit(ioscd_main());
    }
    char sock[200];
    snprintf(sock, sizeof(sock), "%s/ioscd.sock", tmp);
    int fd = -1;
    for (int i = 0; i < 50 && fd < 0; i++) {
        struct sockaddr_un a;
        memset(&a, 0, sizeof(a));
        a.sun_family = AF_UNIX;
        snprintf(a.sun_path, sizeof(a.sun_path), "%s", sock);
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
            close(fd);
            fd = -1;
            usleep(100 * 1000);
        }
    }
    assert(fd >= 0);
    assert(write(fd, "APPS_LIST\n", 10) == 10);
    size_t got = 0;
    ssize_t n;
    while (got + 1 < sizeof(reply_buf) &&
           (n = read(fd, reply_buf + got, sizeof(reply_buf) - 1 - got)) > 0)
        got += (size_t)n;
    reply_buf[got] = 0;
    close(fd);
    kill(daemon, SIGTERM);
    waitpid(daemon, NULL, 0);
    fputs(reply_buf, stdout);
    assert(strstr(reply_buf, "APPS_END\t0") != NULL);
    assert(strstr(reply_buf, "inherited fds: 0\n") != NULL);
    puts("ioscd-fds: APPS_LIST child inherits no daemon fds");

    /* 2. launch_client closes fds opened without close-on-exec */
    init_paths();
    int leak1 = open("/dev/null", O_RDONLY);
    int leak2 = dup(leak1);
    assert(leak1 >= 3 && leak2 >= 3);
    char *app_argv[] = { self, "--list-fds", NULL };
    pid_t app = launch_client("org.example.FdCheck", app_argv, 0);
    assert(app > 0);
    int status = 0;
    assert(waitpid(app, &status, 0) == app);
    snprintf(log, sizeof(log), "%s/ioscd-client.log", tmp);
    slurp(log, reply_buf, sizeof(reply_buf));
    fputs(reply_buf, stdout);
    assert(strstr(reply_buf, "inherited fds: 0\n") != NULL);
    puts("ioscd-fds: launched client inherits no fds");

    close(leak1);
    close(leak2);
    (void)unlink(log);
    (void)unlink(link_path);
    (void)unlink(sock);
    for (int i = 2; i >= 0; i--) {
        snprintf(dir, sizeof(dir), "%s%s", jb, parts[i]);
        (void)rmdir(dir);
    }
    char rest[200];
    const char *leftovers[] = { "ioscd-bus", "ioscd-session.log", "xios-active-session", NULL };
    for (int i = 0; leftovers[i]; i++) {
        snprintf(rest, sizeof(rest), "%s/%s", tmp, leftovers[i]);
        (void)unlink(rest);
        (void)rmdir(rest);
    }
    (void)rmdir(jb);
    (void)rmdir(tmp);
    (void)rmdir(g_root);
    puts("ioscd-fds tests: ok");
    return 0;
}
