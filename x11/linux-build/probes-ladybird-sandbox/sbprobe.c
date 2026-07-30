/*
 * sbprobe — does the com.apple.WebKit.WebContent named profile survive the Mach
 * bootstrap handshake Ladybird's helpers actually use?
 *
 * The ios-platform-features.md matrix measured socket()/write()/kill(). It did NOT
 * measure bootstrap_look_up(), which is how a Ladybird helper gets its IPC channel
 * (Services/WebContent/main.cpp: look_up_from_bootstrap_server(mach_server_name)).
 * That lookup happens AFTER apply_sandbox() upstream, so it is load-bearing.
 *
 * Roles:
 *   parent <mode>   registers a custom bootstrap service, spawns self as child
 *   child <name> <mode>
 *       mode=none    look up, no confinement            (baseline)
 *       mode=before  confine, THEN look up              (upstream call-site order)
 *       mode=after   look up, THEN confine, then use it (proposed call site)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <spawn.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <mach/mach.h>

extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_register(mach_port_t bp, const char *service_name, mach_port_t sp);
extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);
extern int sandbox_init_with_parameters(const char *profile, uint64_t flags,
                                        const char *const parameters[], char **errorbuf);

#define SANDBOX_NAMED 0x1ULL

static int confine(void)
{
    char *err = NULL;
    int rc = sandbox_init_with_parameters("com.apple.WebKit.WebContent", SANDBOX_NAMED, NULL, &err);
    printf("  confine: rc=%d err=%s\n", rc, err ? err : "(none)");
    fflush(stdout);
    return rc;
}

/* A single one-way message on a send right we already hold. */
static void try_send(mach_port_t port)
{
    typedef struct { mach_msg_header_t hdr; } msg_t;
    msg_t m;
    memset(&m, 0, sizeof(m));
    m.hdr.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    m.hdr.msgh_size = sizeof(m);
    m.hdr.msgh_remote_port = port;
    m.hdr.msgh_local_port = MACH_PORT_NULL;
    m.hdr.msgh_id = 0x41;
    kern_return_t kr = mach_msg(&m.hdr, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(m), 0,
                                MACH_PORT_NULL, 500, MACH_PORT_NULL);
    printf("  mach_msg send on held port: kr=0x%x (%s)\n", kr,
           kr == KERN_SUCCESS ? "OK" : mach_error_string(kr));
    fflush(stdout);
}

static void try_writes(void)
{
    /* The two writes WebContent actually performs on this port: the Skia shader
     * cache under LADYBIRD_CACHE_DIR, and anything under /var/jb/tmp. */
    const char *paths[] = { "/var/jb/lib/ladybird/sbprobe.test", "/var/jb/tmp/sbprobe.test" };
    for (int i = 0; i < 2; i++) {
        int fd = open(paths[i], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        printf("  write %-34s %s\n", paths[i],
               fd >= 0 ? "OK" : strerror(errno));
        if (fd >= 0) { close(fd); unlink(paths[i]); }
    }
    /* mkdir is what Core::Directory::create does for the cache dir. */
    int mk = mkdir("/var/jb/lib/ladybird/sbprobe.d", 0755);
    printf("  mkdir /var/jb/lib/ladybird/sbprobe.d   %s\n", mk == 0 ? "OK" : strerror(errno));
    if (mk == 0) rmdir("/var/jb/lib/ladybird/sbprobe.d");
    fflush(stdout);
}

static int do_child(const char *name, const char *mode)
{
    printf("[child pid=%d mode=%s]\n", getpid(), mode);
    fflush(stdout);

    if (!strcmp(mode, "before"))
        confine();

    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, name, &port);
    printf("  bootstrap_look_up(%s): kr=0x%x (%s) port=0x%x\n", name, kr,
           kr == KERN_SUCCESS ? "OK" : mach_error_string(kr), port);
    fflush(stdout);

    if (!strcmp(mode, "after")) {
        confine();
        if (kr == KERN_SUCCESS)
            try_send(port);
    } else if (kr == KERN_SUCCESS) {
        try_send(port);
    }

    try_writes();
    return kr == KERN_SUCCESS ? 0 : 1;
}

static int do_parent(const char *self, const char *mode)
{
    char name[128];
    snprintf(name, sizeof(name), "com.max.sbprobe.%d", getpid());

    mach_port_t recv = MACH_PORT_NULL;
    kern_return_t kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &recv);
    if (kr != KERN_SUCCESS) { printf("parent: mach_port_allocate failed 0x%x\n", kr); return 2; }
    kr = mach_port_insert_right(mach_task_self(), recv, recv, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) { printf("parent: insert_right failed 0x%x\n", kr); return 2; }

    kr = bootstrap_register(bootstrap_port, name, recv);
    printf("[parent pid=%d] bootstrap_register(%s): kr=0x%x (%s)\n", getpid(), name, kr,
           kr == KERN_SUCCESS ? "OK" : mach_error_string(kr));
    fflush(stdout);
    if (kr != KERN_SUCCESS) return 2;

    char *argv[] = { (char *)self, (char *)"child", name, (char *)mode, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, self, NULL, NULL, argv, NULL);
    if (rc != 0) { printf("parent: posix_spawn failed %s\n", strerror(rc)); return 2; }
    int status = 0;
    waitpid(pid, &status, 0);
    printf("[parent] child exited status=%d\n", WEXITSTATUS(status));
    return WEXITSTATUS(status);
}

int main(int argc, char **argv)
{
    if (argc >= 4 && !strcmp(argv[1], "child"))
        return do_child(argv[2], argv[3]);
    if (argc >= 3 && !strcmp(argv[1], "parent"))
        return do_parent(argv[0], argv[2]);
    fprintf(stderr, "usage: %s parent <none|before|after>\n", argv[0]);
    return 64;
}
