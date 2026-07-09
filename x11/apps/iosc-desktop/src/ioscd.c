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
 *     LAUNCH\t<app_id>\t<exec>\n          -> LAUNCHED\n | RAISED\n | ERR <msg>\n
 *     LAUNCH_NATIVE\t<app_id>\t<exec>\n   -> same, on the native iPadOS path
 *     LAUNCH_CLASSIC\t<app_id>\t<exec>\n  -> same, on the classic Xios path
 *     SESSION\t<preset>\t<app>\t<w>\t<h>\t<dpi>\t<slot>\n
 *                                         -> SESSION_STARTED\n | SESSION_ACTIVE\n | ERR <msg>\n
 *     SESSION_ENSURE\t...same payload...  -> same replies, ensure semantics for all peers
 *     APPS_LIST\n                         -> TSV app list + APPS_END\t<status>\n
 *     APPS_SYNC\t<native|classic>\t<dry>\n -> sync log + APPS_END\t<status>\n
 *     APP_ENABLE\t<app_id>\n              -> status + APPS_END\t<status>\n
 *     APP_DISABLE\t<app_id>\n             -> status + APPS_END\t<status>\n
 *     A11Y_STATE\t<0|1>\n                 -> A11Y_OK\n | ERR <msg>\n
 *
 * For each launch ioscd:
 *   1. ensures iosc (the compositor) is running, restarting it if the wayland
 *      socket is gone — same bring-up as run-iosc.sh;
 *   2. foregrounds Xios.app via `uiopen -b com.max.xios` (the on-screen display);
 *   3. if a client we previously spawned for <app_id> is still alive, asks iosc
 *      to raise that window (iosc-wm.sock, see NOTE) instead of duplicating it;
 *      otherwise execs <exec> under the iosc client environment and remembers it.
 *
 * Existing-window raises are sent to iosc over /var/jb/tmp/iosc-wm.sock. If the
 * compositor is from an older build or the socket is gone, ioscd degrades to
 * foregrounding the shared display and avoids duplicating a known-live client.
 *
 * SESSION policy (2026-07-08: stray uid-501 "SESSION gnome" requests repeatedly
 * tore down a healthy KDE desktop, then retried the failing gnome preset in a
 * loop — see x11-ioscd-session-stomp). Destructive session requests (anything
 * except the additive "app" preset and slotted sessions) are gated:
 *   - root + plain SESSION: always honored (the xios-session CLI contract).
 *   - the Xios display app (peer path *\/Xios.app/Xios) + plain SESSION:
 *     honored — the in-app picker is the user speaking — subject to the
 *     cooldown/debounce below.
 *   - everyone else, and SESSION_ENSURE from anyone: ENSURE semantics. If the
 *     active session is healthy: same preset -> SESSION_ACTIVE no-op, different
 *     preset -> ERR (a mere app host never tears down a working desktop). Only
 *     when nothing healthy is running may the request start a session.
 *   - failed presets cool down (2/10/30 min as consecutive failures mount) and
 *     session starts are debounced 20s for every non-root peer, so a broken
 *     preset can't be retried into a desktop-killing loop.
 * "Healthy" = active-session marker set + status state live (up/compositor-only
 * verified against a live wayland-0 listener; starting/waiting/relaunching
 * trusted as-is while a bring-up is in flight).
 *
 * Standalone: depends on nothing else in this repo. Build with build-stub.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <poll.h>
#include <pwd.h>
#include <limits.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/types.h>

#include <stdint.h>

#if defined(__has_include)
#  if __has_include(<libproc.h>)
#    include <libproc.h>
#    define XIOS_HAVE_LIBPROC 1
#  endif
#endif
#ifndef XIOS_HAVE_LIBPROC
/* The iOS SDK ships no libproc.h, so the __has_include probe above silently
 * compiled peer-path attribution out of every device build — the 2026-07-08
 * session-stomp log had uid=501 lines with no path, which is why the sender
 * was never identified. The syscall wrapper is in libSystem regardless
 * (device-proven by TaskManager); redeclare the one prototype we need. */
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define XIOS_HAVE_LIBPROC 1
#endif

#ifndef SOL_LOCAL
#define SOL_LOCAL 0
#endif

#define XIOS_BUNDLE    "com.max.xios"
#define WAYLAND_NAME_CLASSIC "wayland-0"
#define WAYLAND_NAME_NATIVE  "wayland-native-0"

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

struct mode_cfg {
    const char *name;
    const char *wayland_sock;
    const char *wayland_name;
    const char *json;
    const char *ddx_sock;
    const char *input_sock;
    const char *lock_sock;
};

static struct mode_cfg g_modes[2];

static char g_jbroot[PATH_MAX];
static char g_tmp[PATH_MAX];
static char g_runtime_var[PATH_MAX];
static char g_ctl_sock[PATH_MAX];
static char g_iosc_wm_sock[PATH_MAX];
static char g_active_session[PATH_MAX];
static char g_iosc_bin[PATH_MAX];
static char g_xios_session_bin[PATH_MAX];
static char g_xios_session_bin_fallback[PATH_MAX];
static char g_xios_launcher_sync[PATH_MAX];
static char g_uiopen_bin[PATH_MAX];
static char g_bash_bin[PATH_MAX];
static char g_dbus_run[PATH_MAX];
static char g_dbus_daemon[PATH_MAX];
static char g_ioscd_bus_dir[PATH_MAX];
static char g_iosc_log[PATH_MAX];
static char g_ioscd_client_log[PATH_MAX];
static char g_ioscd_session_log[PATH_MAX];
static char g_angle_real_libegl[PATH_MAX];
static char g_home[PATH_MAX];
static char g_xios_pulse_profile[PATH_MAX];
static char g_xios_start_a11y[PATH_MAX];
static char g_xios_hwbridged[PATH_MAX];
static char g_xios_sensord[PATH_MAX];
static char g_xios_sysintd[PATH_MAX];
static char g_native_flag[PATH_MAX];
static char g_session_status[PATH_MAX];
static char g_a11y_enabled[PATH_MAX];
static char g_a11y_force[PATH_MAX];
static char g_path[PATH_MAX * 2];
static char g_local_path[PATH_MAX * 2];

static void copy_path(char *dst, size_t dst_len, const char *src)
{
    if (!dst || dst_len == 0) return;
    snprintf(dst, dst_len, "%s", src ? src : "");
}

static void trim_trailing_slashes(char *s)
{
    size_t len;
    if (!s) return;
    len = strlen(s);
    while (len > 1 && s[len - 1] == '/') {
        s[--len] = 0;
    }
}

static void prefixed_path(char *dst, size_t dst_len, const char *suffix)
{
    if (!dst || dst_len == 0) return;
    if (!suffix) suffix = "";
    if (!g_jbroot[0] || strcmp(g_jbroot, "/") == 0) {
        snprintf(dst, dst_len, "%s", suffix);
    } else {
        snprintf(dst, dst_len, "%s%s", g_jbroot, suffix);
    }
}

static void tmp_path(char *dst, size_t dst_len, const char *name)
{
    snprintf(dst, dst_len, "%s/%s", g_tmp, name);
}

