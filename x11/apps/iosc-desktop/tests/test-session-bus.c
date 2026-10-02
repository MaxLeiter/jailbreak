/*
 * Host checks for ioscd's ensure_session_bus() against names planted in the
 * world-writable tmp dir. ioscd.c is compiled in whole (its main renamed).
 *
 * The Mac has no "mobile" account, so getpwnam("mobile") answers with the
 * current user (TEST_MOBILE_UID overrides the uid) and initgroups() is a
 * no-op; the drop to "mobile" is then a drop to ourselves. DBUS_DAEMON names
 * a dbus-daemon to start; without one the daemon cases are skipped.
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
    const char *u = getenv("TEST_MOBILE_UID");
    memset(&pw, 0, sizeof(pw));
    pw.pw_uid = u ? (uid_t)atoi(u) : getuid();
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

static char g_root[64];

static void path_in(char *dst, size_t len, const char *rel)
{
    snprintf(dst, len, "%s/%s", g_root, rel);
}

static mode_t mode_of(const char *path)
{
    struct stat st;
    assert(stat(path, &st) == 0);
    return st.st_mode & 07777;
}

static void make_socket(const char *path, mode_t mode)
{
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    assert(bind(fd, (struct sockaddr *)&a, sizeof(a)) == 0);
    close(fd);
    assert(chmod(path, mode) == 0);
}

static void stop_daemons(void)
{
    pid_t pid = fork();
    assert(pid >= 0);
    if (pid == 0) {
        char pattern[128];
        snprintf(pattern, sizeof(pattern), "address=unix:path=%s/", g_root);
        int null = open("/dev/null", O_WRONLY);
        if (null >= 0) dup2(null, 2);
        execl("/usr/bin/pkill", "pkill", "-f", pattern, (char *)NULL);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
    usleep(200 * 1000);
}

int main(void)
{
    char tmp[128], jb[128], bin[128], dbus[160], busdir[160], sock[192];
    char victim[160], other[160], addr[PATH_MAX + 16];
    const char *daemon = getenv("DBUS_DAEMON");
    int have_daemon = daemon && access(daemon, X_OK) == 0;

    snprintf(g_root, sizeof(g_root), "/tmp/xios-bus.XXXXXX");
    assert(mkdtemp(g_root));
    path_in(tmp, sizeof(tmp), "t");
    path_in(jb, sizeof(jb), "jb");
    path_in(bin, sizeof(bin), "jb/usr");
    assert(mkdir(tmp, 01777) == 0 && mkdir(jb, 0755) == 0 && mkdir(bin, 0755) == 0);
    path_in(bin, sizeof(bin), "jb/usr/bin");
    assert(mkdir(bin, 0755) == 0);
    if (have_daemon) {
        snprintf(dbus, sizeof(dbus), "%s/dbus-daemon", bin);
        assert(symlink(daemon, dbus) == 0);
    }
    setenv("IOSC_JBROOT", jb, 1);
    setenv("XIOS_RUNTIME_TMP", tmp, 1);
    init_paths();
    snprintf(busdir, sizeof(busdir), "%s/ioscd-bus", tmp);
    snprintf(sock, sizeof(sock), "%s/session-bus", busdir);
    assert(strcmp(busdir, g_ioscd_bus_dir) == 0);

    /* 1. a symlink planted where the bus dir goes: its target is left alone */
    path_in(victim, sizeof(victim), "victim");
    assert(mkdir(victim, 0755) == 0);
    assert(symlink(victim, busdir) == 0);
    assert(!ensure_session_bus(addr, sizeof(addr)));
    assert(mode_of(victim) == 0755);
    char inside[200];
    snprintf(inside, sizeof(inside), "%s/session-bus", victim);
    assert(access(inside, F_OK) != 0);
    assert(unlink(busdir) == 0);
    puts("session-bus: planted dir symlink refused, target untouched");

    /* 2. a symlink planted at the socket name: its target socket is left
     *    alone and the link is replaced */
    assert(mkdir(busdir, 0700) == 0);
    path_in(other, sizeof(other), "other.sock");
    make_socket(other, 0700);
    assert(symlink(other, sock) == 0);
    int r = ensure_session_bus(addr, sizeof(addr));
    assert(mode_of(other) == 0700);
    struct stat st;
    assert(lstat(sock, &st) != 0 || !S_ISLNK(st.st_mode));
    if (have_daemon) {
        assert(r == 1);
        assert(lstat(sock, &st) == 0 && S_ISSOCK(st.st_mode) && st.st_uid == getuid());
        /* the live daemon socket is reused, not restarted */
        ino_t ino = st.st_ino;
        assert(ensure_session_bus(addr, sizeof(addr)) == 1);
        assert(lstat(sock, &st) == 0 && st.st_ino == ino);
        stop_daemons();
    }
    puts("session-bus: planted socket symlink replaced, target untouched");

    /* 3. the daemon's socket left behind by a daemon that died (nothing
     *    listens): restarted, not handed to apps */
    (void)unlink(sock);
    make_socket(sock, 0777);
    assert(lstat(sock, &st) == 0);
    ino_t dead_ino = st.st_ino;
    r = ensure_session_bus(addr, sizeof(addr));
    if (have_daemon) {
        assert(r == 1);
        assert(lstat(sock, &st) == 0 && S_ISSOCK(st.st_mode) && st.st_ino != dead_ino);
        assert(!bus_socket_dead(sock));
        stop_daemons();
    } else {
        assert(r == 0);
    }
    puts("session-bus: dead socket restarted, not reused");

    /* 4. a bus dir owned by neither root nor the mobile uid is refused */
    char uidbuf[32];
    snprintf(uidbuf, sizeof(uidbuf), "%u", (unsigned)getuid() + 1);
    setenv("TEST_MOBILE_UID", uidbuf, 1);
    assert(chmod(busdir, 0755) == 0);
    assert(!ensure_session_bus(addr, sizeof(addr)));
    assert(mode_of(busdir) == 0755);
    unsetenv("TEST_MOBILE_UID");
    puts("session-bus: foreign-owned bus dir refused");

    /* 5. fresh start: a 0700 dir and the daemon's own socket */
    if (have_daemon) {
        (void)unlink(sock);
        assert(rmdir(busdir) == 0);
        assert(ensure_session_bus(addr, sizeof(addr)) == 1);
        assert(lstat(busdir, &st) == 0 && S_ISDIR(st.st_mode) &&
               (st.st_mode & 07777) == 0700 && st.st_uid == getuid());
        assert(lstat(sock, &st) == 0 && S_ISSOCK(st.st_mode));
        stop_daemons();
        puts("session-bus: fresh bus dir 0700 with the daemon's socket");
    } else {
        puts("session-bus: no DBUS_DAEMON, daemon cases skipped");
    }

    (void)unlink(sock);
    (void)rmdir(busdir);
    (void)unlink(other);
    (void)rmdir(victim);
    if (have_daemon) (void)unlink(dbus);
    (void)rmdir(bin);
    path_in(bin, sizeof(bin), "jb/usr");
    (void)rmdir(bin);
    (void)rmdir(jb);
    (void)rmdir(tmp);
    (void)rmdir(g_root);
    puts("session-bus tests: ok");
    return 0;
}
