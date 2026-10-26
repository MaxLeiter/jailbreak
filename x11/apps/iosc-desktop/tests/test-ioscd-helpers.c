/*
 * Host checks for two ioscd paths. ioscd.c is compiled in whole (its main
 * renamed); copies of this binary named xios-hwbridged/-sensord/-sysintd stand
 * in for the helpers (they report inherited fds, then sleep).
 *
 *   1. ensure_native_helpers_for_bus() starts one helper per session bus,
 *      recorded in <busdir>/<name>.pid the way xs_start_native_helper does in
 *      xios-session-lib.sh. A helper of the same name running for another bus
 *      no longer suppresses it; a live recorded helper is not started twice;
 *      a dead or recycled pid is restarted; a planted symlink is never written
 *      through.
 *      They run as mobile (the bus daemon's user; here the current user) with
 *      mobile's HOME, and a dead socket root left at the global sysint name
 *      is cleared for this bus's sysintd.
 *   2. A SESSION request answers "ERR xios-session is not installed" instead
 *      of SESSION_STARTED when the script is missing.
 *   3. X11 for launched apps: iosc_x11_display() believes iosc's latched
 *      x11-display only while the X socket exists; launch_client() passes it
 *      as DISPLAY with GDK_BACKEND=wayland,x11; ioscd's own iosc start turns
 *      on IOSC_XWAYLAND when Xwayland is installed, unless IOSC_XWAYLAND=0.
 *
 *   4. PRESETS runs `xios-session presets` the way SESSION runs xios-session
 *      (bash, the rootless PATH), relays only preset-name lines, ends with
 *      PRESETS_END\t<exit status>, and answers ERR when xios-session is missing
 *      or hangs. Once against stand-in scripts, once against the real
 *      xios-session and lib on a scratch prefix.
 *   5. The accessibility helper starts as the bus owner: mobile on ioscd's bus
 *      (a root client is refused by that bus), root on a root-owned bus; its
 *      logs, socket and at-spi directories are reachable by mobile.
 *
 * As in test-ioscd-fds.c, "mobile" is the current user.
 */
#include <pwd.h>
#include <unistd.h>

static struct passwd *test_getpwnam(const char *name);
/* "mobile" is the current user plus this: bump it to make a bus the test user
 * made look like another user's (a root-owned bus). */
static int t_mobile_uid_offset;
static int test_initgroups(const char *name, int gid);
#define getpwnam test_getpwnam
#define initgroups test_initgroups
#define PRESETS_TIMEOUT_MS 800
#define A11Y_LEFTOVER_UID getuid()
#define main ioscd_main
#include "../src/ioscd.c"
#undef main
#undef initgroups
#undef getpwnam

#include <assert.h>
#include <libgen.h>