static void init_paths(void)
{
    const char *root = getenv("IOSC_JBROOT");
    if (!root || !*root) root = getenv("JBROOT");
    if (!root || !*root) root = getenv("XIOS_PREFIX");
    if (!root || !*root) root = (access("/var/jb/usr", X_OK) == 0) ? "/var/jb" : "";

    copy_path(g_jbroot, sizeof(g_jbroot), root);
    trim_trailing_slashes(g_jbroot);
    if (strcmp(g_jbroot, "/") == 0) g_jbroot[0] = 0;

    const char *runtime_tmp = getenv("XIOS_RUNTIME_TMP");
    if (runtime_tmp && *runtime_tmp) {
        copy_path(g_tmp, sizeof(g_tmp), runtime_tmp);
    } else if (g_jbroot[0]) {
        prefixed_path(g_tmp, sizeof(g_tmp), "/tmp");
    } else {
        copy_path(g_tmp, sizeof(g_tmp), "/var/tmp");
    }
    trim_trailing_slashes(g_tmp);

    const char *runtime_var = getenv("XIOS_RUNTIME_VAR");
    if (runtime_var && *runtime_var) {
        copy_path(g_runtime_var, sizeof(g_runtime_var), runtime_var);
    } else if (g_jbroot[0]) {
        prefixed_path(g_runtime_var, sizeof(g_runtime_var), "/var");
    } else {
        copy_path(g_runtime_var, sizeof(g_runtime_var), "/var");
    }
    trim_trailing_slashes(g_runtime_var);

    tmp_path(g_ctl_sock, sizeof(g_ctl_sock), "ioscd.sock");
    tmp_path(g_iosc_wm_sock, sizeof(g_iosc_wm_sock), "iosc-wm.sock");
    tmp_path(g_active_session, sizeof(g_active_session), "xios-active-session");
    tmp_path(g_ioscd_bus_dir, sizeof(g_ioscd_bus_dir), "ioscd-bus");
    tmp_path(g_iosc_log, sizeof(g_iosc_log), "iosc.log");
    tmp_path(g_ioscd_client_log, sizeof(g_ioscd_client_log), "ioscd-client.log");
    tmp_path(g_ioscd_session_log, sizeof(g_ioscd_session_log), "ioscd-session.log");
    tmp_path(g_native_flag, sizeof(g_native_flag), "iosc.native");
    tmp_path(g_session_status, sizeof(g_session_status), "xios-session-status.json");
    tmp_path(g_a11y_enabled, sizeof(g_a11y_enabled), "xios-a11y-enabled");
    tmp_path(g_a11y_force, sizeof(g_a11y_force), "xios-a11y-force");

    prefixed_path(g_iosc_bin, sizeof(g_iosc_bin), "/usr/local/bin/iosc");
    prefixed_path(g_xios_session_bin, sizeof(g_xios_session_bin), "/usr/local/bin/xios-session");
    prefixed_path(g_xios_session_bin_fallback, sizeof(g_xios_session_bin_fallback), "/usr/bin/xios-session");
    prefixed_path(g_xios_launcher_sync, sizeof(g_xios_launcher_sync), "/usr/local/bin/xios-launcher-sync");
    prefixed_path(g_uiopen_bin, sizeof(g_uiopen_bin), "/usr/bin/uiopen");
    prefixed_path(g_bash_bin, sizeof(g_bash_bin), "/usr/bin/bash");
    prefixed_path(g_dbus_run, sizeof(g_dbus_run), "/usr/bin/dbus-run-session");
    prefixed_path(g_dbus_daemon, sizeof(g_dbus_daemon), "/usr/bin/dbus-daemon");
    prefixed_path(g_angle_real_libegl, sizeof(g_angle_real_libegl), "/lib/angle/libEGL.angle.dylib");
    prefixed_path(g_xios_pulse_profile, sizeof(g_xios_pulse_profile), "/etc/profile.d/xios-pulse.sh");
    prefixed_path(g_xios_start_a11y, sizeof(g_xios_start_a11y), "/usr/local/bin/xios-start-a11y");
    prefixed_path(g_xios_hwbridged, sizeof(g_xios_hwbridged), "/usr/libexec/xios-hwbridged");
    prefixed_path(g_xios_sensord, sizeof(g_xios_sensord), "/usr/libexec/xios-sensord");
    prefixed_path(g_xios_sysintd, sizeof(g_xios_sysintd), "/usr/libexec/xios-sysintd");

    if (g_jbroot[0]) {
        snprintf(g_home, sizeof(g_home), "%s/var/root", g_jbroot);
        snprintf(g_path, sizeof(g_path), "%s/usr/bin:%s/usr/sbin:%s/bin:%s/sbin:/usr/bin:/bin",
                 g_jbroot, g_jbroot, g_jbroot, g_jbroot);
        snprintf(g_local_path, sizeof(g_local_path), "%s/usr/local/bin:%s",
                 g_jbroot, g_path);
    } else {
        copy_path(g_home, sizeof(g_home), "/var/root");
        copy_path(g_path, sizeof(g_path), "/usr/bin:/usr/sbin:/bin:/sbin");
        copy_path(g_local_path, sizeof(g_local_path), "/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin");
    }

    static char wayland_classic[PATH_MAX], wayland_native[PATH_MAX];
    static char json_classic[PATH_MAX], json_native[PATH_MAX];
    static char ddx_classic[PATH_MAX], ddx_native[PATH_MAX];
    static char input_classic[PATH_MAX], input_native[PATH_MAX];
    static char lock_classic[PATH_MAX], lock_native[PATH_MAX];

    tmp_path(wayland_classic, sizeof(wayland_classic), "wayland-0");
    tmp_path(wayland_native, sizeof(wayland_native), "wayland-native-0");
    tmp_path(json_classic, sizeof(json_classic), "xios.json");
    tmp_path(json_native, sizeof(json_native), "xios-native.json");
    tmp_path(ddx_classic, sizeof(ddx_classic), "iosc-ddx.sock");
    tmp_path(ddx_native, sizeof(ddx_native), "iosc-native-ddx.sock");
    tmp_path(input_classic, sizeof(input_classic), "iosc-input.sock");
    tmp_path(input_native, sizeof(input_native), "iosc-native-input.sock");
    tmp_path(lock_classic, sizeof(lock_classic), "wayland-0.lock");
    tmp_path(lock_native, sizeof(lock_native), "wayland-native-0.lock");

    g_modes[0] = (struct mode_cfg){
        .name = "classic",
        .wayland_sock = wayland_classic,
        .wayland_name = WAYLAND_NAME_CLASSIC,
        .json = json_classic,
        .ddx_sock = ddx_classic,
        .input_sock = input_classic,
        .lock_sock = lock_classic,
    };
    g_modes[1] = (struct mode_cfg){
        .name = "native",
        .wayland_sock = wayland_native,
        .wayland_name = WAYLAND_NAME_NATIVE,
        .json = json_native,
        .ddx_sock = ddx_native,
        .input_sock = input_native,
        .lock_sock = lock_native,
    };
}

/* app_id -> last client pid we spawned (so a re-tap raises, not duplicates). */
#define MAX_APPS 64
struct app_entry { char app_id[256]; pid_t pid; int native; };
static struct app_entry g_apps[MAX_APPS];
static int g_napps = 0;

static volatile sig_atomic_t g_sigchld = 0;
static int g_chld_pipe[2] = { -1, -1 };
static pid_t g_iosc_pid[2] = { 0, 0 };  /* [0]=classic, [1]=native */

