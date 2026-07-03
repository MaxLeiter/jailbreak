#include "xios_media_protocol.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static void usage(void) {
    fprintf(stderr,
            "usage: xios-camera-dump [--socket PATH] [--out PATH]\n"
            "       Captures one BGRA camera frame and writes it as a PPM image.\n");
}

static int read_full(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

static int connect_unix(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof(addr.sun_path)) {
        errno = ENAMETOOLONG;
        close(fd);
        return -1;
    }
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int write_ppm(const char *path, const xios_media_video_frame *frame, const uint8_t *bgra) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    fprintf(f, "P6\n%u %u\n255\n", frame->width, frame->height);
    for (uint32_t y = 0; y < frame->height; y++) {
        const uint8_t *row = bgra + ((size_t)y * frame->stride);
        for (uint32_t x = 0; x < frame->width; x++) {
            const uint8_t *px = row + ((size_t)x * 4);
            uint8_t rgb[3] = { px[2], px[1], px[0] };
            fwrite(rgb, 1, sizeof(rgb), f);
        }
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv) {
    const char *sock = getenv("XIOS_MEDIA_VIDEO_SERVER");
    const char *out = "/tmp/xios-camera.ppm";
    if (!sock || !sock[0]) sock = XIOS_MEDIA_DEFAULT_VIDEO_SOCKET;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            sock = argv[++i];
        } else if (!strcmp(argv[i], "--out") && i + 1 < argc) {
            out = argv[++i];
        } else {
            usage();
            return 2;
        }
    }

    int fd = connect_unix(sock);
    if (fd < 0) {
        perror("xios-camera-dump: connect");
        return 1;
    }

    for (;;) {
        xios_media_msg msg;
        if (read_full(fd, &msg, sizeof(msg)) < 0) {
            perror("xios-camera-dump: read header");
            close(fd);
            return 1;
        }
        if (msg.magic != XIOS_MEDIA_MAGIC || msg.version != XIOS_MEDIA_VERSION) {
            fprintf(stderr, "xios-camera-dump: bad protocol header\n");
            close(fd);
            return 1;
        }
        if (msg.type != XIOS_MEDIA_MSG_VIDEO_FRAME) {
            uint8_t scratch[4096];
            uint32_t left = msg.size;
            while (left) {
                size_t n = left < sizeof(scratch) ? left : sizeof(scratch);
                if (read_full(fd, scratch, n) < 0) return 1;
                left -= (uint32_t)n;
            }
            continue;
        }
        if (msg.size < sizeof(xios_media_video_frame)) {
            fprintf(stderr, "xios-camera-dump: short video frame\n");
            close(fd);
            return 1;
        }

        xios_media_video_frame frame;
        if (read_full(fd, &frame, sizeof(frame)) < 0) {
            perror("xios-camera-dump: read frame");
            close(fd);
            return 1;
        }
        size_t payload_len = msg.size - sizeof(frame);
        uint8_t *payload = (uint8_t *)malloc(payload_len);
        if (!payload) {
            close(fd);
            return 1;
        }
        if (read_full(fd, payload, payload_len) < 0) {
            perror("xios-camera-dump: read payload");
            free(payload);
            close(fd);
            return 1;
        }

        if (frame.format != XIOS_MEDIA_VIDEO_FMT_BGRA32 ||
            payload_len < (size_t)frame.stride * frame.height) {
            fprintf(stderr, "xios-camera-dump: unsupported frame format\n");
            free(payload);
            close(fd);
            return 1;
        }

        if (write_ppm(out, &frame, payload) < 0) {
            perror("xios-camera-dump: write ppm");
            free(payload);
            close(fd);
            return 1;
        }
        fprintf(stderr, "xios-camera-dump: wrote %ux%u frame %u to %s\n",
                frame.width, frame.height, frame.frame_index, out);
        free(payload);
        close(fd);
        return 0;
    }
}
