/*
 * xios-sysintd — session-side receiver for iOS system-integration events.
 *
 * The Xios app mirrors iPad state the desktop can't see from inside the session:
 *   XIOS_IN_VOLUME     hardware volume buttons -> the PulseAudio sink volume, so
 *                      the desktop's own volume UI (gvc / GNOME panel) tracks the
 *                      buttons. This is also the media-keys stand-in: gsd's
 *                      media-keys plugin stays dropped, the buttons work anyway.
 *   XIOS_IN_APPEARANCE iOS light/dark -> org.gnome.desktop.interface color-scheme
 *                      (libadwaita/GTK4) plus a gtk-theme flip for GTK3 apps.
 *
 * Deliberately NOT part of iosc: the compositor stays out of audio and theme
 * policy. This daemon is autostarted inside the desktop session (xios-server.sh /
 * xios.session), so it inherits the env that makes the appliers work:
 * PULSE_SERVER for pactl, DBUS_SESSION_BUS_ADDRESS + XDG_* for gsettings/dconf.
 *
 * Transport: the same fixed 24-byte records as the compositor input socket (ONE
 * framing implementation — xios_input_socket.c), on a separate AF_UNIX socket so
 * a lost compositor never takes the volume path down with it.
 *
 * Knobs (env):
 *   XIOS_SYSINT_SOCK        socket path   (default /var/jb/tmp/xios-sysint.sock)
 *   XIOS_SYSINT_SINK        PA sink name  (default "xios")
 *   XIOS_SYSINT_GTK3_LIGHT  gtk-theme for light (default "Adwaita")
 *   XIOS_SYSINT_GTK3_DARK   gtk-theme for dark  (default "Adwaita-dark")
 *   XIOS_SYSINT_NO_GTK3=1   only set color-scheme, leave gtk-theme alone
 */
#include "xios_input_socket.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/time.h>

extern char **environ;

static const char *s_sink = "xios";
static int s_no_gtk3;
static const char *s_gtk3_light = "Adwaita";
static const char *s_gtk3_dark  = "Adwaita-dark";

/* Volume applies are coalesced: KVO on the app side fires per hardware-button
 * step and pactl costs a process spawn, so apply the newest value at most every
 * VOLUME_COALESCE_MS. Appearance changes are rare and apply immediately. */
#define VOLUME_COALESCE_MS 100
static int      s_pending_volume = -1;   /* 0..65535, -1 = nothing pending */
static uint64_t s_last_volume_ms;
static int      s_applied_appearance = -1;

static uint64_t now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000u + (uint64_t)(tv.tv_usec / 1000);
}

/* Spawn argv[0] via PATH, wait, log failures. The appliers are quick one-shots
 * (pactl/gsettings); waiting keeps the daemon zombie-free and serializes writes. */
static int run(char *const argv[])
{
    pid_t pid;
    int rc = posix_spawnp(&pid, argv[0], NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "xios-sysintd: spawn %s failed: %s\n", argv[0], strerror(rc));
        return 127;
    }
    int st = 0;
    while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
        ;
    if (WIFEXITED(st)) {
        if (WEXITSTATUS(st) != 0)
            fprintf(stderr, "xios-sysintd: %s exited %d\n", argv[0], WEXITSTATUS(st));
        return WEXITSTATUS(st);
    }
    if (WIFSIGNALED(st)) {
        fprintf(stderr, "xios-sysintd: %s killed by signal %d\n", argv[0], WTERMSIG(st));
        return 128 + WTERMSIG(st);
    }
    return 1;
}

static void apply_volume(int v16)
{
    int pct = (v16 * 100 + 32767) / 65535;
    char vol[16];
    snprintf(vol, sizeof(vol), "%d%%", pct);
    char *argv[] = { "pactl", "set-sink-volume", (char *)s_sink, vol, NULL };
    run(argv);
    fprintf(stderr, "xios-sysintd: volume -> %s on sink %s\n", vol, s_sink);
}