/* Native iPadOS flavor: each app is presented by its OWN per-app host app in its
 * own UIWindowScene (iosc-host), NOT inside the single fullscreen Xios window. In
 * native mode ioscd starts a second compositor namespace (wayland-native-0 +
 * iosc-native-input.sock) so native hosts can coexist with the classic Xios
 * desktop on wayland-0. A tapped native host is already foreground, so ioscd does
 * not uiopen com.max.xios for native launches. */
static int g_default_native = 0;

static int detect_native(void)
{
    const char *e = getenv("IOSC_NATIVE");
    if (e && (*e == '1' || *e == 't' || *e == 'T' || *e == 'y' || *e == 'Y')) return 1;
    struct stat st; return stat(g_native_flag, &st) == 0;
}

static const struct mode_cfg *mode_cfg(int native) { return &g_modes[native ? 1 : 0]; }
static const char *mode_name(int native) { return mode_cfg(native)->name; }

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

static int socket_exists(const char *p)
{
    struct stat st; return stat(p, &st) == 0 && S_ISSOCK(st.st_mode);
}

static void mobile_socket_perms(const char *path, const char *label)
{
    struct passwd *pw = getpwnam("mobile");
    uid_t uid = pw ? pw->pw_uid : 501;
    gid_t gid = pw ? pw->pw_gid : 501;
    if (chown(path, uid, gid) == 0) {
        chmod(path, 0660);
    } else {
        chmod(path, 0600);
        fprintf(stderr, "ioscd: keeping %s %s owner-only; chown mobile failed: %s\n",
                label, path, strerror(errno));
    }
}

static void child_stdio(const char *logpath, int append)
{
    int in = open("/dev/null", O_RDONLY);
    if (in >= 0) {
        dup2(in, 0);
        if (in > 2) close(in);
    }

    int out = logpath
        ? open(logpath, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0644)
        : open("/dev/null", O_WRONLY);
    if (out >= 0) {
        dup2(out, 1);
        dup2(out, 2);
        if (out > 2) close(out);
    }
}

static void set_rootless_path(int include_local)
{
    setenv("PATH", include_local ? g_local_path : g_path, 1);
}

static int read_active_session(char *buf, size_t buflen)
{
    int fd;
    ssize_t n;

    if (!buf || buflen == 0)
        return 0;
    buf[0] = 0;

    fd = open(g_active_session, O_RDONLY);
    if (fd < 0)
        return 0;
    n = read(fd, buf, buflen - 1);
    close(fd);
    if (n <= 0)
        return 0;
    buf[n] = 0;
    buf[strcspn(buf, "\r\n\t ")] = 0;
    return buf[0] != 0;
}

static int classic_iosc_allowed(char *owner, size_t owner_len)
{
    if (!read_active_session(owner, owner_len))
        return 1;
    return strcmp(owner, "iosc") == 0 || strcmp(owner, "stop") == 0;
}

/* --- session request policy state -------------------------------------------
 * Consecutive-failure tracking per preset (the 2026-07-08 loop retried a gnome
 * preset that had failed 4x in a row, killing the healthy KDE desktop each
 * time) plus the forked xios-session children whose exits feed it. In-memory
 * only: an ioscd restart forgives every preset, which is also the natural
 * "I fixed it, let me try again now" override. */

/* Extract a top-level "key":"value" string from a small JSON file (the shapes
 * xs_write_status emits; no nesting, no escaped quotes in the fields we read). */
static void json_str_field(const char *buf, const char *key,
                           char *dst, size_t dst_len)
{
    char pat[80];
    const char *p, *q;
    if (!dst || dst_len == 0) return;
    dst[0] = 0;
    snprintf(pat, sizeof(pat), "\"%s\":\"", key);
    p = strstr(buf, pat);
    if (!p) return;
    p += strlen(pat);
    q = strchr(p, '"');
    if (!q || (size_t)(q - p) >= dst_len) return;
    memcpy(dst, p, (size_t)(q - p));
    dst[q - p] = 0;
}

/* preset + state out of xios-session-status.json (empty strings if absent). */
static void read_session_status(char *preset, size_t plen,
                                char *state, size_t slen)
{
    char buf[2048];
    ssize_t n;
    preset[0] = state[0] = 0;
    int fd = open(g_session_status, O_RDONLY);
    if (fd < 0) return;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return;
    buf[n] = 0;
    json_str_field(buf, "preset", preset, plen);
    json_str_field(buf, "state", state, slen);
}

#define MAX_PRESET_HEALTH 16
struct preset_health { char preset[64]; int fails; uint64_t last_fail_ms; };
static struct preset_health g_preset_health[MAX_PRESET_HEALTH];
static int g_npreset_health = 0;

#define MAX_SESSION_CHILDREN 8
struct session_child { pid_t pid; char preset[64]; };
static struct session_child g_session_children[MAX_SESSION_CHILDREN];
static uint64_t g_last_session_fork_ms = 0;
#define SESSION_DEBOUNCE_MS 20000

static struct preset_health *preset_health(const char *preset, int create)
{
    for (int i = 0; i < g_npreset_health; i++)
        if (strcmp(g_preset_health[i].preset, preset) == 0)
            return &g_preset_health[i];
    if (!create || g_npreset_health >= MAX_PRESET_HEALTH)
        return NULL;
    struct preset_health *h = &g_preset_health[g_npreset_health++];
    strncpy(h->preset, preset, sizeof(h->preset) - 1);
    h->preset[sizeof(h->preset) - 1] = 0;
    h->fails = 0;
    h->last_fail_ms = 0;
    return h;
}

static uint64_t preset_cooldown_ms(int fails)
{
    if (fails <= 0) return 0;
    if (fails == 1) return 2 * 60 * 1000;
    if (fails == 2) return 10 * 60 * 1000;
    return 30 * 60 * 1000;
}

/* ms until non-root requests for <preset> are honored again; 0 = no cooldown */
static uint64_t preset_cooldown_remaining_ms(const char *preset)
{
    struct preset_health *h = preset_health(preset, 0);
    if (!h || h->fails <= 0) return 0;
    uint64_t cool = preset_cooldown_ms(h->fails);
    uint64_t since = now_ms() - h->last_fail_ms;
    return since >= cool ? 0 : cool - since;
}

static void record_session_outcome(const char *preset, int failed)
{
    struct preset_health *h = preset_health(preset, failed);
    if (!h) return;
    if (failed) {
        h->fails++;
        h->last_fail_ms = now_ms();
    } else {
        h->fails = 0;
    }
}

static void track_session_child(pid_t pid, const char *preset)
{
    for (int i = 0; i < MAX_SESSION_CHILDREN; i++) {
        if (g_session_children[i].pid != 0) continue;
        g_session_children[i].pid = pid;
        strncpy(g_session_children[i].preset, preset,
                sizeof(g_session_children[i].preset) - 1);
        g_session_children[i].preset[sizeof(g_session_children[i].preset) - 1] = 0;
        return;
    }
}

/* Called from the reaper for every exited child; true if it was a session
 * child we track. Failure = nonzero exit (75 excepted: that is xios-session's
 * "another operation is running" busy code, not a preset defect), plus a
 * status-file backstop for bring-up paths that swallow the exit code. */