static struct passwd *test_getpwnam(const char *name)
{
    static struct passwd pw;
    static char nm[64], home[] = "/var/mobile";
    if (strcmp(name, "mobile") != 0) return NULL;
    struct passwd *me = getpwuid(getuid());
    memset(&pw, 0, sizeof(pw));
    pw.pw_uid = getuid() + (uid_t)t_mobile_uid_offset;
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

static const char *k_names[] = { "xios-hwbridged", "xios-sensord", "xios-sysintd" };
static char t_root[64], t_tmp[128], t_jb[128], t_bus[160];

static int helper_main(void)
{
    int n = 0;
    for (int fd = 3; fd < 1024; fd++)
        if (fcntl(fd, F_GETFD) != -1) n++;
    printf("helper inherited fds: %d\n", n);
    const char *own = getenv("XIOS_SYSINT_SOCK");
    printf("helper home=%s sysint=%s\n", getenv("HOME") ? getenv("HOME") : "",
           own ? own : "global");
    fflush(stdout);
    alarm(120);  /* never outlive a crashed test */
    for (;;) pause();
}

/* Stands in for xios-start-a11y: reports what ioscd gave it. */
static int a11y_helper_main(void)
{
    int n = 0;
    for (int fd = 3; fd < 1024; fd++)
        if (fcntl(fd, F_GETFD) != -1) n++;
    printf("a11y fds=%d\n", n);
#define SHOW(v) printf("a11y " v "=%s\n", getenv(v) ? getenv(v) : "")
    SHOW("HOME"); SHOW("USER"); SHOW("XDG_RUNTIME_DIR");
    SHOW("DBUS_SESSION_BUS_ADDRESS"); SHOW("XIOS_TMP"); SHOW("XIOS_A11Y_SOCK");
    SHOW("XIOS_ATSPI_LOG"); SHOW("XIOS_A11YD_LOG");
#undef SHOW
    fflush(stdout);
    return 0;
}

static char t_a11yd_copy[300];

static void slurp(const char *path, char *buf, size_t len)
{
    FILE *f = fopen(path, "r");
    size_t n = f ? fread(buf, 1, len - 1, f) : 0;
    buf[n] = 0;
    if (f) fclose(f);
}

static void bus_file(char *dst, size_t len, const char *name, const char *ext)
{
    snprintf(dst, len, "%s/%s%s", t_bus, name, ext);
}

/* The pid a helper's pid file names, once its shell has written it. */
static pid_t wait_pid(const char *name)
{
    char pf[256], buf[64];
    bus_file(pf, sizeof(pf), name, ".pid");
    for (int i = 0; i < 100; i++) {
        slurp(pf, buf, sizeof(buf));
        if (buf[0] && strchr(buf, '\n')) return (pid_t)atoi(buf);
        usleep(50 * 1000);
    }
    return 0;
}

static int is_helper(pid_t pid, const char *name)
{
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
    memset(&kp, 0, sizeof(kp));
    return pid > 0 && kill(pid, 0) == 0 &&
           sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && len > 0 &&
           strcmp(kp.kp_proc.p_comm, name) == 0;
}

/* Run the guard and wait for its shell (our child) to finish. */
static void run_guard(void)
{
    ensure_native_helpers_for_bus(t_bus, "unix:path=/nonexistent", 1);
    while (waitpid(-1, NULL, 0) > 0) {}
}

static void kill_wait(pid_t pid)
{
    kill(pid, SIGKILL);
    for (int i = 0; i < 100 && kill(pid, 0) == 0; i++) usleep(20 * 1000);
}

static int make_listener(const char *path)
{
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    assert(fd >= 0);
    unlink(path);
    assert(bind(fd, (struct sockaddr *)&a, sizeof(a)) == 0 && listen(fd, 4) == 0);
    return fd;
}

static int connect_ctl(const char *sock)
{
    for (int i = 0; i < 50; i++) {
        struct sockaddr_un a;
        memset(&a, 0, sizeof(a));
        a.sun_family = AF_UNIX;
        snprintf(a.sun_path, sizeof(a.sun_path), "%s", sock);
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) return fd;
        close(fd);
        usleep(100 * 1000);
    }
    return -1;
}

static void request(const char *sock, const char *msg, char *out, size_t len)
{
    int fd = connect_ctl(sock);
    assert(fd >= 0);
    assert(write(fd, msg, strlen(msg)) == (ssize_t)strlen(msg));
    size_t got = 0;
    ssize_t n;
    while (got + 1 < len && (n = read(fd, out + got, len - 1 - got)) > 0) {
        got += (size_t)n;
        if (memchr(out, '\n', got)) break;
    }
    out[got] = 0;
    close(fd);
}

