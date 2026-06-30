/*
 * ABI smoke test for the libpulse-simple shim: a client that knows ONLY the
 * public pulse headers and links -lpulse-simple, exactly as a real desktop app
 * would. Plays a short sine via pa_simple_write() to prove the shim's symbols
 * resolve and route into xios-audiod. Not shipped; built ad hoc.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <pulse/error.h>
#include <pulse/sample.h>
#include <pulse/simple.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

int main(int argc, char **argv) {
    double seconds = argc > 1 ? atof(argv[1]) : 2.0;
    double freq = argc > 2 ? atof(argv[2]) : 523.25; /* C5 */

    pa_sample_spec ss;
    ss.format = PA_SAMPLE_S16LE;
    ss.rate = 48000;
    ss.channels = 2;

    int err = 0;
    pa_simple *s = pa_simple_new(NULL, "pulse-shim-test", PA_STREAM_PLAYBACK,
                                 NULL, "tone", &ss, NULL, NULL, &err);
    if (!s) {
        fprintf(stderr, "pa_simple_new failed: %s\n", pa_strerror(err));
        return 1;
    }

    const int rate = 48000, chunk = 512;
    int total = (int)(seconds * rate);
    int16_t buf[chunk * 2];
    double phase = 0.0, step = (2.0 * M_PI * freq) / rate;

    while (total > 0) {
        int frames = total > chunk ? chunk : total;
        for (int i = 0; i < frames; i++) {
            int16_t v = (int16_t)(sin(phase) * 12000.0);
            phase += step;
            if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
            buf[i * 2] = v;
            buf[i * 2 + 1] = v;
        }
        if (pa_simple_write(s, buf, (size_t)frames * 2 * sizeof(int16_t), &err) < 0) {
            fprintf(stderr, "pa_simple_write failed: %s\n", pa_strerror(err));
            pa_simple_free(s);
            return 1;
        }
        total -= frames;
    }

    if (pa_simple_drain(s, &err) < 0)
        fprintf(stderr, "pa_simple_drain failed: %s\n", pa_strerror(err));
    pa_simple_free(s);
    fprintf(stderr, "pulse-shim-test: ok\n");
    return 0;
}