static int note_session_child_exit(pid_t pid, int status)
{
    for (int i = 0; i < MAX_SESSION_CHILDREN; i++) {
        if (g_session_children[i].pid != pid) continue;
        const char *preset = g_session_children[i].preset;
        int rc = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
        int failed;
        if (rc == 75) {
            failed = 0;
        } else if (rc != 0) {
            failed = 1;
        } else {
            char sp[64], st[64];
            read_session_status(sp, sizeof(sp), st, sizeof(st));
            failed = strcmp(sp, preset) == 0 && strcmp(st, "error") == 0;
        }
        record_session_outcome(preset, failed);
        fprintf(stderr, "ioscd: session child preset=%s pid=%d rc=%d -> %s\n",
                preset, (int)pid, rc, failed ? "FAILED (cooldown armed)" : "ok");
        g_session_children[i].pid = 0;
        return 1;
    }
    return 0;
}

/* Reap exited children and drop them from the table so the next tap relaunches. */
static void reap_children(void)
{
    int status; pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        if (pid == g_iosc_pid[0]) { g_iosc_pid[0] = 0; continue; }
        if (pid == g_iosc_pid[1]) { g_iosc_pid[1] = 0; continue; }
        if (note_session_child_exit(pid, status)) continue;
        int known = 0;
        for (int i = 0; i < g_napps; i++) {
            if (g_apps[i].pid == pid) {
                g_apps[i] = g_apps[--g_napps];   /* swap-remove */
                known = 1;
                break;
            }
        }
        if (!known) {
            if (WIFEXITED(status)) {
                fprintf(stderr, "ioscd: child pid=%d exited status=%d\n",
                        (int)pid, WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                fprintf(stderr, "ioscd: child pid=%d killed signal=%d\n",
                        (int)pid, WTERMSIG(status));
            } else {
                fprintf(stderr, "ioscd: child pid=%d ended status=0x%x\n",
                        (int)pid, status);
            }
        }
    }
}

static struct app_entry *find_app(const char *app_id, int native)
{
    if (!app_id || !*app_id) return NULL;
    for (int i = 0; i < g_napps; i++)
        if (g_apps[i].native == native && strcmp(g_apps[i].app_id, app_id) == 0) return &g_apps[i];
    return NULL;
}

static void remember_app(const char *app_id, pid_t pid, int native)
{
    struct app_entry *e = find_app(app_id, native);
    if (!e) {
        if (g_napps >= MAX_APPS) return;
        e = &g_apps[g_napps++];
        strncpy(e->app_id, app_id ? app_id : "", sizeof(e->app_id) - 1);
        e->app_id[sizeof(e->app_id) - 1] = 0;
        e->native = native;
    }
    e->pid = pid;
}

/* Let the mobile-owned Xios app connect to the root-created rendezvous socket. */
static void fix_ddx_perms(int native)
{
    mobile_socket_perms(mode_cfg(native)->ddx_sock, "ddx socket");
}

static int iosc_alive(int native)
{
    if (g_iosc_pid[native] > 0 &&
        kill(g_iosc_pid[native], 0) == 0 &&
        path_exists(mode_cfg(native)->wayland_sock))
        return 1;
    return 0;
}

/* True if something is actually LISTENING on the wayland socket — i.e. a live
 * compositor ioscd did not spawn (launchd restarted ioscd while the setsid'd
 * iosc survived, or the desktop was brought up by xios-session / run-shell.sh).
 * connect() distinguishes a live listener from a stale path left by a dead
 * compositor (ECONNREFUSED). libwayland treats the immediately-closed probe as
 * a client that disconnected before saying anything — harmless. */
static int wayland_sock_live(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, path, sizeof(a.sun_path) - 1);
    int live = connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0;
    close(fd);
    return live;
}

/* --- session request peers + health ---------------------------------------- */

struct peer_info {
    pid_t pid;
    uid_t uid;
    gid_t gid;
    int have_eid;
    char path[256];
};

static pid_t peer_pid_for_fd(int fd)
{
    pid_t pid = -1;
#ifdef LOCAL_PEERPID
    socklen_t len = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 && pid > 0)
        return pid;
#endif
    return -1;
}

/* Capture identity at accept time, BEFORE the request is read: strays that
 * fire one line and exit are gone by the time the line is parsed, which is
 * how the 2026-07-08 session-stomp loop stayed anonymous. */
static void capture_peer(int fd, struct peer_info *p)
{
    memset(p, 0, sizeof(*p));
    p->pid = peer_pid_for_fd(fd);
    p->uid = (uid_t)-1;
    p->gid = (gid_t)-1;
#if defined(__APPLE__)
    if (getpeereid(fd, &p->uid, &p->gid) == 0)
        p->have_eid = 1;
#endif
#if XIOS_HAVE_LIBPROC
    if (p->pid > 0)
        (void)proc_pidpath((int)p->pid, p->path, (uint32_t)sizeof(p->path));
#endif
}

static void format_peer(const struct peer_info *p, char *dst, size_t dst_len)
{
    if (p->pid > 0 && p->path[0]) {
        if (p->have_eid)
            snprintf(dst, dst_len, "pid=%d uid=%ld gid=%ld path=%s",
                     (int)p->pid, (long)p->uid, (long)p->gid, p->path);
        else
            snprintf(dst, dst_len, "pid=%d path=%s", (int)p->pid, p->path);
    } else if (p->pid > 0) {
        if (p->have_eid)
            snprintf(dst, dst_len, "pid=%d uid=%ld gid=%ld",
                     (int)p->pid, (long)p->uid, (long)p->gid);
        else
            snprintf(dst, dst_len, "pid=%d", (int)p->pid);
    } else if (p->have_eid) {
        snprintf(dst, dst_len, "uid=%ld gid=%ld", (long)p->uid, (long)p->gid);
    } else {
        snprintf(dst, dst_len, "peer=unknown");
    }
}

/* The Xios display app (the in-app session picker) runs as mobile but speaks
 * for the user; recognize it by its resolved binary path. */
static int peer_is_xios_app(const struct peer_info *p)
{
    static const char suffix[] = "/Xios.app/Xios";
    size_t len = strlen(p->path), slen = sizeof(suffix) - 1;
    return len >= slen && strcmp(p->path + len - slen, suffix) == 0;
}

static int session_state_transitional(const char *state)
{
    return strcmp(state, "starting") == 0 || strcmp(state, "waiting") == 0 ||
           strcmp(state, "relaunching") == 0 || strcmp(state, "stopping") == 0;
}

/* Is a desktop session running well enough that a stray request must not tear
 * it down? Writes the active session's name into <active>. A live wayland
 * listener is the ground truth — a stale status file or marker left by a
 * crashed session never blocks recovery — with one grace: while xios-session
 * reports a switch in flight (transitional state + active marker) the socket
 * is legitimately absent, and the bring-up still deserves protection. */
static int active_session_healthy(char *active, size_t active_len)
{
    char sp[64], st[64];
    int have_marker = read_active_session(active, active_len) &&
                      strcmp(active, "stop") != 0;

    read_session_status(sp, sizeof(sp), st, sizeof(st));
    if (have_marker && st[0] && session_state_transitional(st))
        return 1;
    if (wayland_sock_live(mode_cfg(0)->wayland_sock)) {
        if (!have_marker)
            snprintf(active, active_len, "unknown");
        return 1;
    }
    /* No classic session: a live native compositor still counts — the
     * teardown a session start runs would kill the native hosts just the
     * same. */
    if (wayland_sock_live(mode_cfg(1)->wayland_sock)) {
        snprintf(active, active_len, "native");
        return 1;
    }
    return 0;
}