static void test_helpers(const char *self)
{
    char path[256], buf[4096];
    pid_t first[3];

    snprintf(t_bus, sizeof(t_bus), "%s/bus", t_tmp);
    assert(mkdir(t_bus, 0700) == 0);

    /* A sysintd already serving some other bus, with no record in ours: the
     * old global ps check skipped ours because of it. */
    /* Not our child, so run_guard's wait-for-everything cannot hang on it. */
    int pp[2];
    assert(pipe(pp) == 0);
    pid_t mid = fork(), foreign = 0;
    assert(mid >= 0);
    if (mid == 0) {
        pid_t g = fork();
        if (g == 0) {
            int null = open("/dev/null", O_WRONLY);
            dup2(null, 1);
            close(pp[0]);
            close(pp[1]);
            execl(g_xios_sysintd, "xios-sysintd", (char *)NULL);
            _exit(127);
        }
        (void)!write(pp[1], &g, sizeof(g));
        _exit(0);
    }
    close(pp[1]);
    assert(read(pp[0], &foreign, sizeof(foreign)) == sizeof(foreign));
    close(pp[0]);
    waitpid(mid, NULL, 0);
    for (int i = 0; i < 100 && !is_helper(foreign, "xios-sysintd"); i++) usleep(20 * 1000);
    assert(is_helper(foreign, "xios-sysintd"));

    /* A dead socket at the global sysint name: mobile could not replace it
     * in the sticky tmp dir, so the guard clears it. */
    char global[256];
    snprintf(global, sizeof(global), "%s/xios-sysint.sock", t_tmp);
    close(make_listener(global));

    run_guard();
    struct stat gst;
    assert(lstat(global, &gst) != 0);
    for (int i = 0; i < 3; i++) {
        first[i] = wait_pid(k_names[i]);
        assert(is_helper(first[i], k_names[i]));
        bus_file(path, sizeof(path), k_names[i], ".log");
        for (int t = 0; t < 100; t++) {
            slurp(path, buf, sizeof(buf));
            if (buf[0]) break;
            usleep(50 * 1000);
        }
        assert(strstr(buf, "helper inherited fds: 0\n") != NULL);
        assert(strstr(buf, "helper home=/var/mobile sysint=global\n") != NULL);
    }
    assert(first[2] != foreign);
    puts("ioscd-helpers: a helper running for another bus does not block this bus");
    puts("ioscd-helpers: pid files name the helpers; helpers inherit no fds");
    puts("ioscd-helpers: helpers get mobile's HOME; a dead global sysint socket is cleared");

    /* Running and recorded: nothing starts twice. */
    run_guard();
    usleep(300 * 1000);
    for (int i = 0; i < 3; i++)
        assert(wait_pid(k_names[i]) == first[i]);
    puts("ioscd-helpers: live recorded helpers are not started again");

    /* Dead: restarted. Recycled pid (a live process that is not the
     * helper): restarted. */
    kill_wait(first[0]);
    bus_file(path, sizeof(path), k_names[1], ".pid");
    FILE *f = fopen(path, "w");
    assert(f);
    fprintf(f, "%d\n", (int)getpid());
    fclose(f);
    run_guard();
    pid_t again0 = wait_pid(k_names[0]), again1 = wait_pid(k_names[1]);
    assert(again0 != first[0] && is_helper(again0, k_names[0]));
    assert(again1 != getpid() && is_helper(again1, k_names[1]));
    assert(is_helper(first[1], k_names[1]));  /* the unrecorded one stays; not ours to stop */
    kill_wait(first[1]);
    assert(wait_pid(k_names[2]) == first[2]);
    puts("ioscd-helpers: dead and recycled pids are restarted");

    /* Planted symlinks in the mobile-owned dir are replaced, never followed. */
    char victim[200], victim_log[200];
    snprintf(victim, sizeof(victim), "%s/victim-pid", t_root);
    snprintf(victim_log, sizeof(victim_log), "%s/victim-log", t_root);
    f = fopen(victim, "w"); fputs("precious\n", f); fclose(f);
    f = fopen(victim_log, "w"); fputs("precious\n", f); fclose(f);
    kill_wait(first[2]);
    bus_file(path, sizeof(path), k_names[2], ".pid");
    assert(unlink(path) == 0 && symlink(victim, path) == 0);
    bus_file(path, sizeof(path), k_names[2], ".log");
    assert(unlink(path) == 0 && symlink(victim_log, path) == 0);
    int live = make_listener(global);   /* a desktop's sysintd owns the global name */
    run_guard();
    pid_t again2 = wait_pid(k_names[2]);
    assert(is_helper(again2, k_names[2]));
    {
        char want[300];
        snprintf(want, sizeof(want), "sysint=%s/xios-sysint.sock\n", t_bus);
        bus_file(path, sizeof(path), k_names[2], ".log");
        for (int t = 0; t < 100; t++) {
            slurp(path, buf, sizeof(buf));
            if (strstr(buf, "sysint=")) break;
            usleep(50 * 1000);
        }
        assert(strstr(buf, want) != NULL);
    }
    assert(lstat(global, &gst) == 0 && S_ISSOCK(gst.st_mode));   /* left alone */
    close(live);
    unlink(global);
    puts("ioscd-helpers: a live global sysint socket gets this bus a socket of its own");
    slurp(victim, buf, sizeof(buf));
    assert(strcmp(buf, "precious\n") == 0);
    slurp(victim_log, buf, sizeof(buf));
    assert(strcmp(buf, "precious\n") == 0);
    struct stat st;
    bus_file(path, sizeof(path), k_names[2], ".pid");
    assert(lstat(path, &st) == 0 && S_ISREG(st.st_mode));
    bus_file(path, sizeof(path), k_names[2], ".log");
    assert(lstat(path, &st) == 0 && S_ISREG(st.st_mode));
    puts("ioscd-helpers: planted pid/log symlinks are replaced, targets untouched");

    /* A fresh empty pid file is a start in progress: not doubled. */
    kill_wait(again0);
    bus_file(path, sizeof(path), k_names[0], ".pid");
    f = fopen(path, "w"); fclose(f);
    bus_file(path, sizeof(path), k_names[0], ".log");
    unlink(path);
    run_guard();
    usleep(300 * 1000);
    assert(access(path, F_OK) != 0);
    puts("ioscd-helpers: a pid file still being written holds off a second start");

    kill_wait(again1);
    kill_wait(again2);
    kill_wait(foreign);
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    for (int i = 0; i < 3; i++) {
        bus_file(path, sizeof(path), k_names[i], ".pid"); unlink(path);
        bus_file(path, sizeof(path), k_names[i], ".log"); unlink(path);
    }
    rmdir(t_bus);
    unlink(victim);
    unlink(victim_log);
    (void)self;
}

