#include "xios_audio_client.h"
#include "xios_audio_protocol.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static void usage(void) {
    fprintf(stderr,
            "usage: xios-audio-play [--socket PATH] [--seconds N] [--freq HZ]\n"
            "       Generates a stereo 48 kHz sine wave for smoke testing.\n");
}

int main(int argc, char **argv) {
    const char *sock = getenv("XIOS_AUDIO_SERVER");
    double seconds = 2.0;
    double freq = 440.0;
    if (!sock || !sock[0]) sock = XIOS_AUDIO_DEFAULT_SOCKET;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--socket") && i + 1 < argc) {
            sock = argv[++i];
        } else if (!strcmp(argv[i], "--seconds") && i + 1 < argc) {
            seconds = atof(argv[++i]);
        } else if (!strcmp(argv[i], "--freq") && i + 1 < argc) {
            freq = atof(argv[++i]);
        } else {
            usage();
            return 2;
        }
    }

    xios_audio_conn *conn = xios_audio_connect(sock, XIOS_AUDIO_DEFAULT_RATE,
                                               XIOS_AUDIO_DEFAULT_CHANNELS,
                                               XIOS_AUDIO_FMT_S16LE);
    if (!conn) {
        perror("xios-audio-play: connect");
        return 1;
    }

    const int rate = (int)XIOS_AUDIO_DEFAULT_RATE;
    const int chunk = 512;
    int total = (int)(seconds * rate);
    int16_t buf[chunk * 2];
    double phase = 0.0;
    double step = (2.0 * M_PI * freq) / rate;

    while (total > 0) {
        int frames = total > chunk ? chunk : total;
        for (int i = 0; i < frames; i++) {
            int16_t sample = (int16_t)(sin(phase) * 12000.0);
            phase += step;
            if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
            buf[i * 2] = sample;
            buf[i * 2 + 1] = sample;
        }
        if (xios_audio_write(conn, buf, (size_t)frames * 2 * sizeof(int16_t)) < 0) {
            perror("xios-audio-play: write");
            xios_audio_close(conn);
            return 1;
        }
        total -= frames;
        usleep((useconds_t)((frames * 1000000.0) / rate / 2.0));
    }

    xios_audio_drain(conn);
    usleep(200000);
    xios_audio_close(conn);
    return 0;
}

