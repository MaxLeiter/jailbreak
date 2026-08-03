/*
 * sbprobe5 — is `container` a usable renderer jail, when WebContent's profile is not?
 *
 * The earlier probes settled a different question: com.apple.WebKit.WebContent denies
 * poll/select/kevent, so it cannot host any Ladybird process. `container` was set aside
 * at the time as "leaves the network reachable and so removes nothing worth having".
 * That reasoning weighs the wrong axis. What a renderer compromise actually buys an
 * attacker on this device is *filesystem write under /var/jb* — overwrite a dylib or a
 * binary there and you have persistent code execution across the whole desktop stack.
 * Network egress is not the prize, and WebContent does not even do its own networking:
 * RequestServer does, in a separate process that would stay unconfined.
 *
 * sbprobe2's matrix already hints that `container` permits the event-loop primitives and
 * denies a /var/jb/tmp write. That is one write path and one process shape. This probe
 * asks the two questions that decide whether confinement is worth wiring in:
 *
 *   1. Does `container` still deny writes at the paths that matter for persistence
 *      (/var/jb/usr/lib, /var/jb/usr/bin, the engine tree), not just /var/jb/tmp?
 *   2. Can a WebContent-shaped process still do everything it needs under it —
 *      wait on fds, read engine resources and fonts, hold and message Mach ports?
 *
 * A "yes/yes" makes confining WebContent and ImageDecoder (not RequestServer, which
 * needs the network, and not Compositor until its IOSurface path is measured) a real
 * mitigation rather than a cosmetic one. A "no" on either closes the question for good
 * and should be written into the doc so it is not reopened a third time.
 *
 * bootstrap_look_up is included because the doc records it as DENIED under WebContent's
 * profile and "not retested" under `container`. If it is denied here too, that is not a
 * blocker — it just fixes the ordering, exactly as it does for the other profile:
 * confine *after* the Mach handshake, since rights already held keep working.
 *
 * usage: sbprobe5 <none|confined> [profile]        (profile defaults to "container")
 *
 * Run BOTH modes and diff them. `none` is the control: some of these paths fail for
 * boring reasons (a file is absent, the prefix is rootful) and only the delta means
 * anything. A row that is DENIED in both modes is not evidence of confinement.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/select.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <mach/mach.h>

/* servers/bootstrap.h is not in the iOS SDK; declare what we use, as sbprobe.c does. */
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[], char **errorbuf);
#define SANDBOX_NAMED 0x1ULL

static void ok(const char *what, int good, const char *detail)
{
    printf("  %-46s %s%s%s\n", what, good ? "OK" : "DENIED",
           detail && *detail ? " " : "", detail ? detail : "");
    fflush(stdout);
}

/* A write is "denied" only if the open fails. Report errno so EACCES (sandbox) can be
 * told apart from EROFS/ENOENT (the path simply is not there on this device). */
static void probe_write(const char *path)
{
    char detail[192];
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s/.sbprobe5.%d", path, getpid());
    int fd = open(tmp, O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        ssize_t n = write(fd, "x", 1);
        close(fd);
        unlink(tmp);
        snprintf(detail, sizeof(detail), "wrote %zd byte(s)", n);
        ok(tmp, 1, detail);
    } else {
        snprintf(detail, sizeof(detail), "errno=%d %s", errno, strerror(errno));
        ok(tmp, 0, detail);
    }
}

static void probe_read(const char *path)
{
    char detail[192];
    int fd = open(path, O_RDONLY);
    if (fd >= 0) {
        char b[64];
        ssize_t n = read(fd, b, sizeof(b));
        close(fd);
        snprintf(detail, sizeof(detail), "read %zd byte(s)", n);
        ok(path, n >= 0, detail);
    } else {
        snprintf(detail, sizeof(detail), "errno=%d %s", errno, strerror(errno));
        ok(path, 0, detail);
    }
}