static void test_missing_session(void)
{
    char sock[200], log[200], script[200], buf[4096];
    snprintf(sock, sizeof(sock), "%s/ioscd.sock", t_tmp);
    snprintf(log, sizeof(log), "%s/ioscd.log", t_root);
    snprintf(script, sizeof(script), "%s/usr/local/bin/xios-session", t_jb);

    pid_t daemon = fork();
    assert(daemon >= 0);
    if (daemon == 0) {
        int out = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        dup2(out, 2);
        close(out);
        _exit(ioscd_main());
    }
    /* A slotted request skips the switch policy, so only the check decides. */
    const char *req = "SESSION\tiosc\t\t\t\t\ttestslot\n";
    request(sock, req, buf, sizeof(buf));
    assert(strcmp(buf, "ERR xios-session is not installed\n") == 0);
    slurp(log, buf, sizeof(buf));
    assert(strstr(buf, "xios-session is not installed") != NULL);
    puts("ioscd-helpers: missing xios-session is an ERR reply, not SESSION_STARTED");

    FILE *f = fopen(script, "w");
    assert(f);
    fputs("exit 0\n", f);
    fclose(f);
    assert(chmod(script, 0755) == 0);
    request(sock, req, buf, sizeof(buf));
    assert(strcmp(buf, "SESSION_STARTED\n") == 0);
    puts("ioscd-helpers: installed xios-session still answers SESSION_STARTED");

    kill(daemon, SIGTERM);
    waitpid(daemon, NULL, 0);
    usleep(200 * 1000);
    unlink(script);
    unlink(sock);
    unlink(log);
}

/* The whole reply, to EOF. */
static void request_all(const char *sock, const char *msg, char *out, size_t len)
{
    int fd = connect_ctl(sock);
    assert(fd >= 0);
    assert(write(fd, msg, strlen(msg)) == (ssize_t)strlen(msg));
    size_t got = 0;
    ssize_t n;
    while (got + 1 < len && (n = read(fd, out + got, len - 1 - got)) > 0)
        got += (size_t)n;
    out[got] = 0;
    close(fd);
}

static void write_script(const char *path, const char *body)
{
    FILE *f = fopen(path, "w");
    assert(f);
    fputs(body, f);
    fclose(f);
    assert(chmod(path, 0755) == 0);
}

static pid_t start_daemon(const char *log)
{
    pid_t daemon = fork();
    assert(daemon >= 0);
    if (daemon == 0) {
        int out = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        dup2(out, 2);
        close(out);
        _exit(ioscd_main());
    }
    return daemon;
}

static void stop_daemon(pid_t daemon, const char *sock)
{
    kill(daemon, SIGTERM);
    waitpid(daemon, NULL, 0);
    usleep(200 * 1000);
    unlink(sock);
}

