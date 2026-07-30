/*
 * sbprobe4 — can a CONFINED process wait for events at all?
 *
 * Device run of the confinement patches died with:
 *   EventLoopImplementationUnix::wait_for_events: poll: Operation not permitted (errno=1)
 * Core::EventLoop is poll(2)-based, so if poll() is denied the profile cannot host any
 * Ladybird process, no matter where confinement is applied. This checks poll/select/kevent
 * on fds created BEFORE confinement (the only fds a confined process can have).
 *
 * usage: sbprobe4 <none|confined> [profile]
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/select.h>
#include <sys/event.h>
#include <sys/time.h>

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[], char **errorbuf);
#define SANDBOX_NAMED 0x1ULL

static void ok(const char *what, int good, const char *detail)
{
    printf("  %-40s %s%s%s\n", what, good ? "OK" : "DENIED",
           detail && *detail ? " " : "", detail ? detail : "");
    fflush(stdout);
}

int main(int argc, char **argv)
{
    const char *mode = argc >= 2 ? argv[1] : "none";
    const char *profile = argc >= 3 ? argv[2] : "com.apple.WebKit.WebContent";
    printf("[sbprobe4 pid=%d mode=%s profile=%s]\n", getpid(), mode, profile);

    /* Everything the event loop waits on must be created before confinement. */
    int fds[2];
    if (pipe(fds) != 0) { perror("pipe"); return 2; }
    int kq = kqueue();
    printf("  pre-confinement: pipe ok, kqueue fd=%d\n", kq);

    /* A readable byte, so the waits have something to report. */
    (void)write(fds[1], "x", 1);

    if (!strcmp(mode, "confined")) {
        char *err = NULL;
        int rc = sandbox_init_with_parameters(profile, SANDBOX_NAMED, NULL, &err);
        printf("  confine: rc=%d err=%s\n", rc, err ? err : "(none)");
        if (rc != 0) return 2;
    }

    char detail[128];

    /* 1. poll() — what Core::EventLoop actually uses. */
    struct pollfd pfd = { .fd = fds[0], .events = POLLIN, .revents = 0 };
    int prc = poll(&pfd, 1, 100);
    snprintf(detail, sizeof(detail), "rc=%d %s", prc, prc < 0 ? strerror(errno) : "");
    ok("poll() on pre-made pipe", prc >= 0, detail);

    /* 2. select() — the obvious drop-in. */
    fd_set rs; FD_ZERO(&rs); FD_SET(fds[0], &rs);
    struct timeval tv = { .tv_sec = 0, .tv_usec = 100000 };
    int src = select(fds[0] + 1, &rs, NULL, NULL, &tv);
    snprintf(detail, sizeof(detail), "rc=%d %s", src, src < 0 ? strerror(errno) : "");
    ok("select() on pre-made pipe", src >= 0, detail);

    /* 3. kevent() — what Apple's own frameworks use under this profile. */
    if (kq >= 0) {
        struct kevent ev;
        EV_SET(&ev, fds[0], EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, NULL);
        int krc = kevent(kq, &ev, 1, NULL, 0, NULL);
        snprintf(detail, sizeof(detail), "rc=%d %s", krc, krc < 0 ? strerror(errno) : "");
        ok("kevent() register on pre-made kqueue", krc >= 0, detail);

        if (krc >= 0) {
            struct kevent out;
            struct timespec ts = { .tv_sec = 0, .tv_nsec = 100000000 };
            int nrc = kevent(kq, NULL, 0, &out, 1, &ts);
            snprintf(detail, sizeof(detail), "rc=%d %s", nrc, nrc < 0 ? strerror(errno) : "");
            ok("kevent() wait", nrc >= 0, detail);
        }
    }

    /* 4. A plain blocking read on a ready fd, as a floor. */
    char b;
    ssize_t rrc = read(fds[0], &b, 1);
    snprintf(detail, sizeof(detail), "rc=%zd %s", rrc, rrc < 0 ? strerror(errno) : "");
    ok("read() on pre-made pipe", rrc >= 0, detail);

    return 0;
}