/* Bring up the desktop audio stack (xios-audiod + PulseAudio) via the pulse
 * profile helper, the same way the run-*.sh launchers do. We shell out because
 * xios_pulse_start lives in profile.d and ioscd links nothing audio-related.
 * Idempotent: the helper no-ops when each daemon is already up, so calling it
 * from every ensure_iosc is cheap. Synchronous wait (the helper sleeps ~1s at
 * most) so the daemons are up before the first client connects. */
static void ensure_audio(void)
{
    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        char cmd[PATH_MAX + 80];
        setsid();
        child_stdio(NULL, 0);
        setenv("XDG_RUNTIME_DIR", g_tmp, 1);
        set_rootless_path(0);
        snprintf(cmd, sizeof(cmd), ". %s 2>/dev/null && xios_pulse_start", g_xios_pulse_profile);
        execl(g_bash_bin, "bash", "-lc", cmd, (char *)NULL);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
}

/* Start iosc the way run-iosc.sh does: nohup it with XDG_RUNTIME_DIR=/var/jb/tmp,
 * wait for the wayland socket + the app-handshake json, then fix socket perms. */
static int ensure_iosc(int native)
{
    /* Desktop audio comes up alongside the compositor, before any client. */
    ensure_audio();

    const struct mode_cfg *mode = mode_cfg(native);
    char owner[64];

    if (!native && !classic_iosc_allowed(owner, sizeof(owner))) {
        fprintf(stderr,
                "ioscd: refusing to start classic iosc while active session is %s\n",
                owner);
        return -2;
    }

    if (iosc_alive(native)) return 0;

    /* A compositor we did not spawn may own the socket. Adopt it instead of
     * clobbering its rendezvous files out from under its clients (per
     * docs/iosc-desktop-env.md §6: restart only when the compositor is dead OR
     * wayland-0 is gone — "we never forked one" is neither). g_iosc_pid stays 0:
     * we don't own it, and a re-probe next LAUNCH re-adopts or restarts. */
    if (wayland_sock_live(mode->wayland_sock)) {
        fix_ddx_perms(native);
        return 0;
    }

    /* truly stale socket from a dead compositor would fool the wait loop */
    unlink(mode->wayland_sock);
    unlink(mode->lock_sock);
    unlink(mode->json);

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        child_stdio(g_iosc_log, 0);
        setenv("XDG_RUNTIME_DIR", g_tmp, 1);
        set_rootless_path(0);
        if (native) setenv("IOSC_NATIVE", "1", 1);   /* per-window canvas export */
        else unsetenv("IOSC_NATIVE");
        /* Logical desktop; iosc renders a 2x-oversized IOSurface the Xios app
         * supersamples down to the panel for the ~1.5 effective scale (Max-approved).
         * Env override lets the launcher retune without a rebuild. */
        const char *logical = getenv("IOSC_LOGICAL");
        if (!logical || !*logical) logical = "1440x1080";
        execl(g_iosc_bin, "iosc",
              native ? "-native" : "-classic",
              "-s", mode->wayland_name,
              "-ddx-sock", mode->ddx_sock,
              "-json", mode->json,
              "-input-sock", mode->input_sock,
              "-logical", logical,
              (char *)NULL);
        _exit(127);
    }
    g_iosc_pid[native] = pid;

    uint64_t deadline = now_ms() + 8000;   /* up to 8s for socket + handshake */
    while (now_ms() < deadline) {
        /* Detect a crashed/exec-failed iosc directly. We must waitpid here: the
         * SIGCHLD handler never reaps (reap_children runs from the main poll
         * loop, which is blocked while we spin), so a dead child would sit as a
         * zombie and kill(pid, 0) would keep succeeding for the whole deadline. */
        int status;
        if (waitpid(pid, &status, WNOHANG) > 0) { g_iosc_pid[native] = 0; return -1; }
        if (path_exists(mode->wayland_sock) && path_exists(mode->json)) break;
        usleep(150 * 1000);
    }
    if (!path_exists(mode->wayland_sock) || !path_exists(mode->json)) return -1;
    fix_ddx_perms(native);
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
        child_stdio(NULL, 0);
        /* -b (open as if tapped -> foreground) is required: the bare form
         * returns 0 but FrontBoard suspends the background-launched Metal app
         * before it adopts the IOSurface. Same form the run scripts use. */
        execl(g_uiopen_bin, "uiopen", "-b", XIOS_BUNDLE, (char *)NULL);
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
    strncpy(a.sun_path, g_iosc_wm_sock, sizeof(a.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0) {
        char line[300];
        int n = snprintf(line, sizeof(line), "raise\t%s\n", app_id ? app_id : "");
        if (n > 0) (void)!write(fd, line, (size_t)n);
    }
    close(fd);
}

static int env_truthy(const char *name)
{
    const char *v = getenv(name);
    return v && *v && strcmp(v, "0") != 0 &&
           strcasecmp(v, "false") != 0 &&
           strcasecmp(v, "no") != 0 &&
           strcasecmp(v, "off") != 0;
}

static int a11y_enabled_gate(void)
{
    return env_truthy("XIOS_ENABLE_A11Y") ||
           access(g_a11y_enabled, F_OK) == 0 ||
           access(g_a11y_force, F_OK) == 0;
}

static int ensure_session_bus(char *addr, size_t addr_len)
{
    const char *busdir = g_ioscd_bus_dir;
    char sock[PATH_MAX];
    char address_arg[sizeof(sock) + 32];

    if (!addr || addr_len == 0) return 0;
    snprintf(sock, sizeof(sock), "%s/session-bus", busdir);
    snprintf(addr, addr_len, "unix:path=%s", sock);
    if (socket_exists(sock)) return 1;

    mkdir(busdir, 0700);
    chmod(busdir, 0700);
    unlink(sock);
    snprintf(address_arg, sizeof(address_arg), "--address=%s", addr);

    pid_t pid = fork();
    if (pid < 0) return 0;
    if (pid == 0) {
        child_stdio(NULL, 0);
        execl(g_dbus_daemon, "dbus-daemon", "--session", "--fork",
              address_arg, "--print-address", (char *)NULL);
        _exit(127);
    }

    int status = 0;
    waitpid(pid, &status, 0);
    return socket_exists(sock);
}

static void ensure_native_helpers_for_bus(const char *busdir, const char *bus_addr, int have_bus)
{
    if (!have_bus || !busdir || !*busdir || !bus_addr || !*bus_addr)
        return;

    pid_t pid = fork();
    if (pid < 0) return;
    if (pid == 0) {
        char cmd[4096];
        setsid();
        child_stdio(g_ioscd_client_log, 1);
        setenv("XDG_RUNTIME_DIR", busdir, 1);
        setenv("DBUS_SESSION_BUS_ADDRESS", bus_addr, 1);
        setenv("DBUS_SYSTEM_BUS_ADDRESS", bus_addr, 1);
        setenv("XIOS_HWBRIDGE_BUS", "session", 1);
        setenv("HOME", g_home, 1);
        set_rootless_path(1);
        snprintf(cmd, sizeof(cmd),
                 "if [ -r '%s' ]; then . '%s' 2>/dev/null && xios_pulse_start; fi; "
                 "start_helper() { b=\"$1\"; log=\"$2\"; name=\"${b##*/}\"; "
                 "[ -x \"$b\" ] || return 0; "
                 "ps ax 2>/dev/null | grep -v grep | grep -q \"$name\" && return 0; "
                 "\"$b\" >\"$log\" 2>&1 & }; "
                 "start_helper '%s' '%s/xios-hwbridged.log'; "
                 "start_helper '%s' '%s/xios-sensord.log'; "
                 "start_helper '%s' '%s/xios-sysintd.log'; "
                 "sleep 0.2",
                 g_xios_pulse_profile, g_xios_pulse_profile,
                 g_xios_hwbridged, busdir,
                 g_xios_sensord, busdir,
                 g_xios_sysintd, busdir);
        execl(g_bash_bin, "bash", "-lc", cmd, (char *)NULL);
        _exit(127);
    }
}