static void test_presets(const char *session_src_dir)
{
    char sock[200], log[200], script[200], seen[200], buf[4096], body[1024];
    snprintf(sock, sizeof(sock), "%s/ioscd.sock", t_tmp);
    snprintf(log, sizeof(log), "%s/presets.log", t_root);
    snprintf(script, sizeof(script), "%s/usr/local/bin/xios-session", t_jb);
    snprintf(seen, sizeof(seen), "%s/presets-seen", t_root);

    pid_t daemon = start_daemon(log);

    /* Not installed: same ERR as SESSION, and the bare verb is enough. */
    request_all(sock, "PRESETS\n", buf, sizeof(buf));
    assert(strcmp(buf, "ERR xios-session is not installed\n") == 0);
    puts("ioscd-presets: missing xios-session is an ERR reply");

    /* Runs `xios-session presets` through bash with the SESSION child's PATH,
     * relays preset names only (stdout noise and stderr are not presets),
     * and ends with the exit status. */
    snprintf(body, sizeof(body),
        "echo \"$1 $PATH\" > '%s'\n"
        "echo \"warning: something odd\" >&2\n"
        "printf 'iosc\\nkde-desktop\\nNot A Preset\\n\\n../etc\\ngnome\\r\\n'\n", seen);
    write_script(script, body);
    request_all(sock, "PRESETS\n", buf, sizeof(buf));
    assert(strcmp(buf, "iosc\nkde-desktop\ngnome\nPRESETS_END\t0\n") == 0);
    {
        char want[PATH_MAX + 32], got[PATH_MAX + 64];
        snprintf(want, sizeof(want), "presets %s\n", g_local_path);
        slurp(seen, got, sizeof(got));
        assert(strcmp(got, want) == 0);
        slurp(g_ioscd_session_log, got, sizeof(got));
        assert(strstr(got, "warning: something odd") != NULL);   /* stderr -> session log */
    }
    puts("ioscd-presets: runs 'xios-session presets' with the SESSION PATH; relays preset names only");

    /* A tab after the verb is tolerated, like APPS_LIST. */
    request_all(sock, "PRESETS\textra\n", buf, sizeof(buf));
    assert(strcmp(buf, "iosc\nkde-desktop\ngnome\nPRESETS_END\t0\n") == 0);

    /* A failing run still reports its status, so the app can fall back. */
    write_script(script, "echo iosc\nexit 3\n");
    request_all(sock, "PRESETS\n", buf, sizeof(buf));
    assert(strcmp(buf, "iosc\nPRESETS_END\t3\n") == 0);
    puts("ioscd-presets: a non-zero exit is PRESETS_END with that status");

    /* No presets installed is a valid empty answer, not an error. */
    write_script(script, "exit 0\n");
    request_all(sock, "PRESETS\n", buf, sizeof(buf));
    assert(strcmp(buf, "PRESETS_END\t0\n") == 0);

    /* A hung script cannot park the daemon. */
    write_script(script, "echo iosc\nexec sleep 30\n");
    request_all(sock, "PRESETS\n", buf, sizeof(buf));
    assert(strcmp(buf, "ERR presets timed out\n") == 0);
    request_all(sock, "STATUS\n", buf, sizeof(buf));        /* still serving */
    assert(strstr(buf, "STATUS_END") != NULL);
    puts("ioscd-presets: a hung xios-session is killed, the daemon keeps serving");

    /* The real xios-session and lib on a scratch prefix: the answer is the
     * shell's own xs_installed_presets, not a copy of its rules. */
    unlink(script);
    stop_daemon(daemon, sock);
    char libexec[300], iosc[300], shell_sh[300], cmd[1000];
    snprintf(libexec, sizeof(libexec), "%s/libexec/xios-session", t_jb);
    snprintf(iosc, sizeof(iosc), "%s/usr/local/bin/iosc", t_jb);
    snprintf(shell_sh, sizeof(shell_sh), "%s/run-shell.sh", libexec);
    snprintf(cmd, sizeof(cmd), "/bin/mkdir -p '%s'", libexec);
    assert(system(cmd) == 0);
    write_script(iosc, "exit 0\n");
    write_script(shell_sh, "exit 0\n");
    setenv("XS_JB", t_jb, 1);
    setenv("XS_TMP", t_tmp, 1);
    const char *clear[] = { "MUTTER", "SHELL_BIN", "IOSC_BIN", "KWIN_BIN", "PLASMA_BIN",
                            "XIOS_SESSION_BRINGUP_DIR", "XIOS_SESSION_LIB",
                            "XIOS_SESSION_SLOT", NULL };
    for (int i = 0; clear[i]; i++) unsetenv(clear[i]);
    /* The shipped script and lib, installed where ioscd looks for them. */
    snprintf(cmd, sizeof(cmd), "/bin/cp '%s/xios-session' '%s' && /bin/cp '%s/xios-session-lib.sh' '%s/'",
             session_src_dir, script, session_src_dir, libexec);
    assert(system(cmd) == 0);
    daemon = start_daemon(log);
    request_all(sock, "PRESETS\n", buf, sizeof(buf));
    assert(strcmp(buf, "iosc\nPRESETS_END\t0\n") == 0);       /* no mutter, gnome or kde here */
    assert(unlink(iosc) == 0);
    request_all(sock, "PRESETS\n", buf, sizeof(buf));
    assert(strcmp(buf, "PRESETS_END\t0\n") == 0);              /* iosc binary gone */
    puts("ioscd-presets: the real xios-session answers from its own preflight (iosc only, then none)");

    stop_daemon(daemon, sock);
    unsetenv("XS_JB");
    unsetenv("XS_TMP");
    unlink(shell_sh);
    unlink(script);
    unlink(log);
    unlink(seen);
}

