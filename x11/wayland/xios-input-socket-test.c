/*
 * Host test for xios_input_socket.c (the shared iosc / MetaBackendIOS input
 * reader). Runs on the build Mac: the reader only needs AF_UNIX + kqueue.
 */
#include "xios_input_socket.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define check(cond) do { if (!(cond)) { \
    fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond); \
    exit(1); } } while (0)

static void nap(void)
{
    struct timespec ts = { 0, 2 * 1000 * 1000 };
    nanosleep(&ts, NULL);
}

static int connect_client(const char *path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    check(fd >= 0);
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    struct sockaddr_un a;
    memset(&a, 0, sizeof(a));
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof(a.sun_path), "%s", path);
    check(connect(fd, (struct sockaddr *)&a, sizeof(a)) == 0);
    xios_msg hello = xios_protocol_hello();
    check(write(fd, &hello, sizeof(hello)) == (ssize_t)sizeof(hello));
    return fd;
}

/* Pump the reader until `want` clients have completed HELLO. */
static void pump_until_clients(xios_input_socket *s, int want)
{
    for (int i = 0; i < 500 && xios_input_socket_client_count(s) != want; i++) {
        check(xios_input_socket_dispatch(s, NULL, NULL) >= 0);
        nap();
    }
    check(xios_input_socket_client_count(s) == want);
}

static void read_exact(int fd, void *buf, size_t len)
{
    size_t have = 0;
    while (have < len) {
        ssize_t r = read(fd, (char *)buf + have, len - have);
        check(r > 0);
        have += (size_t)r;
    }
}

static xios_msg traits(int seq)
{
    return xios_input_message(XIOS_IN_TRAITS, seq, 0, 0, 0, 0);
}

/* A peer that stops reading (a suspended app) must keep its connection and get
 * every record, in order, once it drains; one that never drains is cut loose. */
static void test_full_peer_is_queued(xios_input_socket *s, const char *path)
{
    int fd = connect_client(path);
    pump_until_clients(s, 1);
    xios_msg m;
    read_exact(fd, &m, sizeof(m));
    check(xios_protocol_is_exact_hello(&m));

    /* Well past the kernel's AF_UNIX buffers, well under the 64 KiB queue. */
    enum { N = 1500 };
    for (int i = 0; i < N; i++) {
        xios_msg t = traits(i);
        check(xios_input_socket_broadcast(s, &t, sizeof(t)) == 1);
    }

    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    int got = 0, spins = 0;
    uint8_t part[sizeof(xios_msg)];
    size_t part_have = 0;
    while (got < N && spins < 5000) {
        ssize_t r = read(fd, part + part_have, sizeof(part) - part_have);
        if (r > 0) {
            part_have += (size_t)r;
            if (part_have == sizeof(part)) {
                memcpy(&m, part, sizeof(m));
                part_have = 0;
                check(m.magic == XIOS_MSG_MAGIC && m.type == XIOS_IN_TRAITS);
                check(m.a == got);
                got++;
            }
            continue;
        }
        check(r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
        check(xios_input_socket_dispatch(s, NULL, NULL) >= 0);   /* flush the queue */
        spins++;
    }
    check(got == N);
    check(xios_input_socket_client_count(s) == 1);
    close(fd);
    pump_until_clients(s, 0);

    /* Never reads at all: the queue bound turns it into a dropped peer. */
    fd = connect_client(path);
    pump_until_clients(s, 1);
    int refused = 0;
    for (int i = 0; i < 8192 && !refused; i++) {
        xios_msg t = traits(i);
        refused = xios_input_socket_broadcast(s, &t, sizeof(t)) == 0;
    }
    check(refused);
    pump_until_clients(s, 0);
    close(fd);
}

int main(void)
{
    const char *tmp = getenv("TMPDIR");
    char dir[256];
    snprintf(dir, sizeof(dir), "%s/xist.XXXXXX", tmp && *tmp ? tmp : "/tmp");
    check(mkdtemp(dir) != NULL);
    char path[300];
    snprintf(path, sizeof(path), "%s/in.sock", dir);
    check(strlen(path) < sizeof(((struct sockaddr_un *)0)->sun_path));

    xios_input_socket *s = xios_input_socket_new(path);
    check(s != NULL);

    test_full_peer_is_queued(s, path);

    xios_input_socket_free(s);
    rmdir(dir);
    puts("xios input-socket tests passed");
    return 0;
}