int main(int argc, char **argv)
{
    const char *mode = argc >= 2 ? argv[1] : "none";
    const char *profile = argc >= 3 ? argv[2] : "container";
    printf("[sbprobe5 pid=%d uid=%d mode=%s profile=%s]\n",
           getpid(), (int)getuid(), mode, profile);

    /* Everything an event loop waits on must exist before confinement, and the pipe()
     * call itself is denied under WebContent's profile -- so create it up front. */
    int fds[2];
    if (pipe(fds) != 0) { perror("pipe"); return 2; }
    int kq = kqueue();
    (void)write(fds[1], "x", 1);

    /* A Mach receive right held across confinement, mirroring the handshake result a
     * helper owns by the time it would confine itself. */
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    printf("  pre-confinement: pipe ok, kqueue fd=%d, mach recv right kr=%d\n", kq, kr);

    if (!strcmp(mode, "confined")) {
        char *err = NULL;
        int rc = sandbox_init_with_parameters(profile, SANDBOX_NAMED, NULL, &err);
        printf("  confine: rc=%d err=%s\n", rc, err ? err : "(none)");
        if (rc != 0) {
            printf("  (profile did not apply -- nothing below is a confinement result)\n");
            return 2;
        }
    }

    /* ---- 1. Can a renderer still run? ------------------------------------------- */
    printf("\n-- event loop primitives (WebContent's profile denies all three) --\n");
    char detail[192];

    struct pollfd pfd = { .fd = fds[0], .events = POLLIN, .revents = 0 };
    int prc = poll(&pfd, 1, 100);
    snprintf(detail, sizeof(detail), "rc=%d %s", prc, prc < 0 ? strerror(errno) : "");
    ok("poll() on pre-made pipe", prc >= 0, detail);

    fd_set rs; FD_ZERO(&rs); FD_SET(fds[0], &rs);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
    int src = select(fds[0] + 1, &rs, NULL, NULL, &tv);
    snprintf(detail, sizeof(detail), "rc=%d %s", src, src < 0 ? strerror(errno) : "");
    ok("select() on pre-made pipe", src >= 0, detail);

    if (kq >= 0) {
        struct kevent ev;
        EV_SET(&ev, fds[0], EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
        int krc = kevent(kq, &ev, 1, NULL, 0, NULL);
        snprintf(detail, sizeof(detail), "rc=%d %s", krc, krc < 0 ? strerror(errno) : "");
        ok("kevent() register on pre-made kqueue", krc >= 0, detail);
    }

    /* pipe() after confinement: MessagePort::entangle_with creates transports at runtime,
     * so if this is denied every `new MessageChannel()` in page JS aborts the renderer
     * unless the shared-notify-pipe patch (see the doc) is revived. */
    int late[2];
    int lrc = pipe(late);
    snprintf(detail, sizeof(detail), "rc=%d %s", lrc, lrc < 0 ? strerror(errno) : "");
    ok("pipe() AFTER confinement", lrc == 0, detail);
    if (lrc == 0) { close(late[0]); close(late[1]); }

    /* An already-held Mach right must keep working; that is what makes "confine after
     * the handshake" a viable ordering. */
    if (kr == KERN_SUCCESS) {
        mach_port_limits_t lim = { .mpl_qlimit = MACH_PORT_QLIMIT_DEFAULT };
        kern_return_t k2 = mach_port_set_attributes(mach_task_self(), port,
                                                    MACH_PORT_LIMITS_INFO,
                                                    (mach_port_info_t)&lim,
                                                    MACH_PORT_LIMITS_INFO_COUNT);
        snprintf(detail, sizeof(detail), "kr=%d", k2);
        ok("operate on pre-held mach receive right", k2 == KERN_SUCCESS, detail);
    }

    /* WARNING — THIS ROW MISLED ONCE. READ BEFORE TRUSTING IT.
     *
     * This looks up an Apple *system* service. `container` permits that. It does NOT permit
     * looking up an app-registered service, which is what a Ladybird helper actually does
     * (org.ladybird.Ladybird.helper.<pid>, registered by its parent). On 2026-08-02 this row
     * read OK, the doc concluded confinement was viable, and a real helper then died with
     * "Unable to look up service org.ladybird.Ladybird.helper.N in bootstrap /
     * Runtime error: Permission denied".
     *
     * A green here means "system services resolve", nothing more. For the question that
     * matters use sbprobe.c, which registers a CUSTOM service in a parent and looks it up
     * from a confined child -- or better, sbinject.c against a real helper. */
    mach_port_t bp = MACH_PORT_NULL;
    kern_return_t bkr = bootstrap_look_up(bootstrap_port, "com.apple.system.notification_center", &bp);
    snprintf(detail, sizeof(detail), "kr=%d (0x%x)", bkr, bkr);
    ok("bootstrap_look_up (SYSTEM service only -- see comment)", bkr == KERN_SUCCESS, detail);

    printf("\n-- resources a renderer must read --\n");
    probe_read("/var/jb/usr/share/Lagom/fonts/SerenitySans-Regular.ttf");
    probe_read("/var/jb/usr/lib/libcrypto.3.dylib");
    /* Not the framework binary: on iOS that path does not exist as a file (frameworks
     * live in the dyld shared cache), so it reports ENOENT in BOTH modes and measures
     * nothing. A real system font is the honest stand-in, and it is what a renderer
     * actually needs from /System anyway. */
    probe_read("/System/Library/Fonts/Core/SFUI.ttf");
    probe_read("/usr/lib/dyld");
    probe_read("/var/jb/etc/ssl/cert.pem");

    /* ---- 2. Is the persistence primitive actually removed? ----------------------- */
    printf("\n-- writes that a renderer compromise would want (want: all DENIED) --\n");
    probe_write("/var/jb/usr/lib");          /* dylib hijack: the whole desktop stack   */
    probe_write("/var/jb/usr/bin");          /* replace a binary: persistent execution  */
    probe_write("/var/jb/usr/share/Lagom");  /* engine resources the helpers re-read    */
    probe_write("/var/jb/etc");              /* config, incl. apt trust material        */
    probe_write("/var/jb/tmp");              /* the one path sbprobe2 already measured  */
    probe_write("/tmp");
    probe_write(getenv("HOME") ? getenv("HOME") : "/var/mobile");

    printf("\n-- network (RequestServer's job, not WebContent's) --\n");
    int u = socket(AF_UNIX, SOCK_STREAM, 0);
    snprintf(detail, sizeof(detail), "fd=%d %s", u, u < 0 ? strerror(errno) : "");
    ok("socket(AF_UNIX)", u >= 0, detail);
    if (u >= 0) close(u);

    int t = socket(AF_INET, SOCK_STREAM, 0);
    snprintf(detail, sizeof(detail), "fd=%d %s", t, t < 0 ? strerror(errno) : "");
    ok("socket(AF_INET)", t >= 0, detail);
    if (t >= 0) close(t);

    printf("\n[done] Compare against the `none` control before concluding anything.\n");
    return 0;
}