static int write_a11y_enabled_state(int on)
{
    if (!on) {
        unlink(g_a11y_enabled);
        return 0;
    }

    int fd = open(g_a11y_enabled, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    (void)!write(fd, "1\n", 2);
    close(fd);
    chmod(g_a11y_enabled, 0644);
    return 0;
}

static int start_a11y_for_busdir(const char *busdir)
{
    char sock[PATH_MAX];
    char addr[PATH_MAX + 16];

    if (!busdir || !*busdir || access(g_xios_start_a11y, X_OK) != 0)
        return 0;
    snprintf(sock, sizeof(sock), "%s/session-bus", busdir);
    if (!socket_exists(sock))
        return 0;
    snprintf(addr, sizeof(addr), "unix:path=%s", sock);

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        child_stdio(g_ioscd_client_log, 1);
        setenv("XDG_RUNTIME_DIR", busdir, 1);
        setenv("DBUS_SESSION_BUS_ADDRESS", addr, 1);
        setenv("HOME", g_home, 1);
        set_rootless_path(1);
        execl(g_xios_start_a11y, "xios-start-a11y", (char *)NULL);
        _exit(127);
    }
    return 1;
}

static void start_a11y_for_existing_buses(void)
{
    char session_busdir[PATH_MAX];
    tmp_path(session_busdir, sizeof(session_busdir), "xios-session-bus");
    (void)start_a11y_for_busdir(g_ioscd_bus_dir);
    (void)start_a11y_for_busdir(session_busdir);
}

static void set_wayland_client_env(const struct mode_cfg *mode, const char *busdir,
                                   int have_bus, const char *bus_addr,
                                   int enable_a11y)
{
    setenv("XDG_RUNTIME_DIR", busdir, 1);                 /* private, dbus-friendly */
    setenv("WAYLAND_DISPLAY", mode->wayland_sock, 1);     /* absolute path */
    setenv("XIOS_CAPABILITY_PROFILE",
           strcmp(mode->name, "native") == 0 ? "native-host" : "iosc-client-gpu",
           1);
    setenv("GDK_BACKEND", "wayland", 1);
    setenv("GSK_RENDERER", "ngl", 1);
    setenv("ANGLE_REAL_LIBEGL", g_angle_real_libegl, 1);
    setenv("GSETTINGS_BACKEND", "memory", 1);
    if (have_bus) {
        setenv("DBUS_SESSION_BUS_ADDRESS", bus_addr, 1);
        setenv("DBUS_SYSTEM_BUS_ADDRESS", bus_addr, 1);
    }
    if (enable_a11y) unsetenv("GTK_A11Y");
    else setenv("GTK_A11Y", "none", 1);
    setenv("HOME", g_home, 1);
    set_rootless_path(0);
}

/* Spawn <exec> as a Wayland client of iosc. Mirrors run-kgx.sh's environment:
 * a shared 0700 session bus dir, WAYLAND_DISPLAY by absolute path,
 * GDK wayland backend, GPU GTK rendering by default — iosc composites imported
 * IOSurfaces zero-copy — and a writable HOME. We exec through `bash -lc` so the
 * client also picks up
 * the /var/jb/etc/profile.d login scripts (PATH + ANGLE/lib paths the run
 * scripts rely on). */
static pid_t launch_client(const char *app_id, const char *exec, int native)
{
    const struct mode_cfg *mode = mode_cfg(native);
    const char *busdir = g_ioscd_bus_dir;
    char bus_addr[256];
    int have_bus = ensure_session_bus(bus_addr, sizeof(bus_addr));
    ensure_native_helpers_for_bus(busdir, bus_addr, have_bus);

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        child_stdio(g_ioscd_client_log, 1);

        int enable_a11y = a11y_enabled_gate();
        set_wayland_client_env(mode, busdir, have_bus, bus_addr, enable_a11y);

        const char *cmd = exec;
        char a11y_cmd[4096];
        if (enable_a11y) {
            int n = snprintf(a11y_cmd, sizeof(a11y_cmd),
                             "if [ -x %s ]; then "
                             "%s; "
                             "elif command -v xios-start-a11y >/dev/null 2>&1; then "
                             "xios-start-a11y; fi; exec %s",
                             g_xios_start_a11y, g_xios_start_a11y, exec);
            if (n > 0 && (size_t)n < sizeof(a11y_cmd)) cmd = a11y_cmd;
        }

        if (!have_bus) {
            execl(g_dbus_run, "dbus-run-session", "--", g_bash_bin, "-lc", cmd, (char *)NULL);
        }
        execl(g_bash_bin, "bash", "-lc", cmd, (char *)NULL);
        _exit(127);
    }
    remember_app(app_id, pid, native);
    return pid;
}

static void reply(int fd, const char *msg)
{
    (void)!write(fd, msg, strlen(msg));
}

static int digits_or_empty(const char *s)
{
    if (!s || !*s) return 1;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if (*p < '0' || *p > '9') return 0;
    return 1;
}

static void set_session_request_env(const char *width, const char *height,
                                    const char *dpi, const char *slot)
{
    if (width && *width && height && *height) {
        char logical[64];
        snprintf(logical, sizeof(logical), "%sx%s", width, height);
        setenv("IOSC_LOGICAL", logical, 1);
        setenv("XIOS_SESSION_WIDTH", width, 1);
        setenv("XIOS_SESSION_HEIGHT", height, 1);
    }
    if (dpi && *dpi) setenv("XIOS_SESSION_DPI", dpi, 1);
    if (slot && *slot) setenv("XIOS_SESSION_SLOT", slot, 1);
}

/* Run the existing xios-session implementation in a child. Keeping the session
 * logic in the shell library avoids a second teardown/startup implementation in
 * ioscd; the socket just replaces the tmp-file trigger path. */
static pid_t launch_session_request(const char *preset, const char *app,
                                    const char *width, const char *height,
                                    const char *dpi, const char *slot)
{
    if (!preset || !*preset) return -1;
    if (!digits_or_empty(width) || !digits_or_empty(height) || !digits_or_empty(dpi))
        return -1;

    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        setsid();
        child_stdio(g_ioscd_session_log, 1);
        set_rootless_path(1);
        fprintf(stderr, "ioscd: child exec xios-session preset=%s%s%s%s%s bash=%s path=%s fallback=%s\n",
                preset, (app && *app) ? " app=" : "", (app && *app) ? app : "",
                (slot && *slot) ? " slot=" : "", (slot && *slot) ? slot : "",
                g_bash_bin, g_xios_session_bin, g_xios_session_bin_fallback);
        fflush(stderr);
        set_session_request_env(width, height, dpi, slot);

        if (app && *app)
            execl(g_bash_bin, "bash", g_xios_session_bin, preset, app, (char *)NULL);
        else
            execl(g_bash_bin, "bash", g_xios_session_bin, preset, (char *)NULL);
        if (app && *app)
            execl(g_bash_bin, "bash", g_xios_session_bin_fallback, preset, app, (char *)NULL);
        else
            execl(g_bash_bin, "bash", g_xios_session_bin_fallback, preset, (char *)NULL);
        fprintf(stderr, "ioscd: exec xios-session failed: %s\n", strerror(errno));
        _exit(127);
    }
    return pid;
}

