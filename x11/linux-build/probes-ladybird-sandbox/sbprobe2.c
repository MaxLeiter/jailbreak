/*
 * sbprobe2 — can a CONFINED process still build a new IPC::Transport?
 *
 * sbprobe answered "can I still use a Mach right I already hold". That is not enough.
 * IPC::Transport::create_paired() and the TransportMachPort constructor
 * (Libraries/LibIPC/TransportMachPort.cpp:95-125) do more than reuse a port:
 *
 *   mach_port_allocate(RECEIVE)          new receive right
 *   mach_port_insert_right(MAKE_SEND)    matching send right
 *   mach_port_allocate(PORT_SET)         a port set
 *   mach_port_insert_member()            add ports to the set
 *   pipe2(O_CLOEXEC | O_NONBLOCK)        the wakeup pipe
 *   pthread_create()                     the receive thread
 *
 * Every one of those runs AFTER confinement in both helpers: ImageDecoder builds a
 * transport per new client (connect_new_client), and WebContent builds one when it
 * attaches to RequestServer/ImageDecoder during the event loop. socket() is denied by
 * this profile, so pipe2() in particular has to be measured rather than assumed.
 *
 * usage: sbprobe2 <none|confined> [profile-name]
 *        profile-name defaults to com.apple.WebKit.WebContent; "container" is the only
 *        other name found precompiled into the kernel collection on this device.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sys/socket.h>
#include <mach/mach.h>

extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[], char **errorbuf);
#define SANDBOX_NAMED 0x1ULL

static int failures = 0;

static void ok(const char *what, int good, const char *detail)
{
    printf("  %-42s %s%s%s\n", what, good ? "OK" : "DENIED",
           detail && *detail ? " " : "", detail ? detail : "");
    if (!good) failures++;
    fflush(stdout);
}

static void *noop_thread(void *arg) { (void)arg; return NULL; }

int main(int argc, char **argv)
{
    const char *mode = argc >= 2 ? argv[1] : "none";
    const char *profile = argc >= 3 ? argv[2] : "com.apple.WebKit.WebContent";
    printf("[sbprobe2 pid=%d mode=%s profile=%s]\n", getpid(), mode, profile);

    if (!strcmp(mode, "confined")) {
        char *err = NULL;
        int rc = sandbox_init_with_parameters(profile, SANDBOX_NAMED, NULL, &err);
        printf("  confine: rc=%d err=%s\n", rc, err ? err : "(none)");
        if (rc != 0) return 2;
    }

    char detail[128];

    /* --- what IPC::Transport::create_paired() does --- */
    mach_port_t recv_a = MACH_PORT_NULL, recv_b = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv_a);
    snprintf(detail, sizeof(detail), "kr=0x%x", kr);
    ok("mach_port_allocate(RECEIVE) #1", kr == KERN_SUCCESS, detail);

    kr = mach_port_insert_right(mach_task_self(), recv_a, recv_a, MACH_MSG_TYPE_MAKE_SEND);
    snprintf(detail, sizeof(detail), "kr=0x%x", kr);
    ok("mach_port_insert_right(MAKE_SEND)", kr == KERN_SUCCESS, detail);

    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv_b);
    snprintf(detail, sizeof(detail), "kr=0x%x", kr);
    ok("mach_port_allocate(RECEIVE) #2", kr == KERN_SUCCESS, detail);

    /* --- what the TransportMachPort constructor does --- */
    mach_port_t pset = MACH_PORT_NULL;
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_PORT_SET, &pset);
    snprintf(detail, sizeof(detail), "kr=0x%x", kr);
    ok("mach_port_allocate(PORT_SET)", kr == KERN_SUCCESS, detail);

    kr = mach_port_insert_member(mach_task_self(), recv_a, pset);
    snprintf(detail, sizeof(detail), "kr=0x%x", kr);
    ok("mach_port_insert_member", kr == KERN_SUCCESS, detail);

    int fds[2] = { -1, -1 };
    int prc = pipe(fds);
    if (prc == 0) {
        /* LibIPC uses pipe2(O_CLOEXEC|O_NONBLOCK); emulate the flag setting too. */
        fcntl(fds[0], F_SETFL, O_NONBLOCK);
        fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    }
    snprintf(detail, sizeof(detail), "%s", prc == 0 ? "" : strerror(errno));
    ok("pipe() + O_NONBLOCK/CLOEXEC (wakeup pipe)", prc == 0, detail);

    /* A byte through the pipe: the wakeup path actually writes to it. */
    if (prc == 0) {
        ssize_t w = write(fds[1], "x", 1);
        snprintf(detail, sizeof(detail), "%s", w == 1 ? "" : strerror(errno));
        ok("write() to the wakeup pipe", w == 1, detail);
    }

    /* --- LibThreading::ThreadPool / the transport receive thread --- */
    pthread_t th;
    int trc = pthread_create(&th, NULL, noop_thread, NULL);
    snprintf(detail, sizeof(detail), "%s", trc == 0 ? "" : strerror(trc));
    ok("pthread_create", trc == 0, detail);
    if (trc == 0) pthread_join(th, NULL);

    /* Control: the two things we already know the profile takes away. */
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    ok("socket(AF_UNIX) [expected DENIED confined]", s >= 0, s >= 0 ? "" : strerror(errno));
    if (s >= 0) close(s);

    int s4 = socket(AF_INET, SOCK_STREAM, 0);
    ok("socket(AF_INET)  [network]", s4 >= 0, s4 >= 0 ? "" : strerror(errno));
    if (s4 >= 0) close(s4);

    int wfd = open("/var/jb/tmp/sbprobe2.test", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    ok("write /var/jb/tmp", wfd >= 0, wfd >= 0 ? "" : strerror(errno));
    if (wfd >= 0) { close(wfd); unlink("/var/jb/tmp/sbprobe2.test"); }

    int rfd = open("/var/jb/usr/lib/libz.1.dylib", O_RDONLY);
    ok("read a /var/jb dylib [must stay OK]", rfd >= 0, rfd >= 0 ? "" : strerror(errno));
    if (rfd >= 0) close(rfd);

    printf("[sbprobe2] failures=%d\n", failures);
    return 0;
}