static void a11y_stub_run(const char *busdir, char *out, size_t len)
{
    char log[256];
    snprintf(log, sizeof(log), "%s/ioscd-client.log", t_tmp);
    unlink(log);
    assert(start_a11y_for_busdir(busdir) == 1);
    while (waitpid(-1, NULL, 0) > 0) {}
    slurp(log, out, len);
}

static void test_a11y(void)
{
    char busdir[200], sock[260], buf[4096], want[600], a11y_sock[300], pid_file[300];
    snprintf(busdir, sizeof(busdir), "%s/abus", t_tmp);
    assert(mkdir(busdir, 0700) == 0);
    snprintf(sock, sizeof(sock), "%s/session-bus", busdir);
    int bus = make_listener(sock);
    snprintf(a11y_sock, sizeof(a11y_sock), "%s/xios-a11y.sock", t_tmp);
    snprintf(pid_file, sizeof(pid_file), "%s.pid", a11y_sock);

    /* A bus mobile owns (ioscd's own): the helper gets mobile's identity, and
     * its logs and socket land where mobile can write; it inherits no fds. */
    a11y_stub_run(busdir, buf, sizeof(buf));
    assert(strstr(buf, "a11y fds=0\n") != NULL);
    assert(strstr(buf, "a11y HOME=/var/mobile\n") != NULL);
    assert(strstr(buf, "a11y USER=mobile\n") != NULL);
    snprintf(want, sizeof(want), "a11y XDG_RUNTIME_DIR=%s\n", busdir);
    assert(strstr(buf, want) != NULL);
    snprintf(want, sizeof(want), "a11y DBUS_SESSION_BUS_ADDRESS=unix:path=%s\n", sock);
    assert(strstr(buf, want) != NULL);
    snprintf(want, sizeof(want), "a11y XIOS_A11Y_SOCK=%s\n", a11y_sock);
    assert(strstr(buf, want) != NULL);
    snprintf(want, sizeof(want), "a11y XIOS_ATSPI_LOG=%s/xios-atspi.log\n", busdir);
    assert(strstr(buf, want) != NULL);
    snprintf(want, sizeof(want), "a11y XIOS_A11YD_LOG=%s/xios-a11yd.log\n", busdir);
    assert(strstr(buf, want) != NULL);
    puts("ioscd-a11y: the helper on mobile's bus runs as mobile, with logs and socket mobile can write");

    /* A bus another user owns (xios-session's, root's) keeps the old helper
     * environment. */
    t_mobile_uid_offset = 1;
    a11y_stub_run(busdir, buf, sizeof(buf));
    assert(strstr(buf, "a11y XIOS_A11Y_SOCK=\n") != NULL);
    assert(strstr(buf, "a11y XIOS_ATSPI_LOG=\n") != NULL);
    assert(strstr(buf, "a11y HOME=/var/mobile\n") == NULL);
    puts("ioscd-a11y: a bus another user owns keeps the old helper environment");

    /* Leftovers of the old root-run helper: a dead one's socket and pid file
     * are cleared so mobile can bind. (The test user stands in for root.) */
    t_mobile_uid_offset = 0;
    close(make_listener(a11y_sock));
    FILE *f = fopen(pid_file, "w");
    assert(f);
    fputs("999999\n", f);
    fclose(f);
    migrate_root_a11y_leftovers(busdir, a11y_sock);
    struct stat st;
    assert(lstat(a11y_sock, &st) != 0 && lstat(pid_file, &st) != 0);
    puts("ioscd-a11y: a dead root helper's socket and pid file are cleared");

    /* A live xios-a11yd, another user's or mobile's, is not disturbed. */
    int pp[2];
    assert(pipe(pp) == 0);
    pid_t mid = fork();
    assert(mid >= 0);
    pid_t live = 0;
    if (mid == 0) {
        pid_t g = fork();
        if (g == 0) {
            int null = open("/dev/null", O_WRONLY);
            dup2(null, 1);
            close(pp[0]);
            close(pp[1]);
            execl(t_a11yd_copy, "xios-a11yd", (char *)NULL);
            _exit(127);
        }
        (void)!write(pp[1], &g, sizeof(g));
        _exit(0);
    }
    close(pp[1]);
    assert(read(pp[0], &live, sizeof(live)) == sizeof(live));
    close(pp[0]);
    waitpid(mid, NULL, 0);
    for (int i = 0; i < 100 && !is_helper(live, "xios-a11yd"); i++) usleep(20 * 1000);
    assert(is_helper(live, "xios-a11yd"));
    close(make_listener(a11y_sock));
    f = fopen(pid_file, "w");
    assert(f);
    fprintf(f, "%d\n", (int)live);
    fclose(f);
    t_mobile_uid_offset = 1;               /* the live helper is now "another user's" */
    migrate_root_a11y_leftovers(busdir, a11y_sock);
    assert(lstat(a11y_sock, &st) == 0 && lstat(pid_file, &st) == 0);
    t_mobile_uid_offset = 0;               /* and as mobile's own */
    migrate_root_a11y_leftovers(busdir, a11y_sock);
    assert(lstat(a11y_sock, &st) == 0 && lstat(pid_file, &st) == 0);
    puts("ioscd-a11y: a live xios-a11yd's socket and pid file are left alone");

    kill_wait(live);
    while (waitpid(-1, NULL, WNOHANG) > 0) {}
    unlink(a11y_sock);
    unlink(pid_file);
    close(bus);
    unlink(sock);
    rmdir(busdir);
}

