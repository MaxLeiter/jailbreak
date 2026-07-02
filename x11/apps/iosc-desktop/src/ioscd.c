/*
 * ioscd.c — the iosc desktop launch daemon.
 *
 * A small root LaunchDaemon that bridges "tap a home-screen icon" to "run a Linux
 * app as an iosc Wayland client + show the Xios display". It exists because a
 * home-screen launcher .app runs as `mobile` inside the iOS app sandbox: any
 * process it forks inherits that sandbox. ioscd runs OUTSIDE the sandbox (root,
 * started by launchd), so it can spawn the GNOME/GTK client the way the manual
 * run-iosc.sh / run-kgx.sh scripts do today — this daemon just generalises them.
 *
 * Protocol (one line per connection on /var/jb/tmp/ioscd.sock):
 *     LAUNCH\t<app_id>\t<exec>\n      ->   LAUNCHED\n | RAISED\n | ERR <msg>\n
 *
 * For each LAUNCH ioscd:
 *   1. ensures iosc (the compositor) is running, restarting it if the wayland
 *      socket is gone — same bring-up as run-iosc.sh;
 *   2. foregrounds Xios.app via `uiopen com.max.xios` (the on-screen display);
 *   3. if a client we previously spawned for <app_id> is still alive, asks iosc
 *      to raise that window (iosc-wm.sock, see NOTE) instead of duplicating it;
 *      otherwise execs <exec> under the iosc client environment and remembers it.
 *
 * NOTE (iosc-side support still needed): raising an existing window by app_id
 * requires iosc to (a) store the xdg_toplevel app_id per surface and (b) accept a
 * `raise\t<app_id>\n` line on /var/jb/tmp/iosc-wm.sock. Until that lands, the
 * raise step is a best-effort no-op: uiopen still brings the display forward and
 * the window is already mapped, it just may not be re-stacked on top. ioscd
 * degrades gracefully (connect failure on iosc-wm.sock is ignored).
 *
 * Standalone: depends on nothing else in this repo. Build with build-stub.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <pwd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>

#define TMP            "/var/jb/tmp"
#define CTL_SOCK       TMP "/ioscd.sock"
#define WAYLAND_SOCK   TMP "/wayland-0"
#define XIOS_JSON      TMP "/xios.json"
#define IOSC_DDX_SOCK  TMP "/iosc-ddx.sock"
#define IOSC_WM_SOCK   TMP "/iosc-wm.sock"
#define IOSC_BIN       "/var/jb/usr/local/bin/iosc"
#define UIOPEN_BIN     "/var/jb/usr/bin/uiopen"
#define BASH_BIN       "/var/jb/usr/bin/bash"
#define DBUS_RUN       "/var/jb/usr/bin/dbus-run-session"
#define XIOS_BUNDLE    "com.max.xios"
#define IOSC_LOG       TMP "/iosc.log"

/* app_id -> last client pid we spawned (so a re-tap raises, not duplicates). */
#define MAX_APPS 64
struct app_entry { char app_id[256]; pid_t pid; };
static struct app_entry g_apps[MAX_APPS];
static int g_napps = 0;

static volatile sig_atomic_t g_sigchld = 0;
static int g_chld_pipe[2] = { -1, -1 };
static pid_t g_iosc_pid = 0;

/* Native iPadOS flavor: each app is presented by its OWN per-app host app in its
 * own UIWindowScene (iosc-host), NOT inside the single fullscreen Xios window. In
 * native mode ioscd (a) starts iosc with IOSC_NATIVE=1 so the compositor exports a
 * per-window canvas over iosc-native.sock, and (b) skips `uiopen com.max.xios` —
 * the tapped host IS the foreground display, so foregrounding Xios would steal it.
 * Enabled by env IOSC_NATIVE (from the LaunchDaemon plist the native flavor
 * installs) or, for test toggling without reinstalling the daemon, the presence of
 * /var/jb/tmp/iosc.native. Classic (single-Xios-window) behavior is unchanged when
 * off. */
#define NATIVE_FLAG    TMP "/iosc.native"
static int g_native = 0;

static int detect_native(void)
{
    const char *e = getenv("IOSC_NATIVE");
    if (e && (*e == '1' || *e == 't' || *e == 'T' || *e == 'y' || *e == 'Y')) return 1;
    struct stat st; return stat(NATIVE_FLAG, &st) == 0;
}