static char *take_tab_field(char **cursor)
{
    if (!cursor || !*cursor)
        return "";
    char *field = *cursor;
    char *tab = strchr(field, '\t');
    if (tab) {
        *tab = 0;
        *cursor = tab + 1;
    } else {
        *cursor = NULL;
    }
    return field;
}

static void log_session_started(const char *preset, const char *app,
                                const char *width, const char *height,
                                const char *dpi, const char *slot, pid_t pid)
{
    fprintf(stderr, "ioscd: session preset=%s", preset);
    if (app && *app) fprintf(stderr, " app=%s", app);
    if (slot && *slot) fprintf(stderr, " slot=%s", slot);
    fprintf(stderr, " pid=%d", (int)pid);
    if (width && *width) fprintf(stderr, " width=%s", width);
    if (height && *height) fprintf(stderr, " height=%s", height);
    if (dpi && *dpi) fprintf(stderr, " dpi=%s", dpi);
    fputc('\n', stderr);
}

static void handle_session_request(int fd, char *payload, int ensure,
                                   const struct peer_info *peer)
{
    char *rest = payload;
    char *preset = take_tab_field(&rest);
    char *app = take_tab_field(&rest);
    char *width = take_tab_field(&rest);
    char *height = take_tab_field(&rest);
    char *dpi = take_tab_field(&rest);
    char *slot = rest ? rest : "";

    if (!*preset) {
        reply(fd, "ERR empty preset\n");
        return;
    }

    /* Additive requests (client launch into the running compositor, slotted
     * side displays) never tear the desktop down: no policy. */
    int destructive = strcmp(preset, "app") != 0 && !*slot;
    int is_root = peer->have_eid && peer->uid == 0;

    if (destructive) {
        /* Explicit switches stay with the actors that speak for the user:
         * root (the xios-session CLI) and the Xios in-app picker. Every
         * other peer gets ensure semantics, as does SESSION_ENSURE from
         * anyone. */
        int ensure_mode = ensure || (!is_root && !peer_is_xios_app(peer));
        if (ensure_mode) {
            char active[64] = "";
            if (active_session_healthy(active, sizeof(active))) {
                if (strcmp(active, preset) == 0) {
                    fprintf(stderr,
                            "ioscd: session request no-op: %.48s already active\n",
                            preset);
                    reply(fd, "SESSION_ACTIVE\n");
                    return;
                }
                fprintf(stderr,
                        "ioscd: session request REFUSED: %.48s is healthy, %.256s wants %.48s (switching needs the Xios picker or root)\n",
                        active, peer->path[0] ? peer->path : "unidentified peer",
                        preset);
                reply(fd, "ERR active session is healthy; switching needs the Xios picker or root xios-session\n");
                return;
            }
        }
        if (!is_root) {
            uint64_t wait = preset_cooldown_remaining_ms(preset);
            if (wait) {
                char msg[192];
                fprintf(stderr,
                        "ioscd: session request REFUSED: preset %.48s cooling down %llus after repeated failures\n",
                        preset, (unsigned long long)(wait / 1000 + 1));
                snprintf(msg, sizeof(msg),
                         "ERR preset %.48s failed recently; retry in %llus or run xios-session as root\n",
                         preset, (unsigned long long)(wait / 1000 + 1));
                reply(fd, msg);
                return;
            }
            if (g_last_session_fork_ms &&
                now_ms() - g_last_session_fork_ms < SESSION_DEBOUNCE_MS) {
                fprintf(stderr,
                        "ioscd: session request REFUSED: debounce (last session start <%ds ago)\n",
                        SESSION_DEBOUNCE_MS / 1000);
                reply(fd, "ERR a session change just ran; retry in a few seconds\n");
                return;
            }
        }
    }

    pid_t pid = launch_session_request(preset, app, width, height, dpi, slot);
    if (pid <= 0) {
        reply(fd, "ERR session start failed\n");
        return;
    }
    if (destructive) {
        track_session_child(pid, preset);
        g_last_session_fork_ms = now_ms();
    }

    log_session_started(preset, app, width, height, dpi, slot, pid);
    reply(fd, "SESSION_STARTED\n");
}

static int run_and_stream(int fd, char *const argv[])
{
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        reply(fd, "ERR pipe failed\n");
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        reply(fd, "ERR fork failed\n");
        return -1;
    }
    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], 1);
        dup2(pipefd[1], 2);
        if (pipefd[1] > 2) close(pipefd[1]);
        set_rootless_path(1);
        execv(argv[0], argv);
        fprintf(stderr, "exec %s failed: %s\n", argv[0], strerror(errno));
        _exit(127);
    }

    close(pipefd[1]);
    char buf[2048];
    ssize_t n;
    while ((n = read(pipefd[0], buf, sizeof(buf))) > 0)
        (void)!write(fd, buf, (size_t)n);
    close(pipefd[0]);
    int status = 0;
    waitpid(pid, &status, 0);
    int code = WIFEXITED(status) ? WEXITSTATUS(status) : 128;
    char end[64];
    snprintf(end, sizeof(end), "APPS_END\t%d\n", code);
    reply(fd, end);
    return code == 0 ? 0 : -1;
}

static int run_launcher_sync(int fd, char *const argv[])
{
    if (access(g_xios_launcher_sync, X_OK) != 0) {
        reply(fd, "ERR xios-launcher-sync not installed\n");
        return -1;
    }
    return run_and_stream(fd, argv);
}

static void handle_apps_list(int fd)
{
    char *argv[] = { g_xios_launcher_sync, "--list", NULL };
    (void)run_launcher_sync(fd, argv);
}

static void handle_apps_sync(int fd, char *payload)
{
    char *rest = payload;
    char *mode = take_tab_field(&rest);
    char *dry = rest ? rest : "";
    int native = strcmp(mode, "classic") != 0;
    int dry_run = strcmp(dry, "dry") == 0 || strcmp(dry, "1") == 0 ||
                  strcasecmp(dry, "true") == 0;

    char *argv[7];
    int i = 0;
    argv[i++] = g_xios_launcher_sync;
    argv[i++] = "--sync";
    argv[i++] = native ? "--native" : "--classic";
    if (dry_run) argv[i++] = "--dry-run";
    argv[i] = NULL;
    (void)run_launcher_sync(fd, argv);
}

static void handle_app_toggle(int fd, const char *verb, char *payload)
{
    char *app_id = payload;
    app_id[strcspn(app_id, "\t\r\n")] = 0;
    if (!*app_id) {
        reply(fd, "ERR empty app_id\n");
        return;
    }
    char *argv[] = {
        g_xios_launcher_sync,
        strcmp(verb, "APP_ENABLE") == 0 ? "--enable" : "--disable",
        app_id,
        NULL
    };
    (void)run_launcher_sync(fd, argv);
}