static void write_status(const char *body)
{
    char dir[256], path[300];
    snprintf(dir, sizeof(dir), "%s/xios-status.d", t_tmp);
    mkdir(dir, 01777);
    snprintf(path, sizeof(path), "%s/iosc.status", dir);
    FILE *f = fopen(path, "w");
    assert(f);
    fputs(body, f);
    fclose(f);
}

static void run_client(const char *self, const char *app_id)
{
    char *argv_env[] = { (char *)self, (char *)"--print-x11-env", NULL };
    pid_t pid = launch_client(app_id, argv_env, 0);
    assert(pid > 0);
    while (waitpid(-1, NULL, 0) > 0) {}
}

static void test_x11(const char *self)
{
    char d[32], xsock[256], log[256], buf[8192];
    snprintf(xsock, sizeof(xsock), "%s/X7", g_x11_unix_dir);
    snprintf(log, sizeof(log), "%s/ioscd-client.log", t_tmp);

    write_status("pacing\tevent-loop\nx11-display\t:7\n");
    assert(iosc_x11_display(0, d, sizeof(d)) == 0);       /* no X socket */
    close(make_listener(xsock));
    assert(iosc_x11_display(0, d, sizeof(d)) == 0);       /* a dead server's socket */
    int x = make_listener(xsock);
    assert(iosc_x11_display(0, d, sizeof(d)) == 1 && strcmp(d, ":7") == 0);
    assert(iosc_x11_display(1, d, sizeof(d)) == 0);       /* native has its own sidecar */
    write_status("x11-display\t:7\nx11-display\tnone\n");   /* Xwayland died */
    assert(iosc_x11_display(0, d, sizeof(d)) == -1);
    write_status("x11-display\t:7x\n");
    assert(iosc_x11_display(0, d, sizeof(d)) == 0);
    puts("ioscd-x11: x11-display is believed only while its X socket answers");

    /* No bus daemon in the scratch prefix, so the client runs straight from
     * the dbus-run-session fallback (also missing) to its own argv. */
    setenv("DISPLAY", ":99", 1);                          /* never inherited */
    write_status("x11-display\t:7\n");
    run_client(self, "test.x11");
    slurp(log, buf, sizeof(buf));
    assert(strstr(buf, "client DISPLAY=:7 GDK_BACKEND=wayland,x11\n") != NULL);
    close(x);
    unlink(xsock);
    run_client(self, "test.nox11");
    slurp(log, buf, sizeof(buf));
    assert(strstr(buf, "client DISPLAY= GDK_BACKEND=wayland\n") != NULL);
    unsetenv("DISPLAY");
    puts("ioscd-x11: launched apps get DISPLAY + GDK_BACKEND=wayland,x11 only while X is up");

    /* ioscd's own classic iosc start, like xios_session_iosc. */
    unsetenv("IOSC_XWAYLAND");
    unsetenv("IOSC_XWAYLAND_BIN");
    set_iosc_xwayland_env(0);
    assert(!getenv("IOSC_XWAYLAND"));                     /* not installed */
    FILE *f = fopen(g_xwayland_bin, "w");
    assert(f);
    fputs("#!/bin/sh\n", f);
    fclose(f);
    assert(chmod(g_xwayland_bin, 0755) == 0);
    set_iosc_xwayland_env(1);
    assert(!getenv("IOSC_XWAYLAND"));                     /* native: left alone */
    set_iosc_xwayland_env(0);
    assert(getenv("IOSC_XWAYLAND") && strcmp(getenv("IOSC_XWAYLAND"), "1") == 0);
    assert(strcmp(getenv("IOSC_XWAYLAND_BIN"), g_xwayland_bin) == 0);
    setenv("IOSC_XWAYLAND", "0", 1);
    unsetenv("IOSC_XWAYLAND_BIN");
    set_iosc_xwayland_env(0);
    assert(strcmp(getenv("IOSC_XWAYLAND"), "0") == 0 && !getenv("IOSC_XWAYLAND_BIN"));
    unsetenv("IOSC_XWAYLAND");
    unlink(g_xwayland_bin);
    puts("ioscd-x11: ioscd's iosc gets IOSC_XWAYLAND=1 when Xwayland is installed; =0 opts out");
}