static void on_sigchld(int sig)
{
    (void)sig;
    g_sigchld = 1;
    if (g_chld_pipe[1] >= 0) { char b = 1; (void)!write(g_chld_pipe[1], &b, 1); }
}

static uint64_t now_ms(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int path_exists(const char *p)
{
    struct stat st; return stat(p, &st) == 0;
}

/* Reap exited children and drop them from the table so the next tap relaunches. */
static void reap_children(void)
{
    int status; pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        if (pid == g_iosc_pid) { g_iosc_pid = 0; continue; }
        for (int i = 0; i < g_napps; i++) {
            if (g_apps[i].pid == pid) {
                g_apps[i] = g_apps[--g_napps];   /* swap-remove */
                break;
            }
        }
    }
}

static struct app_entry *find_app(const char *app_id)
{
    if (!app_id || !*app_id) return NULL;
    for (int i = 0; i < g_napps; i++)
        if (strcmp(g_apps[i].app_id, app_id) == 0) return &g_apps[i];
    return NULL;
}

static void remember_app(const char *app_id, pid_t pid)
{
    struct app_entry *e = find_app(app_id);
    if (!e) {
        if (g_napps >= MAX_APPS) return;
        e = &g_apps[g_napps++];
        strncpy(e->app_id, app_id ? app_id : "", sizeof(e->app_id) - 1);
        e->app_id[sizeof(e->app_id) - 1] = 0;
    }
    e->pid = pid;
}

/* Loosen perms on the Xios<->iosc rendezvous socket so the (mobile) Xios app can
 * connect to the root-owned socket — identical to run-iosc.sh. */
static void fix_ddx_perms(void)
{
    struct passwd *pw = getpwnam("mobile");
    if (pw && chown(IOSC_DDX_SOCK, pw->pw_uid, pw->pw_gid) == 0)
        chmod(IOSC_DDX_SOCK, 0660);
    else
        chmod(IOSC_DDX_SOCK, 0777);
}

static int iosc_alive(void)
{
    if (g_iosc_pid > 0 && kill(g_iosc_pid, 0) == 0 && path_exists(WAYLAND_SOCK))
        return 1;
    return 0;
}

/* Start iosc the way run-iosc.sh does: nohup it with XDG_RUNTIME_DIR=/var/jb/tmp,
 * wait for the wayland socket + the app-handshake json, then fix socket perms. */
static int ensure_iosc(void)
{
    if (iosc_alive()) return 0;

    /* stale socket from a dead compositor would fool the wait loop */
    unlink(WAYLAND_SOCK);
    unlink(TMP "/wayland-0.lock");
    unlink(XIOS_JSON);

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        int log = open(IOSC_LOG, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (log >= 0) { dup2(log, 1); dup2(log, 2); if (log > 2) close(log); }
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, 0); if (devnull > 2) close(devnull); }
        setenv("XDG_RUNTIME_DIR", TMP, 1);
        setenv("PATH", "/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/bin", 1);
        if (g_native) setenv("IOSC_NATIVE", "1", 1);   /* per-window canvas export */
        /* Logical desktop; iosc renders a 2x-oversized IOSurface the Xios app
         * supersamples down to the panel for the ~1.5 effective scale (Max-approved).
         * Env override lets the launcher retune without a rebuild. */
        const char *logical = getenv("IOSC_LOGICAL");
        if (!logical || !*logical) logical = "1440x1080";
        execl(IOSC_BIN, "iosc", "-logical", logical, (char *)NULL);
        _exit(127);
    }
    g_iosc_pid = pid;

    uint64_t deadline = now_ms() + 8000;   /* up to 8s for socket + handshake */
    while (now_ms() < deadline) {
        if (!iosc_alive() && kill(pid, 0) != 0) { g_iosc_pid = 0; return -1; }
        if (path_exists(WAYLAND_SOCK) && path_exists(XIOS_JSON)) break;
        usleep(150 * 1000);
    }
    if (!path_exists(WAYLAND_SOCK)) return -1;
    fix_ddx_perms();
    return 0;
}

/* Bring the Xios display app to the foreground (FrontBoard). uiopen is the same
 * tool the run scripts use; it is the entitled component, ioscd just execs it. */
