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
            "usage: xios-mic-dump [--socket PATH] [--out PATH] [--seconds N]\n"
            "       Captures raw mono f32le microphone PCM.\n");
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

int main(int argc, char **argv) {
    const char *sock = getenv("XIOS_MEDIA_MIC_SERVER");
    const char *out = "/tmp/xios-mic.f32";
    double seconds = 2.0;
    if (!sock || !sock[0]) sock = XIOS_MEDIA_DEFAULT_MIC_SOCKET;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            sock = argv[++i];
        } else if (!strcmp(argv[i], "--out") && i + 1 < argc) {
            out = argv[++i];
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            seconds = atof(argv[++i]);
        } else {
            usage();
            return 2;
        }
    }

    int fd = connect_unix(sock);
    if (fd < 0) {
        perror("xios-mic-dump: connect");
        return 1;
    }

    FILE *f = fopen(out, "wb");
    if (!f) {
        perror("xios-mic-dump: fopen");
        close(fd);
        return 1;
    }

    uint64_t target_frames = (uint64_t)(seconds * XIOS_MEDIA_DEFAULT_AUDIO_RATE);
    uint64_t got_frames = 0;
    while (got_frames < target_frames) {
        xios_media_msg msg;
        if (read_full(fd, &msg, sizeof(msg)) < 0) {
            perror("xios-mic-dump: read header");
            fclose(f);
            close(fd);
            return 1;
        }
        if (msg.magic != XIOS_MEDIA_MAGIC || msg.version != XIOS_MEDIA_VERSION) {
            fprintf(stderr, "xios-mic-dump: bad protocol header\n");
            fclose(f);
            close(fd);
            return 1;
        }
        if (msg.type != XIOS_MEDIA_MSG_MIC_FRAME) {
            uint8_t scratch[4096];
            uint32_t left = msg.size;
            while (left) {
                size_t n = left < sizeof(scratch) ? left : sizeof(scratch);
                if (read_full(fd, scratch, n) < 0) return 1;
                left -= (uint32_t)n;
            }
            continue;
        }
        if (msg.size < sizeof(xios_media_mic_frame)) {
            fprintf(stderr, "xios-mic-dump: short mic frame\n");
            fclose(f);
            close(fd);
            return 1;
        }

        xios_media_mic_frame frame;
        if (read_full(fd, &frame, sizeof(frame)) < 0) {
            perror("xios-mic-dump: read frame");
            fclose(f);
            close(fd);
            return 1;
        }
        size_t payload_len = msg.size - sizeof(frame);
        uint8_t *payload = (uint8_t *)malloc(payload_len);
        if (!payload) {
            fclose(f);
            close(fd);
            return 1;
        }
        if (read_full(fd, payload, payload_len) < 0) {
            perror("xios-mic-dump: read payload");
            free(payload);
            fclose(f);
            close(fd);
            return 1;
        }
        if (frame.format != XIOS_MEDIA_AUDIO_FMT_F32LE ||
            frame.channels != XIOS_MEDIA_DEFAULT_AUDIO_CHANNELS) {
            fprintf(stderr, "xios-mic-dump: unsupported mic format\n");
            free(payload);
            fclose(f);
            close(fd);
            return 1;
        }

        fwrite(payload, 1, payload_len, f);
        got_frames += frame.frames;
        free(payload);
    }

    fclose(f);
    close(fd);
    fprintf(stderr, "xios-mic-dump: wrote %.2f seconds of f32le mono PCM to %s\n",
            (double)got_frames / XIOS_MEDIA_DEFAULT_AUDIO_RATE, out);
    return 0;
}