int main(int argc, char **argv)
{
    char self[PATH_MAX], dir[200], path[256];
    char *base = basename(argv[0]);
    if (strcmp(base, "xios-start-a11y") == 0)
        return a11y_helper_main();
    if (strncmp(base, "xios-", 5) == 0)
        return helper_main();
    if (argc > 1 && strcmp(argv[1], "--print-x11-env") == 0) {
        printf("client DISPLAY=%s GDK_BACKEND=%s\n",
               getenv("DISPLAY") ? getenv("DISPLAY") : "",
               getenv("GDK_BACKEND") ? getenv("GDK_BACKEND") : "");
        return 0;
    }

    assert(realpath(argv[0], self));
    snprintf(t_root, sizeof(t_root), "/tmp/xios-hlp.XXXXXX");
    assert(mkdtemp(t_root));
    snprintf(t_tmp, sizeof(t_tmp), "%s/t", t_root);
    snprintf(t_jb, sizeof(t_jb), "%s/jb", t_root);
    assert(mkdir(t_tmp, 01777) == 0 && mkdir(t_jb, 0755) == 0);
    const char *parts[] = { "/usr", "/usr/bin", "/usr/libexec", "/usr/local", "/usr/local/bin", NULL };
    snprintf(dir, sizeof(dir), "%s/x11", t_root);
    assert(mkdir(dir, 01777) == 0);
    setenv("XIOS_X11_UNIX_DIR", dir, 1);
    for (int i = 0; parts[i]; i++) {
        snprintf(dir, sizeof(dir), "%s%s", t_jb, parts[i]);
        assert(mkdir(dir, 0755) == 0);
    }
    snprintf(path, sizeof(path), "%s/usr/bin/bash", t_jb);
    assert(symlink("/bin/bash", path) == 0);
    /* Copies, not links: the kernel names a process after the file it ran. */
    for (int i = 0; i < 3; i++) {
        char cmd[1024];
        snprintf(cmd, sizeof(cmd), "/bin/cp '%s' '%s/usr/libexec/%s'", self, t_jb, k_names[i]);
        assert(system(cmd) == 0);
    }
    snprintf(path, sizeof(path), "%s/usr/local/bin/xios-start-a11y", t_jb);
    snprintf(dir, sizeof(dir), "/bin/cp '%s' '%s'", self, path);
    assert(system(dir) == 0);
    snprintf(t_a11yd_copy, sizeof(t_a11yd_copy), "%s/usr/libexec/xios-a11yd", t_jb);
    snprintf(dir, sizeof(dir), "/bin/cp '%s' '%s'", self, t_a11yd_copy);
    assert(system(dir) == 0);
    setenv("IOSC_JBROOT", t_jb, 1);
    setenv("XIOS_RUNTIME_TMP", t_tmp, 1);
    init_paths();

    test_helpers(self);
    test_missing_session();
    test_presets(SESSION_SRC_DIR);
    test_a11y();
    test_x11(self);

    char cmd[256];
    snprintf(cmd, sizeof(cmd), "/bin/rm -rf '%s'", t_root);
    (void)system(cmd);
    puts("ioscd-helpers tests: ok");
    return 0;
}