static void handle_a11y_state(int fd, char *payload)
{
    char *state = payload;
    state[strcspn(state, "\t\r\n ")] = 0;

    int on;
    if (strcmp(state, "1") == 0 || strcasecmp(state, "true") == 0 ||
        strcasecmp(state, "yes") == 0 || strcasecmp(state, "on") == 0) {
        on = 1;
    } else if (strcmp(state, "0") == 0 || strcasecmp(state, "false") == 0 ||
               strcasecmp(state, "no") == 0 || strcasecmp(state, "off") == 0) {
        on = 0;
    } else {
        reply(fd, "ERR bad a11y state\n");
        return;
    }

    if (write_a11y_enabled_state(on) != 0) {
        reply(fd, "ERR a11y state write failed\n");
        return;
    }
    if (on)
        start_a11y_for_existing_buses();

    fprintf(stderr, "ioscd: a11y state %s\n", on ? "on" : "off");
    reply(fd, "A11Y_OK\n");
}

static int launch_mode_for_verb(const char *verb, int *native)
{
    if (strcmp(verb, "LAUNCH") == 0) {
        *native = g_default_native;
        return 1;
    }
    if (strcmp(verb, "LAUNCH_NATIVE") == 0) {
        *native = 1;
        return 1;
    }
    if (strcmp(verb, "LAUNCH_CLASSIC") == 0) {
        *native = 0;
        return 1;
    }
    return 0;
}

static void handle_launch_request(int fd, const char *verb, char *payload)
{
    char *app_id = payload;
    char *t2 = strchr(app_id, '\t');
    if (!t2) {
        reply(fd, "ERR malformed\n");
        return;
    }
    *t2 = 0;
    char *exec = t2 + 1;

    int native = g_default_native;
    if (!launch_mode_for_verb(verb, &native)) {
        reply(fd, "ERR unknown verb\n");
        return;
    }
    if (!*exec) {
        reply(fd, "ERR empty exec\n");
        return;
    }

    reap_children();

    int ensure_rc = ensure_iosc(native);
    if (ensure_rc != 0) {
        if (ensure_rc == -2) {
            reply(fd, "ERR active session is not iosc\n");
            return;
        }
        fprintf(stderr, "ioscd: %s iosc failed to start (see %s)\n", mode_name(native), g_iosc_log);
        reply(fd, "ERR iosc start failed\n");
        return;
    }
    if (!native) foreground_xios();

    struct app_entry *e = find_app(app_id, native);
    if (e && e->pid > 0 && kill(e->pid, 0) == 0) {
        iosc_raise(app_id);
        fprintf(stderr, "ioscd: raise mode=%s app_id=%s (pid %d live)\n",
                mode_name(native), app_id, (int)e->pid);
        reply(fd, "RAISED\n");
        return;
    }

    pid_t pid = launch_client(app_id, exec, native);
    if (pid <= 0) {
        reply(fd, "ERR fork failed\n");
        return;
    }

    fprintf(stderr, "ioscd: launch mode=%s app_id=%s pid=%d exec=%s\n",
            mode_name(native), app_id, (int)pid, exec);
    reply(fd, "LAUNCHED\n");
}

static void sanitized_copy(char *dst, size_t dst_len, const char *src)
{
    size_t i;
    if (!dst || dst_len == 0) return;
    if (!src) { dst[0] = 0; return; }
    for (i = 0; i + 1 < dst_len && src[i]; i++) {
        unsigned char c = (unsigned char)src[i];
        dst[i] = (c < 32 || c == 127) ? ' ' : (char)c;
    }
    dst[i] = 0;
}

static void log_session_request_peer(const struct peer_info *peer,
                                     const char *verb, const char *payload)
{
    char who[384];
    char clean[1024];
    format_peer(peer, who, sizeof(who));
    sanitized_copy(clean, sizeof(clean), payload);
    fprintf(stderr, "ioscd: session request %s payload=\"%s %s\"\n",
            who, verb, clean);
}

/* Handle one client connection: read a line, dispatch LAUNCH/SESSION. */
static void handle_conn(int fd)
{
    struct peer_info peer;
    char buf[8192];
    size_t len = 0;

    /* Identify the peer before reading: a one-shot sender may already be gone
     * by the time its line is parsed (see capture_peer). */
    capture_peer(fd, &peer);
    /* Read up to a newline, bounded by a deadline: this loop runs in the single
     * accept thread, so a connected-but-silent client must not park the whole
     * daemon in read() forever (SA_RESTART means signals won't break it out
     * either). A live launcher writes its one line immediately after connect;
     * 3s is generous. On timeout just drop the connection. */
    uint64_t deadline = now_ms() + 3000;
    while (len < sizeof(buf) - 1) {
        uint64_t now = now_ms();
        if (now >= deadline) return;
        struct pollfd p = { .fd = fd, .events = POLLIN, .revents = 0 };
        int pr = poll(&p, 1, (int)(deadline - now));
        if (pr < 0 && errno == EINTR) continue;
        if (pr <= 0) return;
        ssize_t n = read(fd, buf + len, sizeof(buf) - 1 - len);
        if (n <= 0) break;
        len += (size_t)n;
        if (memchr(buf, '\n', len)) break;
    }
    buf[len] = 0;
    char *nl = strchr(buf, '\n'); if (nl) *nl = 0;

    /* split "VERB\t..." */
    char *verb = buf;
    char *t1 = strchr(buf, '\t');
    if (!t1) {
        if (strcmp(verb, "APPS_LIST") == 0) {
            handle_apps_list(fd);
            return;
        }
        reply(fd, "ERR malformed\n");
        return;
    }
    *t1 = 0;

    if (strcmp(verb, "SESSION") == 0 || strcmp(verb, "SESSION_ENSURE") == 0) {
        log_session_request_peer(&peer, verb, t1 + 1);
        handle_session_request(fd, t1 + 1,
                               strcmp(verb, "SESSION_ENSURE") == 0, &peer);
        return;
    }
    if (strcmp(verb, "APPS_LIST") == 0) {
        handle_apps_list(fd);
        return;
    }
    if (strcmp(verb, "APPS_SYNC") == 0) {
        handle_apps_sync(fd, t1 + 1);
        return;
    }
    if (strcmp(verb, "APP_ENABLE") == 0 || strcmp(verb, "APP_DISABLE") == 0) {
        handle_app_toggle(fd, verb, t1 + 1);
        return;
    }
    if (strcmp(verb, "A11Y_STATE") == 0) {
        handle_a11y_state(fd, t1 + 1);
        return;
    }

    handle_launch_request(fd, verb, t1 + 1);
}

static int make_ctl_socket(void)
{
    unlink(g_ctl_sock);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }
    struct sockaddr_un a; memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    strncpy(a.sun_path, g_ctl_sock, sizeof(a.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { perror("bind"); close(fd); return -1; }
    mobile_socket_perms(g_ctl_sock, "control socket");
    if (listen(fd, 16) != 0) { perror("listen"); close(fd); return -1; }
    return fd;
}

int main(void)
{
    init_paths();

    /* keep TMP present (it normally is; harmless if it exists) */
    mkdir(g_tmp, 01777);

    g_default_native = detect_native();
    fprintf(stderr, "ioscd: default launch mode=%s; explicit LAUNCH_NATIVE/LAUNCH_CLASSIC supported\n",
            mode_name(g_default_native));
    fprintf(stderr, "ioscd: session policy active (ensure/switch guard, failure cooldown, peer attribution)\n");

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
    fprintf(stderr, "ioscd: listening on %s\n", g_ctl_sock);

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