static void foreground_xios(void)
{
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        setsid();
        int devnull = open("/dev/null", O_RDWR);
        if (devnull >= 0) { dup2(devnull, 0); dup2(devnull, 1); dup2(devnull, 2); }
        execl(UIOPEN_BIN, "uiopen", XIOS_BUNDLE, (char *)NULL);
        /* older uiopen wants -b for a bundle id */
        execl(UIOPEN_BIN, "uiopen", "-b", XIOS_BUNDLE, (char *)NULL);
        _exit(127);
    }
    /* don't block on it; SIGCHLD reaps it */
}

/* Best-effort: ask iosc to raise the window for <app_id>. Silently ignored if
 * iosc doesn't yet serve iosc-wm.sock (see NOTE at top). */
static void iosc_raise(const char *app_id)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, IOSC_WM_SOCK, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
        char line[300];
        int n = snprintf(line, sizeof(line), "raise\t%s\n", app_id ? app_id : "");
        if (n > 0) (void)!write(fd, line, (size_t)n);
    }
    close(fd);
}

/* Spawn <exec> as a Wayland client of iosc. Mirrors run-kgx.sh's environment:
 * a private 0700 bus dir for dbus-run-session, WAYLAND_DISPLAY by absolute path,
 * GDK wayland backend, GPU GTK rendering by default — iosc composites imported
 * IOSurfaces zero-copy — and a writable HOME. We exec through `bash -lc` so the
 * client also picks up
 * the /var/jb/etc/profile.d login scripts (PATH + ANGLE/lib paths the run
 * scripts rely on). */
static pid_t launch_client(const char *app_id, const char *exec)
{
    const char *busdir = TMP "/ioscd-bus";
    mkdir(busdir, 0700);
    chmod(busdir, 0700);

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        const char *logpath = TMP "/ioscd-client.log";
        int log = open(logpath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (log >= 0) { dup2(log, 1); dup2(log, 2); if (log > 2) close(log); }
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, 0); if (devnull > 2) close(devnull); }

        setenv("XDG_RUNTIME_DIR", busdir, 1);          /* private, dbus-friendly */
        setenv("WAYLAND_DISPLAY", WAYLAND_SOCK, 1);    /* absolute path */
        setenv("GDK_BACKEND", "wayland", 1);
        /* Client-side rendering path. DEFAULT ngl: GTK's GL renderer goes through
         * the wl_egl_window shim (ANGLE Metal -> IOSurface, no CPU cairo paint).
         * Set IOSC_GSK_RENDERER=cairo to force the old wl_shm fallback. */
        const char *gsk = getenv("IOSC_GSK_RENDERER");
        if (!gsk || !*gsk) gsk = "ngl";
        setenv("GSK_RENDERER", gsk, 1);
        if (strcmp(gsk, "cairo") != 0) {
            /* Tell the swapped-in shim where the real ANGLE libEGL lives. */
            const char *real = getenv("ANGLE_REAL_LIBEGL");
            setenv("ANGLE_REAL_LIBEGL",
                   real && *real ? real : "/var/jb/lib/angle/libEGL.angle.dylib", 1);
        }
        setenv("GSETTINGS_BACKEND", "memory", 1);
        setenv("GTK_A11Y", "none", 1);
        setenv("HOME", "/var/jb/var/root", 1);
        setenv("PATH", "/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/bin", 1);

        /* dbus-run-session -- bash -lc "<exec>"  (login shell sources profile.d) */
        execl(DBUS_RUN, "dbus-run-session", "--", BASH_BIN, "-lc", exec, (char *)NULL);
        /* if dbus-run-session is missing, try without a session bus */
        execl(BASH_BIN, "bash", "-lc", exec, (char *)NULL);
        _exit(127);
    }
    remember_app(app_id, pid);
    return pid;
}

static void reply(int fd, const char *msg)
{
    (void)!write(fd, msg, strlen(msg));
}