static void apply_appearance(int dark)
{
    char *scheme[] = { "gsettings", "set", "org.gnome.desktop.interface",
                       "color-scheme", dark ? "prefer-dark" : "prefer-light", NULL };
    char *scheme_fallback[] = { "gsettings", "set", "org.gnome.desktop.interface",
                                "color-scheme", "default", NULL };
    if (run(scheme) != 0 && !dark)
        run(scheme_fallback);
    if (!s_no_gtk3) {
        char *theme[] = { "gsettings", "set", "org.gnome.desktop.interface",
                          "gtk-theme",
                          (char *)(dark ? s_gtk3_dark : s_gtk3_light), NULL };
        run(theme);
    }
    fprintf(stderr, "xios-sysintd: appearance -> %s\n", dark ? "dark" : "light");
}

static void on_record(const struct xios_in_msg *m, const char *text,
                      size_t text_len, uint32_t bound_window, void *user)
{
    (void)text; (void)text_len; (void)bound_window; (void)user;
    switch (m->type) {
    case XIOS_IN_VOLUME: {
        int v = (int)(m->code > 65535u ? 65535u : m->code);
        uint64_t now = now_ms();
        if (now - s_last_volume_ms >= VOLUME_COALESCE_MS) {
            s_last_volume_ms = now;
            s_pending_volume = -1;
            apply_volume(v);
        } else {
            s_pending_volume = v;   /* newest wins; flushed on the poll timeout */
        }
        break;
    }
    case XIOS_IN_APPEARANCE: {
        int dark = m->code ? 1 : 0;
        if (dark != s_applied_appearance) {
            s_applied_appearance = dark;
            apply_appearance(dark);
        }
        break;
    }
    default:
        break;   /* additive registry: unknown types pass through untouched */
    }
}

int main(void)
{
    const char *sock = getenv("XIOS_SYSINT_SOCK");
    if (!sock || !*sock) sock = "/var/jb/tmp/xios-sysint.sock";
    const char *e;
    if ((e = getenv("XIOS_SYSINT_SINK")) && *e) s_sink = e;
    if ((e = getenv("XIOS_SYSINT_GTK3_LIGHT")) && *e) s_gtk3_light = e;
    if ((e = getenv("XIOS_SYSINT_GTK3_DARK")) && *e) s_gtk3_dark = e;
    s_no_gtk3 = (e = getenv("XIOS_SYSINT_NO_GTK3")) && *e && strcmp(e, "0") != 0;

    xios_input_socket *srv = xios_input_socket_new(sock);
    if (!srv) {
        fprintf(stderr, "xios-sysintd: cannot listen on %s\n", sock);
        return 1;
    }
    fprintf(stderr, "xios-sysintd: listening on %s (sink=%s, gtk3=%s)\n",
            sock, s_sink, s_no_gtk3 ? "off" : "on");

    struct pollfd pfd = { .fd = xios_input_socket_fd(srv), .events = POLLIN };
    for (;;) {
        /* Finite timeout only while a coalesced volume is waiting to flush. */
        int timeout = s_pending_volume >= 0 ? VOLUME_COALESCE_MS : -1;
        int pr = poll(&pfd, 1, timeout);
        if (pr < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "xios-sysintd: poll: %s\n", strerror(errno));
            break;
        }
        /* The input-socket callback grew bound_window in the native-window workstream.
         * xios-sysintd ignores that field, so this remains compatible with either
         * header shape while that refactor is in flight. */
        if (pr > 0 && xios_input_socket_dispatch(srv, (xios_input_cb)on_record, NULL) < 0) {
            fprintf(stderr, "xios-sysintd: socket error, exiting\n");
            break;
        }
        if (s_pending_volume >= 0 &&
            now_ms() - s_last_volume_ms >= VOLUME_COALESCE_MS) {
            int v = s_pending_volume;
            s_pending_volume = -1;
            s_last_volume_ms = now_ms();
            apply_volume(v);
        }
    }
    xios_input_socket_free(srv);
    return 1;
}
