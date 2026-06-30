#include "xios_audio_client.h"
#include "xios_audio_protocol.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

struct xios_audio_conn {
    int fd;
};

static int write_all(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static int send_msg(int fd, uint32_t type, const void *payload, uint32_t size) {
    xios_audio_msg msg;
    msg.magic = XIOS_AUDIO_MAGIC;
    msg.version = XIOS_AUDIO_VERSION;
    msg.type = type;
    msg.size = size;
    if (write_all(fd, &msg, sizeof(msg)) < 0) return -1;
    if (size && write_all(fd, payload, size) < 0) return -1;
    return 0;
}

xios_audio_conn *xios_audio_connect(const char *path, uint32_t rate,
                                    uint32_t channels, uint32_t format) {
    if (!path || !path[0]) path = XIOS_AUDIO_DEFAULT_SOCKET;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NULL;

    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(sun.sun_path)) {
        close(fd);
        errno = ENAMETOOLONG;
        return NULL;
    }
    strcpy(sun.sun_path, path);
    if (connect(fd, (struct sockaddr *)&sun, sizeof(sun)) < 0) {
        close(fd);
        return NULL;
    }

    xios_audio_open open_msg;
    open_msg.sample_rate = rate ? rate : XIOS_AUDIO_DEFAULT_RATE;
    open_msg.channels = channels ? channels : XIOS_AUDIO_DEFAULT_CHANNELS;
    open_msg.format = format ? format : XIOS_AUDIO_FMT_S16LE;
    open_msg.flags = 0;
    if (send_msg(fd, XIOS_AUDIO_MSG_OPEN, &open_msg, sizeof(open_msg)) < 0) {
        close(fd);
        return NULL;
    }

    xios_audio_conn *conn = (xios_audio_conn *)calloc(1, sizeof(*conn));
    if (!conn) {
        close(fd);
        return NULL;
    }
    conn->fd = fd;
    return conn;
}

int xios_audio_write(xios_audio_conn *conn, const void *data, size_t bytes) {
    if (!conn || conn->fd < 0 || (!data && bytes)) {
        errno = EINVAL;
        return -1;
    }
    while (bytes) {
        uint32_t chunk = bytes > 65536 ? 65536u : (uint32_t)bytes;
        if (send_msg(conn->fd, XIOS_AUDIO_MSG_DATA, data, chunk) < 0) return -1;
        data = (const char *)data + chunk;
        bytes -= chunk;
    }
    return 0;
}

int xios_audio_drain(xios_audio_conn *conn) {
    if (!conn || conn->fd < 0) {
        errno = EINVAL;
        return -1;
    }
    return send_msg(conn->fd, XIOS_AUDIO_MSG_DRAIN, NULL, 0);
}

void xios_audio_close(xios_audio_conn *conn) {
    if (!conn) return;
    if (conn->fd >= 0) {
        (void)send_msg(conn->fd, XIOS_AUDIO_MSG_CLOSE, NULL, 0);
        close(conn->fd);
    }
    free(conn);
}