/* Handle one client connection: read a line, dispatch LAUNCH. */
static void handle_conn(int fd)
{
    char buf[8192];
    size_t len = 0;
    /* read up to a newline */
    while (len < sizeof(buf) - 1) {
        ssize_t n = read(fd, buf + len, sizeof(buf) - 1 - len);
        if (n <= 0) break;
        len += (size_t)n;
        if (memchr(buf, '\n', len)) break;
    }
    buf[len] = 0;
    char *nl = strchr(buf, '\n'); if (nl) *nl = 0;

    /* split "LAUNCH\t<app_id>\t<exec>" — exec is the remainder (may hold spaces) */
    char *verb = buf;
    char *t1 = strchr(buf, '\t');
    if (!t1) { reply(fd, "ERR malformed\n"); return; }
    *t1 = 0;
    char *app_id = t1 + 1;
    char *t2 = strchr(app_id, '\t');
    if (!t2) { reply(fd, "ERR malformed\n"); return; }
    *t2 = 0;
    char *exec = t2 + 1;

    if (strcmp(verb, "LAUNCH") != 0) { reply(fd, "ERR unknown verb\n"); return; }
    if (!*exec) { reply(fd, "ERR empty exec\n"); return; }

    reap_children();

    if (ensure_iosc() != 0) {
        fprintf(stderr, "ioscd: iosc failed to start (see %s)\n", IOSC_LOG);
        reply(fd, "ERR iosc start failed\n");
        return;
    }
    /* Classic: pull the shared Xios display forward. Native: the tapped per-app
     * host is already foreground and presents this app's own windows, so don't
     * steal focus with uiopen. */
    if (!g_native) foreground_xios();

    struct app_entry *e = find_app(app_id);
    if (e && e->pid > 0 && kill(e->pid, 0) == 0) {
        iosc_raise(app_id);
        fprintf(stderr, "ioscd: raise app_id=%s (pid %d live)\n", app_id, (int)e->pid);
        reply(fd, "RAISED\n");
        return;
    }

    pid_t pid = launch_client(app_id, exec);
    if (pid > 0) {
        fprintf(stderr, "ioscd: launch app_id=%s pid=%d exec=%s\n", app_id, (int)pid, exec);
        reply(fd, "LAUNCHED\n");
    } else {
        reply(fd, "ERR fork failed\n");
    }
}

static int make_ctl_socket(void)
{
    unlink(CTL_SOCK);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, CTL_SOCK, sizeof(a.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { perror("bind"); close(fd); return -1; }
    /* world-accessible: the (mobile) launcher apps must be able to connect. Single
     * user device; the only verb is LAUNCH, which any local process could already do. */
    chmod(CTL_SOCK, 0666);
    if (listen(fd, 16) != 0) { perror("listen"); close(fd); return -1; }
    return fd;
}

int main(void)
{
    /* keep TMP present (it normally is; harmless if it exists) */
    mkdir(TMP, 01777);

    g_native = detect_native();
    fprintf(stderr, "ioscd: mode=%s\n", g_native ? "native (per-app scenes)" : "classic (single Xios window)");

    signal(SIGPIPE, SIG_IGN);
    if (pipe(g_chld_pipe) == 0) {
        fcntl(g_chld_pipe[0], F_SETFL, O_NONBLOCK);
        fcntl(g_chld_pipe[1], F_SETFL, O_NONBLOCK);
    }
    struct sigaction sa; memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigchld;
    sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
    sigaction(SIGCHLD, &sa, NULL);

    int lfd = make_ctl_socket();
    if (lfd < 0) return 1;
    fprintf(stderr, "ioscd: listening on %s\n", CTL_SOCK);

    for (;;) {
        struct pollfd pfds[2];
        pfds[0].fd = lfd;            pfds[0].events = POLLIN; pfds[0].revents = 0;
        pfds[1].fd = g_chld_pipe[0]; pfds[1].events = POLLIN; pfds[1].revents = 0;
        int n = poll(pfds, g_chld_pipe[0] >= 0 ? 2 : 1, -1);
        if (n < 0) { if (errno == EINTR) { if (g_sigchld) { g_sigchld = 0; reap_children(); } continue; } break; }

        if (g_chld_pipe[0] >= 0 && (pfds[1].revents & POLLIN)) {
            char drain[64]; while (read(g_chld_pipe[0], drain, sizeof(drain)) > 0) {}
            reap_children();
        }
        if (pfds[0].revents & POLLIN) {
            int cfd = accept(lfd, NULL, NULL);
            if (cfd >= 0) { handle_conn(cfd); close(cfd); }
        }
    }
    return 0;
}
